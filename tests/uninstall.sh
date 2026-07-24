#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)
managed_pid=''

cleanup() {
    local status=$?
    trap - EXIT
    case "$managed_pid" in
    ''|*[!0-9]*) ;;
    *) kill "$managed_pid" 2>/dev/null || true ;;
    esac
    rm -rf -- "$test_root"
    exit "$status"
}
trap cleanup EXIT

fail() {
    printf 'test-uninstall: %s\n' "$*" >&2
    exit 1
}

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$fake_bin/flock"
chmod 0755 "$fake_bin/flock"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "$*" >> "$FAKE_CRONTAB_CALLS"' 'exit 97' > "$fake_bin/crontab"
chmod 0755 "$fake_bin/crontab"

prepare_install() {
    local case_dir=$1 home_dir install_dir
    home_dir="$case_dir/home"
    install_dir="$home_dir/tools/mihomo"
    mkdir -p "$install_dir/bin" "$install_dir/script" "$install_dir/config" "$case_dir/state"
    printf '%s\n' '#!/bin/sh' 'printf "Mihomo Meta v1.0.0 linux amd64\\n"' > "$install_dir/bin/mihomo"
    chmod 0755 "$install_dir/bin/mihomo"
    printf '%s\n' '#!/usr/bin/env bash' > "$install_dir/script/managed.sh"
    printf '%s\n' 'PROXY_PORT=54321' 'UI_PORT=19090' 'DNS_PORT=15353' > "$install_dir/config/ports.conf"
    printf '%s\n' \
        'export KEEP_BASH=1' \
        ". '$install_dir/script/managed.sh' && watch_proxy # clash-for-lab managed" > "$home_dir/.bashrc"
    printf '%s\n' \
        'export KEEP_ZSH=1' \
        ". '$install_dir/script/managed.sh' && watch_proxy # clash-for-lab managed" > "$home_dir/.zshrc"
}

success_case="$test_root/success"
prepare_install "$success_case"
HOME="$success_case/home" \
PATH="$fake_bin:$PATH" \
FAKE_CRONTAB_CALLS="$success_case/state/crontab.calls" \
    bash "$repo_root/uninstall.sh" > "$success_case/output.log" 2>&1 || {
    sed 's/^/uninstall: /' "$success_case/output.log" >&2
    fail 'uninstall failed'
}
[ ! -e "$success_case/home/tools/mihomo" ] || fail 'uninstall retained the install path'
[ "$(cat "$success_case/home/.bashrc")" = 'export KEEP_BASH=1' ] || fail 'bash RC cleanup failed'
[ "$(cat "$success_case/home/.zshrc")" = 'export KEEP_ZSH=1' ] || fail 'zsh RC cleanup failed'
[ ! -e "$success_case/state/crontab.calls" ] || fail 'uninstall invoked crontab'
grep -Fq 'crontab -e' "$success_case/output.log" || fail 'legacy cron notice is missing'

# If RC cleanup fails, put the installation back and restore completed RC edits.
rollback_case="$test_root/rollback"
prepare_install "$rollback_case"
rm -f "$rollback_case/home/.zshrc"
mkdir "$rollback_case/home/.zshrc"
if HOME="$rollback_case/home" \
    PATH="$fake_bin:$PATH" \
    FAKE_CRONTAB_CALLS="$rollback_case/state/crontab.calls" \
        bash "$repo_root/uninstall.sh" > "$rollback_case/output.log" 2>&1; then
    fail 'uninstall ignored an RC cleanup failure'
fi
[ -d "$rollback_case/home/tools/mihomo" ] || fail 'failed uninstall did not restore the install path'
grep -Fq '# clash-for-lab managed' "$rollback_case/home/.bashrc" ||
    fail 'failed uninstall did not restore the bash RC entry'
[ ! -e "$rollback_case/state/crontab.calls" ] || fail 'failed uninstall invoked crontab'

# The standard path must be a real directory, not a symlink.
symlink_case="$test_root/symlink"
mkdir -p "$symlink_case/home/tools/real-install/bin" "$symlink_case/state"
printf '%s\n' keep > "$symlink_case/home/tools/real-install/marker"
ln -s real-install "$symlink_case/home/tools/mihomo"
if HOME="$symlink_case/home" \
    PATH="$fake_bin:$PATH" \
    FAKE_CRONTAB_CALLS="$symlink_case/state/crontab.calls" \
        bash "$repo_root/uninstall.sh" > "$symlink_case/output.log" 2>&1; then
    fail 'uninstall accepted a symlink installation root'
fi
[ "$(cat "$symlink_case/home/tools/real-install/marker")" = keep ] || fail 'symlink target was modified'

# Process discovery still works if the PID file is missing.
pid_case="$test_root/missing-pid"
prepare_install "$pid_case"
pid_install="$pid_case/home/tools/mihomo"
rm -f "$pid_install/bin/mihomo"
ln -s /bin/sh "$pid_install/bin/mihomo"
"$pid_install/bin/mihomo" \
    -c 'trap "exit 0" TERM; while :; do :; done' \
    managed-mihomo -d "$pid_install" -f "$pid_install/runtime.yaml" &
managed_pid=$!

count=0
while [ "$count" -lt 100 ] && ! ps -p "$managed_pid" -o args= 2>/dev/null | \
    grep -Fq -- "-f $pid_install/runtime.yaml"; do
    /bin/sleep 0.01
    count=$((count + 1))
done
[ "$count" -lt 100 ] || fail 'managed process fixture did not start'

HOME="$pid_case/home" \
PATH="$fake_bin:$PATH" \
FAKE_CRONTAB_CALLS="$pid_case/state/crontab.calls" \
    bash "$repo_root/uninstall.sh" > "$pid_case/output.log" 2>&1 || {
    sed 's/^/pid uninstall: /' "$pid_case/output.log" >&2
    fail 'uninstall failed to stop a PID-less managed process'
}
state=$(ps -p "$managed_pid" -o stat= 2>/dev/null | tr -d '[:space:]' || true)
case "$state" in
''|Z*) ;;
*) fail 'uninstall left the managed process alive' ;;
esac
wait "$managed_pid" 2>/dev/null || true
managed_pid=''
[ ! -e "$pid_install" ] || fail 'PID-less uninstall retained the install tree'

printf '%s\n' 'uninstall tests passed'
