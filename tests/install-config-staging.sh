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
    printf 'test-install-config-staging: %s\n' "$*" >&2
    exit 1
}

fake_bin="$test_root/bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/tar" <<'EOF'
#!/bin/sh
set -eu
archive=
destination=
while [ "$#" -gt 0 ]; do
    case "$1" in
    -xf)
        archive=$2
        shift 2
        ;;
    -C)
        destination=$2
        shift 2
        ;;
    *)
        shift
        ;;
    esac
done
case "$archive" in
*subconverter*)
    mkdir -p "$destination/subconverter"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$destination/subconverter/subconverter"
    chmod 0755 "$destination/subconverter/subconverter"
    ;;
*yq*)
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$destination/yq_linux_amd64"
    chmod 0755 "$destination/yq_linux_amd64"
    ;;
*)
    exit 1
    ;;
esac
EOF
chmod 0755 "$fake_bin/tar"

cat > "$fake_bin/unzip" <<'EOF'
#!/bin/sh
set -eu
destination=
while [ "$#" -gt 0 ]; do
    case "$1" in
    -d)
        destination=$2
        shift 2
        ;;
    *)
        shift
        ;;
    esac
done
[ -n "$destination" ] || exit 1
mkdir -p "$destination/dist"
printf '%s\n' '<html></html>' > "$destination/dist/index.html"
EOF
chmod 0755 "$fake_bin/unzip"

prepare_case() {
    local case_dir=$1 repo_dir="$1/repo"
    mkdir -p "$repo_dir/script" "$repo_dir/resources/zip" "$case_dir/home" "$case_dir/state"
    cp "$repo_root/install.sh" "$repo_dir/install.sh"
    printf '%s\n' \
        'mode: rule' \
        'external-controller: "127.0.0.1:9090"' \
        'secret:' \
        'dns:' \
        '  listen: 127.0.0.1:15353' > "$repo_dir/resources/mixin.yaml"
    : > "$repo_dir/resources/mihomo.lock.tsv"
    : > "$repo_dir/resources/zip/subconverter.tar.gz"
    : > "$repo_dir/resources/zip/yq.tar.gz"
    : > "$repo_dir/resources/zip/zashboard.zip"

    cat > "$repo_dir/script/common.sh" <<'EOF'
SCRIPT_BASE_DIR='./script'
RESOURCES_BASE_DIR='./resources'
RESOURCES_CONFIG="${RESOURCES_BASE_DIR}/config.yaml"
RESOURCES_CONFIG_MIXIN="${RESOURCES_BASE_DIR}/mixin.yaml"
ZIP_BASE_DIR="${RESOURCES_BASE_DIR}/zip"
ZIP_SUBCONVERTER="${ZIP_BASE_DIR}/subconverter.tar.gz"
ZIP_YQ="${ZIP_BASE_DIR}/yq.tar.gz"
ZIP_UI="${ZIP_BASE_DIR}/zashboard.zip"
MIHOMO_BUNDLE_LOCK="${RESOURCES_BASE_DIR}/mihomo.lock.tsv"
MIHOMO_BASE_DIR="$HOME/tools/mihomo"
MIHOMO_SCRIPT_DIR="${MIHOMO_BASE_DIR}/script"
MIHOMO_CONFIG_URL="${MIHOMO_BASE_DIR}/url"
MIHOMO_CONFIG_RAW="${MIHOMO_BASE_DIR}/config.yaml"
MIHOMO_CONFIG_MIXIN="${MIHOMO_BASE_DIR}/mixin.yaml"
BIN_SUBCONVERTER_LOG="${MIHOMO_BASE_DIR}/logs/subconverter.log"

_valid_install_env() { return 0; }
_set_bin() {
    BIN_KERNEL="${MIHOMO_BASE_DIR}/bin/mihomo"
    BIN_SUBCONVERTER_LOG="${MIHOMO_BASE_DIR}/logs/subconverter.log"
}
_valid_config() {
    case "$1" in
    "${MIHOMO_BASE_DIR}/tmp/"*) ;;
    *)
        printf 'invalid-validation-path=%s\n' "$1" >> "$FAKE_TRACE"
        return 1
        ;;
    esac
    grep -q '^valid:' "$1"
}
_download_config() {
    local destination=$1 url=$2 download_temporary
    case "$destination" in
    "${MIHOMO_BASE_DIR}/tmp/"*) ;;
    *) return 1 ;;
    esac
    download_temporary=$(mktemp "${TMPDIR}/download.XXXXXX") || return 1
    case "$download_temporary" in
    "${MIHOMO_BASE_DIR}/tmp/"*) ;;
    *)
        rm -f "$download_temporary"
        return 1
        ;;
    esac
    rm -f "$download_temporary"
    printf 'valid: downloaded from %s\n' "$url" > "$destination"
    printf 'download-destination=%s\n' "$destination" >> "$FAKE_TRACE"
}
_okcat() { printf '%s\n' "$*"; }
_failcat() { printf '%s\n' "$*" >&2; return 1; }
_stop_convert() { return 0; }
stop_mihomo() {
    printf '%s\n' stop >> "$FAKE_TRACE"
    [ "${FAKE_STOP_FAIL:-false}" != true ]
}
_set_rc() {
    if [ "${1:-}" = unset ]; then
        printf '%s\n' rc-unset >> "$FAKE_TRACE"
        return 0
    fi
    printf '%s\n' rc-set >> "$FAKE_TRACE"
    [ "${FAKE_RC_FAIL:-false}" != true ]
}
_quit() { return 0; }
EOF

    cat > "$repo_dir/script/upgrade.sh" <<'EOF'
