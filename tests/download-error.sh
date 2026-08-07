#!/usr/bin/env bash

set -eu
set -o pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'test-download-error: %s\n' "$*" >&2
    exit 1
}

set +u
. "$repo_root/script/common.sh"
. "$repo_root/script/upgrade.sh"
. "$repo_root/script/clashctl.sh"
set -u

# ── _download_error_hint maps curl exit codes ──────────────────────

captured_msg=''
_failcat() { captured_msg="$2"; return 0; }

# DNS failure (curl exit 6)
captured_msg=''
_download_error_hint 6 'https://example.com/sub'
echo "$captured_msg" | grep -q 'DNS' || fail "exit 6 should mention DNS: $captured_msg"

# Connection refused (curl exit 7)
captured_msg=''
_download_error_hint 7 'https://example.com/sub'
echo "$captured_msg" | grep -q '无法连接' || fail "exit 7 should mention connection: $captured_msg"

# Timeout (curl exit 28)
captured_msg=''
_download_error_hint 28 'https://example.com/sub'
echo "$captured_msg" | grep -q '超时' || fail "exit 28 should mention timeout: $captured_msg"

# HTTP error (curl exit 22)
captured_msg=''
_download_error_hint 22 'https://example.com/sub'
echo "$captured_msg" | grep -q 'HTTP' || fail "exit 22 should mention HTTP error: $captured_msg"
echo "$captured_msg" | grep -q '过期' || fail "exit 22 should mention expiry: $captured_msg"

# TLS error (curl exit 35)
captured_msg=''
_download_error_hint 35 'https://example.com/sub'
echo "$captured_msg" | grep -q 'TLS\|SSL\|证书' || fail "exit 35 should mention TLS/SSL: $captured_msg"

# Unknown exit code
captured_msg=''
_download_error_hint 99 'https://example.com/sub'
echo "$captured_msg" | grep -q '99' || fail "unknown code should include the number: $captured_msg"

unset -f _failcat

# ── _download_raw_config calls hint on failure ─────────────────────

(
    set +e
    curl() { return 7; }
    wget() { return 7; }
    _curl_config_line() { :; }
    _failcat() { return 0; }
    _download_error_hint() { echo 'HINT_CALLED'; }

    dest="$test_root/config.yaml"
    output=$(_download_raw_config "$dest" 'https://example.com/sub' 2>&1)
    echo "$output" | grep -q 'HINT_CALLED' || fail '_download_error_hint was not called on failure'
)

printf 'download error tests passed\n'
