// Bounded one-shot QuickJS host bridge. See include/CQuickJS.h.
//
// Safety model:
//  * Every call builds a fresh runtime + context on the calling thread; nothing is shared.
//  * Memory limit, stack limit and interrupt handler are installed before any untrusted byte is
//    parsed or evaluated. The handler enforces a monotonic deadline and an atomic cancel flag; the
//    engine polls it from the bytecode loop and from the regexp matcher.
//  * Only a minimal set of intrinsics exists: no TypedArrays/SharedArrayBuffer/Atomics, no module
//    loader, no quickjs-libc, no timers. Promise jobs are never drained.
//  * The handler result is never touched through JS-visible semantics. Validation and serialization
//    use own-property descriptors only (no getters, no toJSON, no Proxy traps, no toString) and
//    accept only plain objects/arrays whose class ids were captured from fresh pristine values
//    before user code ran.
//  * Exceptions are classified by native flags (stop reason, allocator failure) or by reading the
//    own data `message` of an Error object; arbitrary toString/valueOf is never invoked.

#include "CQuickJS.h"
#include "Vendor/quickjs.h"

#include <math.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if defined(__APPLE__)
#include <malloc/malloc.h>
#else
#include <malloc.h>
#endif

// MARK: cancel token

struct QJSCancelToken {
    atomic_int cancelled;
};

QJSCancelToken *qjs_cancel_token_new(void) {
    QJSCancelToken *t = calloc(1, sizeof(*t));
    if (t) atomic_init(&t->cancelled, 0);
    return t;
}

void qjs_cancel_token_cancel(QJSCancelToken *token) {
    if (token) atomic_store_explicit(&token->cancelled, 1, memory_order_release);
}

void qjs_cancel_token_free(QJSCancelToken *token) {
    free(token);
}

// MARK: run state, budget

typedef struct RunState {
    QJSCancelToken *token;
    uint64_t deadline_ns;
    int stop;   // 0, QJS_TIMEOUT or QJS_CANCELLED; sticky once set
    int oom;    // allocator refused (limit or malloc failure)
    JSClassID cls_object;
    JSClassID cls_array;
} RunState;

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}

static int budget_exceeded(RunState *st) {
    if (st->stop) return 1;
    if (st->token && atomic_load_explicit(&st->token->cancelled, memory_order_acquire)) {
        st->stop = QJS_CANCELLED;
        return 1;
    }
    if (now_ns() >= st->deadline_ns) {
        st->stop = QJS_TIMEOUT;
        return 1;
    }
    return 0;
}

static int interrupt_cb(JSRuntime *rt, void *opaque) {
    (void)rt;
    return budget_exceeded((RunState *)opaque);
}

// MARK: limited allocator (mirrors the engine's default one, plus an OOM flag)

#define ALLOC_OVERHEAD 8

static size_t usable_size(const void *p) {
#if defined(__APPLE__)
    return malloc_size(p);
#else
    return malloc_usable_size((void *)p);
#endif
}

static void *limited_malloc(JSMallocState *s, size_t size) {
    RunState *st = (RunState *)s->opaque;
    if (size == 0) size = 1;
    if (s->malloc_size + size > s->malloc_limit) {
        if (st) st->oom = 1;
        return NULL;
    }
    void *p = malloc(size);
    if (!p) {
        if (st) st->oom = 1;
        return NULL;
    }
    s->malloc_count++;
    s->malloc_size += usable_size(p) + ALLOC_OVERHEAD;
    return p;
}

static void limited_free(JSMallocState *s, void *p) {
    if (!p) return;
    s->malloc_count--;
    s->malloc_size -= usable_size(p) + ALLOC_OVERHEAD;
    free(p);
}

static void *limited_realloc(JSMallocState *s, void *p, size_t size) {
    RunState *st = (RunState *)s->opaque;
    if (!p) {
        if (size == 0) return NULL;
        return limited_malloc(s, size);
    }
    size_t old = usable_size(p);
    if (size == 0) {
        s->malloc_count--;
        s->malloc_size -= old + ALLOC_OVERHEAD;
        free(p);
        return NULL;
    }
    if (s->malloc_size + size - old > s->malloc_limit) {
        if (st) st->oom = 1;
        return NULL;
    }
    void *q = realloc(p, size);
    if (!q) {
        if (st) st->oom = 1;
        return NULL;
    }
    s->malloc_size += usable_size(q) - old;
    return q;
}

static const JSMallocFunctions limited_funcs = {
    limited_malloc, limited_free, limited_realloc, usable_size,
};

// MARK: UTF-8

