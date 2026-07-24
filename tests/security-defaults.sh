#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
mixin="$repo_root/resources/mixin.yaml"

fail() {
    printf 'test-security-defaults: %s\n' "$*" >&2
    exit 1
}

grep -Eq '^external-controller:[[:space:]]*"127\.0\.0\.1:[0-9]+"$' "$mixin" ||
    fail 'management API is not restricted to IPv4 loopback by default'
grep -Eq '^[[:space:]]+listen:[[:space:]]*127\.0\.0\.1:[0-9]+' "$mixin" ||
    fail 'DNS listener is not restricted to IPv4 loopback by default'
if grep -Eq '^(external-controller:|[[:space:]]+listen:)[[:space:]]*"?(0\.0\.0\.0|\[?::\]?):' "$mixin"; then
    fail 'a management or DNS listener still uses a wildcard address'
fi
grep -Eq '^secret:[[:space:]]*$' "$mixin" ||
    fail 'the install-time secret placeholder changed unexpectedly'
grep -Fq '_install_secure_mixin "$MIHOMO_CONFIG_MIXIN"' "$repo_root/install.sh" ||
    fail 'fresh install does not replace the secret placeholder'
grep -Fq 'dns_bind_addr="127.0.0.1"' "$repo_root/script/common.sh" ||
    fail 'a runtime without dns.listen does not fail closed to loopback'

ui_body=$(LC_ALL=C awk '
    /^function clashui\(\)/ { in_ui = 1 }
    in_ui { print }
    in_ui && /^}/ { exit }
' "$repo_root/script/clashctl.sh")
printf '%s\n' "$ui_body" | grep -Fq 'http://127.0.0.1:${UI_PORT}/ui' ||
    fail 'clash ui does not advertise the loopback management endpoint'
printf '%s\n' "$ui_body" | grep -Fq 'ssh -L' ||
    fail 'clash ui does not explain safe remote access through SSH forwarding'
if printf '%s\n' "$ui_body" | grep -Eq 'api64\.ipify|hostname -I|公网|放行端口'; then
    fail 'clash ui still encourages direct LAN or public management access'
fi

tui_body=$(LC_ALL=C awk '
    /^function clashtui\(\)/ { in_tui = 1 }
    in_tui { print }
    in_tui && /^}/ { exit }
' "$repo_root/script/clashctl.sh")
printf '%s\n' "$tui_body" | grep -Fq 'mktemp "${config_file}.tmp.XXXXXX"' ||
    fail 'TUI secret config is not staged in a private temporary file'
printf '%s\n' "$tui_body" | grep -Fq 'chmod 0600 "$config_tmp"' ||
    fail 'TUI secret config is not restricted to mode 0600'

printf '%s\n' 'security default tests passed'
