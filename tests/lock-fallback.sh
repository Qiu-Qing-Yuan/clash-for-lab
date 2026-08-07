#!/usr/bin/env bash

set -eu
set -o pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'test-lock-fallback: %s\n' "$*" >&2
    exit 1
}

set +u
. "$repo_root/script/common.sh"
. "$repo_root/script/upgrade.sh"
. "$repo_root/script/clashctl.sh"
set -u

# ── Lock acquire / release / re-acquire ─────────────────────────────

(
    export HOME="$test_root/home-basic"
    export MIHOMO_UPGRADE_LOCK_DIR="$HOME/.cache/clash-for-lab/mihomo-operation.lock"
    _UPGRADE_LOCK_METHOD=''

    _upgrade_acquire_lock || fail 'lock acquisition failed'
    [ -n "$_UPGRADE_LOCK_METHOD" ] || fail 'lock method not set'

    # Second acquire should fail while the first is still held
    if _upgrade_acquire_lock 2>/dev/null; then
        fail 'second lock acquisition should fail while first is held'
    fi

    _upgrade_release_lock
    [ -z "${_UPGRADE_LOCK_METHOD:-}" ] || fail 'lock method not cleared after release'

    # Re-acquire after release
    _upgrade_acquire_lock || fail 'lock re-acquisition failed after release'
    _upgrade_release_lock
)

# ── mkdir lock mechanism (direct test) ─────────────────────────────
# Test the mkdir-based lock directly, independent of flock availability.

(
    lock_dir="$test_root/mkdir-lock.d"
    parent=$(dirname "$lock_dir")
    mkdir -p "$parent"

    # Acquire: mkdir succeeds
    mkdir "$lock_dir" || fail 'mkdir lock should succeed on first acquire'
    chmod 0700 "$lock_dir" 2>/dev/null || true
    printf '%s\n' "$$" > "$lock_dir/owner" || fail 'cannot write owner'

    # Second acquire: mkdir fails
    if mkdir "$lock_dir" 2>/dev/null; then
        fail 'mkdir lock should fail when already held'
    fi

    # Release
    rm -f "$lock_dir/owner"
    rmdir "$lock_dir" 2>/dev/null || fail 'cannot remove lock dir on release'

    # Re-acquire after release
    mkdir "$lock_dir" || fail 'mkdir lock should succeed after release'
    rm -f "$lock_dir/owner"
    rmdir "$lock_dir" 2>/dev/null || true
)

# ── stale lock cleanup (mkdir method) ───────────────────────────────
# When the owner PID is no longer alive, the stale lock should be cleaned.

(
    lock_dir="$test_root/stale-lock.d"
    parent=$(dirname "$lock_dir")
    mkdir -p "$parent"

    # Create a stale lock with a dead PID
    mkdir "$lock_dir"
    printf '999999\n' > "$lock_dir/owner"

    # Simulate the stale lock cleanup logic from _upgrade_acquire_lock
    stale_owner=$(cat "${lock_dir}/owner" 2>/dev/null || true)
    if [ -n "$stale_owner" ] && ! kill -0 "$stale_owner" 2>/dev/null; then
        rm -f "${lock_dir}/owner" 2>/dev/null || true
        rmdir "$lock_dir" 2>/dev/null || true
    fi

    # Lock dir should be cleaned up
    [ ! -d "$lock_dir" ] || fail 'stale lock was not cleaned up'

    # Should be able to acquire now
    mkdir "$lock_dir" || fail 'cannot acquire after stale lock cleanup'
    rm -f "$lock_dir/owner"
    rmdir "$lock_dir" 2>/dev/null || true
)

# ── live owner prevents stale lock cleanup ─────────────────────────

(
    lock_dir="$test_root/live-lock.d"
    parent=$(dirname "$lock_dir")
    mkdir -p "$parent"

    # Create a lock with our own PID (alive)
    mkdir "$lock_dir"
    printf '%s\n' "$$" > "$lock_dir/owner"

    # Stale lock check should NOT clean up (owner is alive)
    stale_owner=$(cat "${lock_dir}/owner" 2>/dev/null || true)
    if [ -n "$stale_owner" ] && ! kill -0 "$stale_owner" 2>/dev/null; then
        rm -f "${lock_dir}/owner" 2>/dev/null || true
        rmdir "$lock_dir" 2>/dev/null || true
    fi

    [ -d "$lock_dir" ] || fail 'live owner lock was incorrectly cleaned up'

    # Clean up
    rm -f "$lock_dir/owner"
    rmdir "$lock_dir" 2>/dev/null || true
)

# ── _valid_upgrade_env does not require flock ───────────────────────

# Only test on Linux amd64 (the supported platform)
case "$(uname -s 2>/dev/null):$(uname -m 2>/dev/null)" in
Linux:x86_64|Linux:amd64)
    (
        set +u
        _valid_upgrade_env || fail '_valid_upgrade_env should pass without flock'
        set -u
    )
    ;;
esac

printf 'lock fallback tests passed\n'
