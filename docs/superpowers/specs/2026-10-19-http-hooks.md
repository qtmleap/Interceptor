# Four HTTP lifecycle hooks

The user authorized the native app, Rust simulator, author documentation and
client/Interceptor/server diagram to implement the same four-hook design.

## Public API

An author writes `plugins/NAME/plugin.json` and routed TypeScript files such as
`plugins/NAME/hooks/api.example.com/search/POST.ts`. The metadata declares read
and write grants, identity and settings. It contains no routing table. The build
uses the directory path and declared callbacks to generate the manifest and
independent JavaScript files. A root path uses `hooks/HOST/GET.ts`.

```javascript
Interceptor.attach({
  request: {
    onEnter(req, cfg) { req.body.limit = 5; },
    onLeave(req, cfg) {},
  },
  response: {
    onEnter(res, cfg) { res.body.maintenance = true; },
    onLeave(res, cfg) {},
  },
});
```

`attach` takes one object containing callbacks. Source contains no matching
conditions, IDs or filenames. Generated manifests carry exact host/path/method
conditions and a file reference for each declared phase. Schema2 is unreleased
and changes in place. There is no compatibility route for an older schema2 API.

Every phase uses a fresh bounded VM. Native code validates the complete package
before matching the unfiltered request identity and requested phase. No match
returns without evaluating JavaScript. An ambiguous phase match rejects before
evaluation. A single match evaluates only its selected file. The phase set
registered by that file must equal the union of manifest phases referring to it.
There is no mutable JS state between phases. Hosts are canonical lowercase DNS
names, methods uppercase, and paths exact without query. Generated filesystem
routes are literal ASCII paths; dynamic segments, percent/non-ASCII names,
symlinks, aliases and ambiguous routes are rejected. No prefix/glob/regex rules.

`request.onEnter` runs before upstream forwarding; `request.onLeave` runs only
after the upstream end-write promise succeeds. The response pair surrounds
downstream forwarding in the same way. Leave means local successful forwarding,
not receipt/processing by the peer. A failed write never invokes leave. Enter
and leave must NOT run together before forwarding. Leave traffic is read-only.

Callbacks receive their own leg (`request` or `response`) plus config. For a
response, the corresponding request is available read-only as `response.request`.
Its body is present only with a JSON read grant and a bounded eligible forwarded
request body; otherwise it is omitted without blocking an eligible response. Only JSON
body mutation is in this change; status, URL, method and headers cannot change.
`body` is a JSON value, with no author-defined parser or rewriting helper.
An unchanged JSON tree preserves the original wire bytes. Changed JSON is
serialized as UTF-8 and framing headers are repaired by the transport.
Callbacks may return the existing `{ actions: [...] }` intent result, or nothing.
Actions are bounded, declarative and are not delivered to external endpoints.

## Manifest and runtime boundary

Keep v1 packages byte-identical and dry-run compatible, never live-enabled.
New packages use exactly `{manifest, sourceFiles}`; v1 keeps exactly
`{manifest, source}`. The v2 manifest requires schemaVersion2, id, name, version,
endpointBindings, settings, read, write and 1...16 matches, with optional author
and summary. Each match has one host, one method, an exact path, and nested
`hooks.request/response.onEnter/onLeave` file references. Status/prefix selectors
and subscriptions are unsupported. Read body modes are `none` or `json`.

The manifest is the activation authority. All referenced source files must exist,
all source files must be referenced, and the complete package is validated before
selection even on a nonmatch. Safe ASCII relative POSIX paths or IDs are at most
256 bytes; URLs, absolute paths, backslashes and dot/empty segments are rejected.
Caps: 64 source files, 128KiB decoded JavaScript total, 256KiB exact package bytes,
32KiB canonical manifest. Native callbacks cannot widen matching or grants.
Header/query/body read grants apply before JavaScript sees traffic. No tool
credentials, OS, filesystem, network or other native API is exposed.

C `qjs_run_v2` takes token, limits, complete package bytes+length, phase,
event bytes+length and config bytes+length. Swift exposes
`runV2(packageJSON:hook:eventJSON:configJSON:) async throws -> Data`.
`PluginPackage.source: String?` is v1-only; `sourceFiles: [String: String]` is
v2-only. File replacement retains the complete manifest and other files; bulk
save produces one inactive child revision. Exact package bytes bind approval.
The result is `{actions: [...]}` with optional `mutation: {body: <JSON>}` only
for an authorized enter callback. Other mutation keys are rejected.

VM limits remain 50ms, 8MiB heap, 256KiB stack, event64KiB, config8KiB,
result32KiB, depth32 and actions2. Busy calls fail promptly rather than creating
an unbounded queue. The live adapter serializes complete phases around one
executor, with at most8 FIFO waiters and one active phase. Cancellation removes
a queued waiter, and authorization is checked again after admission. Overload
still fails open for an eligible enter phase after a fresh authorization check.
Invalid or late attach remains a sticky failure even if
caught by JavaScript. At most16 registrations are admitted.

The Rust CLI and app use the same C runner. The v2 invocation is
`run-package PACKAGE.json PHASE EVENT.json CONFIG.json`. Legacy `run` is v1-only;
`check` is compile-only. Shared conformance vectors cover both consumers.

## Live execution and activation

Imported, edited and newly installed revisions remain inactive. Add a separate
app-group activation store; do not weaken the existing catalog invariant that
all installed revisions have `enabled == false`. An activation binds exact
package bytes/revision digest, validated manifest and per-revision approval.
Maximum 4 active revisions, composed in deterministic revision order. Each phase
is all-or-nothing across revisions: an error discards earlier mutations and the
transport forwards the original eligible message if authorization remains valid. Existing capture consent is required in addition.
Activation UI describes affected hosts, declared data and JSON modifications in
section footers, and requires an explicit action for this exact revision.
New local edits never inherit activation. Delete/revoke disables the old grant.

