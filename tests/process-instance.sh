#!/usr/bin/env bash

set -eu
set -o pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)

cleanup() {
    exit_code=$?
    trap - EXIT HUP INT TERM
    if [ -n "${fixture_pid:-}" ]; then
        /bin/kill "$fixture_pid" 2>/dev/null || true
        wait "$fixture_pid" 2>/dev/null || true
    fi
    rm -rf -- "$test_root"
    exit "$exit_code"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'test-process-instance: %s\n' "$*" >&2
    exit 1
}

HOME="$test_root/home"
USER=tester
mkdir -p "$HOME"
export HOME USER

# shellcheck source=../script/common.sh
set +u
. "$repo_root/script/common.sh"
set -u

sleep_bin=$(command -v sleep)

# A changed start token represents a reused numeric PID. It must never receive
# either TERM or KILL.
"$sleep_bin" 30 &
fixture_pid=$!
fixture_start_id=$(_process_start_id "$fixture_pid") || fail 'could not capture process start identity'
fixture_executable_id=$(_process_executable_id "$fixture_pid") || fail 'could not capture executable identity'
if ! _terminate_process_instance \
    "$fixture_pid" "changed:$fixture_start_id" "$fixture_executable_id" "$sleep_bin"; then
    fail 'a reused PID should be treated as an already-finished instance'
fi
kill -0 "$fixture_pid" 2>/dev/null || fail 'start-token mismatch signalled an unrelated process'

# Keeping the start token while changing executable identity is ambiguous. The
# helper must fail closed and leave the process untouched.
if _terminate_process_instance "$fixture_pid" "$fixture_start_id" 'inode:0:0' "$sleep_bin"; then
    fail 'executable mismatch was reported as a safe termination'
fi
kill -0 "$fixture_pid" 2>/dev/null || fail 'executable mismatch signalled the process'

# Correct start, executable and argv identities allow normal termination.
_terminate_process_instance \
    "$fixture_pid" "$fixture_start_id" "$fixture_executable_id" "$sleep_bin" ||
    fail 'could not terminate the captured process instance'
wait "$fixture_pid" 2>/dev/null || true
fixture_pid=

# Exercise the real process scanner with a long-running native executable.
# Atomically replacing its on-disk path must not orphan the old inode. Keep the
# unit fallback below for minimal hosts that do not include a C compiler.
if command -v cc >/dev/null 2>&1; then
    managed_dir="$test_root/managed"
    mkdir -p "$managed_dir/bin"
    BIN_KERNEL="$managed_dir/bin/mihomo"
    MIHOMO_BASE_DIR="$managed_dir"
    MIHOMO_CONFIG_RUNTIME="$managed_dir/runtime.yaml"
    cat > "$managed_dir/mihomo-fixture.c" <<'EOF'
#include <unistd.h>
int main(void) {
    for (;;) pause();
    return 0;
}
EOF
    cc -o "$BIN_KERNEL" "$managed_dir/mihomo-fixture.c" ||
        fail 'could not compile native managed-process fixture'
    "$BIN_KERNEL" -d "$MIHOMO_BASE_DIR" -f "$MIHOMO_CONFIG_RUNTIME" >/dev/null &
    fixture_pid=$!
    scan_count=0
    while ! _is_mihomo_pid "$fixture_pid" && [ "$scan_count" -lt 100 ]; do
        sleep 0.01
        scan_count=$((scan_count + 1))
    done
    _is_mihomo_pid "$fixture_pid" || fail 'native managed-process fixture was not identified'
    cc -o "$managed_dir/bin/mihomo.replacement" "$managed_dir/mihomo-fixture.c" ||
        fail 'could not compile replacement managed-process fixture'
    mv -f "$managed_dir/bin/mihomo.replacement" "$BIN_KERNEL"
    _is_mihomo_pid "$fixture_pid" ||
        fail 'atomically replacing BIN_KERNEL orphaned the running old inode'
    managed_pids=$(_find_managed_mihomo_pids) || fail 'managed-process scan failed after replacement'
    printf '%s\n' "$managed_pids" | grep -Fxq "$fixture_pid" ||
        fail 'managed-process scan omitted the running old inode'
    _terminate_managed_mihomo_pid "$fixture_pid" ||
        fail 'could not terminate managed process after its kernel path was replaced'
    wait "$fixture_pid" 2>/dev/null || true
    fixture_pid=
fi

# Managed-process escalation must bind itself to the instance captured before
# TERM. Simulate immediate PID reuse and assert that KILL is never sent.
(
    reused=false
    signals=''
    _is_mihomo_pid() { return 0; }
    _process_start_id() { printf '%s\n' captured-start; }
    _process_executable_id() { printf '%s\n' captured-executable; }
    _process_instance_is_current() { [ "$reused" = false ]; }
    _process_start_instance_is_current() { [ "$reused" = false ]; }
    _failcat() { return 0; }
    sleep() { return 0; }
    kill() {
        case "${1:-}" in
        -9)
            signals="${signals}KILL "
            ;;
        *)
            signals="${signals}TERM "
            reused=true
            ;;
        esac
        return 0
    }
    _terminate_managed_mihomo_pid 4242 || fail 'simulated managed termination failed'
    [ "$signals" = 'TERM ' ] || fail "managed termination signalled a reused PID: $signals"
)

# Replacing the on-disk kernel must not make the already-running managed
# process invisible. Its argv still names the managed kernel/config paths; the
# actual executable inode is captured from the process itself before signals.
(
    BIN_KERNEL='/managed/bin/mihomo'
    MIHOMO_BASE_DIR='/managed'
    MIHOMO_CONFIG_RUNTIME='/managed/runtime.yaml'
    fake_args='/managed/bin/mihomo -d /managed -f /managed/runtime.yaml'

    kill() { return 0; }
    id() { printf '%s\n' 1234; }
    ps() {
        case " $* " in
        *' uid= '*) printf '%s\n' 1234 ;;
        *' stat= '*) printf '%s\n' S ;;
        *' args= '*) printf '%s\n' "$fake_args" ;;
        *) return 1 ;;
        esac
    }

    _is_mihomo_pid 4242 ||
        fail 'managed process became invisible after its on-disk kernel identity changed'

    fake_args='/other/mihomo -d /managed -f /managed/runtime.yaml'
    if _is_mihomo_pid 4242; then
        fail 'process with an unowned argv[0] was accepted as managed'
    fi
)

printf '%s\n' 'process instance tests passed'
