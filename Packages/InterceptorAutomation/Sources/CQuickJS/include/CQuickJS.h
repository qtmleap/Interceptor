#ifndef CQUICKJS_H
#define CQUICKJS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Bounded one-shot QuickJS bridge. No QuickJS types cross this header: callers pass explicit
/// byte lengths and receive typed status plus bounded, malloc-owned UTF-8 JSON bytes.

/// Thread-safe cancellation flag for exactly one `qjs_run` call. The creator owns it and must keep
/// it alive until `qjs_run` has returned; `qjs_cancel_token_cancel` may be called from any thread
/// at any time before `qjs_cancel_token_free`.
typedef struct QJSCancelToken QJSCancelToken;

enum {
    QJS_OK = 0,
    QJS_TIMEOUT = 1,
    QJS_CANCELLED = 2,
    QJS_MEMORY_OR_STACK = 3,
    QJS_INVALID_INPUT = 4,
    QJS_INVALID_RESULT = 5,
    QJS_SCRIPT_ERROR = 6,
    QJS_INTERNAL = 7
};

typedef struct QJSLimits {
    size_t deadline_ms;
    size_t heap_bytes;
    size_t stack_bytes;
    size_t max_source_bytes;
    size_t max_event_bytes;
    size_t max_config_bytes;
    size_t max_result_bytes;
    size_t max_result_depth;
    size_t max_actions;
} QJSLimits;

typedef struct QJSResult {
    int32_t status;
    /// On QJS_OK: `length` bytes of validated canonical result JSON (not NUL-terminated).
    uint8_t *data;
    size_t length;
} QJSResult;

QJSCancelToken *qjs_cancel_token_new(void);
void qjs_cancel_token_cancel(QJSCancelToken *token);
void qjs_cancel_token_free(QJSCancelToken *token);

/// Runs `source`, then calls the global function `hook` (NUL-terminated name) with the parsed
/// event and config JSON. Fresh runtime and context per call; synchronous; never drains promise jobs.
/// The deadline covers evaluation, the handler call and result conversion/validation.
QJSResult qjs_run(QJSCancelToken *token, const QJSLimits *limits,
                  const uint8_t *source, size_t source_len,
                  const char *hook,
                  const uint8_t *event_json, size_t event_len,
                  const uint8_t *config_json, size_t config_len);

/// Maximum accepted manifest size for `qjs_run_v2`.
#define QJS_MAX_MANIFEST_BYTES (32u * 1024u)

#define QJS_MAX_PACKAGE_BYTES (256u * 1024u)

/// Four-phase HTTP lifecycle entry. `package_json` is exactly {manifest,sourceFiles} for schema 2.
/// Validates the entire package before matching the raw event and requested phase. Zero matches
/// return empty actions without evaluation; ambiguity is invalid input. Only the selected source
/// evaluates, with native one-argument Interceptor.attach(callbacks) bound to that route.
QJSResult qjs_run_v2(QJSCancelToken *token, const QJSLimits *limits,
                     const uint8_t *package_json, size_t package_len,
                     const char *hook,
                     const uint8_t *event_json, size_t event_len,
                     const uint8_t *config_json, size_t config_len);

/// Opt-in diagnostics for `qjs_run_v2_diagnostic`: fixed-size, caller-owned scalar records only.
/// No payload, source, file name, hash, exception or string data ever enters this structure, and
/// nothing in it is visible to JavaScript. The ordinary `qjs_run_v2` passes no diagnostics.
#define QJS_DIAG_CAPACITY 24u

