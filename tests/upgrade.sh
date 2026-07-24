#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'test-upgrade: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    [ "$1" = "$2" ] || fail "$3 (expected '$1', got '$2')"
}

assert_same() {
    cmp -s "$1" "$2" || fail "$3"
}

assert_version() {
    local actual
    actual=$(_upgrade_binary_version "$2" 2>/dev/null || true)
    assert_eq "$1" "$actual" "$3"
}

MIHOMO_BASE_DIR="$test_root/bootstrap"
MIHOMO_CONFIG_RUNTIME="$MIHOMO_BASE_DIR/runtime.yaml"
MIHOMO_CONFIG_RAW="$MIHOMO_BASE_DIR/config.yaml"
BIN_MIHOMO="$MIHOMO_BASE_DIR/bin/mihomo"
MIHOMO_UPGRADE_GRACE=0

# shellcheck source=../script/upgrade.sh
. "$repo_root/script/upgrade.sh"

if ! command -v timeout >/dev/null 2>&1; then
    timeout() {
        [ "${1:-}" = --kill-after=5 ] && shift
        shift
        "$@"
    }
fi

if ! command -v flock >/dev/null 2>&1; then
    flock() { return 0; }
fi

_upgrade_platform() {
    UPGRADE_OS=linux
    UPGRADE_ARCH=amd64
    UPGRADE_VARIANT=v1
}

case_number=0
TEST_COMMIT=0123456789abcdef0123456789abcdef01234567

new_case() {
    case_number=$((case_number + 1))
    CASE_ROOT="$test_root/case-$case_number"
    MIHOMO_BASE_DIR="$CASE_ROOT/install"
    MIHOMO_CONFIG_RUNTIME="$MIHOMO_BASE_DIR/runtime.yaml"
    MIHOMO_CONFIG_RAW="$MIHOMO_BASE_DIR/config.yaml"
    BIN_MIHOMO="$MIHOMO_BASE_DIR/bin/mihomo"
    MIHOMO_UPGRADE_STATE_DIR="$MIHOMO_BASE_DIR/state"
    MIHOMO_UPGRADE_STATE_LOCK="$MIHOMO_UPGRADE_STATE_DIR/mihomo.lock.tsv"
    MIHOMO_UPGRADE_PREVIOUS_STATE="$MIHOMO_UPGRADE_STATE_DIR/mihomo.previous.lock.tsv"
    MIHOMO_UPGRADE_PREVIOUS="$MIHOMO_BASE_DIR/bin/mihomo.previous"
    MIHOMO_UPGRADE_LOCK_DIR="$MIHOMO_BASE_DIR/tmp/mihomo-operation.lock"
    MIHOMO_PORT_STATE="$MIHOMO_BASE_DIR/config/ports.conf"
    FIXTURES="$CASE_ROOT/fixtures"
    MANIFEST="$FIXTURES/mihomo.lock.tsv"
    ARCHIVE="$FIXTURES/mihomo-linux-amd64-v1.gz"
    FETCH_LOG="$CASE_ROOT/fetch.log"
    SERVICE_LOG="$CASE_ROOT/service.log"
    SERVICE_STATE="$CASE_ROOT/service.state"
    CASE_LOG="$CASE_ROOT/case.log"
    mkdir -p "$MIHOMO_BASE_DIR/bin" "$MIHOMO_BASE_DIR/config" \
        "$MIHOMO_UPGRADE_STATE_DIR" "$MIHOMO_BASE_DIR/tmp" "$FIXTURES"
    : > "$FETCH_LOG"
    : > "$SERVICE_LOG"
    printf 'stopped\n' > "$SERVICE_STATE"
    unset START_FAIL_VERSION AFTER_PUBLISH_SIGNAL STATE_WRITE_FAIL_ON_CALL
    STATE_WRITE_CALLS=0
}