// Length of the strictly valid UTF-8 sequence at p (1...4) or 0 if invalid/truncated.
static size_t utf8_seq(const uint8_t *p, size_t avail) {
    uint8_t c = p[0];
    size_t need;
    uint32_t cp;
    if (c < 0x80) return 1;
    if (c >= 0xC2 && c <= 0xDF) { need = 1; cp = c & 0x1F; }
    else if ((c & 0xF0) == 0xE0) { need = 2; cp = c & 0x0F; }
    else if (c >= 0xF0 && c <= 0xF4) { need = 3; cp = c & 0x07; }
    else return 0;
    if (avail <= need) return 0;
    for (size_t k = 1; k <= need; k++) {
        if ((p[k] & 0xC0) != 0x80) return 0;
        cp = (cp << 6) | (p[k] & 0x3F);
    }
    if (need == 2 && (cp < 0x800 || (cp >= 0xD800 && cp <= 0xDFFF))) return 0;
    if (need == 3 && (cp < 0x10000 || cp > 0x10FFFF)) return 0;
    return need + 1;
}

static int utf8_valid(const uint8_t *p, size_t n) {
    size_t i = 0;
    while (i < n) {
        size_t k = utf8_seq(p + i, n - i);
        if (k == 0) return 0;
        i += k;
    }
    return 1;
}

// MARK: strict JSON scanner (input validation and output re-check)
//
// Rejects: duplicate keys (also escape-equivalent), lone/invalid surrogates, invalid UTF-8, control
// characters in strings, BOM/leading garbage, trailing input, non-finite numbers, depth > max_depth.

typedef struct { uint32_t off, len, hash; } KeyRec;
typedef struct {
    KeyRec *recs;
    size_t n, cap;
    uint32_t *slots;   // index+1, 0 = empty
    size_t slot_cap;   // power of two
} KeySet;

typedef struct {
    const uint8_t *p, *end;
    uint8_t *arena;    // decoded keys; decoded length never exceeds raw length, so input_len suffices
    size_t arena_used;
    int max_depth;
} Scan;

static uint32_t fnv1a(const uint8_t *p, size_t n) {
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < n; i++) { h ^= p[i]; h *= 16777619u; }
    return h;
}

static int keyset_grow_slots(KeySet *ks) {
    size_t cap = ks->slot_cap ? ks->slot_cap * 2 : 16;
    uint32_t *slots = calloc(cap, sizeof(uint32_t));
    if (!slots) return 0;
    for (size_t i = 0; i < ks->n; i++) {
        size_t j = ks->recs[i].hash & (cap - 1);
        while (slots[j]) j = (j + 1) & (cap - 1);
        slots[j] = (uint32_t)(i + 1);
    }
    free(ks->slots);
    ks->slots = slots;
    ks->slot_cap = cap;
    return 1;
}

// 1 = added, 0 = duplicate, -1 = out of memory
static int keyset_add(Scan *s, KeySet *ks, uint32_t off, uint32_t len) {
    uint32_t h = fnv1a(s->arena + off, len);
    if ((ks->n + 1) * 2 > ks->slot_cap && !keyset_grow_slots(ks)) return -1;
    size_t j = h & (ks->slot_cap - 1);
    while (ks->slots[j]) {
        KeyRec *r = &ks->recs[ks->slots[j] - 1];
        if (r->hash == h && r->len == len && memcmp(s->arena + r->off, s->arena + off, len) == 0) return 0;
        j = (j + 1) & (ks->slot_cap - 1);
    }
    if (ks->n == ks->cap) {
        size_t cap = ks->cap ? ks->cap * 2 : 8;
        KeyRec *recs = realloc(ks->recs, cap * sizeof(KeyRec));
        if (!recs) return -1;
        ks->recs = recs;
        ks->cap = cap;
    }
    ks->recs[ks->n] = (KeyRec){off, len, h};
    ks->n++;
    ks->slots[j] = (uint32_t)ks->n;
    return 1;
}

static void keyset_free(KeySet *ks) {
    free(ks->recs);
    free(ks->slots);
    memset(ks, 0, sizeof(*ks));
}

static void skip_ws(Scan *s) {
    while (s->p < s->end && (*s->p == ' ' || *s->p == '\t' || *s->p == '\n' || *s->p == '\r')) s->p++;
}

