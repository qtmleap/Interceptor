# Native plugin repository fixture

This checked-in fixture supplies the unsigned repository used by the EN/JA import and multi-file editor tests. Request summary and Response details are explicit schema1 viewer/import regressions. Multi-file hooks is a schema2 package emitted by the SDK compiler from `authored/plugins/ui-multifile/`. The separate SDK live package is embedded in the native test target and consumed by a real CONNECT/TLS adapter test.

Regenerate both schema2 packages and their Swift expectations with the actual SDK checkout:

```sh
python3 scripts/generate-plugin-test-fixtures.py --sdk-root /path/to/Interceptor-Plugins
```

The script invokes `tools/compile.mjs` once for both plugins with SDK-pinned Bun/TypeScript, validates and packages the emitted output with the SDK's `package_bytes`, and records the SDK revision, compiler/type/tool hashes, authored input hashes and exact output hashes in `provenance.json`. Native CI uses the checked-in bytes and needs Python3 and OpenSSL. The UI expected text and native embedded bytes are verified against the SDK packages before serving.

Run lightweight provisioning checks from the native repository root:

```sh
python3 scripts/ci-plugin-repository-fixture.py --verify-fixtures
python3 -m unittest discover -s scripts/tests -p test_plugin_repository_fixture.py -v
```

The existing CI simulator setup creates and boots one disposable simulator, records its prior device inventory and host/set, and exports `SIMULATOR_UUID`, `CI_SIMULATOR_DEVICE_SET`, and `RUNNER_TEMP`. Insert the fixture wrapper inside the existing owned worker; retain the workflow's remaining xcodebuild arguments, result handling and cleanup:

```sh
NSUnbufferedIO=YES python3 scripts/ci-simulator-start-worker.py \
  python3 scripts/ci-plugin-repository-fixture.py \
    --work-dir "$RUNNER_TEMP/plugin-repository-fixture" -- \
  xcodebuild test -project Interceptor.xcodeproj -scheme Interceptor \
    -destination "platform=iOS Simulator,id=$SIMULATOR_UUID" \
    -parallel-testing-enabled NO
```

The wrapper requires `$RUNNER_TEMP/simulators-before.json` and `$RUNNER_TEMP/simulator-host.txt` (hostname and exact device-set path on separate lines). A local runner can pass `--device`, `--device-set`, `--simulators-before`, and `--simulator-host` explicitly. The selected UUID must be absent from the prior inventory, booted in that same set and match the command's single iOS Simulator destination. The caller owns simulator creation, boot, worker-group shutdown and device deletion.

Each invocation creates its own CA/key and localhost certificate in a private directory outside the public fixture files, binds an ephemeral IPv4 loopback port, verifies TLS hostname/CA and a run-specific readiness response, and adds the root certificate only to that disposable simulator using `simctl --set … keychain UUID add-root-cert`. The server exposes an explicit byte allowlist. Keys, authored sources, arbitrary paths and directory listings are unavailable through HTTP.

The child xcodebuild receives these environment variables with `TEST_RUNNER_` prefixes:

- `INTERCEPTOR_REPOSITORY_FIXTURE_URL`
- `INTERCEPTOR_REPOSITORY_FIXTURE_TOKEN`
- `INTERCEPTOR_REPOSITORY_FIXTURE_DEVICE`
- `INTERCEPTOR_REPOSITORY_FIXTURE_DIGEST`

The installed xcodebuild man page documents prefix removal for test runners; [Apple's environment variable reference](https://developer.apple.com/documentation/xcode/environment-variable-reference) describes the same mechanism. UI tests require the matching nonce/digest and `SIMULATOR_UDID`; missing setup fails. There is no fixed-port fallback or fixture-dependent skip.

The wrapper waits for its child, stops its own server and removes private TLS files in `finally`, including handled interruptions and setup failures. The existing `ci-simulator-cleanup.py` stops the owned worker group before deleting the disposable simulator, which also removes that run's added CA. The simulator keychain command has add/reset operations and no individual root-removal operation. The wrapper does not reset keychains or change macOS trust. `fixture-run.json` and `public/` are safe result artifacts; keep artifact uploads restricted to those paths.

For an HTTPS/allowlist/cleanup smoke test without creating or trusting a simulator:

```sh
python3 scripts/ci-plugin-repository-fixture.py --self-test --work-dir /new/run-owned/path
```
