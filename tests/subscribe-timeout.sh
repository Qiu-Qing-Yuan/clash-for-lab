#!/usr/bin/env bash

set -eu
set -o pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'test-subscribe-timeout: %s\n' "$*" >&2
    exit 1
}

set +u
. "$repo_root/script/common.sh"
. "$repo_root/script/upgrade.sh"
. "$repo_root/script/clashctl.sh"
set -u

# ── Default timeout is 60 ──────────────────────────────────────────
# _download_raw_config runs curl in a pipeline (subshell), so we
# capture the --max-time argument via a file instead of a variable.

max_time_log="$test_root/max_time.log"

_download_raw_config_with_log() {
    : > "$max_time_log"
    local prev_curl
    prev_curl=$(command -v curl 2>/dev/null || true)

    curl() {
        local in_max_time=false
        for arg in "$@"; do
            if [ "$in_max_time" = true ]; then
                printf '%s\n' "$arg" >> "$max_time_log"
                in_max_time=false
            elif [ "$arg" = "--max-time" ]; then
                in_max_time=true
            fi
        done
        printf 'fake-content\n' > "$_FAKE_OUTPUT"
        return 0
    }
    _download_raw_config "$@"
    local rc=$?
    unset -f curl
    return $rc
}

_curl_config_line() { printf '%s = "%s"\n' "$1" "$2"; }

(
    export _FAKE_OUTPUT="$test_root/curl_out1"
    unset MIHOMO_SUBSCRIBE_TIMEOUT
    _download_raw_config_with_log "$test_root/config1.yaml" 'https://example.com/sub' ||
        fail 'default download failed'
    [ "$(cat "$max_time_log")" = "60" ] ||
        fail "default max-time should be 60, got $(cat "$max_time_log")"
)

# ── Custom timeout via MIHOMO_SUBSCRIBE_TIMEOUT ─────────────────────

(
    export _FAKE_OUTPUT="$test_root/curl_out2"
    export MIHOMO_SUBSCRIBE_TIMEOUT=120
    _download_raw_config_with_log "$test_root/config2.yaml" 'https://example.com/sub' ||
        fail 'custom download failed'
    [ "$(cat "$max_time_log")" = "120" ] ||
        fail "custom max-time should be 120, got $(cat "$max_time_log")"
)

# ── wget fallback also uses the timeout ─────────────────────────────

wget_timeout_log="$test_root/wget_timeout.log"

(
    : > "$wget_timeout_log"
    export _FAKE_OUTPUT="$test_root/wget_out"
    export MIHOMO_SUBSCRIBE_TIMEOUT=90

    curl() { return 1; }
    wget() {
        local in_timeout=false
        for arg in "$@"; do
            if [ "$in_timeout" = true ]; then
                printf '%s\n' "$arg" >> "$wget_timeout_log"
                in_timeout=false
            elif [ "$arg" = "--timeout" ]; then
                in_timeout=true
            fi
        done
        printf 'fake-content\n' > "$_FAKE_OUTPUT"
        return 0
    }

    _download_raw_config "$test_root/config3.yaml" 'https://example.com/sub' ||
        fail 'wget fallback failed'

    [ "$(cat "$wget_timeout_log")" = "90" ] ||
        fail "wget timeout should be 90, got $(cat "$wget_timeout_log")"
)

printf 'subscribe timeout tests passed\n'
