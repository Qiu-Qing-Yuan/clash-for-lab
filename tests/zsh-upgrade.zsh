#!/usr/bin/env zsh

set -eu

test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

MIHOMO_BASE_DIR="$test_root/install"
MIHOMO_CONFIG_RUNTIME="$MIHOMO_BASE_DIR/runtime.yaml"
MIHOMO_CONFIG_RAW="$MIHOMO_BASE_DIR/config.yaml"
BIN_MIHOMO="$MIHOMO_BASE_DIR/bin/mihomo"

source "${0:A:h}/../script/upgrade.sh"

if ! command -v flock >/dev/null 2>&1; then
    flock() { return 0; }
fi

if ! command -v timeout >/dev/null 2>&1; then
    timeout() {
        [[ "${1:-}" == --kill-after=5 ]] && shift
        shift
        "$@"
    }
fi

MIHOMO_UPGRADE_STATE_DIR="$MIHOMO_BASE_DIR/state"
MIHOMO_UPGRADE_STATE_LOCK="$MIHOMO_UPGRADE_STATE_DIR/mihomo.lock.tsv"
MIHOMO_UPGRADE_PREVIOUS_STATE="$MIHOMO_UPGRADE_STATE_DIR/mihomo.previous.lock.tsv"
MIHOMO_UPGRADE_PREVIOUS="$MIHOMO_BASE_DIR/bin/mihomo.previous"
MIHOMO_UPGRADE_LOCK_DIR="$MIHOMO_BASE_DIR/tmp/mihomo-operation.lock"
MIHOMO_PORT_STATE="$MIHOMO_BASE_DIR/config/ports.conf"
mkdir -p "$MIHOMO_BASE_DIR/bin" "$MIHOMO_BASE_DIR/config" \
    "$MIHOMO_UPGRADE_STATE_DIR" "$MIHOMO_BASE_DIR/tmp"

printf '%s\n' '#!/bin/sh' "printf '%s\\n' 'Mihomo Meta v1.2.3 linux amd64'" > \
    "$BIN_MIHOMO"
chmod 0755 "$BIN_MIHOMO"

archive_sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
binary_size=$(_upgrade_file_size "$BIN_MIHOMO")
binary_sha=$(_upgrade_sha256 "$BIN_MIHOMO")
printf 'schema\t1\nasset\tlinux\tamd64\tv1\tv1.2.3\tmihomo-linux-amd64-v1.gz\t1\t%s\n' \
    "$archive_sha" > "$test_root/manifest.tsv"
printf 'schema\t2\nasset\tlinux\tamd64\tv1\tv1.2.3\tmihomo-linux-amd64-v1.gz\t1\t%s\n' \
    "$archive_sha" > "$MIHOMO_UPGRADE_STATE_LOCK"
printf 'binary\tv1.2.3\t%s\t%s\n' "$binary_size" "$binary_sha" >> \
    "$MIHOMO_UPGRADE_STATE_LOCK"

_upgrade_platform() {
    UPGRADE_OS=linux
    UPGRADE_ARCH=amd64
    UPGRADE_VARIANT=v1
}

_upgrade_resolve_repository_snapshot() {
    UPGRADE_REMOTE_VERSION=v1.2.3
    UPGRADE_REMOTE_FILE=mihomo-linux-amd64-v1.gz
    UPGRADE_REMOTE_SIZE=1
    UPGRADE_REMOTE_SHA256=$archive_sha
    UPGRADE_REMOTE_MANIFEST="$test_root/manifest.tsv"
}

_upgrade_info() { :; }

_upgrade_apply_transaction
[[ ! -e "${MIHOMO_UPGRADE_LOCK_DIR}.owner" ]] || {
    print -u2 'zsh-upgrade: apply left owner metadata'
    exit 1
}

rollback_result=0
_upgrade_rollback_transaction >/dev/null 2>&1 || rollback_result=$?
[[ $rollback_result == 1 ]] || {
    print -u2 "zsh-upgrade: expected rollback failure, got $rollback_result"
    exit 1
}
[[ ! -e "${MIHOMO_UPGRADE_LOCK_DIR}.owner" ]] || {
    print -u2 'zsh-upgrade: failed rollback left owner metadata'
    exit 1
}

print 'PROXY_PORT=24567' > "$MIHOMO_PORT_STATE"
backup_port_state="$test_root/ports.before"
cp "$MIHOMO_PORT_STATE" "$backup_port_state"
port_state=$MIHOMO_PORT_STATE
had_port_state=true
rm -f "$MIHOMO_PORT_STATE"
_upgrade_restore_port_state
cmp -s "$backup_port_state" "$MIHOMO_PORT_STATE" || {
    print -u2 'zsh-upgrade: port state restore changed content'
    exit 1
}

victim="$test_root/victim"
print 'victim' > "$victim"
managed_link="$test_root/managed-link"
ln -s "$victim" "$managed_link"
if _upgrade_managed_file_ok "$managed_link" false false; then
    print -u2 'zsh-upgrade: managed symlink passed preflight'
    exit 1
fi
rm -f "$MIHOMO_UPGRADE_LOCK_DIR"
ln -s "$victim" "$MIHOMO_UPGRADE_LOCK_DIR"
if _upgrade_acquire_lock; then
    _upgrade_release_lock
    print -u2 'zsh-upgrade: lock symlink passed preflight'
    exit 1
fi
[[ "$(<"$victim")" == victim ]] || {
    print -u2 'zsh-upgrade: symlink target changed'
    exit 1
}

print 'zsh upgrade core tests passed'