write_binary() {
    local destination=$1 version=$2 config_exit=${3:-0}
    {
        printf '%s\n' '#!/bin/sh'
        printf 'version=%s\n' "$version"
        printf 'config_exit=%s\n' "$config_exit"
        printf '%s\n' \
            'if [ "${1:-}" = -v ]; then' \
            '    printf "Mihomo Meta %s linux amd64\\n" "$version"' \
            '    exit 0' \
            'fi' \
            'for argument in "$@"; do' \
            '    [ "$argument" = -t ] && exit "$config_exit"' \
            'done' \
            'exit 0'
    } > "$destination"
    chmod 0755 "$destination"
}

write_manifest() {
    printf 'schema\t1\nasset\tlinux\tamd64\tv1\t%s\tmihomo-linux-amd64-v1.gz\t%s\t%s\n' \
        "$1" "$2" "$3" > "$MANIFEST"
}

write_state() {
    local destination=$1 version=$2 binary=$3 archive_sha binary_size binary_sha
    archive_sha=$(printf 'a%.0s' {1..64})
    binary_size=$(_upgrade_file_size "$binary")
    binary_sha=$(_upgrade_sha256 "$binary")
    printf 'schema\t2\nasset\tlinux\tamd64\tv1\t%s\tmihomo-linux-amd64-v1.gz\t1\t%s\n' \
        "$version" "$archive_sha" > "$destination"
    printf 'binary\t%s\t%s\t%s\n' "$version" "$binary_size" "$binary_sha" >> "$destination"
}

prepare_remote() {
    local version=$1 config_exit=${2:-0} payload_version=${3:-$1} payload="$FIXTURES/payload"
    write_binary "$payload" "$payload_version" "$config_exit"
    gzip -c "$payload" > "$ARCHIVE"
    REMOTE_SIZE=$(_upgrade_file_size "$ARCHIVE")
    REMOTE_SHA=$(_upgrade_sha256 "$ARCHIVE")
    write_manifest "$version" "$REMOTE_SIZE" "$REMOTE_SHA"
}

write_ports() {
    printf '%s\n' \
        'PROXY_PORT=24567' \
        'UI_PORT=24568' \
        'DNS_PORT=24569' \
        'TIMESTAMP=1700000000' > "$MIHOMO_PORT_STATE"
}

_upgrade_json() { printf '%s\n' "$TEST_COMMIT"; }

_upgrade_fetch_url() {
    local url=$1 destination=$2
    printf '%s\n' "$url" >> "$FETCH_LOG"
    case "$url" in
    */commits/main) printf '{"sha":"%s"}\n' "$TEST_COMMIT" > "$destination" ;;
    */resources/mihomo.lock.tsv) cp "$MANIFEST" "$destination" ;;
    */resources/zip/mihomo-linux-amd64-v1.gz) cp "$ARCHIVE" "$destination" ;;
    *) return 1 ;;
    esac
}

is_mihomo_running() {
    [ "$(cat "$SERVICE_STATE" 2>/dev/null || true)" = running ]
}

stop_mihomo() {
    printf 'stop\n' >> "$SERVICE_LOG"
    printf 'stopped\n' > "$SERVICE_STATE"
    rm -f "$MIHOMO_PORT_STATE"
}

start_mihomo() {
    local version
    version=$(_upgrade_binary_version "$BIN_MIHOMO" 2>/dev/null || true)
    printf 'start:%s\n' "$version" >> "$SERVICE_LOG"
    if [ "${START_FAIL_VERSION:-}" = "$version" ]; then
        return 1
    fi
    printf 'running\n' > "$SERVICE_STATE"
}

_upgrade_after_binary_publish() {
    [ -n "${AFTER_PUBLISH_SIGNAL:-}" ] || return 0
    case "$AFTER_PUBLISH_SIGNAL" in
    TERM) sh -c 'kill -TERM "$PPID"' ;;
    HUP) sh -c 'kill -HUP "$PPID"' ;;
    *) return 1 ;;
    esac
}

_upgrade_write_state() {
    STATE_WRITE_CALLS=$((STATE_WRITE_CALLS + 1))
    [ "${STATE_WRITE_FAIL_ON_CALL:-0}" != "$STATE_WRITE_CALLS" ] || return 1
    _upgrade_write_state_impl "$@"
}

run_upgrade() {
    clashupgrade > "$CASE_LOG" 2>&1 || {
        sed -n '1,100p' "$CASE_LOG" >&2
        fail 'upgrade unexpectedly failed'
    }
}