static int hexval(int c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static int read_hex4(Scan *s, uint32_t *out) {
    if (s->end - s->p < 4) return 0;
    uint32_t v = 0;
    for (int i = 0; i < 4; i++) {
        int h = hexval(s->p[i]);
        if (h < 0) return 0;
        v = (v << 4) | (uint32_t)h;
    }
    s->p += 4;
    *out = v;
    return 1;
}

static void arena_put_utf8(Scan *s, uint32_t cp) {
    uint8_t *q = s->arena + s->arena_used;
    if (cp < 0x80) { *q++ = (uint8_t)cp; }
    else if (cp < 0x800) { *q++ = (uint8_t)(0xC0 | (cp >> 6)); *q++ = (uint8_t)(0x80 | (cp & 0x3F)); }
    else if (cp < 0x10000) {
        *q++ = (uint8_t)(0xE0 | (cp >> 12)); *q++ = (uint8_t)(0x80 | ((cp >> 6) & 0x3F)); *q++ = (uint8_t)(0x80 | (cp & 0x3F));
    } else {
        *q++ = (uint8_t)(0xF0 | (cp >> 18)); *q++ = (uint8_t)(0x80 | ((cp >> 12) & 0x3F));
        *q++ = (uint8_t)(0x80 | ((cp >> 6) & 0x3F)); *q++ = (uint8_t)(0x80 | (cp & 0x3F));
    }
    s->arena_used = (size_t)(q - s->arena);
}

// s->p at the opening quote. When want_key, the decoded bytes are appended to the arena.
static int scan_string(Scan *s, int want_key, uint32_t *off, uint32_t *len) {
    size_t start = s->arena_used;
    s->p++;
    for (;;) {
        if (s->p >= s->end) return 0;
        uint8_t c = *s->p;
        if (c == '"') { s->p++; break; }
        if (c < 0x20) return 0;
        if (c == '\\') {
            s->p++;
            if (s->p >= s->end) return 0;
            uint8_t e = *s->p++;
            uint32_t cp = 0;
            switch (e) {
                case '"': cp = '"'; break;
                case '\\': cp = '\\'; break;
                case '/': cp = '/'; break;
                case 'b': cp = 8; break;
                case 'f': cp = 12; break;
                case 'n': cp = 10; break;
                case 'r': cp = 13; break;
                case 't': cp = 9; break;
                case 'u':
                    if (!read_hex4(s, &cp)) return 0;
                    if (cp >= 0xD800 && cp <= 0xDBFF) {
                        uint32_t lo;
                        if (s->end - s->p < 2 || s->p[0] != '\\' || s->p[1] != 'u') return 0;
                        s->p += 2;
                        if (!read_hex4(s, &lo) || lo < 0xDC00 || lo > 0xDFFF) return 0;
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                    } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                        return 0;
                    }
                    break;
                default: return 0;
            }
            if (want_key) arena_put_utf8(s, cp);
        } else if (c < 0x80) {
            if (want_key) s->arena[s->arena_used++] = c;
            s->p++;
        } else {
            size_t n = utf8_seq(s->p, (size_t)(s->end - s->p));
            if (n == 0) return 0;
            if (want_key) { memcpy(s->arena + s->arena_used, s->p, n); s->arena_used += n; }
            s->p += n;
        }
    }
    if (want_key) { *off = (uint32_t)start; *len = (uint32_t)(s->arena_used - start); }
    return 1;
}

static int is_digit(const uint8_t *p, const uint8_t *end) { return p < end && *p >= '0' && *p <= '9'; }

// The scanned buffer must be NUL-terminated (strtod).
static int scan_number(Scan *s) {
    const uint8_t *q = s->p;
    if (*q == '-') q++;
    if (q >= s->end) return 0;
    if (*q == '0') q++;
    else if (*q >= '1' && *q <= '9') { while (is_digit(q, s->end)) q++; }
    else return 0;
    if (q < s->end && *q == '.') {
        q++;
        if (!is_digit(q, s->end)) return 0;
        while (is_digit(q, s->end)) q++;
    }
    if (q < s->end && (*q == 'e' || *q == 'E')) {
        q++;
        if (q < s->end && (*q == '+' || *q == '-')) q++;
        if (!is_digit(q, s->end)) return 0;
        while (is_digit(q, s->end)) q++;
    }
    if (isinf(strtod((const char *)s->p, NULL))) return 0;
    s->p = q;
    return 1;
}

static int scan_literal(Scan *s, const char *lit) {
    size_t n = strlen(lit);
    if ((size_t)(s->end - s->p) < n || memcmp(s->p, lit, n) != 0) return 0;
    s->p += n;
    return 1;
}

