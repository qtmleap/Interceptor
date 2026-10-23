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

#define MAX_REGS 16

typedef struct { char *s; size_t n; } Str;

// One exact route and its four optional native-selected source references.
typedef struct {
    Str *hosts;
    size_t nhosts;
    Str *methods;
    size_t nmethods;
    int has_methods;
    int path_kind;   // 0 none, 1 exact, 2 prefix
    Str path;
    int has_status;
    int lo, hi;
    Str hooks[4];   // request enter/leave, response enter/leave source references
} Match;

typedef struct { Str name, code; int referenced; } SourceFile;

typedef struct {
    int match;      // native-selected route index
    JSValue cb;     // callback for the invoked phase, or JS_UNDEFINED
} Reg;

#define MAX_OUT 4
#define MAX_INTENTS 16
#define OUT_MAX_VALUE 4096u
#define OUT_MAX_TOTAL 8192u

typedef struct { Str name; Str *headers; size_t nheaders; } OutDecl;
// Snapshot copy of one validated Interceptor.send call; never references JS memory.
typedef struct { Str binding; Str *names; Str *values; size_t n; } Intent;

typedef struct RunState {
    QJSCancelToken *token;
    uint64_t deadline_ns;
    int stop;   // 0, QJS_TIMEOUT or QJS_CANCELLED; sticky once set
    int oom;    // allocator refused (limit or malloc failure)
    JSClassID cls_object;
    JSClassID cls_array;
    // v2 only: registrations made by Interceptor.attach while the source is evaluated.
    int sealed;          // set once the source has been evaluated; later attach calls fail
    int attach_failed;   // sticky: any invalid or surplus registration fails the whole execution
    int nregs;
    Reg regs[MAX_REGS];
    int phase_leg;       // 0 request, 1 response
    int phase_kind;      // 0 enter, 1 leave
    int ndecl;           // declared manifest matches parsed so far
    Match decl[MAX_REGS];
    SourceFile files[64];
    int nfiles;
    int selected_route;
    unsigned expected_phases, registered_phases;
    // v2 only: manifest read grants (header names lowercased), applied while building the event views.
    unsigned read_meta;  // 1 method, 2 host, 4 status, 8 path
    Str *rd_headers;
    size_t n_rd_headers;
    Str *rd_query;
    size_t n_rd_query;
    int read_body_json;
    int body_writable;   // enter phase with the manifest write grant for the invoked leg
    // v2 only: declared outbound bindings and the HTTP intents recorded by Interceptor.send.
    int in_callback;     // set only while the host invokes a registered callback (and drains its promise jobs)
    int requires_async;  // read-only probe attempted a fetch; no network has occurred
    // fetch mode only (qjs_run_v2_fetch): trusted blocking host callback plus aggregate caps.
    QJSFetchCallback fetch_cb;
    void *fetch_opaque;
    uint64_t wall_deadline_ns;   // 0 when not in fetch mode
    unsigned nrequests;
    size_t response_total;
    // saveJSON (qjs_run_v2_fetch_save and the scheduling probe): schema 2 `write.files` grant, separate budgets.
    int write_files;
    int save_exposed;            // Interceptor.saveJSON is installed
    QJSSaveJSONCallback save_cb;
    void *save_opaque;
    unsigned nsaves;
    size_t save_total;
    int nout;
    OutDecl out[MAX_OUT];
    Intent *intents;
    size_t nintents, max_intents;
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
    uint64_t now = now_ns();
    if (now >= st->deadline_ns || (st->wall_deadline_ns && now >= st->wall_deadline_ns)) {
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
    RunState *st;      // optional: polled for cancel/CPU/wall budget; NULL = unbudgeted
    unsigned tick;
    int aborted;       // sticky: budget exhausted mid-scan (st->stop says why)
} Scan;

// Cheap periodic budget poll for per-byte/per-probe loops. Returns 1 once the budget is exhausted (sticky).
#define SCAN_POLL_MASK 255u
static int scan_tick(Scan *s) {
    if (s->aborted) return 1;
    if (s->st && (++s->tick & SCAN_POLL_MASK) == 0 && budget_exceeded(s->st)) s->aborted = 1;
    return s->aborted;
}

static uint32_t fnv1a(Scan *s, const uint8_t *p, size_t n) {
    uint32_t h = 2166136261u;
    for (size_t i = 0; i < n; i++) {
        if (scan_tick(s)) break;
        h ^= p[i]; h *= 16777619u;
    }
    return h;
}

// 1 = ok, 0 = out of memory, -2 = budget exhausted
static int keyset_grow_slots(Scan *sc, KeySet *ks) {
    size_t cap = ks->slot_cap ? ks->slot_cap * 2 : 16;
    uint32_t *slots = calloc(cap, sizeof(uint32_t));
    if (!slots) return 0;
    for (size_t i = 0; i < ks->n; i++) {
        if (scan_tick(sc)) { free(slots); return -2; }
        size_t j = ks->recs[i].hash & (cap - 1);
        while (slots[j]) {
            if (scan_tick(sc)) { free(slots); return -2; }
            j = (j + 1) & (cap - 1);
        }
        slots[j] = (uint32_t)(i + 1);
    }
    free(ks->slots);
    ks->slots = slots;
    ks->slot_cap = cap;
    return 1;
}

// 1 = added, 0 = duplicate, -1 = out of memory, -2 = budget exhausted
static int keyset_add(Scan *s, KeySet *ks, uint32_t off, uint32_t len) {
    uint32_t h = fnv1a(s, s->arena + off, len);
    if (s->aborted) return -2;
    if ((ks->n + 1) * 2 > ks->slot_cap) {
        int g = keyset_grow_slots(s, ks);
        if (g != 1) return g == -2 ? -2 : -1;
    }
    size_t j = h & (ks->slot_cap - 1);
    while (ks->slots[j]) {
        if (scan_tick(s)) return -2;
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
    while (s->p < s->end && (*s->p == ' ' || *s->p == '\t' || *s->p == '\n' || *s->p == '\r')) {
        if (scan_tick(s)) return;
        s->p++;
    }
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
        if (s->p >= s->end || scan_tick(s)) return 0;
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
    else if (*q >= '1' && *q <= '9') { while (is_digit(q, s->end)) { if (scan_tick(s)) return 0; q++; } }
    else return 0;
    if (q < s->end && *q == '.') {
        q++;
        if (!is_digit(q, s->end)) return 0;
        while (is_digit(q, s->end)) { if (scan_tick(s)) return 0; q++; }
    }
    if (q < s->end && (*q == 'e' || *q == 'E')) {
        q++;
        if (q < s->end && (*q == '+' || *q == '-')) q++;
        if (!is_digit(q, s->end)) return 0;
        while (is_digit(q, s->end)) { if (scan_tick(s)) return 0; q++; }
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
    if (s->p >= s->end || s->aborted) return 0;
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

// `z` must be NUL-terminated at z[len]. With `st`, the scan polls the run's cancel/CPU/wall budget and fails
// (leaving st->stop set) once it is exhausted; a final check also covers the tail between polls.
static int json_check_budgeted(const uint8_t *z, size_t len, int max_depth, RunState *st) {
    Scan s;
    s.p = z;
    s.end = z + len;
    s.arena = malloc(len + 1);
    s.arena_used = 0;
    s.max_depth = max_depth;
    s.st = st;
    s.tick = 0;
    s.aborted = 0;
    if (!s.arena) return 0;
    int ok = scan_value(&s, 0);
    if (ok) { skip_ws(&s); ok = (s.p == s.end); }
    free(s.arena);
    if (s.aborted) ok = 0;
    if (ok && st && budget_exceeded(st)) ok = 0;
    return ok;
}

static int json_check(const uint8_t *z, size_t len, int max_depth) {
    return json_check_budgeted(z, len, max_depth, NULL);
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
    size_t nactions;   // actions emitted so far (v2 accumulates across callbacks)
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
    // Keep finite JS Numbers outside Core's safe integer range in its double grammar.
    // This preserves the value already represented by JS, without claiming extra precision.
    if (fabs(d) > 9007199254740991.0 && !strchr(buf, '.') &&
        !strchr(buf, 'e') && !strchr(buf, 'E')) {
        strcat(buf, ".0");
    }
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

    if (!limits || !hook || (strcmp(hook, "onRequest") && strcmp(hook, "onResponse")) ||
        limits->deadline_ms == 0 || limits->heap_bytes == 0 || limits->stack_bytes == 0 ||
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
        // Fixed, validated identifiers resolve global lexical const/let bindings as well.
        fn = JS_Eval(ctx, hook, strlen(hook), "<hook>", JS_EVAL_TYPE_GLOBAL);
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

// MARK: v2: four HTTP lifecycle phases
//
// `qjs_run_v2` shares the limits, allocator, scanner and result serializer above. In addition:
//  * `Interceptor.attach(callbacks)` is a native function installed before user code. Every
//    registration is read with own-data-property descriptors only (no getters, no Proxy, no
//    prototype lookups) and binds to the native-selected route. The registered phase union must
//    equal every manifest phase referencing the selected file. Invalid and late registrations
//    remain sticky even if user code catches the TypeError.
//  * Matching uses the UNFILTERED request method/host/path and requested phase. No match evaluates
//    no code; ambiguity rejects before evaluation. The selected file runs in one fresh VM, then
//    only callbacks of the invoked phase run, each with (own leg, config).
//  * The only possible mutation is the JSON `body` of the invoked leg, for an enter phase whose
//    write grant is declared in the manifest. The final tree is compared with the canonical form
//    of the original tree; an unchanged tree yields no mutation at all.

#define BODY_COMPARE_CAP (512u * 1024u)
#define BODY_COMPARE_DEPTH 64

static void str_free(Str *s) { free(s->s); s->s = NULL; s->n = 0; }

static void strs_free(Str *a, size_t n) {
    for (size_t i = 0; i < n; i++) str_free(&a[i]);
    free(a);
}

static void match_free(Match *m) {
    strs_free(m->hosts, m->nhosts);
    strs_free(m->methods, m->nmethods);
    str_free(&m->path);
    for (int i = 0; i < 4; i++) str_free(&m->hooks[i]);
    memset(m, 0, sizeof(*m));
}

static int str_cmp(const void *a, const void *b) {
    const Str *x = a, *y = b;
    size_t n = x->n < y->n ? x->n : y->n;
    int c = n ? memcmp(x->s, y->s, n) : 0;
    if (c) return c;
    return x->n < y->n ? -1 : (x->n > y->n);
}

// Enumerable own data property; takes ownership of *out. Never invokes accessors.
static int own_data(JSContext *ctx, JSValueConst obj, JSAtom atom, JSValue *out) {
    JSPropertyDescriptor d;
    if (JS_GetOwnProperty(ctx, &d, obj, atom) <= 0) return 0;
    int ok = !(d.flags & JS_PROP_GETSET) && (d.flags & JS_PROP_ENUMERABLE);
    JS_FreeValue(ctx, d.getter);
    JS_FreeValue(ctx, d.setter);
    if (!ok) { JS_FreeValue(ctx, d.value); return 0; }
    *out = d.value;
    return 1;
}

static int str_eq(JSContext *ctx, JSValueConst s, const char *lit) {
    if (!JS_IsString(s)) return 0;
    size_t n;
    const char *c = JS_ToCStringLen2(ctx, &n, s, 0);
    if (!c) return 0;
    int eq = n == strlen(lit) && memcmp(c, lit, n) == 0;
    JS_FreeCString(ctx, c);
    return eq;
}

// Reads a plain object whose own property names are a subset of `keys` (all enumerable data), with
// the `required` bit mask present. vals[i] is owned, JS_UNDEFINED when absent. All-or-nothing.
static int read_obj_fields(RunState *st, JSContext *ctx, JSValueConst obj, const char *const *keys, int n,
                           unsigned required, JSValue *vals, unsigned *seen_out) {
    for (int i = 0; i < n; i++) vals[i] = JS_UNDEFINED;
    if (JS_GetClassID(obj) != st->cls_object) return 0;
    JSPropertyEnum *tab;
    uint32_t cnt;
    if (JS_GetOwnPropertyNames(ctx, &tab, &cnt, obj, JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK) < 0) return 0;
    int ok = 1;
    unsigned seen = 0;
    for (uint32_t j = 0; j < cnt && ok; j++) {
        JSValue kv = JS_AtomToValue(ctx, tab[j].atom);
        int idx = -1;
        if (JS_IsString(kv)) {
            for (int i = 0; i < n; i++) if (str_eq(ctx, kv, keys[i])) idx = i;
        }
        JS_FreeValue(ctx, kv);
        if (idx < 0 || (seen >> idx & 1u)) { ok = 0; break; }
        JSValue d;
        if (!own_data(ctx, obj, tab[j].atom, &d)) { ok = 0; break; }
        vals[idx] = d;
        seen |= 1u << idx;
    }
    JS_FreePropertyEnum(ctx, tab, cnt);
    if (ok && (seen & required) != required) ok = 0;
    if (!ok) {
        for (int i = 0; i < n; i++) { JS_FreeValue(ctx, vals[i]); vals[i] = JS_UNDEFINED; }
    }
    if (ok && seen_out) *seen_out = seen;
    return ok;
}

static int read_obj(RunState *st, JSContext *ctx, JSValueConst obj, const char *const *keys, int n,
                    unsigned required, JSValue *vals) {
    return read_obj_fields(st, ctx, obj, keys, n, required, vals, NULL);
}

static int get_str(JSContext *ctx, JSValueConst v, Str *out, size_t max) {
    if (!JS_IsString(v)) return 0;
    size_t n;
    const char *c = JS_ToCStringLen2(ctx, &n, v, 0);
    if (!c) return 0;
    int ok = n <= max && memchr(c, 0, n) == NULL && utf8_valid((const uint8_t *)c, n);
    if (ok) {
        out->s = malloc(n + 1);
        if (out->s) { memcpy(out->s, c, n); out->s[n] = 0; out->n = n; } else ok = 0;
    }
    JS_FreeCString(ctx, c);
    return ok;
}

static int get_int(JSValueConst v, int *out) {
    if (JS_VALUE_GET_TAG(v) == JS_TAG_INT) { *out = JS_VALUE_GET_INT(v); return 1; }
    if (JS_VALUE_GET_TAG(v) == JS_TAG_FLOAT64) {
        double d = JS_VALUE_GET_FLOAT64(v);
        if (d >= -2147483648.0 && d <= 2147483647.0 && d == (double)(int)d) { *out = (int)d; return 1; }
    }
    return 0;
}

// Plain dense array of strings, sorted, no duplicates, 1...max entries.
static int get_str_set(RunState *st, JSContext *ctx, JSValueConst arr, size_t max, Str **out, size_t *count) {
    V tmp;
    memset(&tmp, 0, sizeof(tmp));
    tmp.ctx = ctx;
    tmp.st = st;
    tmp.out.cap = 65536;
    int32_t n;
    *out = NULL;
    *count = 0;
    if (!array_prepare(&tmp, arr, &n) || n < 1 || (size_t)n > max) return 0;
    Str *a = calloc((size_t)n, sizeof(Str));
    if (!a) return 0;
    int ok = 1;
    for (int32_t i = 0; i < n && ok; i++) {
        JSValue el;
        if (!array_get(&tmp, arr, i, &el)) { ok = 0; break; }
        ok = get_str(ctx, el, &a[i], 1024);
        JS_FreeValue(ctx, el);
    }
    if (ok) {
        qsort(a, (size_t)n, sizeof(Str), str_cmp);
        for (int32_t i = 1; i < n; i++) if (str_cmp(&a[i - 1], &a[i]) == 0) ok = 0;
    }
    if (!ok) { strs_free(a, (size_t)n); return 0; }
    *out = a;
    *count = (size_t)n;
    return 1;
}

// Source keys are bounded, safe relative ASCII POSIX paths, independent of route conditions.
static int source_path_ok(const Str *s) {
    if (!s->n || s->n > 256) return 0;
    size_t start = 0;
    for (size_t i = 0; i <= s->n; i++) {
        if (i == s->n || s->s[i] == '/') {
            size_t n = i - start;
            if (!n || (n == 1 && s->s[start] == '.') || (n == 2 && s->s[start] == '.' && s->s[start + 1] == '.')) return 0;
            start = i + 1;
        } else {
            unsigned char c = s->s[i];
            if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' || c == '.' || c == '_' || c == '~')) return 0;
        }
    }
    return 1;
}

static int parse_match(RunState *st, JSContext *ctx, JSValueConst obj, Match *m) {
    static const char *const mk[] = {"hosts", "methods", "path", "hooks"};
    static const char *const pk[] = {"kind", "value"};
    static const char *const legs[] = {"request", "response"};
    static const char *const phases[] = {"onEnter", "onLeave"};
    JSValue f[4], p[2], h[2];
    int ok = 0, count = 0;
    memset(m, 0, sizeof(*m));
    if (!read_obj(st, ctx, obj, mk, 4, 15u, f)) return 0;
    if (!get_str_set(st, ctx, f[0], 1, &m->hosts, &m->nhosts)) goto done;
    m->has_methods = 1;
    if (!get_str_set(st, ctx, f[1], 1, &m->methods, &m->nmethods)) goto done;
    if (!read_obj(st, ctx, f[2], pk, 2, 3u, p)) goto done;
    int good = str_eq(ctx, p[0], "exact") && get_str(ctx, p[1], &m->path, 1024);
    JS_FreeValue(ctx, p[0]); JS_FreeValue(ctx, p[1]);
    if (!good) goto done;
    m->path_kind = 1;
    if (!read_obj(st, ctx, f[3], legs, 2, 0u, h)) goto done;
    good = 1;
    for (int l = 0; l < 2 && good; l++) {
        if (JS_IsUndefined(h[l])) continue;
        JSValue refs[2];
        if (!read_obj(st, ctx, h[l], phases, 2, 0u, refs)) { good = 0; break; }
        int leg_count = 0;
        for (int k = 0; k < 2 && good; k++) {
            if (JS_IsUndefined(refs[k])) continue;
            good = get_str(ctx, refs[k], &m->hooks[l * 2 + k], 256) && source_path_ok(&m->hooks[l * 2 + k]);
            leg_count++; count++;
        }
        JS_FreeValue(ctx, refs[0]); JS_FreeValue(ctx, refs[1]);
        if (!leg_count) good = 0;
    }
    JS_FreeValue(ctx, h[0]); JS_FreeValue(ctx, h[1]);
    if (!good || !count) goto done;
    ok = 1;
done:
    for (int i = 0; i < 4; i++) JS_FreeValue(ctx, f[i]);
    if (!ok) match_free(m);
    return ok;
}

typedef struct {
    Str method, host, path;
    int status;   // 0 when absent
} Ident;

static void ident_free(Ident *id) {
    str_free(&id->method);
    str_free(&id->host);
    str_free(&id->path);
}

static int in_set(const Str *a, size_t n, const Str *s) {
    for (size_t i = 0; i < n; i++) if (a[i].n == s->n && memcmp(a[i].s, s->s, s->n) == 0) return 1;
    return 0;
}

// Fields combine with AND, set members with OR. A status constraint never matches a leg without one.
static int match_accepts(const Match *m, const Ident *id, int response_phase) {
    if (!in_set(m->hosts, m->nhosts, &id->host)) return 0;
    if (m->has_methods && !in_set(m->methods, m->nmethods, &id->method)) return 0;
    if (m->path_kind == 1 && !(m->path.n == id->path.n && memcmp(m->path.s, id->path.s, id->path.n) == 0)) return 0;
    if (m->path_kind == 2 && !(id->path.n >= m->path.n && memcmp(m->path.s, id->path.s, m->path.n) == 0)) return 0;
    if (m->has_status && !(response_phase && id->status >= m->lo && id->status <= m->hi)) return 0;
    return 1;
}

static JSValue js_attach(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    static const char *const ck[] = {"request", "response"};
    static const char *const hk[] = {"onEnter", "onLeave"};
    (void)this_val;
    RunState *st = JS_GetContextOpaque(ctx);
    JSValue legs[2], cb = JS_UNDEFINED;
    unsigned phases = 0;
    int ok = 0;
    legs[0] = legs[1] = JS_UNDEFINED;
    if (!st || st->sealed || argc != 1 || st->nregs >= MAX_REGS) goto done;
    if (!read_obj(st, ctx, argv[0], ck, 2, 0u, legs)) goto done;
    for (int l = 0; l < 2; l++) {
        if (JS_IsUndefined(legs[l])) continue;
        JSValue h[2];
        if (!read_obj(st, ctx, legs[l], hk, 2, 0u, h)) goto done;
        int good = 1;
        for (int k = 0; k < 2; k++) {
            if (JS_IsUndefined(h[k])) continue;
            if (!JS_IsFunction(ctx, h[k])) good = 0;
            else phases |= 1u << (l * 2 + k);
        }
        if (good && l == st->phase_leg) cb = JS_DupValue(ctx, h[st->phase_kind]);
        JS_FreeValue(ctx, h[0]); JS_FreeValue(ctx, h[1]);
        if (!good) goto done;
    }
    if (phases & ~st->expected_phases) goto done;
    st->registered_phases |= phases;
    st->regs[st->nregs].match = st->selected_route;
    st->regs[st->nregs].cb = cb;
    cb = JS_UNDEFINED;
    st->nregs++;
    ok = 1;
done:
    JS_FreeValue(ctx, legs[0]); JS_FreeValue(ctx, legs[1]); JS_FreeValue(ctx, cb);
    if (ok) return JS_UNDEFINED;
    if (st) st->attach_failed = 1;
    return JS_ThrowTypeError(ctx, "invalid Interceptor.attach");
}

static void intent_free(Intent *it) {
    str_free(&it->binding);
    strs_free(it->names, it->n);
    strs_free(it->values, it->n);
    memset(it, 0, sizeof(*it));
}

static void intents_free(RunState *st) {
    for (size_t i = 0; i < st->nintents; i++) intent_free(&st->intents[i]);
    free(st->intents);
    st->intents = NULL;
    st->nintents = 0;
}

// Interceptor.send(binding, {headers}): validates immediately and records a snapshot copy. Performs no I/O,
// returns undefined. Any violation (including a call outside a callback) is a sticky failure.
static JSValue js_send(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    static const char *const ok_keys[] = {"headers"};
    (void)this_val;
    RunState *st = JS_GetContextOpaque(ctx);
    JSValue opt[1], hv = JS_UNDEFINED;
    const OutDecl *decl = NULL;
    Intent it;
    JSPropertyEnum *tab = NULL;
    uint32_t cnt = 0;
    size_t total = 0;
    int ok = 0;
    memset(&it, 0, sizeof(it));
    opt[0] = JS_UNDEFINED;
    if (!st || !st->in_callback || argc != 2 || !st->intents || st->nintents >= st->max_intents) goto done;
    if (!get_str(ctx, argv[0], &it.binding, 32)) goto done;

    for (int i = 0; i < st->nout; i++) if (str_cmp(&st->out[i].name, &it.binding) == 0) decl = &st->out[i];
    if (!decl) goto done;
    if (!read_obj(st, ctx, argv[1], ok_keys, 1, 1u, opt)) goto done;
    hv = opt[0];
    if (JS_GetClassID(hv) != st->cls_object) goto done;
    if (JS_GetOwnPropertyNames(ctx, &tab, &cnt, hv, JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK) < 0) { tab = NULL; goto done; }
    if (cnt > 8) goto done;
    it.names = calloc(cnt ? cnt : 1, sizeof(Str));
    it.values = calloc(cnt ? cnt : 1, sizeof(Str));
    if (!it.names || !it.values) { st->oom = 1; goto done; }
    for (uint32_t i = 0; i < cnt; i++) {
        JSValue key = JS_AtomToValue(ctx, tab[i].atom), val = JS_UNDEFINED;
        int good = JS_IsString(key) && get_str(ctx, key, &it.names[i], 128) && in_set(decl->headers, decl->nheaders, &it.names[i]);
        it.n = i + 1;
        if (good) good = own_data(ctx, hv, tab[i].atom, &val) && get_str(ctx, val, &it.values[i], OUT_MAX_VALUE);
        if (good) {
            total += it.values[i].n;
            for (size_t k = 0; k < it.values[i].n; k++) {
                unsigned char c = (unsigned char)it.values[i].s[k];
                if (!(c == '\t' || (c >= 0x20 && c <= 0x7E))) good = 0;
            }
            if (total > OUT_MAX_TOTAL) good = 0;
        }
        JS_FreeValue(ctx, key);
        JS_FreeValue(ctx, val);
        if (!good) goto done;
    }
    // Canonical order: sorted by header name (names are unique own keys).
    for (size_t i = 1; i < it.n; i++)
        for (size_t j = i; j > 0 && str_cmp(&it.names[j - 1], &it.names[j]) > 0; j--) {
            Str t = it.names[j]; it.names[j] = it.names[j - 1]; it.names[j - 1] = t;
            t = it.values[j]; it.values[j] = it.values[j - 1]; it.values[j - 1] = t;
        }
    st->intents[st->nintents++] = it;
    memset(&it, 0, sizeof(it));
    ok = 1;
done:
    if (tab) JS_FreePropertyEnum(ctx, tab, cnt);
    JS_FreeValue(ctx, opt[0]);
    intent_free(&it);
    if (ok) return JS_UNDEFINED;
    if (st) st->attach_failed = 1;
    return JS_ThrowTypeError(ctx, "invalid Interceptor.send");
}

// {"type":"http","binding":..,"headers":{..}}; values are printable ASCII, escaped for JSON.
static void emit_intent(Buf *b, const Intent *it) {
    b_str(b, "{\"type\":\"http\",\"binding\":\"");
    b_put(b, it->binding.s, it->binding.n);
    b_str(b, "\",\"headers\":{");
    for (size_t i = 0; i < it->n; i++) {
        if (i) b_ch(b, ',');
        b_ch(b, '"');
        b_put(b, it->names[i].s, it->names[i].n);
        b_str(b, "\":\"");
        for (size_t k = 0; k < it->values[i].n; k++) {
            unsigned char c = (unsigned char)it->values[i].s[k];
            if (c == '"' || c == '\\') { b_ch(b, '\\'); b_ch(b, (char)c); }
            else if (c == '\t') b_str(b, "\\t");
            else b_ch(b, (char)c);
        }
        b_ch(b, '"');
    }
    b_str(b, "}}");
}

static int install_interceptor(JSContext *ctx) {
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue ns = JS_NewObject(ctx);
    JSValue fn = JS_NewCFunction(ctx, js_attach, "attach", 1);
    JSValue sfn = JS_NewCFunction(ctx, js_send, "send", 2);
    int ok = !JS_IsException(ns) && !JS_IsException(fn) && !JS_IsException(sfn);
    // JS_DefinePropertyValueStr consumes the value on success and failure.
    if (ok) ok = JS_DefinePropertyValueStr(ctx, ns, "attach", fn, JS_PROP_ENUMERABLE) > 0;   // read-only, fixed
    else JS_FreeValue(ctx, fn);
    if (ok) ok = JS_DefinePropertyValueStr(ctx, ns, "send", sfn, JS_PROP_ENUMERABLE) > 0;
    else JS_FreeValue(ctx, sfn);
    if (ok) ok = JS_DefinePropertyValueStr(ctx, global, "Interceptor", ns, 0) > 0;
    else JS_FreeValue(ctx, ns);
    JS_FreeValue(ctx, global);
    return ok;
}

// Canonical JSON of one value into a fresh buffer (caller frees buf->p).
static int serialize_value(RunState *st, JSContext *ctx, JSValueConst val, int depth, int max_depth, size_t cap, Buf *out) {
    V v;
    memset(&v, 0, sizeof(v));
    v.ctx = ctx;
    v.st = st;
    v.max_depth = max_depth;
    v.out.cap = cap;
    v.out.p = malloc(cap + 1);
    if (!v.out.p) return 0;
    int ok = emit_value(&v, val, depth);
    if (ok) v.out.p[v.out.len] = 0;
    if (!ok) { free(v.out.p); return 0; }
    *out = v.out;
    return 1;
}

// Appends the actions of one callback result: exactly {actions:[...]}; at most max_actions in total.
static int emit_actions(V *v, JSValueConst root) {
    static const char *const root_keys[] = {"actions"};
    static const char *const action_keys[] = {"type", "endpointId", "json"};
    JSValue actions = JS_UNDEFINED;
    int32_t n = 0, i;
    if (!exact_props(v, root, root_keys, 1, &actions)) return v_fail(v);
    int ok = 0;
    if (!array_prepare(v, actions, &n) || (size_t)n > v->max_actions - v->nactions) goto done;
    for (i = 0; i < n; i++) {
        JSValue act, f[3];
        if (!array_get(v, actions, i, &act)) goto done;
        int exact = exact_props(v, act, action_keys, 3, f);
        JS_FreeValue(v->ctx, act);
        if (!exact) goto done;
        int good = string_equals(v, f[0], "webhook");
        if (v->nactions) b_ch(&v->out, ',');
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
        v->nactions++;
    }
    ok = !v->out.overflow;
done:
    JS_FreeValue(v->ctx, actions);
    return ok ? 1 : v_fail(v);
}

static int parse_phase(const char *hook, int *leg, int *kind) {
    if (!hook) return 0;
    if (!strcmp(hook, "request.onEnter")) { *leg = 0; *kind = 0; return 1; }
    if (!strcmp(hook, "request.onLeave")) { *leg = 0; *kind = 1; return 1; }
    if (!strcmp(hook, "response.onEnter")) { *leg = 1; *kind = 0; return 1; }
    if (!strcmp(hook, "response.onLeave")) { *leg = 1; *kind = 1; return 1; }
    return 0;
}

// MARK: strict v2 manifest (validated here as well: the Rust CLI reaches this entry directly)
//
// Mirrors AutomationCore.PluginManifest for schemaVersion 2. Exactly these keys, nothing else:
// schemaVersion=2, id, name, version, matches(1...16), read, write, endpointBindings(0...4), settings
// and optional author, summary, category (scalar-bounded 1...80, <=256 bytes) and publishedAt
// (exactly 20 ASCII bytes, UTC yyyy-MM-ddTHH:mm:ssZ, valid Gregorian date, year 1...9999). Any violation
// (schema 1/3, missing, unknown or mistyped field) is
// QJS_INVALID_INPUT. The read grants are applied to the event before any plugin code exists.

#define MAX_MAP_ENTRIES 256

static int next_cp(const uint8_t *p, size_t avail, uint32_t *cp, size_t *len) {
    size_t k = utf8_seq(p, avail);
    if (k == 0) return 0;
    uint32_t c = p[0];
    if (k == 2) c &= 0x1F; else if (k == 3) c &= 0x0F; else if (k == 4) c &= 0x07;
    for (size_t i = 1; i < k; i++) c = (c << 6) | (p[i] & 0x3F);
    *cp = c;
    *len = k;
    return 1;
}

static int is_format_cp(uint32_t c) {
    return c == 0xAD || (c >= 0x600 && c <= 0x605) || c == 0x61C || c == 0x6DD || c == 0x70F || c == 0x180E ||
           (c >= 0x200B && c <= 0x200F) || (c >= 0x2028 && c <= 0x202E) || (c >= 0x2060 && c <= 0x2064) ||
           (c >= 0x2066 && c <= 0x206F) || c == 0xFEFF || (c >= 0xFFF9 && c <= 0xFFFB) || c == 0xE0001 ||
           (c >= 0xE0020 && c <= 0xE007F);
}

static int is_space_cp(uint32_t c) {
    return c == 0x20 || (c >= 0x09 && c <= 0x0D) || c == 0xA0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) ||
           c == 0x202F || c == 0x205F || c == 0x3000;
}

// Display text: non-empty, bounded in scalars and bytes, no control/format/separator scalars.
static int text_ok(const Str *s, size_t max_chars, size_t max_bytes, int reject_blank) {
    size_t i = 0, chars = 0;
    int all_space = 1;
    if (s->n == 0 || s->n > max_bytes) return 0;
    while (i < s->n) {
        uint32_t c;
        size_t k;
        if (!next_cp((const uint8_t *)s->s + i, s->n - i, &c, &k)) return 0;
        if (c < 0x20 || (c >= 0x7F && c <= 0x9F) || is_format_cp(c)) return 0;
        if (!is_space_cp(c)) all_space = 0;
        i += k;
        chars++;
    }
    return chars <= max_chars && !(reject_blank && all_space);
}

// Category only: generated from Vendor/libunicode's Unicode 17.0.0 Cc/Cf/Zl/Zp
// ranges (unicode_general_category), sorted and merged where adjacent. Regenerate
// after a reviewed Unicode vendor bump, then compare every valid scalar with
// Swift UnicodeScalar.Properties.generalCategory. Do not change the legacy
// name/author/summary predicate above when updating category's contract.
static int is_category_forbidden_cp(uint32_t c) {
    static const uint32_t ranges[][2] = {
        {0x0, 0x1F}, {0x7F, 0x9F}, {0xAD, 0xAD}, {0x600, 0x605},
        {0x61C, 0x61C}, {0x6DD, 0x6DD}, {0x70F, 0x70F}, {0x890, 0x891},
        {0x8E2, 0x8E2}, {0x180E, 0x180E}, {0x200B, 0x200F}, {0x2028, 0x202E},
        {0x2060, 0x2064}, {0x2066, 0x206F}, {0xFEFF, 0xFEFF}, {0xFFF9, 0xFFFB},
        {0x110BD, 0x110BD}, {0x110CD, 0x110CD}, {0x13430, 0x1343F},
        {0x1BCA0, 0x1BCA3}, {0x1D173, 0x1D17A}, {0xE0001, 0xE0001}, {0xE0020, 0xE007F},
    };
    size_t lo = 0, hi = sizeof(ranges) / sizeof(ranges[0]);
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (c < ranges[mid][0]) hi = mid;
        else if (c > ranges[mid][1]) lo = mid + 1;
        else return 1;
    }
    return 0;
}

static int category_text_ok(const Str *s) {
    size_t i = 0, scalars = 0;
    int all_space = 1;
    if (s->n == 0 || s->n > 256) return 0;
    while (i < s->n) {
        uint32_t c;
        size_t k;
        if (!next_cp((const uint8_t *)s->s + i, s->n - i, &c, &k) || is_category_forbidden_cp(c)) return 0;
        if (!is_space_cp(c)) all_space = 0;
        i += k;
        if (++scalars > 80) return 0;
    }
    return !all_space;
}

static int is_alnum_c(int c) { return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'); }

static int published_at_ok(const Str *s) {
    static const unsigned char dim[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    static const int seps[6][2] = {{4, '-'}, {7, '-'}, {10, 'T'}, {13, ':'}, {16, ':'}, {19, 'Z'}};
    static const int from[6] = {0, 5, 8, 11, 14, 17};
    const unsigned char *u = (const unsigned char *)s->s;
    int v[6] = {0, 0, 0, 0, 0, 0};
    if (s->n != 20) return 0;
    for (int i = 0; i < 6; i++) if (u[seps[i][0]] != seps[i][1]) return 0;
    for (int k = 0; k < 6; k++) {
        int w = k == 0 ? 4 : 2;
        for (int j = 0; j < w; j++) {
            unsigned char c = u[from[k] + j];
            if (c < '0' || c > '9') return 0;
            v[k] = v[k] * 10 + (c - '0');
        }
    }
    if (v[0] < 1 || v[1] < 1 || v[1] > 12 || v[3] > 23 || v[4] > 59 || v[5] > 59) return 0;
    int leap = (v[0] % 4 == 0 && v[0] % 100 != 0) || v[0] % 400 == 0;
    int max = dim[v[1] - 1] + (v[1] == 2 && leap);
    return v[2] >= 1 && v[2] <= max;
}

static int semver_ok(const Str *s) {
    const char *p = s->s, *end = s->s + s->n;
    if (s->n == 0 || s->n > 64) return 0;
    for (int part = 0; part < 3; part++) {
        const char *q = p;
        while (q < end && *q >= '0' && *q <= '9') q++;
        size_t n = (size_t)(q - p);
        if (n == 0 || n > 10 || (n > 1 && *p == '0')) return 0;
        p = q;
        if (part < 2) { if (p >= end || *p != '.') return 0; p++; }
    }
    for (int tail = 0; tail < 2 && p < end; tail++) {
        char lead = tail == 0 ? '-' : '+';
        if (*p != lead) { if (tail == 0) continue; return 0; }
        p++;
        for (;;) {
            const char *q = p;
            int numeric = 1;
            while (q < end && (is_alnum_c(*q) || *q == '-')) { if (*q < '0' || *q > '9') numeric = 0; q++; }
            size_t n = (size_t)(q - p);
            if (n == 0) return 0;
            if (tail == 0 && numeric && n > 1 && *p == '0') return 0;
            p = q;
            if (p < end && *p == '.') { p++; continue; }
            break;
        }
    }
    return p == end;
}

static int uuid_ok(const Str *s) {
    if (s->n != 36) return 0;
    for (size_t i = 0; i < 36; i++) {
        if (i == 8 || i == 13 || i == 18 || i == 23) { if (s->s[i] != '-') return 0; }
        else if (hexval((unsigned char)s->s[i]) < 0) return 0;
    }
    return 1;
}

static int binding_ok(const Str *s) {
    if (s->n == 0 || s->n > 32 || !((s->s[0] >= 'A' && s->s[0] <= 'Z') || (s->s[0] >= 'a' && s->s[0] <= 'z'))) return 0;
    for (size_t i = 0; i < s->n; i++) if (!is_alnum_c(s->s[i]) && s->s[i] != '_') return 0;
    return 1;
}

static int host_ok(const Str *s) {
    if (s->n == 0 || s->n > 253) return 0;
    size_t label = 0;
    for (size_t i = 0; i <= s->n; i++) {
        if (i == s->n || s->s[i] == '.') {
            if (label == 0 || label > 63 || s->s[i - label] == '-' || s->s[i - 1] == '-') return 0;
            label = 0;
        } else {
            char c = s->s[i];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || c == '-')) return 0;
            label++;
        }
    }
    return 1;
}

static int method_ok(const Str *s) {
    if (s->n == 0 || s->n > 16) return 0;
    for (size_t i = 0; i < s->n; i++) if (s->s[i] < 'A' || s->s[i] > 'Z') return 0;
    return 1;
}

static int encoded_path_ok(const Str *s, size_t max) {
    if (s->n == 0 || s->n > max || s->s[0] != '/') return 0;
    for (size_t i = 0; i < s->n; i++) {
        unsigned char c = (unsigned char)s->s[i];
        if (c == '%') {
            if (i + 2 >= s->n || hexval((unsigned char)s->s[i + 1]) < 0 || hexval((unsigned char)s->s[i + 2]) < 0) return 0;
            i += 2;
        } else if (!(is_alnum_c(c) || strchr("-._~!$&'()*+,;=:@/", c))) return 0;
    }
    return 1;
}

static int header_name_ok(const Str *s) {
    if (s->n == 0 || s->n > 128) return 0;
    for (size_t i = 0; i < s->n; i++) if (!(is_alnum_c(s->s[i]) || strchr("!#$%&'*+-.^_`|~", s->s[i]))) return 0;
    return 1;
}

static int decl_match_ok(const Match *m) {
    for (size_t i = 0; i < m->nhosts; i++) if (!host_ok(&m->hosts[i])) return 0;
    for (size_t i = 0; i < m->nmethods; i++) if (!method_ok(&m->methods[i])) return 0;
    return m->path_kind == 0 || encoded_path_ok(&m->path, 1024);
}

// `arr` -> sorted unique strings, min...max entries. n == 0 yields *out == NULL.
static int get_list(RunState *st, JSContext *ctx, JSValueConst arr, size_t min, size_t max, Str **out, size_t *count) {
    V tmp;
    int32_t n;
    memset(&tmp, 0, sizeof(tmp));
    tmp.ctx = ctx;
    tmp.st = st;
    tmp.out.cap = 65536;
    *out = NULL;
    *count = 0;
    if (!array_prepare(&tmp, arr, &n) || (size_t)n < min || (size_t)n > max) return 0;
    if (n == 0) return 1;
    return get_str_set(st, ctx, arr, max, out, count);
}

// MARK: outbound declarations (mirrors AutomationCore.PluginOutboundPolicy)

static int out_header_ok(const Str *s) {
    if (s->n == 0 || s->n > 128) return 0;
    for (size_t i = 0; i < s->n; i++) {
        char c = s->s[i];
        if (!c || !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || strchr("!#$%&'*+-.^_`|~", c))) return 0;
    }
    static const char *const denied[] = {"host", "content-length", "transfer-encoding", "connection", "upgrade",
                                         "te", "trailer", "expect", "keep-alive", "set-cookie"};
    for (size_t i = 0; i < sizeof(denied) / sizeof(denied[0]); i++)
        if (s->n == strlen(denied[i]) && memcmp(s->s, denied[i], s->n) == 0) return 0;
    return !(s->n >= 6 && memcmp(s->s, "proxy-", 6) == 0);
}

// https://<lowercase DNS host, >= 2 labels, alphabetic TLD>/<encoded path>; default port, no userinfo/query/fragment.
static int out_url_ok(const Str *u) {
    static const char prefix[] = "https://";
    const size_t pl = sizeof(prefix) - 1;
    if (u->n > 2048 || u->n <= pl || memcmp(u->s, prefix, pl) != 0) return 0;
    const char *rest = u->s + pl;
    const char *slash = memchr(rest, '/', u->n - pl);
    if (!slash) return 0;
    Str host = {(char *)rest, (size_t)(slash - rest)}, path = {(char *)slash, u->n - pl - host.n};
    if (!host_ok(&host)) return 0;
    const char *dot = NULL;
    for (size_t i = 0; i < host.n; i++) if (host.s[i] == '.') dot = host.s + i;
    if (!dot) return 0;
    const char *tld = dot + 1;
    size_t tn = (size_t)(host.s + host.n - tld);
    int has_letter = 0;
    for (size_t i = 0; i < tn; i++) if (tld[i] >= 'a' && tld[i] <= 'z') has_letter = 1;
    if (!has_letter) return 0;
    if ((tn == 5 && memcmp(tld, "local", 5) == 0) || (tn == 9 && memcmp(tld, "localhost", 9) == 0)) return 0;
    if (!encoded_path_ok(&path, 1024)) return 0;
    for (size_t i = 0; i < path.n; i++) if (path.s[i] == '%') {
        int v = hexval((unsigned char)path.s[i + 1]) << 4 | hexval((unsigned char)path.s[i + 2]);
        if (v < 0x20 || v == 0x7F || v == 0x5C) return 0;
        i += 2;
    }
    return 1;
}

static void out_free(OutDecl *d) {
    str_free(&d->name);
    strs_free(d->headers, d->nheaders);
    memset(d, 0, sizeof(*d));
}

// `v` -> optional strict {binding:{url,method:'GET',headers:[...]}} (<= 4 bindings). Takes copies into st->out.
static int parse_outbound(RunState *st, JSContext *ctx, JSValueConst v) {
    static const char *const ok_keys[] = {"url", "method", "headers"};
    if (JS_GetClassID(v) != st->cls_object) return 0;
    JSPropertyEnum *tab;
    uint32_t cnt;
    if (JS_GetOwnPropertyNames(ctx, &tab, &cnt, v, JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK) < 0) return 0;
    int ok = cnt <= MAX_OUT;
    for (uint32_t i = 0; i < cnt && ok; i++) {
        JSValue key = JS_AtomToValue(ctx, tab[i].atom), val = JS_UNDEFINED, f[3];
        OutDecl *d = &st->out[st->nout];
        Str url = {NULL, 0};
        int good = JS_IsString(key) && get_str(ctx, key, &d->name, 32) && binding_ok(&d->name);
        st->nout++;
        if (good) good = own_data(ctx, v, tab[i].atom, &val);
        if (good) {
            good = read_obj(st, ctx, val, ok_keys, 3, 7u, f);
            if (good) {
                good = str_eq(ctx, f[1], "GET") && get_str(ctx, f[0], &url, 2048) && out_url_ok(&url) &&
                       get_list(st, ctx, f[2], 0, 8, &d->headers, &d->nheaders);
                for (size_t h = 0; good && h < d->nheaders; h++) good = out_header_ok(&d->headers[h]);
                for (int k = 0; k < 3; k++) JS_FreeValue(ctx, f[k]);
            }
        }
        str_free(&url);
        JS_FreeValue(ctx, key);
        JS_FreeValue(ctx, val);
        ok = good;
    }
    JS_FreePropertyEnum(ctx, tab, cnt);
    return ok;
}

static int load_read(RunState *st, JSContext *ctx, JSValueConst v) {
    static const char *const rk[] = {"metadata", "headers", "queryKeys", "body"};
    static const char *const bk[] = {"mode"};
    JSValue f[4], b[1];
    Str *meta = NULL;
    size_t nmeta = 0;
    int ok = 0;
    if (!read_obj(st, ctx, v, rk, 4, 15u, f)) return 0;
    b[0] = JS_UNDEFINED;
    if (!get_list(st, ctx, f[0], 0, 4, &meta, &nmeta)) goto done;
    for (size_t i = 0; i < nmeta; i++) {
        if (meta[i].n == 6 && !memcmp(meta[i].s, "method", 6)) st->read_meta |= 1u;
        else if (meta[i].n == 4 && !memcmp(meta[i].s, "host", 4)) st->read_meta |= 2u;
        else if (meta[i].n == 6 && !memcmp(meta[i].s, "status", 6)) st->read_meta |= 4u;
        else if (meta[i].n == 4 && !memcmp(meta[i].s, "path", 4)) st->read_meta |= 8u;
        else goto done;
    }
    if (!get_list(st, ctx, f[1], 0, 32, &st->rd_headers, &st->n_rd_headers)) goto done;
    for (size_t i = 0; i < st->n_rd_headers; i++) {
        if (!header_name_ok(&st->rd_headers[i])) goto done;
        for (size_t j = 0; j < st->rd_headers[i].n; j++) {
            char *c = &st->rd_headers[i].s[j];
            if (*c >= 'A' && *c <= 'Z') *c = (char)(*c + 32);
        }
        for (size_t k = 0; k < i; k++) if (str_cmp(&st->rd_headers[k], &st->rd_headers[i]) == 0) goto done;
    }
    if (!get_list(st, ctx, f[2], 0, 32, &st->rd_query, &st->n_rd_query)) goto done;
    for (size_t i = 0; i < st->n_rd_query; i++) {
        const Str *q = &st->rd_query[i];
        if (q->n == 0 || q->n > 128) goto done;
        for (size_t j = 0; j < q->n; j++) if ((unsigned char)q->s[j] < 0x20 || q->s[j] == 0x7F) goto done;
    }
    if (!read_obj(st, ctx, f[3], bk, 1, 1u, b)) goto done;
    if (str_eq(ctx, b[0], "json")) st->read_body_json = 1;
    else if (!str_eq(ctx, b[0], "none")) goto done;
    ok = 1;
done:
    strs_free(meta, nmeta);
    for (int i = 0; i < 4; i++) JS_FreeValue(ctx, f[i]);
    JS_FreeValue(ctx, b[0]);
    return ok;
}

static int load_manifest(RunState *st, JSContext *ctx, JSValueConst root, int *write_request, int *write_response) {
    static const char *const mk[] = {"schemaVersion", "id", "name", "version", "matches", "read", "write",
                                     "endpointBindings", "settings", "author", "summary", "category",
                                     "publishedAt", "outbound"};
    static const char *const wk[] = {"requestBody", "responseBody", "files"};
    JSValue f[14], w[3];
    Str s = {NULL, 0}, *bind = NULL;
    size_t nbind = 0;
    int ok = 0;
    w[0] = w[1] = w[2] = JS_UNDEFINED;
    if (!read_obj(st, ctx, root, mk, 14, 0x1FFu, f)) return 0;
    if (JS_VALUE_GET_TAG(f[0]) != JS_TAG_INT || JS_VALUE_GET_INT(f[0]) != 2) goto done;
    if (!get_str(ctx, f[1], &s, 36) || !uuid_ok(&s)) goto done;
    str_free(&s);
    if (!get_str(ctx, f[2], &s, 256) || !text_ok(&s, 80, 256, 0)) goto done;
    str_free(&s);
    if (!get_str(ctx, f[3], &s, 64) || !semver_ok(&s)) goto done;
    str_free(&s);
    if (!JS_IsUndefined(f[9])) {
        if (!get_str(ctx, f[9], &s, 256) || !text_ok(&s, 80, 256, 1)) goto done;
        str_free(&s);
    }
    if (!JS_IsUndefined(f[10])) {
        if (!get_str(ctx, f[10], &s, 1024) || !text_ok(&s, 280, 1024, 1)) goto done;
        str_free(&s);
    }
    if (!JS_IsUndefined(f[11])) {
        if (!get_str(ctx, f[11], &s, 256) || !category_text_ok(&s)) goto done;
        str_free(&s);
    }
    if (!JS_IsUndefined(f[12])) {
        if (!get_str(ctx, f[12], &s, 20) || !published_at_ok(&s)) goto done;
        str_free(&s);
    }
    {
        V tmp;
        int32_t n;
        memset(&tmp, 0, sizeof(tmp));
        tmp.ctx = ctx;
        tmp.st = st;
        tmp.out.cap = 65536;
        if (!array_prepare(&tmp, f[4], &n) || n < 1 || n > MAX_REGS) goto done;
        for (int32_t i = 0; i < n; i++) {
            JSValue el;
            if (!array_get(&tmp, f[4], i, &el)) goto done;
            int good = parse_match(st, ctx, el, &st->decl[st->ndecl]);
            JS_FreeValue(ctx, el);
            if (!good) goto done;
            st->ndecl++;
            if (!decl_match_ok(&st->decl[st->ndecl - 1])) goto done;
        }
    }
    if (!load_read(st, ctx, f[5])) goto done;
    if (!read_obj(st, ctx, f[6], wk, 3, 3u, w)) goto done;
    if (JS_VALUE_GET_TAG(w[0]) != JS_TAG_BOOL || JS_VALUE_GET_TAG(w[1]) != JS_TAG_BOOL) goto done;
    if (!JS_IsUndefined(w[2])) {
        if (JS_VALUE_GET_TAG(w[2]) != JS_TAG_BOOL) goto done;
        st->write_files = JS_VALUE_GET_BOOL(w[2]);
    }
    *write_request = JS_VALUE_GET_BOOL(w[0]);
    *write_response = JS_VALUE_GET_BOOL(w[1]);
    if (!get_list(st, ctx, f[7], 0, 4, &bind, &nbind)) goto done;
    for (size_t i = 0; i < nbind; i++) if (!binding_ok(&bind[i])) goto done;
    if (!JS_IsUndefined(f[13]) && !parse_outbound(st, ctx, f[13])) goto done;
    if (JS_GetClassID(f[8]) != st->cls_object) goto done;
    {
        Buf settings = {NULL, 0, 0, 0};
        if (!serialize_value(st, ctx, f[8], 1, 16, 8192, &settings)) goto done;
        free(settings.p);
    }
    ok = 1;
done:
    str_free(&s);
    strs_free(bind, nbind);
    for (int i = 0; i < 14; i++) JS_FreeValue(ctx, f[i]);
    JS_FreeValue(ctx, w[0]);
    JS_FreeValue(ctx, w[1]);
    JS_FreeValue(ctx, w[2]);
    return ok;
}

// Validate every decoded source and all references, including files that will never evaluate.
static int load_package(RunState *st, JSContext *ctx, JSValueConst root, int *write_request, int *write_response) {
    static const char *const keys[] = {"manifest", "sourceFiles"};
    JSValue f[2];
    if (!read_obj(st, ctx, root, keys, 2, 3u, f)) return 0;
    int ok = 0;
    Buf manifest = {NULL, 0, 0, 0};
    if (!serialize_value(st, ctx, f[0], 1, 32, QJS_MAX_MANIFEST_BYTES, &manifest)) goto done;
    free(manifest.p); manifest.p = NULL;
    if (!load_manifest(st, ctx, f[0], write_request, write_response)) goto done;
    if (JS_GetClassID(f[1]) != st->cls_object) goto done;
    JSPropertyEnum *tab;
    uint32_t count;
    if (JS_GetOwnPropertyNames(ctx, &tab, &count, f[1], JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK) < 0) goto done;
    int good = count >= 1 && count <= 64;
    size_t total = 0;
    for (uint32_t i = 0; i < count && good; i++) {
        SourceFile *file = &st->files[st->nfiles++];
        JSValue key = JS_AtomToValue(ctx, tab[i].atom), code = JS_UNDEFINED;
        good = get_str(ctx, key, &file->name, 256) && source_path_ok(&file->name) &&
               own_data(ctx, f[1], tab[i].atom, &code) && get_str(ctx, code, &file->code, 128u * 1024u);
        JS_FreeValue(ctx, key); JS_FreeValue(ctx, code);
        total += file->code.n;
        if (total > 128u * 1024u) good = 0;
    }
    JS_FreePropertyEnum(ctx, tab, count);
    if (!good) goto done;
    for (int i = 0; i < st->ndecl; i++) for (int p = 0; p < 4; p++) {
        Str *ref = &st->decl[i].hooks[p];
        if (!ref->s) continue;
        int found = 0;
        for (int j = 0; j < st->nfiles; j++) if (str_cmp(ref, &st->files[j].name) == 0) {
            found = 1; st->files[j].referenced = 1; break;
        }
        if (!found) goto done;
    }
    for (int i = 0; i < st->nfiles; i++) if (!st->files[i].referenced) goto done;
    ok = 1;
done:
    free(manifest.p);
    JS_FreeValue(ctx, f[0]); JS_FreeValue(ctx, f[1]);
    return ok;
}

// MARK: immutable views
//
// Everything a callback receives is frozen natively before user code exists (own properties become
// non-writable/non-configurable, objects non-extensible) and v2 sources are evaluated in strict mode,
// so every attempted edit - nested assignment, replacement, delete, defineProperty, adding keys - throws
// deterministically. The single exception is the invoked leg's `body` tree, and only for an enter phase
// whose manifest write grant is declared. Frozen values still serialize as plain JSON data.

static int freeze_flags(JSContext *ctx, JSValueConst obj, JSAtom atom) {
    return JS_DefineProperty(ctx, obj, atom, JS_UNDEFINED, JS_UNDEFINED, JS_UNDEFINED,
                             JS_PROP_HAS_CONFIGURABLE | JS_PROP_HAS_WRITABLE) > 0;
}

// skip_body: leave the leg's own `body` property (writable, configurable) untouched.
static int freeze_tree(RunState *st, JSContext *ctx, JSValueConst val, int depth, int skip_body) {
    if (JS_VALUE_GET_TAG(val) != JS_TAG_OBJECT) return 1;
    if (depth > 80) return 0;
    JSClassID cid = JS_GetClassID(val);
    if (cid != st->cls_object && cid != st->cls_array) return 0;
    JSPropertyEnum *tab;
    uint32_t cnt;
    int ok = 1;
    if (JS_GetOwnPropertyNames(ctx, &tab, &cnt, val, JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK) < 0) return 0;
    for (uint32_t j = 0; j < cnt && ok; j++) {
        JSValue child;
        if (budget_exceeded(st)) { ok = 0; break; }
        if (skip_body) {
            JSValue kv = JS_AtomToValue(ctx, tab[j].atom);
            int is_body = str_eq(ctx, kv, "body");
            JS_FreeValue(ctx, kv);
            if (is_body) continue;
        }
        if (cid == st->cls_array && tab[j].is_enumerable == 0) {   // length: not enumerable, still frozen below
            ok = freeze_flags(ctx, val, tab[j].atom);
            continue;
        }
        if (own_data(ctx, val, tab[j].atom, &child)) {
            ok = freeze_tree(st, ctx, child, depth + 1, 0);
            JS_FreeValue(ctx, child);
        } else {
            ok = 0;   // accessor or non-enumerable property: not plain data
        }
        if (ok) ok = freeze_flags(ctx, val, tab[j].atom);
    }
    JS_FreePropertyEnum(ctx, tab, cnt);
    if (ok) ok = JS_PreventExtensions(ctx, val) >= 0;
    return ok;
}

// MARK: public event envelope -> unfiltered identity + granted views
//
// Envelope: {id?, phase?, exchangeID?, time?, request, response?} and nothing else. request is
// {method, host, path, headers?, query?, body?}, response {status, headers?, body?}. Matching uses the
// UNFILTERED method/host/path/status. Callbacks only ever see the views built here from the manifest's
// read grants: metadata names, declared header names (ASCII case-insensitive, exposed lowercase),
// declared exact query keys, and the JSON body only for read.body.mode == "json".

static int define_dup(JSContext *ctx, JSValueConst obj, const char *name, JSValueConst v) {
    return JS_DefinePropertyValueStr(ctx, obj, name, JS_DupValue(ctx, v), JS_PROP_C_W_E) > 0;
}

// Plain object of string -> string. Returns a fresh object holding only the granted entries.
static int filter_map(RunState *st, JSContext *ctx, JSValueConst obj, const Str *granted, size_t ng, int fold, JSValue *out) {
    JSPropertyEnum *tab;
    uint32_t cnt;
    Str *keys = NULL;
    JSValue res;
    int ok = 0;
    uint32_t made = 0;
    *out = JS_UNDEFINED;
    if (JS_GetClassID(obj) != st->cls_object) return 0;
    if (JS_GetOwnPropertyNames(ctx, &tab, &cnt, obj, JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK) < 0) return 0;
    res = JS_NewObject(ctx);
    if (cnt > MAX_MAP_ENTRIES || JS_IsException(res)) goto done;
    keys = calloc(cnt ? cnt : 1, sizeof(Str));
    if (!keys) goto done;
    for (uint32_t j = 0; j < cnt; j++, made++) {
        JSValue kv = JS_AtomToValue(ctx, tab[j].atom), d;
        int good = get_str(ctx, kv, &keys[j], 1024);
        JS_FreeValue(ctx, kv);
        if (!good) goto done;
        if (fold) for (size_t c = 0; c < keys[j].n; c++) if (keys[j].s[c] >= 'A' && keys[j].s[c] <= 'Z') keys[j].s[c] += 32;
        for (uint32_t k = 0; k < j; k++) if (str_cmp(&keys[k], &keys[j]) == 0) goto done;
        if (!own_data(ctx, obj, tab[j].atom, &d)) goto done;
        if (!JS_IsString(d)) { JS_FreeValue(ctx, d); goto done; }
        for (size_t i = 0; i < ng; i++) {
            if (str_cmp(&granted[i], &keys[j]) == 0) {
                if (JS_DefinePropertyValueStr(ctx, res, granted[i].s, d, JS_PROP_C_W_E) <= 0) goto done;
                d = JS_UNDEFINED;
                break;
            }
        }
        JS_FreeValue(ctx, d);
    }
    ok = 1;
done:
    JS_FreePropertyEnum(ctx, tab, cnt);
    for (uint32_t j = 0; j < cnt && keys; j++) str_free(&keys[j]);
    free(keys);
    (void)made;
    if (ok) *out = res; else JS_FreeValue(ctx, res);
    return ok;
}

static int granted_map(RunState *st, JSContext *ctx, JSValueConst v, const Str *granted, size_t ng, int fold, JSValue *out) {
    if (JS_IsUndefined(v)) { *out = JS_NewObject(ctx); return !JS_IsException(*out); }
    return filter_map(st, ctx, v, granted, ng, fold, out);
}

static int build_request(RunState *st, JSContext *ctx, JSValueConst req, Ident *id, JSValue *out) {
    static const char *const rk[] = {"method", "host", "path", "headers", "query", "body"};
    JSValue f[6], view = JS_UNDEFINED, hdr = JS_UNDEFINED, qry = JS_UNDEFINED;
    int ok = 0;
    if (!read_obj(st, ctx, req, rk, 6, 7u, f)) return 0;
    if (!get_str(ctx, f[0], &id->method, 16) || !method_ok(&id->method)) goto done;
    if (!get_str(ctx, f[1], &id->host, 253) || id->host.n == 0) goto done;
    if (!get_str(ctx, f[2], &id->path, 4096) || id->path.n == 0 || id->path.s[0] != '/' ||
        memchr(id->path.s, '?', id->path.n) || memchr(id->path.s, '#', id->path.n)) goto done;
    if (!granted_map(st, ctx, f[3], st->rd_headers, st->n_rd_headers, 1, &hdr)) goto done;
    if (!granted_map(st, ctx, f[4], st->rd_query, st->n_rd_query, 0, &qry)) goto done;
    view = JS_NewObject(ctx);
    if (JS_IsException(view)) goto done;
    if (((st->read_meta & 1u) && !define_dup(ctx, view, "method", f[0])) ||
        ((st->read_meta & 2u) && !define_dup(ctx, view, "host", f[1])) ||
        ((st->read_meta & 8u) && !define_dup(ctx, view, "path", f[2]))) goto done;
    if (JS_DefinePropertyValueStr(ctx, view, "headers", hdr, JS_PROP_C_W_E) <= 0) { hdr = JS_UNDEFINED; goto done; }
    hdr = JS_UNDEFINED;
    if (JS_DefinePropertyValueStr(ctx, view, "query", qry, JS_PROP_C_W_E) <= 0) { qry = JS_UNDEFINED; goto done; }
    qry = JS_UNDEFINED;
    if (st->read_body_json && !JS_IsUndefined(f[5]) && !define_dup(ctx, view, "body", f[5])) goto done;
    ok = 1;
done:
    for (int i = 0; i < 6; i++) JS_FreeValue(ctx, f[i]);
    JS_FreeValue(ctx, hdr);
    JS_FreeValue(ctx, qry);
    if (ok) *out = view; else JS_FreeValue(ctx, view);
    return ok;
}

static int build_response(RunState *st, JSContext *ctx, JSValueConst resp, Ident *id, JSValue *out) {
    static const char *const sk[] = {"status", "headers", "body"};
    JSValue f[3], view = JS_UNDEFINED, hdr = JS_UNDEFINED;
    int ok = 0;
    if (!read_obj(st, ctx, resp, sk, 3, 1u, f)) return 0;
    if (!get_int(f[0], &id->status) || id->status < 100 || id->status > 599) goto done;
    if (!granted_map(st, ctx, f[1], st->rd_headers, st->n_rd_headers, 1, &hdr)) goto done;
    view = JS_NewObject(ctx);
    if (JS_IsException(view)) goto done;
    if ((st->read_meta & 4u) && !define_dup(ctx, view, "status", f[0])) goto done;
    if (JS_DefinePropertyValueStr(ctx, view, "headers", hdr, JS_PROP_C_W_E) <= 0) { hdr = JS_UNDEFINED; goto done; }
    hdr = JS_UNDEFINED;
    if (st->read_body_json && !JS_IsUndefined(f[2]) && !define_dup(ctx, view, "body", f[2])) goto done;
    ok = 1;
done:
    for (int i = 0; i < 3; i++) JS_FreeValue(ctx, f[i]);
    JS_FreeValue(ctx, hdr);
    if (ok) *out = view; else JS_FreeValue(ctx, view);
    return ok;
}

// Envelope -> identity (unfiltered) and the invoked leg's granted view in *legv.
static int load_event(RunState *st, JSContext *ctx, JSValueConst ev, const char *hook, int response_phase,
                      Ident *id, JSValue *legv) {
    static const char *const ek[] = {"id", "phase", "exchangeID", "time", "request", "response"};
    JSValue f[6], reqv = JS_UNDEFINED, respv = JS_UNDEFINED;
    Str s = {NULL, 0};
    int ok = 0;
    if (!read_obj(st, ctx, ev, ek, 6, 16u | (response_phase ? 32u : 0u), f)) return 0;
    for (int i = 0; i < 3; i += 2) {   // id, exchangeID
        if (JS_IsUndefined(f[i])) continue;
        if (!get_str(ctx, f[i], &s, 36) || !uuid_ok(&s)) goto done;
        str_free(&s);
    }
    if (!JS_IsUndefined(f[1])) {
        if (!get_str(ctx, f[1], &s, 32) || s.n != strlen(hook) || memcmp(s.s, hook, s.n)) goto done;
        str_free(&s);
    }
    if (!JS_IsUndefined(f[3])) {
        if (!get_str(ctx, f[3], &s, 64) || s.n == 0) goto done;
        for (size_t i = 0; i < s.n; i++) if ((unsigned char)s.s[i] < 0x20 || s.s[i] == 0x7F) goto done;
        str_free(&s);
    }
    if (!build_request(st, ctx, f[4], id, &reqv)) goto done;
    if (!JS_IsUndefined(f[5])) {
        if (!build_response(st, ctx, f[5], id, &respv)) goto done;
        if (!response_phase) id->status = 0;   // a response is meaningless for request phases; never matched or exposed
    }
    if (response_phase) {
        if (!freeze_tree(st, ctx, reqv, 1, 0)) goto done;   // response.request is read-only, body included
        if (JS_DefinePropertyValueStr(ctx, respv, "request", reqv, JS_PROP_C_W_E) <= 0) { reqv = JS_UNDEFINED; goto done; }
        reqv = JS_UNDEFINED;
        if (!freeze_tree(st, ctx, respv, 1, st->body_writable)) goto done;
        *legv = respv;
        respv = JS_UNDEFINED;
    } else {
        if (!freeze_tree(st, ctx, reqv, 1, st->body_writable)) goto done;
        *legv = reqv;
        reqv = JS_UNDEFINED;
    }
    ok = 1;
done:
    str_free(&s);
    for (int i = 0; i < 6; i++) JS_FreeValue(ctx, f[i]);
    JS_FreeValue(ctx, reqv);
    JS_FreeValue(ctx, respv);
    return ok;
}

// Keep the shared C entry safe even when a caller bypasses Swift/Rust JSON preflight.
// An integer outside the common JSON range would be rounded by JS_ParseJSON, then silently
// change an untouched field when another body field is edited. Strings and floating tokens
// retain the existing IEEE-754 contract. This scanner runs after strict JSON validation.
static int v2_safe_integer_tokens(const uint8_t *text, size_t len) {
    int quoted = 0, escaped = 0;
    for (size_t i = 0; i < len; i++) {
        uint8_t c = text[i];
        if (quoted) {
            if (escaped) escaped = 0;
            else if (c == '\\') escaped = 1;
            else if (c == '"') quoted = 0;
        } else if (c == '"') quoted = 1;
        else if (c == '-' || (c >= '0' && c <= '9')) {
            size_t start = i;
            int integral = 1;
            while (i < len && !strchr(" \t\r\n,]}", text[i])) {
                if (text[i] == '.' || text[i] == 'e' || text[i] == 'E') integral = 0;
                i++;
            }
            size_t digits = start + (c == '-'), count = i - digits;
            if (integral && (count > 16 || (count == 16 && memcmp(text + digits, "9007199254740991", 16) > 0))) return 0;
            if (i) i--;
        }
    }
    return 1;
}

// MARK: standard global fetch (fetch mode only)
//
// One synchronous trusted host callback per request. fetch() validates natively, blocks in the callback
// (the wait extends the CPU deadline but never the wall deadline) and returns an already-settled
// Promise. Promise jobs are drained only while a registered callback is active.

#define FETCH_CPU_MS 250u
#define FETCH_WALL_MS 120000ull
#define FETCH_MAX_REQUESTS 64u
#define FETCH_MAX_JSON_BYTES 8192u
#define FETCH_MAX_JSON_DEPTH 16
#define FETCH_REQUEST_MS 5000u
#define FETCH_MAX_BODY (1024u * 1024u)
#define FETCH_MAX_TOTAL (16u * 1024u * 1024u)
#define FETCH_REQ_BODY_MAX 8192u
#define FETCH_REQ_JSON_CAP (128u * 1024u)

struct QJSFetchReply {
    int32_t status;
    uint8_t *body;
    size_t len;
    int has;
    int overflow;
};

int32_t qjs_fetch_reply_set(QJSFetchReply *reply, int32_t status, const uint8_t *body, size_t len) {
    if (!reply) return 1;
    if (status < 100 || status > 599 || len > FETCH_MAX_BODY || (len && !body)) {
        reply->overflow = 1;
        return 1;
    }
    uint8_t *copy = copy_z(body, len);
    if (!copy) { reply->overflow = 1; return 1; }
    free(reply->body);
    reply->body = copy;
    reply->len = len;
    reply->status = status;
    reply->has = 1;
    return 0;
}

// Consumes `v`. Returns a Promise already fulfilled (reject == 0) or rejected (reject == 1) with it.
static JSValue settled_promise(JSContext *ctx, JSValue v, int reject) {
    JSValue f[2];
    JSValue p = JS_NewPromiseCapability(ctx, f);
    if (JS_IsException(p)) { JS_FreeValue(ctx, v); return p; }
    JSValue r = JS_Call(ctx, f[reject], JS_UNDEFINED, 1, (JSValueConst *)&v);
    int failed = JS_IsException(r);
    JS_FreeValue(ctx, r);
    JS_FreeValue(ctx, v);
    JS_FreeValue(ctx, f[0]);
    JS_FreeValue(ctx, f[1]);
    if (failed) { JS_FreeValue(ctx, p); return JS_EXCEPTION; }
    return p;
}

static JSValue reject_error(JSContext *ctx, int syntax, const char *msg) {
    if (syntax) JS_ThrowSyntaxError(ctx, "%s", msg);
    else JS_ThrowTypeError(ctx, "%s", msg);
    return settled_promise(ctx, JS_GetException(ctx), 1);
}

// Private shared state for the two body readers; neither JS nor the Response exposes this object.
static int consume_response_body(JSContext *ctx, JSValueConst state) {
    JSValue used = JS_GetPropertyStr(ctx, state, "used");
    if (JS_IsException(used)) return -1;
    int consumed = JS_ToBool(ctx, used);
    JS_FreeValue(ctx, used);
    if (consumed < 0) return -1;
    if (consumed) return 0;
    return JS_SetPropertyStr(ctx, state, "used", JS_TRUE) < 0 ? -1 : 1;
}

static JSValue js_resp_used(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data) {
    (void)this_val; (void)argc; (void)argv; (void)magic;
    return JS_GetPropertyStr(ctx, data[0], "used");
}

static JSValue js_resp_text(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data) {
    (void)this_val; (void)argc; (void)argv; (void)magic;
    int consumed = consume_response_body(ctx, data[1]);
    if (consumed < 0) return JS_EXCEPTION;
    if (!consumed) return reject_error(ctx, 0, "response body already consumed");
    return settled_promise(ctx, JS_DupValue(ctx, data[0]), 0);
}

static JSValue js_resp_json(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv, int magic, JSValue *data) {
    (void)this_val; (void)argc; (void)argv; (void)magic;
    int consumed = consume_response_body(ctx, data[1]);
    if (consumed < 0) return JS_EXCEPTION;
    if (!consumed) return reject_error(ctx, 0, "response body already consumed");
    RunState *st = JS_GetContextOpaque(ctx);
    size_t n;
    const char *c = JS_ToCStringLen2(ctx, &n, data[0], 0);
    if (!c) return JS_EXCEPTION;
    int ok = json_check_budgeted((const uint8_t *)c, n, 64, st) && v2_safe_integer_tokens((const uint8_t *)c, n);
    if (st && budget_exceeded(st)) {
        JS_FreeCString(ctx, c);
        return JS_ThrowTypeError(ctx, "response JSON stopped");
    }
    JSValue parsed = JS_UNDEFINED;
    if (ok) parsed = JS_ParseJSON(ctx, c, n, "<response>");
    JS_FreeCString(ctx, c);
    if (!ok) return reject_error(ctx, 1, "invalid JSON");
    if (JS_IsException(parsed)) {
        if (!st || st->stop || st->oom) return JS_EXCEPTION;
        return settled_promise(ctx, JS_GetException(ctx), 1);
    }
    return settled_promise(ctx, parsed, 0);
}

static JSValue make_response(JSContext *ctx, int32_t status, const uint8_t *body, size_t len) {
    JSValue obj = JS_NewObject(ctx);
    JSValue bodyv = JS_NewStringLen(ctx, (const char *)body, len);
    JSValue state = JS_NewObjectProto(ctx, JS_NULL);
    JSValue text = JS_UNDEFINED, json = JS_UNDEFINED, used = JS_UNDEFINED;
    if (JS_IsException(obj) || JS_IsException(bodyv) || JS_IsException(state)) goto fail;
    if (JS_SetPropertyStr(ctx, state, "used", JS_FALSE) < 0) goto fail;
    JSValueConst data[2] = {bodyv, state};
    text = JS_NewCFunctionData(ctx, js_resp_text, 0, 0, 2, data);
    json = JS_NewCFunctionData(ctx, js_resp_json, 0, 0, 2, data);
    used = JS_NewCFunctionData(ctx, js_resp_used, 0, 0, 1, (JSValueConst *)&state);
    if (JS_IsException(text) || JS_IsException(json) || JS_IsException(used)) goto fail;
    if (JS_DefinePropertyValueStr(ctx, obj, "status", JS_NewInt32(ctx, status), JS_PROP_ENUMERABLE) < 0) goto fail;
    if (JS_DefinePropertyValueStr(ctx, obj, "ok", JS_NewBool(ctx, status >= 200 && status <= 299), JS_PROP_ENUMERABLE) < 0) goto fail;
    JSAtom atom = JS_NewAtom(ctx, "bodyUsed");
    if (atom == JS_ATOM_NULL) goto fail;
    int ok = JS_DefinePropertyGetSet(ctx, obj, atom, used, JS_UNDEFINED, JS_PROP_ENUMERABLE);
    used = JS_UNDEFINED;
    JS_FreeAtom(ctx, atom);
    if (ok < 0) goto fail;
    if (JS_SetPropertyStr(ctx, obj, "text", text) < 0) { text = JS_UNDEFINED; goto fail; }
    text = JS_UNDEFINED;
    if (JS_SetPropertyStr(ctx, obj, "json", json) < 0) { json = JS_UNDEFINED; goto fail; }
    JS_FreeValue(ctx, bodyv);
    JS_FreeValue(ctx, state);
    return obj;
fail:
    JS_FreeValue(ctx, obj);
    JS_FreeValue(ctx, bodyv);
    JS_FreeValue(ctx, text);
    JS_FreeValue(ctx, json);
    JS_FreeValue(ctx, state);
    JS_FreeValue(ctx, used);
    return JS_EXCEPTION;
}

typedef struct {
    Str url, method;
    Str *names, *values;
    size_t n;
    Str body;
    int has_body;
} FetchReq;

static void fetch_req_free(FetchReq *r) {
    str_free(&r->url);
    str_free(&r->method);
    strs_free(r->names, r->n);
    strs_free(r->values, r->n);
    str_free(&r->body);
    memset(r, 0, sizeof(*r));
}

static int fetch_header_value_ok(const Str *v) {
    for (size_t k = 0; k < v->n; k++) {
        unsigned char c = (unsigned char)v->s[k];
        if (!(c == '\t' || (c >= 0x20 && c <= 0x7E))) return 0;
    }
    return 1;
}

// Fills `r` from fetch(url[, init]). 1 = valid, 0 = invalid, -1 = allocation failure.
static int parse_fetch_args(RunState *st, JSContext *ctx, int argc, JSValueConst *argv, FetchReq *r) {
    static const char *const keys[] = {"method", "headers", "body"};
    JSValue f[3] = {JS_UNDEFINED, JS_UNDEFINED, JS_UNDEFINED};
    JSPropertyEnum *tab = NULL;
    uint32_t cnt = 0;
    unsigned seen = 0;
    size_t total = 0;
    int ok = 0, is_write = 0;
    memset(r, 0, sizeof(*r));
    if (argc < 1 || argc > 2 || !get_str(ctx, argv[0], &r->url, 2048) || !out_url_ok(&r->url)) goto done;
    if (argc == 2 && !JS_IsUndefined(argv[1]) && !read_obj_fields(st, ctx, argv[1], keys, 3, 0u, f, &seen)) goto done;

    if (!JS_IsUndefined(f[0])) {
        if (!get_str(ctx, f[0], &r->method, 16)) goto done;
        for (size_t i = 0; i < r->method.n; i++) if (r->method.s[i] >= 'a' && r->method.s[i] <= 'z') r->method.s[i] -= 32;
    } else {
        r->method.s = strdup("GET");
        if (!r->method.s) { st->oom = 1; goto done; }
        r->method.n = 3;
    }
    if (!((r->method.n == 3 && (!memcmp(r->method.s, "GET", 3) || !memcmp(r->method.s, "PUT", 3))) ||
          (r->method.n == 4 && !memcmp(r->method.s, "POST", 4)))) goto done;
    is_write = r->method.s[0] != 'G';

    if (!JS_IsUndefined(f[2])) {
        if (!is_write || !get_str(ctx, f[2], &r->body, FETCH_REQ_BODY_MAX) ||
            !json_check((const uint8_t *)r->body.s, r->body.n, FETCH_MAX_JSON_DEPTH)) goto done;
        r->has_body = 1;
    }
    if (!JS_IsUndefined(f[1])) {
        if (JS_GetClassID(f[1]) != st->cls_object) goto done;
        if (JS_GetOwnPropertyNames(ctx, &tab, &cnt, f[1], JS_GPN_STRING_MASK | JS_GPN_SYMBOL_MASK) < 0) { tab = NULL; goto done; }
        if (cnt > 8) goto done;
    }
    r->names = calloc(cnt + 1, sizeof(Str));
    r->values = calloc(cnt + 1, sizeof(Str));
    if (!r->names || !r->values) { st->oom = 1; goto done; }
    for (uint32_t i = 0; i < cnt; i++) {
        JSValue key = JS_AtomToValue(ctx, tab[i].atom), val = JS_UNDEFINED;
        int good = JS_IsString(key) && get_str(ctx, key, &r->names[i], 128);
        r->n = i + 1;
        if (good) {
            for (size_t k = 0; k < r->names[i].n; k++) {
                char *c = &r->names[i].s[k];
                if (*c >= 'A' && *c <= 'Z') *c += 32;
            }
            good = out_header_ok(&r->names[i]) && !(r->names[i].n == 15 && !memcmp(r->names[i].s, "accept-encoding", 15)) &&
                   own_data(ctx, f[1], tab[i].atom, &val) && get_str(ctx, val, &r->values[i], OUT_MAX_VALUE) &&
                   fetch_header_value_ok(&r->values[i]);
        }
        if (good) {
            total += r->values[i].n;
            if (total > OUT_MAX_TOTAL) good = 0;
            for (uint32_t j = 0; good && j < i; j++) if (str_cmp(&r->names[j], &r->names[i]) == 0) good = 0;
            if (good && r->has_body && r->names[i].n == 12 && !memcmp(r->names[i].s, "content-type", 12) &&
                !(r->values[i].n == 16 && !memcmp(r->values[i].s, "application/json", 16))) good = 0;
        }
        JS_FreeValue(ctx, key);
        JS_FreeValue(ctx, val);
        if (!good) goto done;
    }
    for (size_t i = 1; i < r->n; i++)
        for (size_t j = i; j > 0 && str_cmp(&r->names[j - 1], &r->names[j]) > 0; j--) {
            Str t = r->names[j]; r->names[j] = r->names[j - 1]; r->names[j - 1] = t;
            t = r->values[j]; r->values[j] = r->values[j - 1]; r->values[j - 1] = t;
        }
    ok = 1;
done:
    if (tab) JS_FreePropertyEnum(ctx, tab, cnt);
    for (int i = 0; i < 3; i++) JS_FreeValue(ctx, f[i]);
    if (!ok) { int oom = st->oom; fetch_req_free(r); return oom ? -1 : 0; }
    return 1;
}

static void put_json_string(Buf *b, const Str *s) {
    b_ch(b, '"');
    for (size_t k = 0; k < s->n; k++) {
        unsigned char c = (unsigned char)s->s[k];
        if (c == '"' || c == '\\') { b_ch(b, '\\'); b_ch(b, (char)c); }
        else if (c < 0x20 || c == 0x7F) { char e[7]; snprintf(e, sizeof(e), "\\u%04x", c); b_str(b, e); }
        else b_ch(b, (char)c);
    }
    b_ch(b, '"');
}

// {"url","method","headers":{lowercase,sorted},"body"?:"<json text>"}. A body without content-type gets application/json.
static int build_fetch_json(const FetchReq *r, Buf *b) {
    int has_ct = 0;
    for (size_t i = 0; i < r->n; i++) if (r->names[i].n == 12 && !memcmp(r->names[i].s, "content-type", 12)) has_ct = 1;
    b->p = malloc(FETCH_REQ_JSON_CAP + 1);
    b->len = 0;
    b->cap = FETCH_REQ_JSON_CAP;
    b->overflow = 0;
    if (!b->p) return 0;
    b_str(b, "{\"url\":");
    put_json_string(b, &r->url);
    b_str(b, ",\"method\":");
    put_json_string(b, &r->method);
    b_str(b, ",\"headers\":{");
    int first = 1, ct_done = !(r->has_body && !has_ct);
    for (size_t i = 0; i <= r->n; i++) {
        if (!ct_done && (i == r->n || str_cmp(&(Str){"content-type", 12}, &r->names[i]) < 0)) {
            if (!first) b_ch(b, ',');
            b_str(b, "\"content-type\":\"application/json\"");
            first = 0;
            ct_done = 1;
        }
        if (i == r->n) break;
        if (!first) b_ch(b, ',');
        first = 0;
        put_json_string(b, &r->names[i]);
        b_ch(b, ':');
        put_json_string(b, &r->values[i]);
    }
    b_ch(b, '}');
    if (r->has_body) {
        b_str(b, ",\"body\":");
        put_json_string(b, &r->body);
    }
    b_ch(b, '}');
    if (b->overflow) { free(b->p); b->p = NULL; return 0; }
    b->p[b->len] = 0;
    return 1;
}

static JSValue js_fetch(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    RunState *st = JS_GetContextOpaque(ctx);
    FetchReq req;
    Buf json = {NULL, 0, 0, 0};
    // Outside an active registered callback (including its promise-job drain) the whole run is invalid.
    if (!st || !st->fetch_cb || !st->in_callback) {
        if (st) st->attach_failed = 1;
        return JS_ThrowTypeError(ctx, "invalid fetch");
    }
    if (budget_exceeded(st)) return JS_ThrowTypeError(ctx, "fetch stopped");
    int parsed = parse_fetch_args(st, ctx, argc, argv, &req);
    if (parsed < 0) return JS_ThrowTypeError(ctx, "out of memory");
    if (!parsed) return reject_error(ctx, 0, "invalid fetch request");
    if (st->nrequests >= FETCH_MAX_REQUESTS) { fetch_req_free(&req); return reject_error(ctx, 0, "fetch request limit"); }
    int built = build_fetch_json(&req, &json);
    fetch_req_free(&req);
    if (!built) return reject_error(ctx, 0, "invalid fetch request");
    st->nrequests++;

    uint64_t t0 = now_ns();
    uint64_t left_ms = st->wall_deadline_ns > t0 ? (st->wall_deadline_ns - t0) / 1000000ull : 0;
    if (left_ms == 0) {
        free(json.p);
        st->stop = QJS_TIMEOUT;
        return JS_ThrowTypeError(ctx, "fetch stopped");
    }
    uint32_t timeout_ms = left_ms < FETCH_REQUEST_MS ? (uint32_t)left_ms : FETCH_REQUEST_MS;
    QJSFetchReply reply;
    memset(&reply, 0, sizeof(reply));
    int32_t rc = st->fetch_cb(st->fetch_opaque, json.p, json.len, timeout_ms, &reply);
    free(json.p);
    // Host wait is excluded from the cumulative CPU budget only; the wall deadline keeps running.
    st->deadline_ns += now_ns() - t0;
    JSValue out;
    if (rc == 2) {
        st->stop = QJS_CANCELLED;
        out = JS_ThrowTypeError(ctx, "fetch aborted");
    } else if (budget_exceeded(st)) {
        out = JS_ThrowTypeError(ctx, "fetch stopped");
    } else if (reply.overflow || (rc == 0 && reply.has && st->response_total + reply.len > FETCH_MAX_TOTAL)) {
        st->stop = QJS_MEMORY_OR_STACK;
        out = JS_ThrowTypeError(ctx, "fetch response too large");
    } else if (rc != 0 || !reply.has || !utf8_valid(reply.body, reply.len)) {
        out = reject_error(ctx, 0, "network error");
    } else {
        st->response_total += reply.len;
        JSValue resp = make_response(ctx, reply.status, reply.body, reply.len);
        out = JS_IsException(resp) ? resp : settled_promise(ctx, resp, 0);
    }
    free(reply.body);
    return out;
}

// Read-only scheduling probe: no transport, no committed intents, and a fresh VM for the later run.
static JSValue js_probe_fetch(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    RunState *st = JS_GetContextOpaque(ctx);
    if (!st || !st->in_callback) {
        if (st) st->attach_failed = 1;
        return JS_ThrowTypeError(ctx, "fetch outside callback");
    }
    st->requires_async = 1;
    return JS_ThrowTypeError(ctx, "asynchronous hook required");
}

static int install_fetch(JSContext *ctx, int probe) {
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue fn = JS_NewCFunction(ctx, probe ? js_probe_fetch : js_fetch, "fetch", 1);
    int ok = !JS_IsException(fn) && JS_DefinePropertyValueStr(ctx, global, "fetch", fn, 0) > 0;
    if (JS_IsException(fn)) JS_FreeValue(ctx, fn);
    JS_FreeValue(ctx, global);
    return ok;
}

// MARK: Interceptor.saveJSON (response.onLeave: fetch-save mode and the read-only scheduling probe)
//
// saveJSON(key, jsonText) validates natively: key 1...1024 UTF-8 bytes (no NUL, no lone surrogate), text 1...1 MiB of
// UTF-8 that the raw strict scanner accepts (depth <= 64, no duplicate keys). No second JS value tree is built. It
// then blocks in one trusted host callback with the original bytes and returns an already-settled Promise. Rejected
// attempts never reach the host and do not consume the save budgets.

#define SAVE_MAX_KEY 1024u
#define SAVE_MAX_JSON (1024u * 1024u)
#define SAVE_MAX_COUNT 64u
#define SAVE_MAX_TOTAL (16u * 1024u * 1024u)
#define SAVE_REQUEST_MS 10000u

// Borrowed UTF-8 view of a string argument. Returns 1 valid, 0 invalid, -1 conversion failure (exception pending).
// `*c` is NULL unless a view was obtained and must then be released with JS_FreeCString.
static int save_arg(JSContext *ctx, JSValueConst v, size_t max, const char **c, size_t *n) {
    *c = NULL;
    *n = 0;
    if (!JS_IsString(v)) return 0;
    *c = JS_ToCStringLen2(ctx, n, v, 0);
    if (!*c) return -1;
    return *n >= 1 && *n <= max && memchr(*c, 0, *n) == NULL && utf8_valid((const uint8_t *)*c, *n);
}

static JSValue js_save_json(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    RunState *st = JS_GetContextOpaque(ctx);
    const char *key = NULL, *text = NULL;
    size_t key_len = 0, text_len = 0;
    if (!st || !st->save_exposed || !st->in_callback) {
        if (st) st->attach_failed = 1;
        return JS_ThrowTypeError(ctx, "invalid saveJSON");
    }
    if (budget_exceeded(st)) return JS_ThrowTypeError(ctx, "saveJSON stopped");
    if (argc != 2) return reject_error(ctx, 0, "invalid saveJSON arguments");
    // Grant, callback and count are checked before any string conversion or scanning.
    if (!st->write_files || !st->save_cb || st->nsaves >= SAVE_MAX_COUNT) return reject_error(ctx, 0, "saveJSON rejected");
    int valid = save_arg(ctx, argv[0], SAVE_MAX_KEY, &key, &key_len);
    if (valid < 0) return JS_EXCEPTION;
    if (valid) {
        valid = save_arg(ctx, argv[1], SAVE_MAX_JSON, &text, &text_len);
        if (valid < 0) { JS_FreeCString(ctx, key); return JS_EXCEPTION; }
    }
    // Byte quota is known once the text length is; it precedes the scan. The converted text is NUL-terminated.
    if (valid && text_len > SAVE_MAX_TOTAL - st->save_total) valid = 0;
    if (valid) valid = json_check_budgeted((const uint8_t *)text, text_len, 64, st);
    if (!valid) {
        JS_FreeCString(ctx, key);
        JS_FreeCString(ctx, text);
        if (budget_exceeded(st)) return JS_ThrowTypeError(ctx, "saveJSON stopped");
        return reject_error(ctx, 0, "saveJSON rejected");
    }
    // Final budget check immediately before the host call.
    if (budget_exceeded(st)) {
        JS_FreeCString(ctx, key);
        JS_FreeCString(ctx, text);
        return JS_ThrowTypeError(ctx, "saveJSON stopped");
    }
    st->nsaves++;
    st->save_total += text_len;

    uint64_t t0 = now_ns();
    uint64_t left_ms = st->wall_deadline_ns > t0 ? (st->wall_deadline_ns - t0) / 1000000ull : 0;
    if (left_ms == 0) {
        JS_FreeCString(ctx, key);
        JS_FreeCString(ctx, text);
        st->stop = QJS_TIMEOUT;
        return JS_ThrowTypeError(ctx, "saveJSON stopped");
    }
    uint32_t timeout_ms = left_ms < SAVE_REQUEST_MS ? (uint32_t)left_ms : SAVE_REQUEST_MS;
    int32_t rc = st->save_cb(st->save_opaque, (const uint8_t *)key, key_len, (const uint8_t *)text, text_len, timeout_ms);
    JS_FreeCString(ctx, key);
    JS_FreeCString(ctx, text);
    // Host wait is excluded from the cumulative CPU budget only; the wall deadline keeps running.
    st->deadline_ns += now_ns() - t0;
    if (rc == 2) {
        st->stop = QJS_CANCELLED;
        return JS_ThrowTypeError(ctx, "saveJSON aborted");
    }
    if (budget_exceeded(st)) return JS_ThrowTypeError(ctx, "saveJSON stopped");
    if (rc != 0) return reject_error(ctx, 0, "saveJSON failed");
    return settled_promise(ctx, JS_UNDEFINED, 0);
}

// Read-only scheduling probe: recognition only. Any call, even a swallowed one, requires the asynchronous path;
// nothing is validated, saved or called back.
static JSValue js_probe_save_json(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val; (void)argc; (void)argv;
    RunState *st = JS_GetContextOpaque(ctx);
    if (!st || !st->in_callback) {
        if (st) st->attach_failed = 1;
        return JS_ThrowTypeError(ctx, "saveJSON outside callback");
    }
    st->requires_async = 1;
    return JS_ThrowTypeError(ctx, "asynchronous hook required");
}

static int install_save_json(JSContext *ctx, int probe) {
    JSValue global = JS_GetGlobalObject(ctx);
    JSValue ns = JS_GetPropertyStr(ctx, global, "Interceptor");
    JSValue fn = JS_NewCFunction(ctx, probe ? js_probe_save_json : js_save_json, "saveJSON", 2);
    int ok = !JS_IsException(ns) && !JS_IsException(fn);
    // JS_DefinePropertyValueStr consumes `fn` on success and failure.
    if (ok) ok = JS_DefinePropertyValueStr(ctx, ns, "saveJSON", fn, JS_PROP_ENUMERABLE) > 0;
    else JS_FreeValue(ctx, fn);
    JS_FreeValue(ctx, ns);
    JS_FreeValue(ctx, global);
    return ok;
}

// Drains promise jobs until none remain, then resolves a returned Promise in place (*ret is replaced by its
// fulfilment value). Pending after the drain means no job can ever settle it: a script error.
static int settle_callback(RunState *st, JSContext *ctx, JSRuntime *rt, JSValue *ret) {
    for (;;) {
        if (budget_exceeded(st)) return st->stop;
        JSContext *jctx = NULL;
        int r = JS_ExecutePendingJob(rt, &jctx);
        if (r == 0) break;
        if (r < 0) return classify_exception(ctx, st, QJS_SCRIPT_ERROR);
    }
    if (budget_exceeded(st)) return st->stop;
    int state = (int)JS_PromiseState(ctx, *ret);
    if (state < 0) return 0;   // not a Promise
    if (state == JS_PROMISE_FULFILLED) {
        JSValue v = JS_PromiseResult(ctx, *ret);
        JS_FreeValue(ctx, *ret);
        *ret = v;
        return 0;
    }
    return st->oom ? QJS_MEMORY_OR_STACK : QJS_SCRIPT_ERROR;
}

static int v2_setup_failure(const RunState *st) {
    return st->stop ? st->stop : st->oom ? QJS_MEMORY_OR_STACK : QJS_INVALID_INPUT;
}

static QJSResult run_v2_impl(QJSCancelToken *token, const QJSLimits *limits,
                            QJSFetchCallback fetch_cb, void *fetch_opaque, int probe_fetch,
                            int expose_save, QJSSaveJSONCallback save_callback_in, void *save_opaque_in,
                            const uint8_t *package_json, size_t package_len,
                            const char *hook,
                            const uint8_t *event_json, size_t event_len,
                            const uint8_t *config_json, size_t config_len) {
    QJSResult res = {QJS_INTERNAL, NULL, 0};
    uint8_t *src = NULL, *ev = NULL, *cfg = NULL, *package = NULL;
    size_t source_len = 0;
    JSRuntime *rt = NULL;
    JSContext *ctx = NULL;
    JSValue evv = JS_UNDEFINED, cfgv = JS_UNDEFINED, manv = JS_UNDEFINED, legv = JS_UNDEFINED;
    Buf original = {NULL, 0, 0, 0};
    Ident id;
    RunState st;
    int status = QJS_INTERNAL, have_id = 0, leg = 0, kind = 0;
    int write_request = 0, write_response = 0, had_body = 0;

    memset(&st, 0, sizeof(st));
    memset(&id, 0, sizeof(id));
    for (int i = 0; i < MAX_REGS; i++) st.regs[i].cb = JS_UNDEFINED;
    st.token = token;
    {
        size_t cpu_ms = limits ? limits->deadline_ms : 0;
        if (fetch_cb && cpu_ms > FETCH_CPU_MS) cpu_ms = FETCH_CPU_MS;
        st.deadline_ns = now_ns() + (uint64_t)cpu_ms * 1000000ull;
    }
    st.save_cb = save_callback_in;
    st.save_opaque = save_opaque_in;
    st.save_exposed = expose_save || probe_fetch;
    if (fetch_cb) {
        st.fetch_cb = fetch_cb;
        st.fetch_opaque = fetch_opaque;
        st.wall_deadline_ns = now_ns() + FETCH_WALL_MS * 1000000ull;
    }

    if (!limits || limits->deadline_ms == 0 || limits->heap_bytes == 0 || limits->stack_bytes == 0 ||
        limits->max_result_bytes == 0 || limits->max_result_depth == 0) {
        return res;
    }
    if (!parse_phase(hook, &leg, &kind)) { res.status = QJS_INVALID_INPUT; return res; }
    // Fetch mode exists only for response.onLeave; every other phase keeps the synchronous contract.
    if ((fetch_cb || probe_fetch) && !(leg == 1 && kind == 1)) { res.status = QJS_INVALID_INPUT; return res; }
    st.phase_leg = leg;
    st.phase_kind = kind;

    if (!package_json || package_len == 0 || package_len > QJS_MAX_PACKAGE_BYTES ||
        !event_json || event_len == 0 || event_len > limits->max_event_bytes ||
        !config_json || config_len == 0 || config_len > limits->max_config_bytes) {
        res.status = QJS_INVALID_INPUT;
        return res;
    }
    if (budget_exceeded(&st)) { res.status = st.stop; return res; }
    ev = copy_z(event_json, event_len);
    cfg = copy_z(config_json, config_len);
    package = copy_z(package_json, package_len);
    if (!ev || !cfg || !package) { status = QJS_MEMORY_OR_STACK; goto cleanup; }
    if (!json_check(ev, event_len, 64) || !json_check(cfg, config_len, 64) || !json_check(package, package_len, 64) ||
        !v2_safe_integer_tokens(ev, event_len) || !v2_safe_integer_tokens(cfg, config_len) ||
        !v2_safe_integer_tokens(package, package_len)) {
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
    {
        JSValue o = JS_NewObject(ctx), a = JS_NewArray(ctx);
        st.cls_object = JS_GetClassID(o);
        st.cls_array = JS_GetClassID(a);
        JS_FreeValue(ctx, o);
        JS_FreeValue(ctx, a);
        if (!st.cls_object || !st.cls_array || st.cls_object == st.cls_array) goto cleanup;
    }
    JS_SetContextOpaque(ctx, &st);

    // Manifest, event and config are parsed and validated natively before user code exists.
    manv = JS_ParseJSON(ctx, (const char *)package, package_len, "<package>");
    if (JS_IsException(manv)) { status = classify_exception(ctx, &st, QJS_INVALID_INPUT); goto cleanup; }
    evv = JS_ParseJSON(ctx, (const char *)ev, event_len, "<event>");
    if (JS_IsException(evv)) { status = classify_exception(ctx, &st, QJS_INVALID_INPUT); goto cleanup; }
    cfgv = JS_ParseJSON(ctx, (const char *)cfg, config_len, "<config>");
    if (JS_IsException(cfgv)) { status = classify_exception(ctx, &st, QJS_INVALID_INPUT); goto cleanup; }

    if (!load_package(&st, ctx, manv, &write_request, &write_response)) { status = v2_setup_failure(&st); goto cleanup; }
    st.body_writable = kind == 0 && (leg == 0 ? write_request : write_response);
    if (!freeze_tree(&st, ctx, cfgv, 1, 0)) { status = v2_setup_failure(&st); goto cleanup; }
    have_id = 1;   // ident_free tolerates a partially filled identity
    if (!load_event(&st, ctx, evv, hook, leg == 1, &id, &legv)) { status = v2_setup_failure(&st); goto cleanup; }

    // Select from the raw identity and requested phase before evaluating any source.
    int candidates = 0, phase = leg * 2 + kind, selected_file = -1;
    for (int i = 0; i < st.ndecl; i++) {
        if (st.decl[i].hooks[phase].s && match_accepts(&st.decl[i], &id, leg == 1)) {
            st.selected_route = i; candidates++;
        }
    }
    if (candidates > 1) { status = QJS_INVALID_INPUT; goto cleanup; }
    if (!candidates) {
        if (budget_exceeded(&st)) { status = st.stop; goto cleanup; }
        const char *empty = "{\"actions\":[]}";
        size_t len = strlen(empty);
        if (len > limits->max_result_bytes) { status = QJS_INVALID_RESULT; goto cleanup; }
        res.data = copy_z((const uint8_t *)empty, len);
        if (!res.data) { status = QJS_MEMORY_OR_STACK; goto cleanup; }
        res.length = len; status = QJS_OK; goto cleanup;
    }
    Str *selected = &st.decl[st.selected_route].hooks[phase];
    for (int i = 0; i < st.nfiles; i++) if (str_cmp(selected, &st.files[i].name) == 0) selected_file = i;
    if (selected_file < 0) { status = QJS_INVALID_INPUT; goto cleanup; }
    for (int i = 0; i < st.ndecl; i++) for (int p = 0; p < 4; p++)
        if (st.decl[i].hooks[p].s && str_cmp(selected, &st.decl[i].hooks[p]) == 0) st.expected_phases |= 1u << p;
    source_len = st.files[selected_file].code.n;
    if (source_len > limits->max_source_bytes) { status = QJS_INVALID_INPUT; goto cleanup; }
    src = copy_z((const uint8_t *)st.files[selected_file].code.s, source_len);
    if (!src) { status = QJS_MEMORY_OR_STACK; goto cleanup; }

    // Canonical form of the original body of the invoked leg (the only thing a callback may change).
    if (kind == 0 && (leg == 0 ? write_request : write_response)) {
        JSAtom ba = JS_NewAtom(ctx, "body");
        JSValue b = JS_UNDEFINED;
        if (ba == JS_ATOM_NULL) { status = QJS_INTERNAL; goto cleanup; }
        had_body = own_data(ctx, legv, ba, &b);
        JS_FreeAtom(ctx, ba);
        if (had_body) {
            int ok = serialize_value(&st, ctx, b, 1, BODY_COMPARE_DEPTH, BODY_COMPARE_CAP, &original);
            JS_FreeValue(ctx, b);
            if (!ok) { status = budget_exceeded(&st) ? st.stop : v2_setup_failure(&st); goto cleanup; }
        }
    }

    if (!install_interceptor(ctx) || ((fetch_cb || probe_fetch) && !install_fetch(ctx, probe_fetch)) ||
        (st.save_exposed && !install_save_json(ctx, probe_fetch))) { status = st.oom ? QJS_MEMORY_OR_STACK : QJS_INTERNAL; goto cleanup; }

    {
        JSValue completion = JS_Eval(ctx, (const char *)src, source_len, "<plugin>", JS_EVAL_TYPE_GLOBAL | JS_EVAL_FLAG_STRICT);
        if (JS_IsException(completion)) { status = classify_exception(ctx, &st, QJS_SCRIPT_ERROR); goto cleanup; }
        JS_FreeValue(ctx, completion);
        st.sealed = 1;
        if (st.attach_failed || st.registered_phases != st.expected_phases) { status = st.stop ? st.stop : QJS_SCRIPT_ERROR; goto cleanup; }
    }

    {
        V v;
        int ok = 1;
        memset(&v, 0, sizeof(v));
        v.ctx = ctx;
        v.st = &st;
        v.max_depth = (int)limits->max_result_depth;
        v.max_actions = limits->max_actions;
        v.out.cap = limits->max_result_bytes;
        v.out.p = malloc(v.out.cap + 1);
        if (!v.out.p) { status = QJS_MEMORY_OR_STACK; goto cleanup; }
        b_str(&v.out, "{\"actions\":[");
        st.max_intents = limits->max_actions < MAX_INTENTS ? limits->max_actions : MAX_INTENTS;
        st.intents = calloc(st.max_intents + 1, sizeof(Intent));
        if (!st.intents) { free(v.out.p); status = QJS_MEMORY_OR_STACK; goto cleanup; }
        for (int i = 0; i < st.nregs && ok; i++) {
            if (!JS_IsFunction(ctx, st.regs[i].cb)) continue;
            JSValueConst argv[2];
            argv[0] = legv;
            argv[1] = cfgv;
            size_t first_intent = st.nintents;
            st.in_callback = 1;
            JSValue ret = JS_Call(ctx, st.regs[i].cb, JS_UNDEFINED, 2, argv);
            if (probe_fetch && !budget_exceeded(&st) &&
                (st.requires_async || (!JS_IsException(ret) && (int)JS_PromiseState(ctx, ret) >= 0))) {
                st.in_callback = 0;
                JS_FreeValue(ctx, ret);
                free(v.out.p);
                status = QJS_ASYNC_REQUIRED;
                goto cleanup;
            }
            if (fetch_cb && !JS_IsException(ret)) {
                int fs = settle_callback(&st, ctx, rt, &ret);
                if (fs) { st.in_callback = 0; JS_FreeValue(ctx, ret); free(v.out.p); status = fs; goto cleanup; }
            }
            st.in_callback = 0;
            if (JS_IsException(ret)) {
                status = classify_exception(ctx, &st, QJS_SCRIPT_ERROR);
                free(v.out.p);
                goto cleanup;
            }
            if (st.attach_failed) { JS_FreeValue(ctx, ret); free(v.out.p); status = QJS_SCRIPT_ERROR; goto cleanup; }
            // Recorded sends first (FIFO), then returned legacy actions; both share the action cap.
            for (size_t k = first_intent; k < st.nintents && ok; k++) {
                if (v.nactions >= v.max_actions) { ok = v_fail(&v); break; }
                if (v.nactions) b_ch(&v.out, ',');
                emit_intent(&v.out, &st.intents[k]);
                v.nactions++;
                if (v.out.overflow) ok = v_fail(&v);
            }
            if (ok && !JS_IsUndefined(ret)) ok = emit_actions(&v, ret);
            JS_FreeValue(ctx, ret);
        }
        if (ok) b_ch(&v.out, ']');
        if (ok && kind == 0 && (leg == 0 ? write_request : write_response)) {
            JSAtom ba = JS_NewAtom(ctx, "body");
            JSValue b = JS_UNDEFINED;
            int now_has = ba != JS_ATOM_NULL;
            if (now_has) {
                // An accessor or non-enumerable replacement counts as present-but-invalid.
                JSPropertyDescriptor d;
                int has = JS_GetOwnProperty(ctx, &d, legv, ba);
                if (has > 0) { JS_FreeValue(ctx, d.value); JS_FreeValue(ctx, d.getter); JS_FreeValue(ctx, d.setter); }
                now_has = has != 0;
                if (has > 0 && !own_data(ctx, legv, ba, &b)) ok = 0;
                else if (has < 0) ok = 0;
            } else ok = 0;
            if (ba != JS_ATOM_NULL) JS_FreeAtom(ctx, ba);
            if (ok && had_body != now_has) ok = 0;   // body may be changed in place or replaced, never added/removed
            if (ok && had_body) {
                Buf finalb = {NULL, 0, 0, 0};
                if (!serialize_value(&st, ctx, b, 1, BODY_COMPARE_DEPTH, BODY_COMPARE_CAP, &finalb)) {
                    ok = 0;
                } else {
                    int same = finalb.len == original.len && memcmp(finalb.p, original.p, finalb.len) == 0;
                    free(finalb.p);
                    if (!same) {
                        b_str(&v.out, ",\"mutation\":{\"body\":");
                        ok = emit_value(&v, b, 3);   // root=1, mutation=2, body value=3
                        b_str(&v.out, "}");
                    }
                }
            }
            JS_FreeValue(ctx, b);
        }
        if (ok) b_ch(&v.out, '}');
        if (ok && v.out.overflow) ok = 0;
        if (ok) v.out.p[v.out.len] = 0;
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
        for (int i = 0; i < st.nregs; i++) JS_FreeValue(ctx, st.regs[i].cb);
        JS_FreeValue(ctx, legv);
        JS_FreeValue(ctx, cfgv);
        JS_FreeValue(ctx, evv);
        JS_FreeValue(ctx, manv);
        JS_FreeContext(ctx);
    }
    if (rt) JS_FreeRuntime(rt);
    for (int i = 0; i < st.ndecl; i++) match_free(&st.decl[i]);
    strs_free(st.rd_headers, st.n_rd_headers);
    strs_free(st.rd_query, st.n_rd_query);
    if (have_id) ident_free(&id);
    intents_free(&st);
    for (int i = 0; i < st.nout; i++) out_free(&st.out[i]);
    free(original.p);
    free(src);
    free(ev);
    free(cfg);
    free(package);
    for (int i = 0; i < st.nfiles; i++) { str_free(&st.files[i].name); str_free(&st.files[i].code); }
    res.status = status;
    return res;
}

QJSResult qjs_run_v2(QJSCancelToken *token, const QJSLimits *limits,
                     const uint8_t *package_json, size_t package_len,
                     const char *hook,
                     const uint8_t *event_json, size_t event_len,
                     const uint8_t *config_json, size_t config_len) {
    return run_v2_impl(token, limits, NULL, NULL, 0, 0, NULL, NULL, package_json, package_len, hook, event_json, event_len,
                       config_json, config_len);
}

QJSResult qjs_run_v2_fetch(QJSCancelToken *token, const QJSLimits *limits,
                           QJSFetchCallback callback, void *opaque,
                           const uint8_t *package_json, size_t package_len,
                           const char *hook,
                           const uint8_t *event_json, size_t event_len,
                           const uint8_t *config_json, size_t config_len) {
    if (!callback) {
        QJSResult res = {QJS_INVALID_INPUT, NULL, 0};
        return res;
    }
    return run_v2_impl(token, limits, callback, opaque, 0, 0, NULL, NULL, package_json, package_len, hook, event_json, event_len,
                       config_json, config_len);
}

QJSResult qjs_run_v2_probe(QJSCancelToken *token, const QJSLimits *limits,
                          const uint8_t *package_json, size_t package_len, const char *hook,
                          const uint8_t *event_json, size_t event_len,
                          const uint8_t *config_json, size_t config_len) {
    if (!hook || strcmp(hook, "response.onLeave")) {
        QJSResult res = {QJS_INVALID_INPUT, NULL, 0};
        return res;
    }
    return run_v2_impl(token, limits, NULL, NULL, 1, 0, NULL, NULL, package_json, package_len, hook,
                       event_json, event_len, config_json, config_len);
}

QJSResult qjs_run_v2_fetch_save(QJSCancelToken *token, const QJSLimits *limits,
                                QJSFetchCallback callback, void *opaque,
                                QJSSaveJSONCallback save_callback, void *save_opaque,
                                const uint8_t *package_json, size_t package_len,
                                const char *hook,
                                const uint8_t *event_json, size_t event_len,
                                const uint8_t *config_json, size_t config_len) {
    if (!callback) {
        QJSResult res = {QJS_INVALID_INPUT, NULL, 0};
        return res;
    }
    return run_v2_impl(token, limits, callback, opaque, 0, 1, save_callback, save_opaque, package_json, package_len,
                       hook, event_json, event_len, config_json, config_len);
}