expect_upgrade_failure() {
    clashupgrade > "$CASE_LOG" 2>&1 && fail 'upgrade unexpectedly succeeded'
    return 0
}

prepare_installed_pair() {
    write_binary "$BIN_MIHOMO" v1.0.0
    write_binary "$MIHOMO_UPGRADE_PREVIOUS" v0.9.0
    write_state "$MIHOMO_UPGRADE_STATE_LOCK" v1.0.0 "$BIN_MIHOMO"
    write_state "$MIHOMO_UPGRADE_PREVIOUS_STATE" v0.9.0 "$MIHOMO_UPGRADE_PREVIOUS"
}

prepare_rollback_pair() {
    write_binary "$BIN_MIHOMO" v2.0.0
    write_binary "$MIHOMO_UPGRADE_PREVIOUS" v1.0.0
    write_state "$MIHOMO_UPGRADE_STATE_LOCK" v2.0.0 "$BIN_MIHOMO"
    write_state "$MIHOMO_UPGRADE_PREVIOUS_STATE" v1.0.0 "$MIHOMO_UPGRADE_PREVIOUS"
}

test_stable_parsing_and_pinned_source() {
    local snapshot
    new_case
    prepare_remote v2.0.0
    snapshot="$FIXTURES/snapshot"
    mkdir -p "$snapshot"
    _upgrade_platform
    _upgrade_resolve_repository_snapshot "$snapshot" || fail 'could not resolve pinned source'
    grep -Fxq 'https://api.github.com/repos/SaladDay/clash-for-lab/commits/main' "$FETCH_LOG" ||
        fail 'commit source is not fixed'
    grep -Fxq "https://raw.githubusercontent.com/SaladDay/clash-for-lab/$TEST_COMMIT/resources/mihomo.lock.tsv" "$FETCH_LOG" ||
        fail 'manifest was not pinned to the immutable commit'
    assert_eq "https://raw.githubusercontent.com/SaladDay/clash-for-lab/$TEST_COMMIT/resources/zip/mihomo-linux-amd64-v1.gz" \
        "$UPGRADE_REMOTE_URL" 'payload was not pinned to the immutable commit'
    write_manifest v2.0.0-alpha "$REMOTE_SIZE" "$REMOTE_SHA"
    _upgrade_parse_manifest "$MANIFEST" >/dev/null 2>&1 && fail 'preview version was accepted'
    return 0
}

test_successful_running_upgrade() {
    local old_current old_state ports_before
    new_case
    prepare_installed_pair
    prepare_remote v2.0.0
    old_current="$FIXTURES/current.before"
    old_state="$FIXTURES/state.before"
    ports_before="$FIXTURES/ports.before"
    cp "$BIN_MIHOMO" "$old_current"
    cp "$MIHOMO_UPGRADE_STATE_LOCK" "$old_state"
    write_ports
    cp "$MIHOMO_PORT_STATE" "$ports_before"
    printf 'running\n' > "$SERVICE_STATE"
    run_upgrade
    assert_version v2.0.0 "$BIN_MIHOMO" 'new binary was not installed'
    assert_same "$old_current" "$MIHOMO_UPGRADE_PREVIOUS" 'old binary was not retained'
    assert_same "$old_state" "$MIHOMO_UPGRADE_PREVIOUS_STATE" 'old state was not retained'
    _upgrade_binary_matches_state "$BIN_MIHOMO" "$MIHOMO_UPGRADE_STATE_LOCK" >/dev/null 2>&1 ||
        fail 'new binary state is invalid'
    assert_same "$ports_before" "$MIHOMO_PORT_STATE" 'actual non-default ports were lost'
    assert_eq $'stop\nstart:v2.0.0' "$(cat "$SERVICE_LOG")" 'running service was not restarted once'
}

