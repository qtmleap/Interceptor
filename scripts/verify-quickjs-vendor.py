#!/usr/bin/env python3
"""Verify the vendored QuickJS bytes and the explicit SwiftPM C source list."""
import argparse
import difflib
import hashlib
import json
from pathlib import Path
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--package-dir", type=Path, default=Path(__file__).resolve().parents[1] / "Packages/InterceptorAutomation")
args = parser.parse_args()
package = args.package_dir.resolve()
try:
    record = json.loads((package / "quickjs-vendor.json").read_text())
    vendor = package / "Sources/CQuickJS/Vendor"
    actual = {p.name for p in vendor.iterdir() if p.is_file()}
    if actual != set(record["files"]):
        raise ValueError("Vendor file inventory differs from the pinned release")
    for name, expected in record["files"].items():
        path = vendor / name
        if path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise ValueError("QuickJS checksum mismatch: " + name)
    patches = record.get("patches", [])
    if len(patches) != 1 or patches[0]["id"] != "bound-native-work":
        raise ValueError("Expected the audited native-work limits patch")
    patch = patches[0]
    if patch["file"] != "quickjs.c" or patch["patchFile"] != "Patches/0001-bound-native-work.patch":
        raise ValueError("Unexpected QuickJS patch target")
    expected_substitutions = [
        {"find": "#define JS_BIGINT_MAX_SIZE ((1024 * 1024) / JS_LIMB_BITS) /* in limbs */",
         "replace": "#define JS_BIGINT_MAX_SIZE (8192 / JS_LIMB_BITS) /* in limbs */", "expectedCount": 1},
        {"find": "#define JS_INTERRUPT_COUNTER_INIT 10000",
         "replace": "#define JS_INTERRUPT_COUNTER_INIT 64", "expectedCount": 1},
    ]
    if patch["substitutions"] != expected_substitutions:
        raise ValueError("Unexpected native-work limits")
    patched = (vendor / patch["file"]).read_bytes()
    original = patched
    for edit in reversed(expected_substitutions):
        before, after = edit["find"].encode(), edit["replace"].encode()
        if original.count(after) != 1 or before in original:
            raise ValueError("QuickJS patch does not apply exactly once")
        original = original.replace(after, before, 1)
    if hashlib.sha256(original).hexdigest() != patch["originalSHA256"]:
        raise ValueError("QuickJS reverse patch differs from the official source")
    patch_path = package / patch["patchFile"]
    expected_diff = "".join(difflib.unified_diff(
        original.decode().splitlines(keepends=True), patched.decode().splitlines(keepends=True),
        fromfile="a/Sources/CQuickJS/Vendor/quickjs.c", tofile="b/Sources/CQuickJS/Vendor/quickjs.c",
    )).encode()
    if patch_path.is_symlink() or patch_path.read_bytes() != expected_diff or hashlib.sha256(expected_diff).hexdigest() != patch["patchSHA256"]:
        raise ValueError("QuickJS patch record differs from the actual source change")
    dump = subprocess.run(
        ["swift", "package", "--package-path", str(package), "dump-package"],
        check=True, text=True, capture_output=True, timeout=60,
    )
    targets = json.loads(dump.stdout)["targets"]
    target = next(t for t in targets if t["name"] == "CQuickJS")
    expected_sources = {"bridge.c"} | {"Vendor/" + p for p in record["compiledSources"]}
    if set(target.get("sources", [])) != expected_sources:
        raise ValueError("CQuickJS compiled sources differ from the reviewed core-only list")
    print("QuickJS " + record["version"] + ": pinned vendor bytes, audited native-work patch and core-only sources verified")
except (OSError, ValueError, KeyError, StopIteration, subprocess.SubprocessError) as error:
    print(str(error), file=sys.stderr)
    sys.exit(1)