static int scan_value(Scan *s, int depth) {
    skip_ws(s);
    if (s->p >= s->end) return 0;
    switch (*s->p) {
        case '{': {
            if (depth + 1 > s->max_depth) return 0;
            s->p++;
            skip_ws(s);
            if (s->p < s->end && *s->p == '}') { s->p++; return 1; }
            KeySet ks;
            memset(&ks, 0, sizeof(ks));
            int ok = 0;
            for (;;) {
                uint32_t off, len;
                skip_ws(s);
                if (s->p >= s->end || *s->p != '"') break;
                if (!scan_string(s, 1, &off, &len)) break;
                if (keyset_add(s, &ks, off, len) != 1) break;
                skip_ws(s);
                if (s->p >= s->end || *s->p != ':') break;
                s->p++;
                if (!scan_value(s, depth + 1)) break;
                skip_ws(s);
                if (s->p >= s->end) break;
                if (*s->p == ',') { s->p++; continue; }
                if (*s->p == '}') { s->p++; ok = 1; }
                break;
            }
            keyset_free(&ks);
            return ok;
        }
        case '[': {
            if (depth + 1 > s->max_depth) return 0;
            s->p++;
            skip_ws(s);
            if (s->p < s->end && *s->p == ']') { s->p++; return 1; }
            for (;;) {
                if (!scan_value(s, depth + 1)) return 0;
                skip_ws(s);
                if (s->p >= s->end) return 0;
                if (*s->p == ',') { s->p++; continue; }
                if (*s->p == ']') { s->p++; return 1; }
                return 0;
            }
        }
        case '"': return scan_string(s, 0, NULL, NULL);
        case 't': return scan_literal(s, "true");
        case 'f': return scan_literal(s, "false");
        case 'n': return scan_literal(s, "null");
        default: return scan_number(s);
    }
}

// `z` must be NUL-terminated at z[len].
static int json_check(const uint8_t *z, size_t len, int max_depth) {
    Scan s;
    s.p = z;
    s.end = z + len;
    s.arena = malloc(len + 1);
    s.arena_used = 0;
    s.max_depth = max_depth;
    if (!s.arena) return 0;
    int ok = scan_value(&s, 0);
    if (ok) { skip_ws(&s); ok = (s.p == s.end); }
    free(s.arena);
    return ok;
}

static uint8_t *copy_z(const uint8_t *p, size_t n) {
    uint8_t *q = malloc(n + 1);
    if (!q) return NULL;
    if (n) memcpy(q, p, n);
    q[n] = 0;
    return q;
}

// MARK: bounded output buffer

typedef struct {
    uint8_t *p;
    size_t len, cap;
    int overflow;
} Buf;

static void b_put(Buf *b, const void *d, size_t n) {
    if (b->overflow) return;
    if (n > b->cap - b->len) { b->overflow = 1; return; }
    memcpy(b->p + b->len, d, n);
    b->len += n;
}
static void b_ch(Buf *b, char c) { b_put(b, &c, 1); }
static void b_str(Buf *b, const char *s) { b_put(b, s, strlen(s)); }

// MARK: native result validation + canonical serialization

typedef struct {
    JSContext *ctx;
    RunState *st;
    Buf out;
    int err;          // first failure status (QJS_INVALID_RESULT or a stop reason)
    unsigned nodes;
    int max_depth;
    size_t max_actions;
} V;

static int v_fail(V *v) {
    if (!v->err) v->err = QJS_INVALID_RESULT;
    return 0;
}

static int v_budget(V *v) {
    // A shared sub-DAG can expand exponentially; stop walking as soon as the byte cap is blown.
    if (v->out.overflow) return v_fail(v);
    if ((v->nodes++ & 31u) != 0) return 1;
    if (budget_exceeded(v->st)) { v->err = v->st->stop; return 0; }
    return 1;
}

static int emit_string(V *v, JSValueConst s) {
    size_t len;
    const char *c = JS_ToCStringLen2(v->ctx, &len, s, 0);
    if (!c) return v_fail(v);
    if (len > v->out.cap || !utf8_valid((const uint8_t *)c, len)) {
        JS_FreeCString(v->ctx, c);
        return v_fail(v);
    }
    b_ch(&v->out, '"');
    for (size_t i = 0; i < len && !v->out.overflow; i++) {
        uint8_t ch = (uint8_t)c[i];
        switch (ch) {
            case '"': b_str(&v->out, "\\\""); break;
            case '\\': b_str(&v->out, "\\\\"); break;
            case '\n': b_str(&v->out, "\\n"); break;
            case '\r': b_str(&v->out, "\\r"); break;
            case '\t': b_str(&v->out, "\\t"); break;
            case '\b': b_str(&v->out, "\\b"); break;
            case '\f': b_str(&v->out, "\\f"); break;
            default:
                if (ch < 0x20) {
                    char esc[8];
                    snprintf(esc, sizeof(esc), "\\u%04x", ch);
                    b_str(&v->out, esc);
                } else {
                    b_ch(&v->out, (char)ch);
                }
        }
    }
    b_ch(&v->out, '"');
    JS_FreeCString(v->ctx, c);
    return v->out.overflow ? v_fail(v) : 1;
}

