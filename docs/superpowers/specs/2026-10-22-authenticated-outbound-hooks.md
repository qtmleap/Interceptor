# Authenticated secondary API calls — proposed design

Status: proposal for human review. This document does not claim that the native capability exists. The user selected one-way secondary requests and clarified the flow: obtain credentials from a GET response, then use them to call another API. The secondary response does not change the original traffic.

## Developer contract

Keep the four existing lifecycle callbacks and filesystem-generated matching. Add a synchronous `Interceptor.send(binding, options)` helper. It records a bounded request intent; it performs no networking in JavaScript, returns no response and does not wait for the network. A successful callback does not mean the secondary API accepted the request.

For example, `hooks/auth.example.com/credentials/GET.ts` may contain:

```javascript
Interceptor.attach({
  response: {
    onLeave(res) {
      Interceptor.send('profile', {
        headers: { authorization: `Bearer ${res.body.accessToken}` },
      });
    },
  },
});
```

The author declares the named operation in plugin metadata. The build generates the manifest; source files do not repeat trigger hosts, paths, methods, script filenames or UUIDs.

```json
{
  "outbound": {
    "profile": {
      "url": "https://api.example.com/profile",
      "method": "GET",
      "headers": ["authorization"]
    }
  }
}
```

The generated schema-2 manifest carries the same strict `outbound` declarations. Schema 2 remains unreleased. Existing packages without declarations retain their current behavior. The old `endpointBindings`/webhook dry-run contract does not implicitly grant live delivery.

Each binding has a fixed HTTPS destination, GET method and explicit permitted header names. No user credential input, login manager, Keychain lookup, captured-token persistence or automatic cookie jar is introduced. The approval for the exact package revision identifies the receiving destination, outbound header names and every granted input that scripts may send there: request/response JSON bodies and the granted captured header names. Do not imply that static analysis can identify a narrower value source for arbitrary JavaScript. Read permission alone does not grant outbound permission.

`options.headers` is a plain string map whose names must be declared. Values may come from data already granted to the current callback, including the GET response JSON or granted `set-cookie`. Cookie callers pass the cookie name/value pair, excluding Set-Cookie attributes. GET has no body. Options accept no JSON body, URL, method, redirect flag or arbitrary native setting. POST and response-dependent processing are separate later features. No `let` or `var` is needed in examples or generated code.

## Validation and phase semantics

Limit declarations to four bindings. C and Swift validate strict supported keys, canonical header names, at most eight headers, no CR/LF, at most 4 KiB per header value and 8 KiB of header values in one operation. Output remains within the existing 32 KiB result budget. The existing two-action per-VM cap includes send intents and legacy declarative intents together. The same two-send limit applies to the complete composed phase, so multiple approved revisions cannot multiply the native dispatch count.

Calls during source registration, unknown bindings, undeclared headers, invalid values and limit violations cause a sticky phase failure even if the script catches the immediate exception. They never dispatch. Intents are emitted through the existing validated C-result boundary. The helper does not send from inside the callback.

All approved revisions in a phase finish and all result/mutation validation succeeds before any intent is committed. Failure in a later revision discards earlier intents and mutations. Authorization and capture consent are checked again before committing intents and immediately before network admission. An onEnter intent may be admitted after its phase commits; it does not imply a later successful original write. An onLeave intent can only originate from an actually invoked leave callback after successful local forwarding.

The native dispatcher releases phase/VM admission before waiting for any network operation. Preserve fresh VMs and the existing 50 ms active JavaScript budget. Use at most four concurrent outbound operations and no waiting queue; overload drops the intent without retrying or delaying original traffic. Each operation has a three-second total deadline and a 64 KiB response cap. The response is discarded. A test-injected observer may receive only the endpoint binding and status/error class; this does not add a production history screen. No credential values, request/response bodies or secret-bearing URLs are logged.

Revocation, capture-consent loss, activation-generation change or tunnel shutdown prevents queued admission and cancels owned in-flight tasks. Already transmitted bytes cannot be recalled. A secondary-network failure never changes or retries the original traffic. Ordinary VM/validation failures retain the existing original-traffic failure policy; permission loss retains its existing revocation policy.

Use an ephemeral native client with cookie storage, credential storage, cache, proxy auto-configuration and redirect following disabled. Keep normal TLS validation. Reject URL userinfo/fragments and ambiguous or non-HTTPS destinations; only GET is supported in this increment. No JS URL substitution or redirect may move credentials to another destination. Live destinations use canonical DNS names; private-address/loopback targets are available only through an injected test transport, without weakening production validation. A real tunnel test must verify that the secondary client bypasses the same interception path and cannot recursively invoke its hook. Do not add a forgeable external HTTP header as the isolation mechanism.

## Credential sources and bodyless traffic

The GET-credentials flow uses an eligible small JSON response and `response.onLeave`; an empty original GET body does not suppress the existing response callback. This is the first acceptance flow.

The earlier captured-header/bodyless-request case remains a separate follow-up. It needs explicit metadata-only transport admission and is not required for the GET-response-credentials flow. This first increment retains current JSON/content eligibility and the 24 KiB body limit; it does not claim that every bodyless request gets a request callback. Granted request headers may still be reused when an existing eligible callback receives them.

## Required implementation and evidence

- AutomationCore and the shared C bridge validate the same declarations and send-result DTO. Keep v1 synthetic behavior separate; a dry run never delivers.
- SDK metadata, directory builder, TypeScript types, examples and reference documentation emit and explain the contract without manual routing synchronization.
- Native processor and a bounded dispatcher integrate exact-revision grants, whole-phase commit, lifecycle ownership and cancellation. The approval footer adds the destination and forwarded header names using the existing UI pattern.
- Rust validates and reports the same intents without claiming native HTTP delivery. Shared positive and negative conformance fixtures bind the actual runtime sources.
- Unit tests assert correct token/Cookie extraction, exact target/method/header values, absence of undeclared headers, no sends after errors/revocation, limits, concurrency, timeout and redirect behavior.
- Native loopback TCP/CONNECT/TLS tests start with a GET returning synthetic credentials and prove that the production dispatcher calls the protected second endpoint. Add nonmatching traffic and recursion controls. A fake sink alone is insufficient delivery evidence. Metadata-only header/request callbacks need separate follow-up tests when implemented.
- Public Workers tests separately prove the dummy origin's GET-credentials to Bearer/Cookie API contracts. They do not establish plugin delivery.
- A signed Debug build is installed on the authorized M3 after native source changes, with current device ownership checked before launch/VPN manipulation. Physical PacketTunnel verification and Rust conformance remain separate evidence.

## Origin fixture preparation

`GET /auth/credentials` returns the existing public synthetic bearer token as `accessToken`, `tokenType: "Bearer"` and the existing fixed Set-Cookie. Existing `/auth/bearer` checks the token. New `/auth/cookie` checks exactly one expected `fixture_session` name/value pair; unrelated cookies may coexist. Missing, incorrect, duplicated or comma-joined session cookies receive 401 with no Bearer challenge. Cookie names are case-sensitive: a differently cased name alone does not authenticate, and it does not invalidate an otherwise valid exact-case session cookie. The server keeps no state and does not reflect incoming credentials. Global 64 KiB/no-store/405 behavior remains unchanged.

This origin preparation is independently testable. Native and SDK implementation begins after this proposed API/design is reviewed; no native outbound pass is claimed before that work exists.