Use atomic bounded protected files and the existing lock discipline. Corruption
disables live processing and preserves the file. The tunnel rechecks activation
generation and capture consent before invoking and immediately before applying
or forwarding a buffered result. Revocation stops the affected tunnel; the
existing consent-monitor fallback also checks the activation generation. Do not
auto-add capture hosts or start/restart capture. Only configured captured hosts
can produce hooks. Every approval snapshot change, including an addition, stops the existing tunnel.
New activation takes effect on the next explicit connection. Consent is checked
before every approval-monitor read, including while a previous read is in flight.

## Transport

Mudmouth owns public transport message/phase types and an async processor seam;
it does not import AutomationRuntime. PacketTunnel supplies the adapter. Keep
the proxy's recording/notification behavior and record the actual forwarded
message. Separate lifecycle handling from record persistence.

The match host is the validated CONNECT authority (443), never an untrusted
decrypted Host header. Plumb it from ConnectHandler into lifecycle handling.
Async release explicitly flushes, rather than relying on a completed read cycle.
Extend the glue with a promise-carrying end-write completion and an explicit
peer-read hold mechanism. Request and response stages share FIFO exchange state;
do not assume the current record queue supplies async/pipelining coordination.

Transport's public pure module is `MudmouthHTTPHooks`. Its public Sendable
`HTTPPluginPhase` cases/raw values match the runtime's four new cases.
`HTTPPluginRequest` exposes `id: UUID`, `method`, authenticated `host`, `path`
(without query), `query: [String: String]` (default empty in the public initializer),
`headers: [String: String]` (lowercase names) and `body: Data`.
The transport parses query items from the original URI before removing the query
from `path`; the native adapter passes these through the runtime read-grant filter.
`HTTPPluginResponse` exposes `status: Int`, `headers` and `body: Data`.
Both have public memberwise initializers. `HTTPPluginProcessing: Sendable` has
`matches(_ request: HTTPPluginRequest) -> Bool`,
`isAuthorized() async -> Bool`, and
`process(_ phase: HTTPPluginPhase, request: HTTPPluginRequest,
response: HTTPPluginResponse?) async throws -> Data?`.
Returned data replaces that leg's JSON body on enter; nil means no mutation.
The transport ignores/rejects mutation data from leave. The PacketTunnel adapter
owns JS actions as intents. `MITM.startTunnel(options:pluginProcessor:)` accepts
an optional processor with a nil default, keeping current callers compatible.

Only matched eligible messages are buffered. Unmatched traffic streams normally.
Original body eligibility is at most 24KiB; connection buffered/queued data is
at most 64KiB. An overflow replays original parts without hooks, rather than
truncating or partially modifying. Pause the appropriate peer read while an
async phase is in flight; preserve FIFO and cap pipelining/queued parts.
Never block the NIO event loop on JS. Original forwarding is the default on
runtime failure, deadline, busy, unsupported body or encoding. Consent/grant
revocation closes the connection. Never replay after a partial write failure.

Observational leave work is bounded to4 tasks per connection and shares the
64KiB retained-body budget. Pending request/response end writes also share a
128-entry ledger; its count limit can drop observations before the byte limit.
Excess leave work is dropped. It is not guaranteed
delivery; it cannot delay or retry traffic already forwarded. Tests cover the
task/body limits. Plain unsupported or unmatched HTTP still follows the proxy's
capture-consent guard; no plugin sees it. Fresh activation checks surround
admitted eligible callbacks and their original/mutated release, and the monitor
stops the connection on approval changes.

Body edits require valid bounded safe-number JSON, JSON/+json content type,
UTF-8, identity content encoding and complete body. Compressed, oversized,
streaming, Expect:100-continue, and bodyless HEAD/1xx/204/304 cases
pass through unchanged without body hooks. Forward informational responses as
head-only parts; they must not wait for an end or consume the request association.
Invalid HTTP framing is rejected by the existing decoder;
never introduce CL/TE ambiguity or permit routing changes. Chunked eligible
JSON can be reframed with Content-Length after complete bounded buffering.

Protocol upgrades and nested CONNECT are unsupported. Refuse them with501 and
Connection:close before forwarding upstream, after prior responses have been
successfully written in FIFO order. Close after the refusal end write, hold
reads while waiting, and never evaluate hooks for the refused request. An
unsolicited101 closes without forwarding it. This explicit refusal replaces the
earlier assumed opaque pass-through: the existing NIO decoders stop after an
upgrade and cannot transparently forward opaque bytes without coordinated codec
replacement. No WebSocket or arbitrary upgraded-protocol support is claimed.

## Evidence and integration

Test the actual C runtime, Swift admission/result parsing, atomic activation and
revocation, NIO embedded forwarding/mutation/write failures/pipelining, and real
loopback TCP HTTP and production CONNECT/TLS through the real adapter. An internal
bootstrap seam isolates the listener, event loop, consent and upstream socket/trust
for tests; production keeps captured-host/443 policy, CONNECT-host SNI and system
trust. Early bytes during CONNECT setup close safely. Full-close semantics remain
the production default; embedded half-close tests are separate evidence. Run native build and affected UI checks on
available iOS 18.5 and 26.x with owned simulator cleanup. Linux builds/checks and
standalone runtime tests exercise the same C source. Native/Mudmouth/Plugins
PRs use exact dependency commits and existing gates; no automatic App Review,
manual TestFlight upload or unrelated history/branch cleanup is authorized.
Document implemented behavior and limitations, restore the four-hook figure,
review Japanese with Yomiyasu2.0.1 and a docs-only LocalGPT reader when available,
and open the tested homepage in the browser.