test_stopped_upgrade_stays_stopped() {
    local ports_before
    new_case
    prepare_installed_pair
    prepare_remote v2.0.0
    write_ports
    ports_before="$FIXTURES/ports.before"
    cp "$MIHOMO_PORT_STATE" "$ports_before"
    run_upgrade
    assert_eq stopped "$(cat "$SERVICE_STATE")" 'stopped service was started by upgrade'
    [ ! -s "$SERVICE_LOG" ] || fail 'stopped upgrade touched the service'
    assert_same "$ports_before" "$MIHOMO_PORT_STATE" 'stopped upgrade changed ports state'
}

test_legacy_first_upgrade_retains_rollback() {
    new_case
    write_binary "$BIN_MIHOMO" v1.0.0
    prepare_remote v2.0.0

    run_upgrade
    assert_version v2.0.0 "$BIN_MIHOMO" 'legacy upgrade did not install the new binary'
    assert_version v1.0.0 "$MIHOMO_UPGRADE_PREVIOUS" \
        'legacy upgrade did not retain the previous binary'
    _upgrade_binary_matches_state \
        "$MIHOMO_UPGRADE_PREVIOUS" "$MIHOMO_UPGRADE_PREVIOUS_STATE" >/dev/null 2>&1 ||
        fail 'legacy upgrade did not create a rollback identity'

    clashupgrade rollback > "$CASE_LOG" 2>&1 || fail 'legacy first upgrade could not roll back'
    assert_version v1.0.0 "$BIN_MIHOMO" 'legacy rollback restored the wrong binary'
    assert_eq stopped "$(cat "$SERVICE_STATE")" 'legacy rollback started a stopped service'
}

test_archive_and_candidate_validation() {
    local bad_sha corrupt
    new_case
    prepare_remote v2.0.0
    _upgrade_platform
    bad_sha=$(printf '0%.0s' {1..64})
    write_manifest v2.0.0 "$REMOTE_SIZE" "$bad_sha"
    _upgrade_parse_manifest "$MANIFEST"
    _upgrade_verify_archive "$ARCHIVE" >/dev/null 2>&1 && fail 'bad checksum was accepted'
    corrupt="$FIXTURES/corrupt.gz"
    printf 'not gzip\n' > "$corrupt"
    write_manifest v2.0.0 "$(_upgrade_file_size "$corrupt")" "$(_upgrade_sha256 "$corrupt")"
    _upgrade_parse_manifest "$MANIFEST"
    _upgrade_verify_archive "$corrupt" >/dev/null 2>&1 && fail 'invalid gzip was accepted'
    prepare_remote v2.0.0 0 v3.0.0
    _upgrade_parse_manifest "$MANIFEST"
    _upgrade_prepare_candidate "$ARCHIVE" "$FIXTURES/candidate" >/dev/null 2>&1 &&
        fail 'payload with the wrong actual version was accepted'
    prepare_remote v2.0.0 23
    printf 'mixed-port: 7890\n' > "$MIHOMO_CONFIG_RUNTIME"
    _upgrade_parse_manifest "$MANIFEST"
    _upgrade_prepare_candidate "$ARCHIVE" "$FIXTURES/candidate-config" >/dev/null 2>&1 &&
        fail 'payload rejecting the published config was accepted'
    return 0
}

test_checksum_failure_is_non_mutating() {
    local current_before state_before bad_sha
    new_case
    prepare_installed_pair
    prepare_remote v2.0.0
    bad_sha=$(printf '0%.0s' {1..64})
    write_manifest v2.0.0 "$REMOTE_SIZE" "$bad_sha"
    current_before="$FIXTURES/current.before"
    state_before="$FIXTURES/state.before"
    cp "$BIN_MIHOMO" "$current_before"
    cp "$MIHOMO_UPGRADE_STATE_LOCK" "$state_before"
    expect_upgrade_failure
    assert_same "$current_before" "$BIN_MIHOMO" 'checksum failure changed current binary'
    assert_same "$state_before" "$MIHOMO_UPGRADE_STATE_LOCK" 'checksum failure changed current state'
    [ ! -s "$SERVICE_LOG" ] || fail 'checksum failure touched service'
}

