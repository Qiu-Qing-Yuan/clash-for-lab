#!/usr/bin/env bash

set -eu
set -o pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'test-log-cmd: %s\n' "$*" >&2
    exit 1
}

set +u
. "$repo_root/script/common.sh"
. "$repo_root/script/upgrade.sh"
. "$repo_root/script/clashctl.sh"
set -u

log_dir="$test_root/logs"
log_file="$log_dir/mihomo.log"
mkdir -p "$log_dir"

# Write test log content
printf '%s\n' 'line1' 'line2' 'line3' 'line4' 'line5' > "$log_file"

export MIHOMO_BASE_DIR="$test_root"

# ── Default: shows last 50 lines ───────────────────────────────────

(
    _failcat() { return 1; }
    output=$(clashlog 2>&1)
    [ "$(echo "$output" | wc -l | tr -d ' ')" = "5" ] || fail 'default should show all 5 lines'
    echo "$output" | grep -qx 'line5' || fail 'should contain last line'
)

# ── Specific line count ─────────────────────────────────────────────

(
    _failcat() { return 1; }
    output=$(clashlog 2 2>&1)
    [ "$(echo "$output" | wc -l | tr -d ' ')" = "2" ] || fail 'should show 2 lines'
    echo "$output" | grep -qx 'line5' || fail 'should contain last line'
    echo "$output" | grep -qx 'line4' || fail 'should contain second-to-last line'
)

# ── Line count of 1 ─────────────────────────────────────────────────

(
    _failcat() { return 1; }
    output=$(clashlog 1 2>&1)
    [ "$(echo "$output" | wc -l | tr -d ' ')" = "1" ] || fail 'should show 1 line'
    [ "$output" = "line5" ] || fail 'should show only last line'
)

# ── Invalid line count ─────────────────────────────────────────────

(
    _failcat() { return 1; }
    if clashlog abc 2>/dev/null; then
        fail 'invalid line count should fail'
    fi
)

# ── Zero lines ─────────────────────────────────────────────────────

(
    _failcat() { return 1; }
    if clashlog 0 2>/dev/null; then
        fail 'zero lines should fail'
    fi
)

# ── Missing log file ───────────────────────────────────────────────

(
    _failcat() { return 1; }
    rm -f "$log_file"
    if clashlog 2>/dev/null; then
        fail 'missing log file should fail'
    fi
    # Restore for subsequent tests
    printf '%s\n' 'line1' 'line2' 'line3' 'line4' 'line5' > "$log_file"
)

# ── Symlink log file rejected ──────────────────────────────────────

(
    _failcat() { return 1; }
    rm -f "$log_file"
    ln -s /dev/null "$log_file"
    if clashlog 2>/dev/null; then
        fail 'symlink log file should fail'
    fi
    rm -f "$log_file"
    printf '%s\n' 'line1' 'line2' 'line3' 'line4' 'line5' > "$log_file"
)

printf 'log command tests passed\n'
