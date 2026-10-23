# QuickJS fetch implementation

The Salmon Run Plugin needs to POST GraphQL queries and read the responses in
ordinary JavaScript. The existing response.onLeave hook already supplies the
captured BulletToken response; no new capture API is needed.

- Provide global fetch in response.onLeave with GET/POST/PUT and JSON bodies.
- Reuse the existing strict schema2 package/grants boundary and direct public
  HTTPS443/TLS transport. The outgoing request is defined solely in JS.
- Use a dedicated bounded VM thread for the trusted transport callback and drain
  Promise jobs for await. Keep legacy synchronous execution unchanged elsewhere.
- HTTPResponse.status/ok/bodyUsed/text()/json() are available; body is consumed
  once. No redirects, streaming, compressed replies or automatic credentials.
- Body<=8KiB, response<=1MiB,64requests,16MiB aggregate,8MiB JS heap,250ms CPU
  excluding callbackwait,120sec wall. Two VMs perprocess; one perprocessor.
- Probe responseLeave without networking. Synchronous hooks keep their existing
  results/errors; a returned Promise or attempted fetch schedules a fresh VM
  after the phase permit is released. The read-only hook may run again up to its
  first fetch; no probe output or send intent is committed.
- The processor has one active background run and no waiting queue. Additional
  runs are rejected through the existing observer; it does not hold original
  traffic or synchronous hooks while external requests finish.
- A phase mixing synchronous send intents and deferred hooks commits all intents
  after the deferred results validate. Overload, cancellation or failure drops
  that phase's intents together, preserving the phase's all-or-nothing behavior.
- Check authorization before transport and subsequent requests; cancel and drain
  the VM and socket on shutdown. Keep callbacks and token ownership race-safe.
- No new UI, proprietary JS send API, credential storage or result persistence.

Verification: real shared-C Swift runtime tests; real NIO/TLS fixture origin;
iOS app/extension build and affected native tests; generated Salmon Plugin
through the exact shared C bridge with offline HTTP fixtures. Real Nintendo
acceptance is a separate hardware/service check.
