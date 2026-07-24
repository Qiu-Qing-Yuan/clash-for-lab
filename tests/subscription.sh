#!/usr/bin/env bash

set -eu
set -o pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)

cleanup() {
    exit_status=$?
    trap - EXIT HUP INT TERM
    rm -rf -- "$test_root"
    exit "$exit_status"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'test-subscription: %s\n' "$*" >&2
    exit 1
}

mode_of() {
    stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}

export HOME="$test_root/home"
export MIHOMO_BASE_DIR="$HOME/tools/mihomo"
export MIHOMO_CONFIG_RAW="$MIHOMO_BASE_DIR/config.yaml"
export MIHOMO_CONFIG_RAW_BAK="$MIHOMO_CONFIG_RAW.bak"
export MIHOMO_CONFIG_RUNTIME="$MIHOMO_BASE_DIR/runtime.yaml"
export MIHOMO_CONFIG_URL="$MIHOMO_BASE_DIR/url"
export MIHOMO_CONFIG_MIXIN="$MIHOMO_BASE_DIR/mixin.yaml"
export MIHOMO_UPDATE_LOG="$MIHOMO_BASE_DIR/mihomoctl.log"
export MIHOMO_PORT_PREF="$MIHOMO_BASE_DIR/config/port.pref"
export MIHOMO_PORT_STATE="$MIHOMO_BASE_DIR/config/ports.conf"

set +u
# shellcheck source=../script/clashctl.sh
. "$repo_root/script/clashctl.sh"
set -u

trace="$test_root/trace"
service_state="$test_root/service.state"
actual_runtime="$test_root/actual-runtime"

_okcat() { return 0; }
_failcat() { return 1; }
_mihomo_run_locked() {
    printf 'lock:%s\n' "$1" >> "$trace"
    "$@"
}
_download_config() {
    destination=$1
    url=$2
    printf 'download\n' >> "$trace"
    printf '%s' "$url" > "$test_root/download.url"
    [ ! -f "$test_root/download.fail" ] || return 1
    printf 'downloaded:%s\n' "$url" > "$destination"
}
_valid_config() {
    [ ! -f "$test_root/validation.fail" ] && grep -q '^downloaded:' "$1"
}
_build_runtime_candidate() {
    raw=$1
    destination=$2
    [ ! -f "$test_root/build.fail" ] || return 1
    printf 'runtime:%s\n' "$(cat "$raw")" > "$destination"
}
is_mihomo_running() {
    [ "$(cat "$service_state" 2>/dev/null || true)" = running ]
}
_stop_mihomo_unlocked() {
    printf 'stop\n' >> "$trace"
    printf '%s\n' stopped > "$service_state"
    [ ! -f "$test_root/stop.fail" ]
}
_activate_published_runtime_unlocked() {
    printf 'start\n' >> "$trace"
    cp "$MIHOMO_CONFIG_RUNTIME" "$actual_runtime"
    printf '%s\n' running > "$service_state"
    if [ -f "$test_root/start.fail-once" ]; then
        rm -f "$test_root/start.fail-once"
        return 1
    fi
}
_refresh_runtime_environment_unlocked() {
    printf 'refresh\n' >> "$trace"
}
_unset_system_proxy() {
    printf 'proxy-off\n' >> "$trace"
}

reset_fixture() {
    rm -rf -- "$MIHOMO_BASE_DIR"
    mkdir -p "$MIHOMO_BASE_DIR/config"
    printf '%s\n' old-raw > "$MIHOMO_CONFIG_RAW"
    printf '%s\n' old-backup > "$MIHOMO_CONFIG_RAW_BAK"
    printf '%s\n' old-runtime > "$MIHOMO_CONFIG_RUNTIME"
    printf '%s\n' 'https://saved.example/sub?token=TOKEN_SECRET' > "$MIHOMO_CONFIG_URL"
    printf '%s\n' mixin > "$MIHOMO_CONFIG_MIXIN"
    printf '%s\n' stopped > "$service_state"
    printf '%s\n' old-runtime > "$actual_runtime"
    : > "$trace"
    rm -f "$test_root/download.fail" "$test_root/validation.fail" \
        "$test_root/build.fail" "$test_root/stop.fail" "$test_root/start.fail-once" \
        "$test_root/download.url" "$test_root/private.checked"
}

snapshot_managed() {
    prefix=$1
    cp "$MIHOMO_CONFIG_RAW" "$prefix.raw"
    cp "$MIHOMO_CONFIG_RAW_BAK" "$prefix.raw-bak"
    cp "$MIHOMO_CONFIG_RUNTIME" "$prefix.runtime"
    cp "$MIHOMO_CONFIG_URL" "$prefix.url"
    cp "$service_state" "$prefix.service"
}

