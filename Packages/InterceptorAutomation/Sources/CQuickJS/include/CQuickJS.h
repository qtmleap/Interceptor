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
    QJS_INTERNAL = 7,
    QJS_ASYNC_REQUIRED = 8
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

/// Standard global `fetch` host contract (response.onLeave only). The callback is trusted, runs on the
/// calling thread and may block; it must honor `timeout_ms` and the cancel token. `request_json` is a
/// validated {url,method,headers,body?} (lowercase header names; body is a JSON text <= 8192 bytes).
typedef struct QJSFetchReply QJSFetchReply;

/// Copies a bounded response (status 100...599, body <= 1 MiB UTF-8). Returns 0 on success.
int32_t qjs_fetch_reply_set(QJSFetchReply *reply, int32_t status, const uint8_t *body, size_t len);

/// Callback result: 0 success (reply set), 1 network error, 2 abort/cancel/revoked.
typedef int32_t (*QJSFetchCallback)(void *opaque, const uint8_t *request_json, size_t len,
                                    uint32_t timeout_ms, QJSFetchReply *reply);

/// Same as `qjs_run_v2` plus a global `fetch` (64 requests, 120 s wall, 250 ms CPU excluding callback wait,
/// 1 MiB per / 16 MiB total response). Only valid for `response.onLeave`; NULL callback is invalid input.
QJSResult qjs_run_v2_fetch(QJSCancelToken *token, const QJSLimits *limits,
                           QJSFetchCallback callback, void *opaque,
                           const uint8_t *package_json, size_t package_len,
                           const char *hook,
                           const uint8_t *event_json, size_t event_len,
                           const uint8_t *config_json, size_t config_len);

/// Read-only response.onLeave scheduling probe. Runs sync hooks unchanged, but performs no network.
/// A fetch attempt or returned Promise gives QJS_ASYNC_REQUIRED, discarding all recorded intents.
QJSResult qjs_run_v2_probe(QJSCancelToken *token, const QJSLimits *limits,
                          const uint8_t *package_json, size_t package_len, const char *hook,
                          const uint8_t *event_json, size_t event_len,
                          const uint8_t *config_json, size_t config_len);

void qjs_result_free(QJSResult *result);

#ifdef __cplusplus
}
#endif

#endif