test_start_failure_restores_everything() {
    local current_before previous_before state_before previous_state_before ports_before
    new_case
    prepare_installed_pair
    prepare_remote v2.0.0
    current_before="$FIXTURES/current.before"; cp "$BIN_MIHOMO" "$current_before"
    previous_before="$FIXTURES/previous.before"; cp "$MIHOMO_UPGRADE_PREVIOUS" "$previous_before"
    state_before="$FIXTURES/state.before"; cp "$MIHOMO_UPGRADE_STATE_LOCK" "$state_before"
    previous_state_before="$FIXTURES/previous-state.before"; cp "$MIHOMO_UPGRADE_PREVIOUS_STATE" "$previous_state_before"
    write_ports
    ports_before="$FIXTURES/ports.before"; cp "$MIHOMO_PORT_STATE" "$ports_before"
    printf 'running\n' > "$SERVICE_STATE"
    START_FAIL_VERSION=v2.0.0
    expect_upgrade_failure
    assert_same "$current_before" "$BIN_MIHOMO" 'start failure did not restore current binary'
    assert_same "$previous_before" "$MIHOMO_UPGRADE_PREVIOUS" 'start failure changed previous binary'
    assert_same "$state_before" "$MIHOMO_UPGRADE_STATE_LOCK" 'start failure changed current state'
    assert_same "$previous_state_before" "$MIHOMO_UPGRADE_PREVIOUS_STATE" 'start failure changed previous state'
    assert_same "$ports_before" "$MIHOMO_PORT_STATE" 'start failure lost non-default ports'
    assert_eq running "$(cat "$SERVICE_STATE")" 'old service was not restarted'
}

test_state_failure_restores_four_objects() {
    local current_before previous_before state_before previous_state_before
    new_case
    prepare_installed_pair
    prepare_remote v2.0.0
    current_before="$FIXTURES/current.before"; cp "$BIN_MIHOMO" "$current_before"
    previous_before="$FIXTURES/previous.before"; cp "$MIHOMO_UPGRADE_PREVIOUS" "$previous_before"
    state_before="$FIXTURES/state.before"; cp "$MIHOMO_UPGRADE_STATE_LOCK" "$state_before"
    previous_state_before="$FIXTURES/previous-state.before"; cp "$MIHOMO_UPGRADE_PREVIOUS_STATE" "$previous_state_before"
    STATE_WRITE_FAIL_ON_CALL=2
    expect_upgrade_failure
    assert_same "$current_before" "$BIN_MIHOMO" 'state failure did not restore current binary'
    assert_same "$previous_before" "$MIHOMO_UPGRADE_PREVIOUS" 'state failure did not restore previous binary'
    assert_same "$state_before" "$MIHOMO_UPGRADE_STATE_LOCK" 'state failure did not restore current state'
    assert_same "$previous_state_before" "$MIHOMO_UPGRADE_PREVIOUS_STATE" 'state failure did not restore previous state'
}

test_manual_rollback_swaps_pair_and_ports() {
    local current_before previous_before current_state_before previous_state_before ports_before
    new_case
    prepare_rollback_pair
    current_before="$FIXTURES/current.before"; cp "$BIN_MIHOMO" "$current_before"
    previous_before="$FIXTURES/previous.before"; cp "$MIHOMO_UPGRADE_PREVIOUS" "$previous_before"
    current_state_before="$FIXTURES/current-state.before"; cp "$MIHOMO_UPGRADE_STATE_LOCK" "$current_state_before"
    previous_state_before="$FIXTURES/previous-state.before"; cp "$MIHOMO_UPGRADE_PREVIOUS_STATE" "$previous_state_before"
    write_ports
    ports_before="$FIXTURES/ports.before"; cp "$MIHOMO_PORT_STATE" "$ports_before"
    printf 'running\n' > "$SERVICE_STATE"
    clashupgrade rollback > "$CASE_LOG" 2>&1 || fail 'manual rollback failed'
    assert_same "$previous_before" "$BIN_MIHOMO" 'rollback did not install previous binary'
    assert_same "$current_before" "$MIHOMO_UPGRADE_PREVIOUS" 'rollback did not retain replaced binary'
    assert_same "$previous_state_before" "$MIHOMO_UPGRADE_STATE_LOCK" 'rollback did not install previous state'
    assert_same "$current_state_before" "$MIHOMO_UPGRADE_PREVIOUS_STATE" 'rollback did not retain replaced state'
    assert_same "$ports_before" "$MIHOMO_PORT_STATE" 'rollback lost non-default ports'
    assert_eq $'stop\nstart:v1.0.0' "$(cat "$SERVICE_LOG")" 'rollback did not restart once'
}