_upgrade_acquire_lock() { return 0; }
_upgrade_release_lock() { return 0; }
_install_bundled_mihomo() {
    local destination=$3
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$destination"
    chmod 0755 "$destination"
}
EOF

    cat > "$repo_dir/script/clashctl.sh" <<'EOF'
_is_valid_subscription_url() {
    case "$1" in
    http://?*|https://?*) return 0 ;;
    *) return 1 ;;
    esac
}
_config_atomic_copy() {
    local source=$1 destination=$2 temporary
    mkdir -p "$(dirname "$destination")" || return 1
    temporary=$(mktemp "${destination}.tmp.XXXXXX") || return 1
    if cp "$source" "$temporary" && mv -f "$temporary" "$destination"; then
        return 0
    fi
    rm -f "$temporary"
    return 1
}
_config_atomic_write() {
    local destination=$1 value=$2 temporary
    mkdir -p "$(dirname "$destination")" || return 1
    temporary=$(mktemp "${destination}.tmp.XXXXXX") || return 1
    if printf '%s\n' "$value" > "$temporary" && mv -f "$temporary" "$destination"; then
        return 0
    fi
    rm -f "$temporary"
    return 1
}
mihomoctl() {
    [ "${1:-}" = on ] || return 1
    [ -f "$MIHOMO_CONFIG_RAW" ] || return 1
    [ -f "$MIHOMO_CONFIG_MIXIN" ] || return 1
    printf 'start-config=%s\n' "$(cat "$MIHOMO_CONFIG_RAW")" >> "$FAKE_TRACE"
    printf 'start-mixin=%s\n' "$(cat "$MIHOMO_CONFIG_MIXIN")" >> "$FAKE_TRACE"
    [ "${FAKE_START_FAIL:-false}" != true ]
}
clashui() { printf '%s\n' ui >> "$FAKE_TRACE"; }
EOF

    cat > "$repo_dir/script/install-lib.sh" <<'EOF'
_install_script_release() {
    mkdir -p "$MIHOMO_SCRIPT_DIR"
    printf '%s\n' '#!/bin/sh' > "$MIHOMO_SCRIPT_DIR/managed.sh"
}
EOF
}

late_failure_case="$test_root/late-failure"
prepare_case "$late_failure_case"
if printf '%s\n' 'https://secret.example/subscription' | \
    HOME="$late_failure_case/home" \
    PATH="$fake_bin:$PATH" \
    FAKE_TRACE="$late_failure_case/state/trace" \
    FAKE_RC_FAIL=true \
    bash "$late_failure_case/repo/install.sh" > "$late_failure_case/state/output" 2>&1; then
    fail 'late RC failure was reported as a successful install'
fi
[ ! -e "$late_failure_case/repo/resources/config.yaml" ] ||
    fail 'failed install created a source-tree config.yaml'
[ ! -e "$late_failure_case/home/tools/mihomo" ] ||
    fail 'failed install retained its transaction directory'
grep -Fq "download-destination=$late_failure_case/home/tools/mihomo/tmp/install-config." \
    "$late_failure_case/state/trace" || fail 'subscription was not downloaded into the install transaction'
grep -Fq 'start-mixin=mode: rule' "$late_failure_case/state/trace" ||
    fail 'late failure happened before the staged config and mixin reached startup'

