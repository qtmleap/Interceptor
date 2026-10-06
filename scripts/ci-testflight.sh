#!/usr/bin/env bash
set -euo pipefail
umask 077

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_dir"

# Validate before creating a keychain or contacting Apple. Never echo secret values.
ruby -r ./fastlane/lib/testflight_config -e 'TestFlightConfig.validate_credentials!(ENV)'
if [[ ! "${APP_STORE_CONNECT_API_KEY_KEY_ID:-}" =~ ^[A-Za-z0-9]{10}$ ]]; then
    printf 'APP_STORE_CONNECT_API_KEY_KEY_ID must be a ten-character key ID.\n' >&2
    exit 2
fi
if [[ -z "${QUANTUMLEAP_READ_TOKEN:-}" ]]; then
    printf 'Missing credential: QUANTUMLEAP_READ_TOKEN\n' >&2
    exit 2
fi

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/interceptor-testflight.XXXXXXXX")
keychain_path="$work/signing.keychain-db"
original_keychains=()
netrc_installed=false

cleanup() {
    result=$?
    trap - EXIT INT TERM
    security list-keychains -d user -s "${original_keychains[@]}" >/dev/null 2>&1 || true
    security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
    if [[ "$netrc_installed" == true ]]; then
        rm -f "$HOME/.netrc"
        if [[ -e "$work/original.netrc" || -L "$work/original.netrc" ]]; then
            mv "$work/original.netrc" "$HOME/.netrc"
        fi
    fi
    rm -rf "$work"
    exit "$result"
}

security list-keychains -d user > "$work/keychains.txt"
while IFS= read -r line; do
    # security emits one quoted absolute path per line. Preserve spaces in paths.
    line=${line#*\"}
    line=${line%\"*}
    [[ -n "$line" ]] && original_keychains+=("$line")
done < "$work/keychains.txt"
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -e "$HOME/.netrc" || -L "$HOME/.netrc" ]]; then
    mv "$HOME/.netrc" "$work/original.netrc"
fi
netrc_installed=true
printf 'machine github.com\n  login x-access-token\n  password %s\n' "$QUANTUMLEAP_READ_TOKEN" > "$HOME/.netrc"
unset QUANTUMLEAP_READ_TOKEN

keychain_password=$(openssl rand -hex 24)
security create-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 7200 "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security list-keychains -d user -s "$keychain_path" "${original_keychains[@]}"
export MATCH_KEYCHAIN_NAME="$keychain_path"
export MATCH_KEYCHAIN_PASSWORD="$keychain_password"
export PLL_SOURCE_PACKAGES_PATH="$work/SourcePackages"
export RELEASE_DERIVED_DATA_PATH="$work/DerivedData"
export RELEASE_OUTPUT_PATH="$work/output"
export RELEASE_UPLOAD_HOME="$work/upload-home"
# Altool/Java Transporter uses Dir.mktmpdir rather than HOME for its .p8 file.
# Own both locations so interrupted uploads are covered by the same cleanup.
export TMPDIR="$work/tmp"
mkdir -p "$PLL_SOURCE_PACKAGES_PATH" "$RELEASE_DERIVED_DATA_PATH" "$TMPDIR"
# LicenseList's build plugin locates its checkout through DerivedData/SourcePackages.
ln -s "$PLL_SOURCE_PACKAGES_PATH" "$RELEASE_DERIVED_DATA_PATH/SourcePackages"

export CI=true FASTLANE_SKIP_UPDATE_CHECK=1 FASTLANE_SKIP_WELCOME=1
bundle exec fastlane ios beta
