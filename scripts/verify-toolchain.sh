#!/usr/bin/env bash
set -euo pipefail
app_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
exec ruby "$app_root/scripts/verify-toolchain.rb"