test_stopped_rollback_stays_stopped() {
    local ports_before
    new_case
    prepare_rollback_pair
    write_ports
    ports_before="$FIXTURES/ports.before"
    cp "$MIHOMO_PORT_STATE" "$ports_before"
    clashupgrade rollback > "$CASE_LOG" 2>&1 || fail 'stopped rollback failed'
    assert_version v1.0.0 "$BIN_MIHOMO" 'stopped rollback used wrong binary'
    assert_eq stopped "$(cat "$SERVICE_STATE")" 'stopped rollback started service'
    [ ! -s "$SERVICE_LOG" ] || fail 'stopped rollback touched service'
    assert_same "$ports_before" "$MIHOMO_PORT_STATE" 'stopped rollback changed ports state'
}

test_signal_restores_snapshot() {
    local current_before previous_before state_before previous_state_before result=0
    new_case
    prepare_installed_pair
    prepare_remote v2.0.0
    current_before="$FIXTURES/current.before"; cp "$BIN_MIHOMO" "$current_before"
    previous_before="$FIXTURES/previous.before"; cp "$MIHOMO_UPGRADE_PREVIOUS" "$previous_before"
    state_before="$FIXTURES/state.before"; cp "$MIHOMO_UPGRADE_STATE_LOCK" "$state_before"
    previous_state_before="$FIXTURES/previous-state.before"; cp "$MIHOMO_UPGRADE_PREVIOUS_STATE" "$previous_state_before"
    AFTER_PUBLISH_SIGNAL=TERM
    clashupgrade > "$CASE_LOG" 2>&1 || result=$?
    assert_eq 143 "$result" 'TERM returned the wrong status'
    assert_same "$current_before" "$BIN_MIHOMO" 'TERM did not restore current binary'
    assert_same "$previous_before" "$MIHOMO_UPGRADE_PREVIOUS" 'TERM changed previous binary'
    assert_same "$state_before" "$MIHOMO_UPGRADE_STATE_LOCK" 'TERM changed current state'
    assert_same "$previous_state_before" "$MIHOMO_UPGRADE_PREVIOUS_STATE" 'TERM changed previous state'
}

test_symlink_and_special_preflight() {
    local victim real_binary
    new_case
    victim="$FIXTURES/victim"
    real_binary="$FIXTURES/real-binary"
    printf 'victim\n' > "$victim"
    write_binary "$real_binary" v1.0.0
    ln -s "$real_binary" "$BIN_MIHOMO"
    prepare_remote v2.0.0
    expect_upgrade_failure
    [ -L "$BIN_MIHOMO" ] || fail 'managed binary symlink was replaced'
    assert_eq victim "$(cat "$victim")" 'symlink preflight changed unrelated data'

    new_case
    prepare_installed_pair
    rm -f "$MIHOMO_UPGRADE_PREVIOUS_STATE"
    mkdir "$MIHOMO_UPGRADE_PREVIOUS_STATE"
    prepare_remote v2.0.0
    expect_upgrade_failure
    [ -d "$MIHOMO_UPGRADE_PREVIOUS_STATE" ] || fail 'special managed path was removed'

    new_case
    prepare_installed_pair
    prepare_remote v2.0.0
    victim="$FIXTURES/port-victim"
    printf 'port-victim\n' > "$victim"
    ln -s "$victim" "$MIHOMO_PORT_STATE"
    expect_upgrade_failure
    assert_eq port-victim "$(cat "$victim")" 'port-state symlink target was changed'

    new_case
    victim="$FIXTURES/lock-victim"
    printf 'lock-victim\n' > "$victim"
    ln -s "$victim" "$MIHOMO_UPGRADE_LOCK_DIR"
    _upgrade_acquire_lock && fail 'lock symlink was accepted'
    assert_eq lock-victim "$(cat "$victim")" 'lock symlink target was changed'
    rm -f "$MIHOMO_UPGRADE_LOCK_DIR"
    mkdir "$MIHOMO_UPGRADE_LOCK_DIR"
    _upgrade_acquire_lock && fail 'special lock path was accepted'
    rmdir "$MIHOMO_UPGRADE_LOCK_DIR"
    : > "$MIHOMO_UPGRADE_LOCK_DIR"
    ln -s "$victim" "${MIHOMO_UPGRADE_LOCK_DIR}.owner"
    _upgrade_acquire_lock && fail 'owner symlink was accepted'
    assert_eq lock-victim "$(cat "$victim")" 'owner symlink target was changed'
}

