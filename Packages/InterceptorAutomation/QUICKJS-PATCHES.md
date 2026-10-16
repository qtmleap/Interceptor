# QuickJS local patches

Pinned release: official QuickJS 2026-06-04, archive SHA-256 recorded in quickjs-vendor.json. The CLI, quickjs-libc, std/os and module loader are not compiled.

## 0001: bound native work and poll interrupts frequently

`Patches/0001-bound-native-work.patch` changes two constants in quickjs.c: the engine's maximum BigInt storage is reduced from 1,048,576 bits to 8,192 bits including sign/storage overhead (about 1 KiB of limbs). Temporary values count against the same allocation cap, so operations close to the nominal maximum can fail earlier. Ordinary small BigInt arithmetic remains available; BigInt action output is still rejected by the JSON contract.

The interpreter interrupt does not preempt native BigInt decimal conversion. Its polling interval is also reduced from 10000 to 64 control-flow checks: with capped native operations, a tight loop otherwise amortized thousands of native conversions between budget checks and still exceeded two seconds in debug. A million-bit conversion returned a timeout only after 4.407 seconds in the native debug regression test and 1.902 seconds under AddressSanitizer O1. The operand cap bounds native work before the long conversion can start. It does not turn the cooperative 50 ms execution budget into process isolation or a hard wall-time guarantee for every engine primitive.

quickjs-vendor.json pins the original whole-file SHA, patched whole-file SHA, exact two substitutions and patch-file SHA. scripts/verify-quickjs-vendor.py verifies all vendor bytes, reconstructs the original file and checks its SHA, compares the complete generated unified diff with the recorded patch and verifies the actual SwiftPM C source list.

For an upstream update, review the patch and every use of JS_BIGINT_MAX_SIZE again, update both source hashes and patch record deliberately, and rerun debug/release/runtime and sanitizer probes. The verifier fails rather than silently applying a patch to a different upstream file. Preserve the upstream MIT notice.