static int emit_double(V *v, double d) {
    char buf[48];
    for (int prec = 15; prec <= 17; prec++) {
        snprintf(buf, sizeof(buf), "%.*g", prec, d);
        if (strtod(buf, NULL) == d) break;
    }
    for (char *q = buf; *q; q++) if (*q == ',') *q = '.';
    b_str(&v->out, buf);
    return 1;
}

// Data property (never an accessor) that is enumerable; takes ownership of *out.
static int desc_data(V *v, JSValueConst obj, JSAtom atom, JSValue *out) {
    JSPropertyDescriptor d;
    if (JS_GetOwnProperty(v->ctx, &d, obj, atom) <= 0) return 0;
    int ok = !(d.flags & JS_PROP_GETSET) && (d.flags & JS_PROP_ENUMERABLE);
    JS_FreeValue(v->ctx, d.getter);
    JS_FreeValue(v->ctx, d.setter);
    if (!ok) { JS_FreeValue(v->ctx, d.value); return 0; }
    *out = d.value;
    return 1;
}

// Validates `arr` is a plain dense array of enumerable own elements and no other enumerable
// properties (including symbols); returns its length.
static int array_prepare(V *v, JSValueConst arr, int32_t *n) {
    if (JS_GetClassID(arr) != v->st->cls_array) return 0;
    JSValue lv = JS_GetPropertyStr(v->ctx, arr, "length");
    if (JS_VALUE_GET_TAG(lv) != JS_TAG_INT) { JS_FreeValue(v->ctx, lv); return 0; }
    int32_t len = JS_VALUE_GET_INT(lv);
    if (len < 0 || (size_t)len > v->out.cap) return 0;
    JSPropertyEnum *tab;
    uint32_t cnt;
    if (JS_GetOwnPropertyNames(v->ctx, &tab, &cnt, arr,
                               JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK | JS_GPN_ENUM_ONLY) < 0) return 0;
    JS_FreePropertyEnum(v->ctx, tab, cnt);
    if (cnt != (uint32_t)len) return 0;
    *n = len;
    return 1;
}

static int array_get(V *v, JSValueConst arr, int32_t i, JSValue *out) {
    JSAtom a = JS_NewAtomUInt32(v->ctx, (uint32_t)i);
    if (a == JS_ATOM_NULL) return 0;
    int ok = desc_data(v, arr, a, out);
    JS_FreeAtom(v->ctx, a);
    return ok;
}

static int emit_value(V *v, JSValueConst val, int depth);

static int emit_array(V *v, JSValueConst arr, int depth) {
    int32_t n, i;
    if (!array_prepare(v, arr, &n)) return v_fail(v);
    b_ch(&v->out, '[');
    for (i = 0; i < n; i++) {
        JSValue el;
        if (!array_get(v, arr, i, &el)) return v_fail(v);
        if (i) b_ch(&v->out, ',');
        int ok = emit_value(v, el, depth + 1);
        JS_FreeValue(v->ctx, el);
        if (!ok) return 0;
    }
    b_ch(&v->out, ']');
    return v->out.overflow ? v_fail(v) : 1;
}

static int emit_object(V *v, JSValueConst obj, int depth) {
    JSPropertyEnum *tab = NULL;
    uint32_t cnt = 0, i;
    int got = 0, ok = 0;
    if (JS_GetOwnPropertyNames(v->ctx, &tab, &cnt, obj, JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK) < 0) goto done;
    got = 1;
    if (cnt > v->out.cap) goto done;
    b_ch(&v->out, '{');
    for (i = 0; i < cnt; i++) {
        JSValue key = JS_AtomToValue(v->ctx, tab[i].atom);
        if (!JS_IsString(key)) { JS_FreeValue(v->ctx, key); goto done; }   // symbol keys rejected
        if (i) b_ch(&v->out, ',');
        int kok = emit_string(v, key);
        JS_FreeValue(v->ctx, key);
        if (!kok) goto done;
        b_ch(&v->out, ':');
        JSValue val;
        if (!desc_data(v, obj, tab[i].atom, &val)) goto done;
        int vok = emit_value(v, val, depth + 1);
        JS_FreeValue(v->ctx, val);
        if (!vok) goto done;
    }
    b_ch(&v->out, '}');
    ok = !v->out.overflow;
done:
    if (got) JS_FreePropertyEnum(v->ctx, tab, cnt);
    return ok ? 1 : v_fail(v);
}