test_bundled_install_and_failure_restore() {
    local before before_state
    new_case
    prepare_remote v2.0.0
    _install_bundled_mihomo "$MANIFEST" "$FIXTURES" "$BIN_MIHOMO" > "$CASE_LOG" 2>&1 ||
        fail 'bundled install failed'
    assert_version v2.0.0 "$BIN_MIHOMO" 'bundled install used wrong binary'
    _upgrade_binary_matches_state "$BIN_MIHOMO" "$MIHOMO_UPGRADE_STATE_LOCK" >/dev/null 2>&1 ||
        fail 'bundled install state is invalid'

    write_binary "$BIN_MIHOMO" v1.0.0
    write_state "$MIHOMO_UPGRADE_STATE_LOCK" v1.0.0 "$BIN_MIHOMO"
    before="$FIXTURES/bundle-current.before"; cp "$BIN_MIHOMO" "$before"
    before_state="$FIXTURES/bundle-state.before"; cp "$MIHOMO_UPGRADE_STATE_LOCK" "$before_state"
    STATE_WRITE_CALLS=0
    STATE_WRITE_FAIL_ON_CALL=1
    _install_bundled_mihomo "$MANIFEST" "$FIXTURES" "$BIN_MIHOMO" > "$CASE_LOG" 2>&1 &&
        fail 'bundled install ignored state failure'
    assert_same "$before" "$BIN_MIHOMO" 'bundled failure did not restore binary'
    assert_same "$before_state" "$MIHOMO_UPGRADE_STATE_LOCK" 'bundled failure did not restore state'
}

test_status_and_lock() {
    new_case
    prepare_installed_pair
    clashupgrade status > "$CASE_LOG" 2>&1 || fail 'status failed'
    grep -q '当前内核：v1.0.0' "$CASE_LOG" || fail 'status omitted current version'
    grep -q '可回滚版本：v0.9.0' "$CASE_LOG" || fail 'status omitted previous version'
    [ ! -e "${MIHOMO_UPGRADE_LOCK_DIR}.owner" ] || fail 'status left owner metadata'
}

tests_run=0
run_test() {
    "$2"
    tests_run=$((tests_run + 1))
    printf 'ok - %s\n' "$1"
}

run_test 'stable parsing and immutable source pinning' test_stable_parsing_and_pinned_source
run_test 'successful running upgrade' test_successful_running_upgrade
run_test 'stopped upgrade stays stopped' test_stopped_upgrade_stays_stopped
run_test 'legacy first upgrade retains rollback' test_legacy_first_upgrade_retains_rollback
run_test 'archive and candidate validation' test_archive_and_candidate_validation
run_test 'checksum failure is non-mutating' test_checksum_failure_is_non_mutating
run_test 'startup failure restores everything' test_start_failure_restores_everything
run_test 'state failure restores all four objects' test_state_failure_restores_four_objects
run_test 'manual rollback swaps pair and ports' test_manual_rollback_swaps_pair_and_ports
run_test 'stopped rollback stays stopped' test_stopped_rollback_stays_stopped
run_test 'signal restores snapshot' test_signal_restores_snapshot
run_test 'symlink and special-file preflight' test_symlink_and_special_preflight
run_test 'bundled install and failure restore' test_bundled_install_and_failure_restore
run_test 'status and lock cleanup' test_status_and_lock

printf 'upgrade tests passed (%s cases)\n' "$tests_run"
