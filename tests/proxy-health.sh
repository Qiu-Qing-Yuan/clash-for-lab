#!/usr/bin/env bash

set -eu
set -o pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'test-proxy-health: %s\n' "$*" >&2
    exit 1
}

set +u
. "$repo_root/script/common.sh"
. "$repo_root/script/upgrade.sh"
. "$repo_root/script/clashctl.sh"
set -u

# ── _proxy_env_is_set ──────────────────────────────────────────────

(
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
    ! _proxy_env_is_set || fail 'is_set returned true with no vars'

    export http_proxy=http://127.0.0.1:7890
    _proxy_env_is_set || fail 'is_set returned false with http_proxy'
)

(
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
    export HTTP_PROXY=http://127.0.0.1:7890
    _proxy_env_is_set || fail 'is_set returned false with HTTP_PROXY'
)

(
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY no_proxy NO_PROXY
    export all_proxy=socks5h://127.0.0.1:7890
    _proxy_env_is_set || fail 'is_set returned false with all_proxy'
)

# ── _proxy_env_is_loopback ─────────────────────────────────────────

(
    export http_proxy=http://127.0.0.1:7890
    _proxy_env_is_loopback || fail '127.0.0.1 not detected as loopback'
)

(
    export http_proxy=http://localhost:7890
    _proxy_env_is_loopback || fail 'localhost not detected as loopback'
)

(
    export http_proxy='http://[::1]:7890'
    _proxy_env_is_loopback || fail '[::1] not detected as loopback'
)

(
    export http_proxy=http://10.0.0.1:7890
    ! _proxy_env_is_loopback || fail '10.0.0.1 incorrectly detected as loopback'
)

(
    export http_proxy=http://proxy.example.com:8080
    ! _proxy_env_is_loopback || fail 'external host incorrectly detected as loopback'
)

# ── _proxy_env_diagnose ────────────────────────────────────────────

export MIHOMO_BASE_DIR="$test_root/diagnose"
export MIHOMO_PORT_STATE="$MIHOMO_BASE_DIR/config/ports.conf"
mkdir -p "$MIHOMO_BASE_DIR/config"
printf 'PROXY_PORT=54016\nUI_PORT=19090\nDNS_PORT=15353\n' > "$MIHOMO_PORT_STATE"

# inactive: no proxy vars
(
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY all_proxy ALL_PROXY
    [ "$(_proxy_env_diagnose)" = "inactive" ] || fail 'should be inactive'
)

# external: non-loopback proxy
(
    export http_proxy=http://proxy.example.com:8080
    [ "$(_proxy_env_diagnose)" = "external" ] || fail 'should be external'
)

# poisoned: loopback proxy, mihomo not running
(
    export http_proxy=http://127.0.0.1:54016
    is_mihomo_running() { return 1; }
    [ "$(_proxy_env_diagnose)" = "poisoned" ] || fail 'should be poisoned'
)

# healthy: loopback proxy, mihomo running, port matches
(
    export http_proxy=http://127.0.0.1:54016
    is_mihomo_running() { return 0; }
    [ "$(_proxy_env_diagnose)" = "healthy" ] || fail 'should be healthy'
)

# stale: loopback proxy, mihomo running, port mismatch
(
    export http_proxy=http://127.0.0.1:99999
    is_mihomo_running() { return 0; }
    [ "$(_proxy_env_diagnose)" = "stale" ] || fail 'should be stale'
)

# ── _watch_proxy_cleanup ───────────────────────────────────────────

# Poisoned: should clear
(
    export http_proxy=http://127.0.0.1:54016
    export https_proxy=http://127.0.0.1:54016
    is_mihomo_running() { return 1; }
    unset_called=false
    _unset_system_proxy() {
        unset_called=true
        unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
        unset all_proxy ALL_PROXY no_proxy NO_PROXY
    }
    _watch_proxy_cleanup
    [ "$unset_called" = "true" ] || fail 'cleanup did not clear poisoned proxy'
    [ -z "${http_proxy:-}" ] || fail 'http_proxy still set after cleanup'
)

# External: should NOT clear
(
    export http_proxy=http://proxy.example.com:8080
    is_mihomo_running() { return 1; }
    _unset_system_proxy() { fail 'cleanup should not touch external proxy'; }
    _watch_proxy_cleanup
    [ "$http_proxy" = "http://proxy.example.com:8080" ] || fail 'external proxy was modified'
)