assert_managed_snapshot() {
    prefix=$1
    cmp -s "$prefix.raw" "$MIHOMO_CONFIG_RAW" || fail 'raw config was not restored'
    cmp -s "$prefix.raw-bak" "$MIHOMO_CONFIG_RAW_BAK" || fail 'raw backup was not restored'
    cmp -s "$prefix.runtime" "$MIHOMO_CONFIG_RUNTIME" || fail 'runtime was not restored'
    cmp -s "$prefix.url" "$MIHOMO_CONFIG_URL" || fail 'subscription URL was not restored'
    cmp -s "$prefix.service" "$service_state" || fail 'service state was not restored'
}

_is_valid_subscription_url 'https://example.com/sub?token=a' ||
    fail 'valid HTTPS URL was rejected'
if _is_valid_subscription_url 'HTTPS://example.com/sub'; then
    fail 'uppercase scheme was accepted'
fi
if _is_valid_subscription_url 'https://example.com/sub token'; then
    fail 'URL containing whitespace was accepted'
fi

# subscribe saves through one locked atomic replacement and does not expose the
# token in the success message or any product log.
reset_fixture
printf 'n\n' | clashsubscribe 'https://new.example/sub?token=NEW_TOKEN' >/dev/null ||
    fail 'subscribe failed'
[ "$(cat "$MIHOMO_CONFIG_URL")" = 'https://new.example/sub?token=NEW_TOKEN' ] ||
    fail 'subscribe did not save the URL'
[ "$(mode_of "$MIHOMO_CONFIG_URL")" = 600 ] || fail 'saved URL mode is not 600'
[ "$(grep -c '^lock:_clashsubscribe_set_locked$' "$trace")" -eq 1 ] ||
    fail 'subscribe did not use exactly one lifecycle lock'
[ ! -e "$MIHOMO_UPDATE_LOG" ] || fail 'subscribe wrote an update log before updating'

# A failed atomic rename leaves the previous URL byte-for-byte intact.
reset_fixture
cp "$MIHOMO_CONFIG_URL" "$test_root/url.before"
if (
    mv() { return 1; }
    printf 'n\n' | clashsubscribe 'https://failed.example/sub' >/dev/null 2>&1
); then
    fail 'subscribe reported success after atomic publication failed'
fi
cmp -s "$test_root/url.before" "$MIHOMO_CONFIG_URL" ||
    fail 'failed subscribe changed the current URL'

# Confirmation invokes update without pinning the prompted URL, so update reads
# whichever URL is current at confirmation time.
reset_fixture
(
    clashupdate() {
        _read_subscription_url_snapshot "$MIHOMO_CONFIG_URL" > "$test_root/confirmed.url"
    }
    printf 'y\n' | clashsubscribe 'https://confirmed.example/sub' >/dev/null
) || fail 'subscribe confirmation failed'
[ "$(cat "$test_root/confirmed.url")" = 'https://confirmed.example/sub' ] ||
    fail 'confirmation did not update the current URL'

# Successful stopped-service update publishes complete files, keeps the service
# stopped, backs up the old raw file, and never logs the URL token.
reset_fixture
clashupdate || fail 'stopped-service update failed'
grep -Fq 'TOKEN_SECRET' "$MIHOMO_CONFIG_RAW" || fail 'downloaded raw config was not published'
[ "$(cat "$MIHOMO_CONFIG_RAW_BAK")" = old-raw ] || fail 'old raw was not backed up'
grep -Fq 'runtime:downloaded:' "$MIHOMO_CONFIG_RUNTIME" ||
    fail 'runtime candidate was not published'
[ "$(cat "$service_state")" = stopped ] || fail 'stopped service was started by update'
[ "$(grep -c '^lock:_clashupdate_locked$' "$trace")" -eq 1 ] ||
    fail 'update did not use exactly one lifecycle lock'
[ "$(grep -c '^download$' "$trace")" -eq 1 ] || fail 'update did not download exactly once'
if grep -Fq TOKEN_SECRET "$MIHOMO_UPDATE_LOG"; then
    fail 'subscription token was written to the update log'
fi
grep -Fq '订阅更新成功' "$MIHOMO_UPDATE_LOG" || fail 'success log entry is missing'
for managed in "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_RAW_BAK" \
    "$MIHOMO_CONFIG_RUNTIME" "$MIHOMO_CONFIG_URL" "$MIHOMO_UPDATE_LOG"; do
    [ "$(mode_of "$managed")" = 600 ] || fail "managed file mode is not 600: $managed"
done