/// Phases of one v2 call, in execution order. A record means "this phase was ENTERED"; the previous
/// phase completed at the same timestamp, so a phase's duration is the next record minus its own.
/// Phases a path never reaches (e.g. evaluation for non-matching traffic) have no record.
enum {
    QJS_DIAG_PHASE_NONE = 0,
    QJS_DIAG_PHASE_PREFLIGHT = 1,         // C entry: argument checks and first budget poll
    QJS_DIAG_PHASE_INPUT_COPY = 2,        // NUL-terminated copies of package, event, config
    QJS_DIAG_PHASE_INPUT_SCAN = 3,        // strict JSON shape + safe integer scans
    QJS_DIAG_PHASE_RUNTIME = 4,           // runtime creation, limits, interrupt handler
    QJS_DIAG_PHASE_CONTEXT = 5,           // context + intrinsics + pristine class ids
    QJS_DIAG_PHASE_JSON_PARSE = 6,        // package, event, config JS_ParseJSON
    QJS_DIAG_PHASE_PACKAGE = 7,           // manifest / source file validation
    QJS_DIAG_PHASE_CONFIG_EVENT = 8,      // config freeze, event view preparation
    QJS_DIAG_PHASE_SELECTION = 9,         // native route + source selection, source copy
    QJS_DIAG_PHASE_ORIGINAL_BODY = 10,    // canonical serialization of the original body
    QJS_DIAG_PHASE_API_INSTALL = 11,      // Interceptor.attach installation
    QJS_DIAG_PHASE_EVAL = 12,             // source evaluation + registration check
    QJS_DIAG_PHASE_CALLBACKS = 13,        // all callbacks and their action conversion
    QJS_DIAG_PHASE_RESULT = 14,           // body mutation comparison, envelope completion
    QJS_DIAG_PHASE_FINAL_ACCEPTANCE = 15, // last budget check before the result is accepted
    QJS_DIAG_PHASE_TEARDOWN = 16,         // context/runtime/buffer release
    QJS_DIAG_PHASE_EXIT = 17              // C about to return
};

/// How the first (sticky) stop request was detected; independent of the phase it happened in.
enum {
    QJS_DIAG_ORIGIN_NONE = 0,
    QJS_DIAG_ORIGIN_INTERRUPT = 1,        // engine interrupt handler
    QJS_DIAG_ORIGIN_INLINE_POLL = 2,      // bridge's own explicit budget polls
    QJS_DIAG_ORIGIN_FINAL_CHECK = 3       // final acceptance check
};

enum {
    QJS_DIAG_WALL_SUPPORTED = 1,
    QJS_DIAG_THREAD_CPU_SUPPORTED = 2
};

typedef struct QJSDiagnosticRecord {
    int32_t phase;   // QJS_DIAG_PHASE_* entered
    /// Monotonic wall nanoseconds since the deadline start at C entry; thread CPU nanoseconds
    /// since the first CPU reading (0 when unsupported). CPU is observed, never enforced.
    uint64_t wall_ns;
    uint64_t thread_cpu_ns;
} QJSDiagnosticRecord;

typedef struct QJSDiagnostics {
    uint32_t capacity;
    uint32_t count;
    uint32_t supported_flags;
    int32_t status;                // final native status
    int32_t stop_status;           // QJS_TIMEOUT / QJS_CANCELLED of the first stop, else 0
    int32_t stop_origin;           // QJS_DIAG_ORIGIN_*
    int32_t stop_phase;            // QJS_DIAG_PHASE_* running when the first stop was detected
    uint64_t stop_wall_ns;
    uint64_t stop_thread_cpu_ns;
    uint32_t interrupt_polls;      // saturating
    uint32_t inline_polls;         // saturating (includes the final check)
    uint64_t deadline_relative_ns; // effective deadline relative to the deadline start
    QJSLimits limits;              // effective limits as passed (valid only if limits_valid)
    uint32_t limits_valid;
    uint32_t route_count;          // declared routes
    uint32_t file_count;           // source files in the package
    uint32_t registration_count;   // Interceptor.attach registrations
    int32_t selected_route;        // -1 when none
    int32_t selected_source;       // -1 when none
    uint64_t package_len, event_len, config_len, source_len, result_len;
    QJSDiagnosticRecord records[QJS_DIAG_CAPACITY];
} QJSDiagnostics;

/// Same behavior, limits and result as `qjs_run_v2`; additionally fills `diagnostics` (may be NULL).
QJSResult qjs_run_v2_diagnostic(QJSCancelToken *token, const QJSLimits *limits,
                                const uint8_t *package_json, size_t package_len,
                                const char *hook,
                                const uint8_t *event_json, size_t event_len,
                                const uint8_t *config_json, size_t config_len,
                                QJSDiagnostics *diagnostics);

void qjs_result_free(QJSResult *result);

#ifdef __cplusplus
}
#endif

#endif