// `depth` is the container depth this value would occupy (root object = 1).
static int emit_value(V *v, JSValueConst val, int depth) {
    if (!v_budget(v)) return 0;
    switch (JS_VALUE_GET_NORM_TAG(val)) {
        case JS_TAG_NULL: b_str(&v->out, "null"); break;
        case JS_TAG_BOOL: b_str(&v->out, JS_VALUE_GET_BOOL(val) ? "true" : "false"); break;
        case JS_TAG_INT: {
            char num[16];
            snprintf(num, sizeof(num), "%d", (int)JS_VALUE_GET_INT(val));
            b_str(&v->out, num);
            break;
        }
        case JS_TAG_FLOAT64: {
            double d = JS_VALUE_GET_FLOAT64(val);
            if (!isfinite(d)) return v_fail(v);
            emit_double(v, d);
            break;
        }
        case JS_TAG_STRING:
        case JS_TAG_STRING_ROPE:
            if (!emit_string(v, val)) return 0;
            break;
        case JS_TAG_OBJECT: {
            if (depth > v->max_depth) return v_fail(v);
            JSClassID cid = JS_GetClassID(val);
            if (cid == v->st->cls_array) return emit_array(v, val, depth);
            if (cid == v->st->cls_object) return emit_object(v, val, depth);
            return v_fail(v);   // Proxy, Promise, function, Date, Map, Error, boxed primitives, ...
        }
        default:
            return v_fail(v);   // undefined, symbol, BigInt, exception markers
    }
    return v->out.overflow ? v_fail(v) : 1;
}

// obj must be a plain object whose own property names are exactly `keys` (all enumerable data).
static int exact_props(V *v, JSValueConst obj, const char *const *keys, uint32_t n, JSValue *out) {
    JSPropertyEnum *tab;
    uint32_t cnt, j;
    if (JS_GetClassID(obj) != v->st->cls_object) return 0;
    if (JS_GetOwnPropertyNames(v->ctx, &tab, &cnt, obj, JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK) < 0) return 0;
    JS_FreePropertyEnum(v->ctx, tab, cnt);
    if (cnt != n) return 0;
    for (j = 0; j < n; j++) {
        JSAtom a = JS_NewAtom(v->ctx, keys[j]);
        int ok = a != JS_ATOM_NULL && desc_data(v, obj, a, &out[j]);
        if (a != JS_ATOM_NULL) JS_FreeAtom(v->ctx, a);
        if (!ok) {
            while (j-- > 0) JS_FreeValue(v->ctx, out[j]);
            return 0;
        }
    }
    return 1;
}

static int string_equals(V *v, JSValueConst s, const char *lit) {
    if (!JS_IsString(s)) return 0;
    size_t n;
    const char *c = JS_ToCStringLen2(v->ctx, &n, s, 0);
    if (!c) return 0;
    int eq = n == strlen(lit) && memcmp(c, lit, n) == 0;
    JS_FreeCString(v->ctx, c);
    return eq;
}

static int emit_uuid(V *v, JSValueConst s) {
    if (!JS_IsString(s)) return 0;
    size_t n;
    const char *c = JS_ToCStringLen2(v->ctx, &n, s, 0);
    if (!c) return 0;
    int ok = n == 36;
    for (size_t i = 0; ok && i < 36; i++) {
        if (i == 8 || i == 13 || i == 18 || i == 23) ok = c[i] == '-';
        else ok = hexval((unsigned char)c[i]) >= 0;
    }
    if (ok) { b_ch(&v->out, '"'); b_put(&v->out, c, 36); b_ch(&v->out, '"'); }
    JS_FreeCString(v->ctx, c);
    return ok;
}

// Exactly {actions:[{type:'webhook',endpointId:UUID,json:JSONValue}]}, <= max_actions.
static int emit_result(V *v, JSValueConst root) {
    static const char *const root_keys[] = {"actions"};
    static const char *const action_keys[] = {"type", "endpointId", "json"};
    JSValue actions = JS_UNDEFINED;
    int32_t n = 0, i;
    if (!exact_props(v, root, root_keys, 1, &actions)) return v_fail(v);
    int ok = 0;
    if (!array_prepare(v, actions, &n) || (size_t)n > v->max_actions) goto done;
    b_str(&v->out, "{\"actions\":[");
    for (i = 0; i < n; i++) {
        JSValue act, f[3];
        if (!array_get(v, actions, i, &act)) goto done;
        int exact = exact_props(v, act, action_keys, 3, f);
        JS_FreeValue(v->ctx, act);
        if (!exact) goto done;
        int good = string_equals(v, f[0], "webhook");
        if (i) b_ch(&v->out, ',');
        if (good) {
            b_str(&v->out, "{\"type\":\"webhook\",\"endpointId\":");
            good = emit_uuid(v, f[1]);
        }
        if (good) {
            b_str(&v->out, ",\"json\":");
            good = emit_value(v, f[2], 4);   // root=1, actions=2, action=3, json value=4
        }
        if (good) b_ch(&v->out, '}');
        JS_FreeValue(v->ctx, f[0]);
        JS_FreeValue(v->ctx, f[1]);
        JS_FreeValue(v->ctx, f[2]);
        if (!good) goto done;
    }
    b_str(&v->out, "]}");
    ok = !v->out.overflow;
done:
    JS_FreeValue(v->ctx, actions);
    return ok ? 1 : v_fail(v);
}