# The transaction directory and snapshots are private before the first publish.
reset_fixture
_lifecycle_before_object_publish() {
    transaction_dir=$(find "$MIHOMO_BASE_DIR/tmp" -maxdepth 1 -type d \
        -name 'subscription-update.*' -print -quit)
    [ -n "$transaction_dir" ] || return 1
    [ "$(mode_of "$transaction_dir")" = 700 ] || return 1
    [ "$(mode_of "$transaction_dir/snapshot")" = 700 ] || return 1
    for private_file in \
        "$transaction_dir/snapshot/raw.state" \
        "$transaction_dir/snapshot/raw.previous" \
        "$transaction_dir/snapshot/raw-bak.state" \
        "$transaction_dir/snapshot/raw-bak.previous" \
        "$transaction_dir/snapshot/runtime.state" \
        "$transaction_dir/snapshot/runtime.previous" \
        "$transaction_dir/snapshot/url.state" \
        "$transaction_dir/snapshot/url.previous"; do
        [ "$(mode_of "$private_file")" = 600 ] || return 1
    done
    : > "$test_root/private.checked"
}
clashupdate >/dev/null || fail 'private snapshot update failed'
[ -f "$test_root/private.checked" ] || fail 'private snapshots were not inspected'
_lifecycle_before_object_publish() { :; }

# A running service is stopped once and restarted on the new runtime.
reset_fixture
printf '%s\n' running > "$service_state"
clashupdate 'https://explicit.example/sub?token=EXPLICIT_SECRET' ||
    fail 'running-service update failed'
[ "$(cat "$service_state")" = running ] || fail 'running service was not restarted'
cmp -s "$MIHOMO_CONFIG_RUNTIME" "$actual_runtime" ||
    fail 'service did not start with the published runtime'
[ "$(cat "$MIHOMO_CONFIG_URL")" = 'https://explicit.example/sub?token=EXPLICIT_SECRET' ] ||
    fail 'explicit URL was not committed'
[ "$(grep -c '^stop$' "$trace")" -eq 1 ] || fail 'running service was not stopped once'
[ "$(grep -c '^start$' "$trace")" -eq 1 ] || fail 'running service was not started once'

# Download and validation failures happen before snapshots or service changes.
for failure_kind in download validation; do
    reset_fixture
    snapshot_managed "$test_root/$failure_kind.before"
    : > "$test_root/$failure_kind.fail"
    if clashupdate >/dev/null 2>&1; then
        fail "$failure_kind failure was reported as success"
    fi
    assert_managed_snapshot "$test_root/$failure_kind.before"
    if grep -Eq '^(stop|start)$' "$trace"; then
        fail "$failure_kind failure changed the service"
    fi
done

# A startup failure after publication restores all four managed files and the
# exact previous running state, then starts the restored runtime.
reset_fixture
printf '%s\n' running > "$service_state"
snapshot_managed "$test_root/start.before"
: > "$test_root/start.fail-once"
if clashupdate 'https://rollback.example/sub?token=ROLLBACK_SECRET' >/dev/null 2>&1; then
    fail 'startup failure was reported as success'
fi
assert_managed_snapshot "$test_root/start.before"
cmp -s "$MIHOMO_CONFIG_RUNTIME" "$actual_runtime" ||
    fail 'rollback service did not use the restored runtime'
[ "$(grep -c '^start$' "$trace")" -eq 2 ] ||
    fail 'startup rollback did not retry with the old runtime'

# Every managed path rejects both a symlink and a special object before taking
# the lifecycle lock, creating temp files, downloading, or touching peers.
for managed_path in "$MIHOMO_CONFIG_RAW" "$MIHOMO_CONFIG_RAW_BAK" \
    "$MIHOMO_CONFIG_RUNTIME" "$MIHOMO_CONFIG_URL" \
    "$MIHOMO_CONFIG_MIXIN" "$MIHOMO_PORT_PREF" \
    "$MIHOMO_PORT_STATE" "$MIHOMO_UPDATE_LOG"; do
    reset_fixture
    [ -e "$managed_path" ] || printf '%s\n' placeholder > "$managed_path"
    mv "$managed_path" "$managed_path.target"
    ln -s "$managed_path.target" "$managed_path"
    if clashupdate >/dev/null 2>&1; then
        fail "update accepted managed symlink: $managed_path"
    fi
    [ -L "$managed_path" ] || fail "managed symlink was changed: $managed_path"
    [ ! -s "$trace" ] || fail "managed symlink caused operational side effects: $managed_path"
    [ ! -e "$MIHOMO_BASE_DIR/tmp" ] || fail "managed symlink created a temp directory: $managed_path"

    reset_fixture
    rm -f "$managed_path"
    mkdir "$managed_path"
    if clashupdate >/dev/null 2>&1; then
        fail "update accepted managed special path: $managed_path"
    fi
    [ -d "$managed_path" ] || fail "managed special path was changed: $managed_path"
    [ ! -s "$trace" ] || fail "managed special path caused operational side effects: $managed_path"
    [ ! -e "$MIHOMO_BASE_DIR/tmp" ] || fail "managed special path created a temp directory: $managed_path"
done

# Deprecated automatic updates fail before locking and never call crontab.
reset_fixture
if clashupdate auto >/dev/null 2>&1; then
    fail 'update auto was accepted'
fi
[ ! -s "$trace" ] || fail 'update auto entered a locked operation'
if command -v crontab >/dev/null 2>&1 && [ -e "$test_root/crontab.calls" ]; then
    fail 'update auto called crontab'
fi

printf '%s\n' 'subscription tests passed'