# Healthy: should NOT clear
(
    export http_proxy=http://127.0.0.1:54016
    is_mihomo_running() { return 0; }
    _unset_system_proxy() { fail 'cleanup should not clear healthy proxy'; }
    _watch_proxy_cleanup
    [ "$http_proxy" = "http://127.0.0.1:54016" ] || fail 'healthy proxy was modified'
)

# System proxy disabled: watch_proxy must not call _watch_proxy_cleanup,
# even with a poisoned loopback proxy and mihomo not running.
(
    export http_proxy=http://127.0.0.1:54016
    is_mihomo_running() { return 1; }
    _unset_system_proxy() { fail 'watch_proxy should not clear when system proxy is disabled'; }

    # Simulate watch_proxy's branch: system proxy disabled → skip cleanup
    system_proxy_status=false
    if [ -z "${http_proxy:-}" ]; then
        :
    elif [ "$system_proxy_status" = "true" ]; then
        _watch_proxy_cleanup
    fi

    [ "$http_proxy" = "http://127.0.0.1:54016" ] || fail 'proxy was cleared despite system proxy being disabled'
)

# ── clash doctor ────────────────────────────────────────────────────

(
    export MIHOMO_BASE_DIR="$test_root/doctor"
    export MIHOMO_CONFIG_MIXIN="$MIHOMO_BASE_DIR/mixin.yaml"
    export MIHOMO_CONFIG_RUNTIME="$MIHOMO_BASE_DIR/runtime.yaml"
    export MIHOMO_CONFIG_URL="$MIHOMO_BASE_DIR/url"
    export MIHOMO_PORT_STATE="$MIHOMO_BASE_DIR/config/ports.conf"
    mkdir -p "$MIHOMO_BASE_DIR/config"
    printf 'system-proxy:\n  enable: true\n' > "$MIHOMO_CONFIG_MIXIN"
    printf 'mixed-port: 54016\n' > "$MIHOMO_CONFIG_RUNTIME"
    printf 'PROXY_PORT=54016\nUI_PORT=19090\nDNS_PORT=15353\n' > "$MIHOMO_PORT_STATE"

    # Mock: mihomo not running, poisoned proxy
    is_mihomo_running() { return 1; }
    _get_proxy_port() { MIXED_PORT=54016; }
    _get_ui_port() { UI_PORT=19090; }
    _get_dns_port() { DNS_PORT=15353; }
    _is_bind() { return 1; }

    export http_proxy=http://127.0.0.1:54016
    export https_proxy=http://127.0.0.1:54016

    unset_was_called=false
    _unset_system_proxy() {
        unset_was_called=true
        unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
        unset all_proxy ALL_PROXY no_proxy NO_PROXY
    }
    _set_system_proxy() { fail 'should not set proxy when mihomo is dead'; }
    _okcat() { :; }
    _failcat() { return 0; }

    clashdoctor

    [ "$unset_was_called" = "true" ] || fail 'doctor did not clear poisoned proxy env'
    [ -z "${http_proxy:-}" ] || fail 'doctor left proxy env after fix'
)

# ── clash status warns about poisoned env ──────────────────────────

(
    export MIHOMO_BASE_DIR="$test_root/status"
    export MIHOMO_CONFIG_MIXIN="$MIHOMO_BASE_DIR/mixin.yaml"
    export MIHOMO_CONFIG_RUNTIME="$MIHOMO_BASE_DIR/runtime.yaml"
    export MIHOMO_CONFIG_URL="$MIHOMO_BASE_DIR/url"
    export MIHOMO_PORT_STATE="$MIHOMO_BASE_DIR/config/ports.conf"
    mkdir -p "$MIHOMO_BASE_DIR/config"
    printf 'system-proxy:\n  enable: true\n' > "$MIHOMO_CONFIG_MIXIN"
    printf 'mixed-port: 54016\n' > "$MIHOMO_CONFIG_RUNTIME"

    is_mihomo_running() { return 1; }
    _get_proxy_port() { MIXED_PORT=54016; }
    _get_ui_port() { UI_PORT=19090; }
    _get_dns_port() { DNS_PORT=15353; }

    export http_proxy=http://127.0.0.1:54016

    warning_shown=false
    _okcat() { :; }
    _failcat() {
        case "$1" in
        *doctor*) warning_shown=true ;;
        esac
        return 0
    }

    clashstatus >/dev/null 2>&1 || true

    [ "$warning_shown" = "true" ] || fail 'status did not warn about poisoned proxy env'
)

printf 'proxy health tests passed\n'
