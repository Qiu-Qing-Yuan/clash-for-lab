#!/usr/bin/env bash

set -eu
set -o pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'test-connectivity: %s\n' "$*" >&2
    exit 1
}

set +u
. "$repo_root/script/common.sh"
. "$repo_root/script/upgrade.sh"
. "$repo_root/script/clashctl.sh"
set -u

# ── _connectivity_check ────────────────────────────────────────────

# Both API and proxy OK
(
    curl() {
        case "$*" in
        *"/version"*) return 0 ;;
        *"generate_204"*) return 0 ;;
        *) return 1 ;;
        esac
    }
    [ "$(_connectivity_check 19090 54016 '')" = "ok" ] || fail 'expected ok'
)

# API OK, proxy fail
(
    curl() {
        case "$*" in
        *"/version"*) return 0 ;;
        *"generate_204"*) return 1 ;;
        *) return 1 ;;
        esac
    }
    [ "$(_connectivity_check 19090 54016 '')" = "proxy_fail" ] || fail 'expected proxy_fail'
)

# API fail, proxy OK
(
    curl() {
        case "$*" in
        *"/version"*) return 1 ;;
        *"generate_204"*) return 0 ;;
        *) return 1 ;;
        esac
    }
    [ "$(_connectivity_check 19090 54016 '')" = "api_fail" ] || fail 'expected api_fail'
)

# Both fail
(
    curl() { return 1; }
    [ "$(_connectivity_check 19090 54016 '')" = "down" ] || fail 'expected down'
)

# With secret — should pass auth header
(
    secret_passed=false
    curl() {
        case "$*" in
        *"/version"*)
            for arg in "$@"; do
                [ "$arg" = "Authorization: Bearer mysecret" ] && secret_passed=true
            done
            return 0
            ;;
        *"generate_204"*) return 0 ;;
        *) return 1 ;;
        esac
    }
    _connectivity_check 19090 54016 'mysecret' >/dev/null
    [ "$secret_passed" = "true" ] || fail 'secret was not passed to curl'
)

# Without secret — should NOT pass auth header
(
    secret_passed=false
    curl() {
        case "$*" in
        *"/version"*)
            for arg in "$@"; do
                [ "$arg" = "Authorization: Bearer " ] && secret_passed=true
            done
            return 0
            ;;
        *"generate_204"*) return 0 ;;
        *) return 1 ;;
        esac
    }
    _connectivity_check 19090 54016 '' >/dev/null
    [ "$secret_passed" = "false" ] || fail 'empty secret should not add auth header'
)

# ── clash status --no-probe ─────────────────────────────────────────

(
    set +e
    export MIHOMO_BASE_DIR="$test_root/status-noprobe"
    export MIHOMO_CONFIG_MIXIN="$MIHOMO_BASE_DIR/mixin.yaml"
    export MIHOMO_CONFIG_RUNTIME="$MIHOMO_BASE_DIR/runtime.yaml"
    export MIHOMO_CONFIG_URL="$MIHOMO_BASE_DIR/url"
    export MIHOMO_PORT_STATE="$MIHOMO_BASE_DIR/config/ports.conf"
    mkdir -p "$MIHOMO_BASE_DIR/config"
    printf 'system-proxy:\n  enable: true\n' > "$MIHOMO_CONFIG_MIXIN"
    printf 'mixed-port: 54016\nexternal-controller: "127.0.0.1:19090"\n' > "$MIHOMO_CONFIG_RUNTIME"

    is_mihomo_running() { return 0; }
    _is_mihomo_pid() { return 0; }
    _find_managed_mihomo_pids() { printf '12345\n'; }
    _get_proxy_port() { MIXED_PORT=54016; }
    _get_ui_port() { UI_PORT=19090; }
    _get_dns_port() { DNS_PORT=15353; }
    ps() { printf '  00:00:01\n'; }

    # Create PID file so clashstatus can read it
    printf '12345\n' > "$MIHOMO_BASE_DIR/config/mihomo.pid"

    # clashproxy status references $http_proxy and $all_proxy
    export http_proxy='' https_proxy='' HTTP_PROXY='' HTTPS_PROXY=''
    export all_proxy='' ALL_PROXY='' no_proxy='' NO_PROXY=''

    _connectivity_check() { printf 'ok\n'; }
    _okcat() { [ $# -gt 1 ] && shift; printf '%s\n' "$1"; }
    _failcat() { [ $# -gt 1 ] && shift; printf '%s\n' "$1" >&2; return 0; }

    fake_yq="$test_root/fake-yq"
    cat > "$fake_yq" <<'FAKE_YQ'
#!/bin/sh
case "$1" in
'.secret // ""')
    printf '\n'
    ;;
'.system-proxy.enable // true')
    printf 'true\n'
    ;;
'.system-proxy.enable')
    printf 'true\n'
    ;;
'.authentication[0] // ""')
    printf '\n'
    ;;
*)
    exit 1
    ;;
esac
FAKE_YQ
    chmod 0755 "$fake_yq"
    BIN_YQ=$fake_yq

    # Without --no-probe: output SHOULD contain connectivity info
    output=$(clashstatus 2>&1 || true)
    if ! echo "$output" | grep -q '连通性'; then
        fail 'status should show connectivity'
    fi

    # With --no-probe: output should NOT contain connectivity info
    output=$(clashstatus --no-probe 2>&1 || true)
    if echo "$output" | grep -q '连通性'; then
        fail '--no-probe should not show connectivity'
    fi
)

printf 'connectivity tests passed\n'
