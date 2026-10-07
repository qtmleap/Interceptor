#!/usr/bin/env bash
# Checks the real toolchain instead of trusting runner labels. Prints no environment.
set -euo pipefail
expected=${EXPECTED_XCODE_MAJOR:-27}

if [[ "$(uname -s)" != "Darwin" || "$(uname -m)" != "arm64" ]]; then
    echo "::error::A macOS ARM64 runner is required." >&2
    exit 1
fi
version=$(xcodebuild -version | sed -n '1s/^Xcode \([0-9][0-9]*\).*/\1/p')
if [[ "$version" != "$expected" ]]; then
    echo "::error::Xcode $expected is required; found '${version:-unknown}'." >&2
    exit 1
fi
xcodebuild -version
