#!/usr/bin/env bash
# Undoes release side effects even if the Ruby process was killed: restores the keychain search
# list, deletes the temporary keychain, restores ~/.netrc and removes the work directory.
# Exits non-zero if any step fails so a cleanup failure is never silent.
set -uo pipefail

temp=${RUNNER_TEMP:?RUNNER_TEMP is required}
work=${RELEASE_WORK:?RELEASE_WORK is required}
state="$temp/release-state"
task_home=${HOME:?}
failed=0

if [[ -f "$state/original.txt" ]]; then
    original=()
    while IFS= read -r line; do
        [[ -n "$line" ]] && original+=("$line")
    done < "$state/original.txt"
    security list-keychains -d user -s "${original[@]}" >/dev/null 2>&1 || { echo "::error::Could not restore the keychain search list." >&2; failed=1; }
    if [[ -f "$state/path" ]]; then
        keychain=$(head -n 1 "$state/path")
        security delete-keychain "$keychain" >/dev/null 2>&1 || [[ ! -e "$keychain" ]] || { echo "::error::Could not delete the temporary keychain." >&2; failed=1; }
    fi
fi

if [[ -e "$state/original.netrc" || -L "$state/original.netrc" ]]; then
    rm -f "$task_home/.netrc" && mv "$state/original.netrc" "$task_home/.netrc" || { echo "::error::Could not restore ~/.netrc; recovery state retained." >&2; failed=1; }
elif [[ -f "$state/netrc-installed" ]] && [[ "$(cat "$state/netrc-installed")" != original-pending ]]; then
    rm -f "$task_home/.netrc" || failed=1
fi

# Refuse to remove anything that is not inside RUNNER_TEMP.
case "$work" in
    "$temp"/*) rm -rf "$work" || failed=1; if [[ "$failed" -eq 0 ]]; then rm -rf "$state" || failed=1; fi ;;
    *) echo "::error::RELEASE_WORK is outside RUNNER_TEMP." >&2; failed=1 ;;
esac
[[ -e "$work" ]] && failed=1
exit "$failed"