cleanup_failure_case="$test_root/cleanup-failure"
prepare_case "$cleanup_failure_case"
if printf '%s\n' 'https://secret.example/subscription' | \
    HOME="$cleanup_failure_case/home" \
    PATH="$fake_bin:$PATH" \
    FAKE_TRACE="$cleanup_failure_case/state/trace" \
    FAKE_RC_FAIL=true \
    FAKE_STOP_FAIL=true \
        bash "$cleanup_failure_case/repo/install.sh" > "$cleanup_failure_case/state/output" 2>&1; then
    fail 'cleanup failure was reported as a successful install'
fi
[ -d "$cleanup_failure_case/home/tools/mihomo" ] ||
    fail 'failed install removed files while the managed process could not be stopped'
grep -Fq '自动清理未完成' "$cleanup_failure_case/state/output" ||
    fail 'cleanup failure did not report the retained install path'

invalid_url_case="$test_root/invalid-url"
prepare_case "$invalid_url_case"
if printf '%s\n' 'htps://broken.example/subscription' | \
    HOME="$invalid_url_case/home" \
    PATH="$fake_bin:$PATH" \
    FAKE_TRACE="$invalid_url_case/state/trace" \
        bash "$invalid_url_case/repo/install.sh" > "$invalid_url_case/state/output" 2>&1; then
    fail 'install accepted an invalid subscription URL'
fi
[ ! -e "$invalid_url_case/home/tools/mihomo" ] ||
    fail 'invalid subscription URL left an installation tree'
if [ -f "$invalid_url_case/state/trace" ] &&
    grep -q '^download-destination=' "$invalid_url_case/state/trace"; then
    fail 'invalid subscription URL reached the downloader'
fi

source_config_case="$test_root/source-config"
prepare_case "$source_config_case"
printf '%s\n' 'valid: bundled config' 'credential: source-secret' > \
    "$source_config_case/repo/resources/config.yaml"
cp "$source_config_case/repo/resources/config.yaml" "$source_config_case/state/config.before"
HOME="$source_config_case/home" \
PATH="$fake_bin:$PATH" \
FAKE_TRACE="$source_config_case/state/trace" \
    bash "$source_config_case/repo/install.sh" </dev/null > "$source_config_case/state/output" 2>&1 ||
    fail 'install with a bundled source config failed'
cmp -s "$source_config_case/state/config.before" "$source_config_case/repo/resources/config.yaml" ||
    fail 'install modified the bundled source config'
cmp -s "$source_config_case/state/config.before" "$source_config_case/home/tools/mihomo/config.yaml" ||
    fail 'bundled source config was not published to the install directory'
if grep -q '^download-destination=' "$source_config_case/state/trace"; then
    fail 'install downloaded a subscription despite having a usable source config'
fi

download_success_case="$test_root/download-success"
prepare_case "$download_success_case"
subscription_url='https://secret.example/success'
printf '%s\n' "$subscription_url" | \
    HOME="$download_success_case/home" \
    PATH="$fake_bin:$PATH" \
    FAKE_TRACE="$download_success_case/state/trace" \
    bash "$download_success_case/repo/install.sh" > "$download_success_case/state/output" 2>&1 ||
    fail 'install with a downloaded config failed'
[ ! -e "$download_success_case/repo/resources/config.yaml" ] ||
    fail 'successful download created a source-tree config.yaml'
[ "$(cat "$download_success_case/home/tools/mihomo/config.yaml")" = "valid: downloaded from $subscription_url" ] ||
    fail 'downloaded config was not published to the install directory'
[ "$(cat "$download_success_case/home/tools/mihomo/url")" = "$subscription_url" ] ||
    fail 'subscription URL was not published to the install directory'
[ -f "$download_success_case/home/tools/mihomo/mixin.yaml" ] ||
    fail 'mixin was not installed before startup'
grep -Eq '^secret: "[0-9a-f]{64}"$' \
    "$download_success_case/home/tools/mihomo/mixin.yaml" ||
    fail 'fresh install did not generate a unique API secret'
mixin_mode=$(stat -f '%Lp' "$download_success_case/home/tools/mihomo/mixin.yaml" 2>/dev/null ||
    stat -c '%a' "$download_success_case/home/tools/mihomo/mixin.yaml")
[ "$mixin_mode" = 600 ] || fail 'installed mixin containing the API secret is not mode 0600'
if find "$download_success_case/home/tools/mihomo/tmp" -name 'install-config.*' -print -quit | grep -q .; then
    fail 'successful install retained its config staging file'
fi

printf '%s\n' 'install config staging tests passed'
