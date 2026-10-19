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

/// Four-phase HTTP lifecycle entry. Same arguments as `qjs_run` followed by the FULL strict schemaVersion 2
/// manifest bytes (unknown/missing fields, schema 1/3 and partial manifests are QJS_INVALID_INPUT). `hook` must be
/// one of "request.onEnter", "request.onLeave", "response.onEnter", "response.onLeave".
/// The event is the public envelope `{id?,phase?,exchangeID?,time?,request,response?}` (no caller identity).
/// Matching uses the unfiltered request method/host/path and response status; callbacks then receive their own
/// leg filtered by read.metadata/headers/queryKeys/body.mode, plus config. On QJS_OK the data is
/// `{"actions":[...]}` plus optional `"mutation":{"body":<JSON>}` (authorized enter phase only).
/// Legacy `qjs_run` is unchanged.
QJSResult qjs_run_v2(QJSCancelToken *token, const QJSLimits *limits,
                     const uint8_t *source, size_t source_len,
                     const char *hook,
                     const uint8_t *event_json, size_t event_len,
                     const uint8_t *config_json, size_t config_len,
                     const uint8_t *manifest_json, size_t manifest_len);

void qjs_result_free(QJSResult *result);

#ifdef __cplusplus
}
#endif

#endif