// MARK: failure classification (no JS-visible conversion of the exception)

static int classify_exception(JSContext *ctx, RunState *st, int fallback) {
    if (st->stop) return st->stop;
    if (st->oom) return QJS_MEMORY_OR_STACK;
    int status = fallback;
    JSValue ex = JS_GetException(ctx);
    if (JS_IsError(ctx, ex)) {
        JSAtom a = JS_NewAtom(ctx, "message");
        JSPropertyDescriptor d;
        if (a != JS_ATOM_NULL && JS_GetOwnProperty(ctx, &d, ex, a) > 0) {
            if (!(d.flags & JS_PROP_GETSET) && JS_IsString(d.value)) {
                size_t n;
                const char *c = JS_ToCStringLen2(ctx, &n, d.value, 0);
                if (c) {
                    // Engine-raised resource errors. A script can throw the same text; that only
                    // reclassifies its own failure between two error kinds.
                    static const char *const resource[] = {"stack overflow", "string too long", "out of memory",
                                                           "invalid string length", "invalid array length",
                                                           "BigInt is too large", "BigInt is too large to allocate"};
                    for (size_t k = 0; k < sizeof(resource) / sizeof(resource[0]); k++)
                        if (n == strlen(resource[k]) && memcmp(c, resource[k], n) == 0) status = QJS_MEMORY_OR_STACK;
                    JS_FreeCString(ctx, c);
                }
            }
            JS_FreeValue(ctx, d.value);
            JS_FreeValue(ctx, d.getter);
            JS_FreeValue(ctx, d.setter);
        }
        if (a != JS_ATOM_NULL) JS_FreeAtom(ctx, a);
    }
    JS_FreeValue(ctx, ex);
    return status;
}

void qjs_result_free(QJSResult *result) {
    if (!result) return;
    free(result->data);
    result->data = NULL;
    result->length = 0;
}

// MARK: entry point

