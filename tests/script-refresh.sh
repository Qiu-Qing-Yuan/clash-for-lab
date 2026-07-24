#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'test-script-refresh: %s\n' "$*" >&2
    exit 1
}

_failcat() { return 0; }
rc_log="$test_root/rc.log"
_set_rc() { printf '%s\n' called >> "$rc_log"; }

# shellcheck source=../script/install-lib.sh
. "$repo_root/script/install-lib.sh"

write_release() {
    local source_dir=$1 marker=$2
    rm -rf -- "$source_dir"
    mkdir -p "$source_dir"
    printf '#!/usr/bin/env bash\nRELEASE_MARKER=%q\n' "$marker" > "$source_dir/common.sh"
    printf '#!/usr/bin/env bash\nupgrade_marker=%q\n' "$marker" > "$source_dir/upgrade.sh"
    printf '#!/usr/bin/env bash\ncontrol_marker=%q\n' "$marker" > "$source_dir/clashctl.sh"
}

MIHOMO_BASE_DIR="$test_root/install"
MIHOMO_SCRIPT_DIR="$MIHOMO_BASE_DIR/script"
SCRIPT_BASE_DIR="$test_root/source"
mkdir -p "$MIHOMO_BASE_DIR"

write_release "$SCRIPT_BASE_DIR" v1
_install_script_release || fail 'initial script release failed'
[ -L "$MIHOMO_SCRIPT_DIR" ] || fail 'stable script path is not a symlink'
[ "$(. "$MIHOMO_SCRIPT_DIR/managed.sh"; printf '%s:%s:%s' \
    "$RELEASE_MARKER" "$upgrade_marker" "$control_marker")" = v1:v1:v1 ] ||
    fail 'initial managed release is inconsistent'
first_release=$(readlink "$MIHOMO_SCRIPT_DIR")
printf '%s\n' custom > "$MIHOMO_BASE_DIR/$first_release/custom.txt"

write_release "$SCRIPT_BASE_DIR" v2
_install_script_release || fail 'script refresh failed'
[ "$(. "$MIHOMO_SCRIPT_DIR/managed.sh"; printf '%s:%s:%s' \
    "$RELEASE_MARKER" "$upgrade_marker" "$control_marker")" = v2:v2:v2 ] ||
    fail 'refreshed managed release is inconsistent'
recovered_custom=$(find "$MIHOMO_BASE_DIR" -path '*/script.recovery.*/original/custom.txt' -print -quit)
[ -n "$recovered_custom" ] && [ "$(cat "$recovered_custom")" = custom ] ||
    fail 'old script release was not archived'

stable_target=$(readlink "$MIHOMO_SCRIPT_DIR")
printf '%s\n' 'if then' > "$SCRIPT_BASE_DIR/broken.sh"
if _install_script_release >/dev/null 2>&1; then
    fail 'invalid scripts were published'
fi
[ "$(readlink "$MIHOMO_SCRIPT_DIR")" = "$stable_target" ] ||
    fail 'failed refresh changed the stable release'
rm -f "$SCRIPT_BASE_DIR/broken.sh"

legacy_base="$test_root/legacy"
MIHOMO_BASE_DIR=$legacy_base
MIHOMO_SCRIPT_DIR="$legacy_base/script"
mkdir -p "$MIHOMO_SCRIPT_DIR"
printf '%s\n' legacy > "$MIHOMO_SCRIPT_DIR/custom.txt"
write_release "$SCRIPT_BASE_DIR" v3
_install_script_release || fail 'legacy script migration failed'
[ -L "$MIHOMO_SCRIPT_DIR" ] || fail 'legacy path was not switched to a release link'
recovered_legacy=$(find "$legacy_base" -path '*/script.recovery.*/original/custom.txt' -print -quit)
[ -n "$recovered_legacy" ] || fail 'legacy script directory was not archived'

no_rc_base="$test_root/no-rc"
MIHOMO_BASE_DIR=$no_rc_base
MIHOMO_SCRIPT_DIR="$no_rc_base/script"
mkdir -p "$no_rc_base"
rc_before=$(wc -l < "$rc_log" | tr -d '[:space:]')
_install_script_release false || fail 'publish-only refresh failed'
rc_after=$(wc -l < "$rc_log" | tr -d '[:space:]')
[ "$rc_before" = "$rc_after" ] || fail 'publish-only refresh touched shell RC files'

printf '%s\n' 'script refresh tests passed'
