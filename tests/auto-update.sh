#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)
cleanup() {
    local exit_status=$?
    trap - EXIT
    rm -rf -- "$test_root"
    exit "$exit_status"
}
trap cleanup EXIT

fail() {
    printf 'test-auto-update: %s\n' "$*" >&2
    exit 1
}

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"
cat > "$fake_bin/crontab" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$FAKE_CRONTAB_CALLS"
exit 97
EOF
chmod 0755 "$fake_bin/crontab"

export PATH="$fake_bin:$PATH"
export HOME="$test_root/home"
export MIHOMO_BASE_DIR="$HOME/tools/mihomo"
export MIHOMO_CONFIG_URL="$MIHOMO_BASE_DIR/url"
export MIHOMO_CONFIG_RAW="$MIHOMO_BASE_DIR/config.yaml"
export MIHOMO_UPDATE_LOG="$MIHOMO_BASE_DIR/update.log"
export FAKE_CRONTAB_CALLS="$test_root/crontab.calls"
mkdir -p "$MIHOMO_BASE_DIR/tmp"
printf '%s\n' 'https://current.example/sub' > "$MIHOMO_CONFIG_URL"
printf '%s\n' 'current-config' > "$MIHOMO_CONFIG_RAW"
printf '%s\n' '15 3 * * * keep-this-job' > "$test_root/crontab"
cp "$MIHOMO_CONFIG_URL" "$test_root/url.before"
cp "$MIHOMO_CONFIG_RAW" "$test_root/config.before"
cp "$test_root/crontab" "$test_root/crontab.before"

set +u
# shellcheck source=../script/clashctl.sh
. "$repo_root/script/clashctl.sh"
set -u

failure_log="$test_root/failure.log"
_okcat() { :; }
_failcat() {
    printf '%s\n' "$*" >> "$failure_log"
    return 1
}
LOCK_CALLS=0
_mihomo_run_locked() {
    LOCK_CALLS=$((LOCK_CALLS + 1))
    "$@"
}

if clashupdate auto; then
    fail 'deprecated automatic update was reported as enabled'
fi
if clashupdate auto 'https://replacement.example/sub'; then
    fail 'deprecated automatic update accepted an explicit URL'
fi

cmp -s "$test_root/url.before" "$MIHOMO_CONFIG_URL" || fail 'deprecated auto command changed the subscription URL'
cmp -s "$test_root/config.before" "$MIHOMO_CONFIG_RAW" || fail 'deprecated auto command changed the subscription config'
cmp -s "$test_root/crontab.before" "$test_root/crontab" || fail 'deprecated auto command changed unrelated cron data'
[ ! -e "$FAKE_CRONTAB_CALLS" ] || fail 'deprecated auto command invoked crontab'
[ "$LOCK_CALLS" -eq 0 ] || fail 'deprecated auto command entered a mutation transaction'
[ "$(grep -c '不再自动写入定时任务' "$failure_log")" -eq 2 ] || fail 'deprecated auto command omitted its safety explanation'

printf '%s\n' 'automatic crontab mutation deprecation tests passed'