QJSResult qjs_run(QJSCancelToken *token, const QJSLimits *limits,
                  const uint8_t *source, size_t source_len,
                  const char *hook,
                  const uint8_t *event_json, size_t event_len,
                  const uint8_t *config_json, size_t config_len) {
    QJSResult res = {QJS_INTERNAL, NULL, 0};
    uint8_t *src = NULL, *ev = NULL, *cfg = NULL;
    JSRuntime *rt = NULL;
    JSContext *ctx = NULL;
    JSValue fn = JS_UNDEFINED, evv = JS_UNDEFINED, cfgv = JS_UNDEFINED, ret = JS_UNDEFINED;
    RunState st;
    int status = QJS_INTERNAL;

    memset(&st, 0, sizeof(st));
    st.token = token;
    st.deadline_ns = now_ns() + (uint64_t)(limits ? limits->deadline_ms : 0) * 1000000ull;

    if (!limits || !hook || limits->deadline_ms == 0 || limits->heap_bytes == 0 || limits->stack_bytes == 0 ||
        limits->max_result_bytes == 0 || limits->max_result_depth == 0) {
        return res;
    }

    // Caps and encoding. Nothing below parses or evaluates before these pass.
    if (!source || source_len == 0 || source_len > limits->max_source_bytes ||
        !event_json || event_len == 0 || event_len > limits->max_event_bytes ||
        !config_json || config_len == 0 || config_len > limits->max_config_bytes) {
        res.status = QJS_INVALID_INPUT;
        return res;
    }
    if (memchr(source, 0, source_len) != NULL || !utf8_valid(source, source_len)) {
        res.status = QJS_INVALID_INPUT;
        return res;
    }
    if (budget_exceeded(&st)) {   // cancelled before admission turned into execution
        res.status = st.stop;
        return res;
    }
    src = copy_z(source, source_len);
    ev = copy_z(event_json, event_len);
    cfg = copy_z(config_json, config_len);
    if (!src || !ev || !cfg) { status = QJS_MEMORY_OR_STACK; goto cleanup; }
    if (!json_check(ev, event_len, 64) || !json_check(cfg, config_len, 64)) {
        status = QJS_INVALID_INPUT;
        goto cleanup;
    }

    rt = JS_NewRuntime2(&limited_funcs, &st);
    if (!rt) { status = st.oom ? QJS_MEMORY_OR_STACK : QJS_INTERNAL; goto cleanup; }
    JS_SetMemoryLimit(rt, limits->heap_bytes);
    JS_SetMaxStackSize(rt, limits->stack_bytes);
    JS_UpdateStackTop(rt);
    JS_SetCanBlock(rt, 0);
    JS_SetInterruptHandler(rt, interrupt_cb, &st);

    ctx = JS_NewContextRaw(rt);
    if (!ctx) { status = st.oom ? QJS_MEMORY_OR_STACK : QJS_INTERNAL; goto cleanup; }
    if (JS_AddIntrinsicBaseObjects(ctx) || JS_AddIntrinsicDate(ctx) || JS_AddIntrinsicEval(ctx) ||
        JS_AddIntrinsicStringNormalize(ctx) || JS_AddIntrinsicRegExp(ctx) || JS_AddIntrinsicJSON(ctx) ||
        JS_AddIntrinsicProxy(ctx) || JS_AddIntrinsicMapSet(ctx) || JS_AddIntrinsicPromise(ctx)) {
        status = st.oom ? QJS_MEMORY_OR_STACK : QJS_INTERNAL;
        goto cleanup;
    }

    // Pristine class ids captured before any user code can run.
    {
        JSValue o = JS_NewObject(ctx), a = JS_NewArray(ctx);
        st.cls_object = JS_GetClassID(o);
        st.cls_array = JS_GetClassID(a);
        JS_FreeValue(ctx, o);
        JS_FreeValue(ctx, a);
        if (!st.cls_object || !st.cls_array || st.cls_object == st.cls_array) goto cleanup;
    }

    // Event/config are parsed before user code exists, under the same deadline.
    evv = JS_ParseJSON(ctx, (const char *)ev, event_len, "<event>");
    if (JS_IsException(evv)) { status = classify_exception(ctx, &st, QJS_INVALID_INPUT); goto cleanup; }
    cfgv = JS_ParseJSON(ctx, (const char *)cfg, config_len, "<config>");
    if (JS_IsException(cfgv)) { status = classify_exception(ctx, &st, QJS_INVALID_INPUT); goto cleanup; }

    {
        JSValue completion = JS_Eval(ctx, (const char *)src, source_len, "<plugin>", JS_EVAL_TYPE_GLOBAL);
        if (JS_IsException(completion)) { status = classify_exception(ctx, &st, QJS_SCRIPT_ERROR); goto cleanup; }
        JS_FreeValue(ctx, completion);
    }

    {
        JSValue global = JS_GetGlobalObject(ctx);
        fn = JS_GetPropertyStr(ctx, global, hook);
        JS_FreeValue(ctx, global);
        if (JS_IsException(fn)) { status = classify_exception(ctx, &st, QJS_SCRIPT_ERROR); goto cleanup; }
        if (!JS_IsFunction(ctx, fn)) { status = st.stop ? st.stop : QJS_SCRIPT_ERROR; goto cleanup; }
    }

    {
        JSValueConst argv[2];
        argv[0] = evv;
        argv[1] = cfgv;
        ret = JS_Call(ctx, fn, JS_UNDEFINED, 2, argv);
        if (JS_IsException(ret)) { status = classify_exception(ctx, &st, QJS_SCRIPT_ERROR); goto cleanup; }
    }

    {
        V v;
        memset(&v, 0, sizeof(v));
        v.ctx = ctx;
        v.st = &st;
        v.max_depth = (int)limits->max_result_depth;
        v.max_actions = limits->max_actions;
        v.out.cap = limits->max_result_bytes;
        v.out.p = malloc(v.out.cap + 1);
        if (!v.out.p) { status = QJS_MEMORY_OR_STACK; goto cleanup; }
        int ok = emit_result(&v, ret);
        if (ok) v.out.p[v.out.len] = 0;
        // Defense in depth: re-scan the serialized bytes natively, then the final budget check.
        if (ok && !json_check(v.out.p, v.out.len, (int)limits->max_result_depth)) ok = 0;
        if (budget_exceeded(&st)) {
            status = st.stop;
        } else if (ok) {
            res.data = v.out.p;
            res.length = v.out.len;
            status = QJS_OK;
            v.out.p = NULL;
        } else if (st.oom) {
            status = QJS_MEMORY_OR_STACK;
        } else {
            status = v.err ? v.err : QJS_INVALID_RESULT;
        }
        free(v.out.p);
    }

cleanup:
    if (ctx) {
        JS_FreeValue(ctx, ret);
        JS_FreeValue(ctx, fn);
        JS_FreeValue(ctx, cfgv);
        JS_FreeValue(ctx, evv);
        JS_FreeContext(ctx);
    }
    if (rt) JS_FreeRuntime(rt);
    free(src);
    free(ev);
    free(cfg);
    res.status = status;
    return res;
}
