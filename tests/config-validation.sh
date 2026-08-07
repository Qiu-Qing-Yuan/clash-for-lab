#!/usr/bin/env bash

set -eu
set -o pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)
cleanup() {
    exit_status=$?
    trap - EXIT HUP INT TERM
    rm -rf -- "$test_root"
    exit "$exit_status"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'test-config-validation: %s\n' "$*" >&2
    exit 1
}

HOME="$test_root/home"
USER=tester
export HOME USER
mkdir -p "$HOME" "$test_root/bin"

# shellcheck source=../script/common.sh
set +u
. "$repo_root/script/common.sh"
# shellcheck source=../script/clashctl.sh
. "$repo_root/script/clashctl.sh"
set -u

cat > "$test_root/bin/timeout" <<'FAKE_TIMEOUT'
#!/bin/sh
set -eu
[ "$1" = "--kill-after=5" ] || exit 90
shift
shift
exec "$@"
FAKE_TIMEOUT
chmod 0755 "$test_root/bin/timeout"

cat > "$test_root/bin/mihomo" <<'FAKE_MIHOMO'
#!/bin/sh
set -eu
home_dir=''
config=''
while [ "$#" -gt 0 ]; do
    case "$1" in
    -d)
        home_dir=$2
        shift 2
        ;;
    -f)
        config=$2
        shift 2
        ;;
    -t)
        shift
        ;;
    *)
        exit 91
        ;;
    esac
done
printf '%s\t%s\n' "$home_dir" "$config" >> "$FAKE_MIHOMO_TRACE"
[ "$home_dir" != "$FAKE_MIHOMO_SOURCE_HOME" ] || exit 92
[ -f "$config" ] || exit 93
[ "$(cat "$home_dir/Country.mmdb" 2>/dev/null || true)" = offline-geodata ] || exit 94
printf '%s\n' candidate-side-effect > "$home_dir/GeoSite.dat"
if grep -q '^force-validation-failure:' "$config"; then
    exit 95
fi
FAKE_MIHOMO
chmod 0755 "$test_root/bin/mihomo"

PATH="$test_root/bin:$PATH"
export PATH

MIHOMO_BASE_DIR="$test_root/home with space/tools/mihomo"
MIHOMO_CONFIG_RAW="$MIHOMO_BASE_DIR/config.yaml"
MIHOMO_CONFIG_MIXIN="$MIHOMO_BASE_DIR/mixin.yaml"
MIHOMO_CONFIG_RUNTIME="$MIHOMO_BASE_DIR/runtime.yaml"
BIN_KERNEL="$test_root/bin/mihomo"
FAKE_MIHOMO_SOURCE_HOME=$MIHOMO_BASE_DIR
FAKE_MIHOMO_TRACE="$test_root/mihomo.trace"
export FAKE_MIHOMO_SOURCE_HOME FAKE_MIHOMO_TRACE

candidate_dir="$MIHOMO_BASE_DIR/tmp/subscription-update.test"
candidate="$candidate_dir/raw.candidate"
mkdir -p "$candidate_dir"
printf '%s\n' offline-geodata > "$MIHOMO_BASE_DIR/Country.mmdb"
printf '%s\n' 'proxies: []' 'rules: []' > "$candidate"
: > "$FAKE_MIHOMO_TRACE"

_valid_config "$candidate" "$MIHOMO_BASE_DIR" ||
    fail 'an explicit installed HomeDir did not validate'
[ "$(cat "$MIHOMO_BASE_DIR/Country.mmdb")" = offline-geodata ] ||
    fail 'candidate validation changed installed geodata'
[ ! -e "$MIHOMO_BASE_DIR/GeoSite.dat" ] ||
    fail 'candidate validation wrote new geodata into the installed HomeDir'
validation_home=$(sed -n '1s/\t.*//p' "$FAKE_MIHOMO_TRACE")
[ -n "$validation_home" ] && [ ! -e "$validation_home" ] ||
    fail 'candidate validation retained its private HomeDir'
case "$validation_home" in
"$candidate_dir"/.mihomo-config-test.*) ;;
*) fail 'candidate validation used global or tmpfs temporary storage' ;;
esac

printf '%s\n' 'proxies: []' 'force-validation-failure: true' > "$candidate"
if _valid_config "$candidate" "$MIHOMO_BASE_DIR"; then
    fail 'forced candidate validation failure was reported as success'
fi
[ "$(cat "$MIHOMO_BASE_DIR/Country.mmdb")" = offline-geodata ] &&
    [ ! -e "$MIHOMO_BASE_DIR/GeoSite.dat" ] ||
    fail 'failed candidate validation changed the installed HomeDir'
failed_validation_home=$(tail -n 1 "$FAKE_MIHOMO_TRACE" | cut -f1)
[ -n "$failed_validation_home" ] && [ ! -e "$failed_validation_home" ] ||
    fail 'failed candidate validation retained its private HomeDir'

printf '%s\n' 'proxies: []' 'rules: []' > "$candidate"
persistent_validation_home="$candidate_dir/persistent-validation-home"
validation_data_manifest="$candidate_dir/validation-data.manifest"
_valid_config "$candidate" "$MIHOMO_BASE_DIR" "$persistent_validation_home" ||
    fail 'transaction-scoped validation failed'
[ "$(cat "$persistent_validation_home/GeoSite.dat")" = candidate-side-effect ] ||
    fail 'transaction-scoped validation did not retain fetched GEO data'
_valid_config "$candidate" "$MIHOMO_BASE_DIR" "$persistent_validation_home" ||
    fail 'transaction-scoped validation HomeDir was not reusable'
_publish_new_config_validation_data "$persistent_validation_home" \
    "$MIHOMO_BASE_DIR" "$validation_data_manifest" ||
    fail 'validated GEO data was not published'
[ "$(cat "$MIHOMO_BASE_DIR/GeoSite.dat")" = candidate-side-effect ] ||
    fail 'published GEO data is missing from the installed HomeDir'
_rollback_new_config_validation_data "$persistent_validation_home" \
    "$MIHOMO_BASE_DIR" "$validation_data_manifest" ||
    fail 'published GEO data rollback failed'
[ ! -e "$MIHOMO_BASE_DIR/GeoSite.dat" ] ||
    fail 'GEO data rollback retained a newly published file'
rm -rf "$persistent_validation_home"
rm -f "$validation_data_manifest"

if _valid_config "$candidate"; then
    fail 'candidate directory accidentally behaved like the installed HomeDir'
fi

# Runtime candidates also live below tmp/ and must use the installed HomeDir.
cat > "$test_root/bin/yq" <<'FAKE_YQ'
#!/bin/sh
printf '%s\n' 'proxies: []' 'rules: []'
FAKE_YQ
chmod 0755 "$test_root/bin/yq"
BIN_YQ="$test_root/bin/yq"
printf '%s\n' 'proxies: []' 'rules: []' > "$MIHOMO_CONFIG_RAW"
printf '%s\n' 'mode: rule' 'allow-lan: false' > "$MIHOMO_CONFIG_MIXIN"
runtime_candidate="$candidate_dir/runtime.candidate"
_resolve_port_conflicts() { return 0; }
_build_runtime_candidate "$MIHOMO_CONFIG_RAW" "$runtime_candidate" false ||
    fail 'runtime candidate did not validate against the installed HomeDir'

private_call_count=$(awk -F '\t' -v home="$MIHOMO_BASE_DIR" '$1 != home { count++ } END { print count + 0 }' "$FAKE_MIHOMO_TRACE")
[ "$private_call_count" -ge 2 ] ||
    fail 'validation did not consistently use a private HomeDir'
if awk -F '\t' -v home="$MIHOMO_BASE_DIR" '$1 == home { found=1 } END { exit !found }' \
    "$FAKE_MIHOMO_TRACE"; then
    fail 'validation invoked Mihomo against the installed HomeDir'
fi

# Conversion prefers the local snapshot, handles a one-line proxy URI without
# another network request, and keeps the original URL as the last compatibility
# fallback for formats the stable converter cannot read from a file.
downloaded="$candidate_dir/downloaded.raw"
provider_url='https://provider.example/sub?token=NETWORK_SECRET'
conversion_source="$test_root/conversion.source"
conversion_case=local
_download_raw_config() {
    case "$conversion_case" in
    local) printf '%s\n' 'base64-subscription-body' 'second-line' > "$1" ;;
    single) printf '%s\r\n' 'ss://single-local-node' > "$1" ;;
    anytls)
        printf '%s\r\n' \
            "anytls://p%40ss%27word@[2001:db8::1]/?sni=edge.example&insecure=1#%E6%B5%8B%E8%AF%95%20%27node%27" > "$1"
        ;;
    remote) printf '%s\n' 'legacy-provider-body' 'second-line' > "$1" ;;
    *) return 1 ;;
    esac
}
_valid_config() {
    [ "$2" = "$MIHOMO_BASE_DIR" ] && grep -q '^proxies:' "$1"
}
_download_convert_config() {
    printf '%s\n' "$2" >> "$conversion_source"
    case "$conversion_case:$2" in
    "local:$1" | single:ss://* | "remote:$provider_url")
        printf '%s\n' 'proxies: []' 'rules: []' > "$1"
        ;;
    "remote:$1")
        printf '%s\n' 'invalid: local conversion' 'rules: []' > "$1"
        ;;
    *) return 1 ;;
    esac
}
_okcat() { return 0; }
_failcat() { return 1; }

: > "$conversion_source"
_download_config "$downloaded" "$provider_url" "$MIHOMO_BASE_DIR" ||
    fail 'local snapshot conversion failed'
[ "$(cat "$conversion_source")" = "$downloaded" ] ||
    fail 'conversion retried the remote provider instead of using the local snapshot'
if grep -Fq NETWORK_SECRET "$conversion_source"; then
    fail 'the provider URL leaked into the local conversion source'
fi

conversion_case=single
: > "$conversion_source"
_download_config "$downloaded" "$provider_url" "$MIHOMO_BASE_DIR" ||
    fail 'single-link local conversion failed'
[ "$(sed -n '1p' "$conversion_source")" = 'ss://single-local-node' ] ||
    fail 'single-link conversion did not normalize and use the downloaded node URI'
[ "$(wc -l < "$conversion_source" | tr -d '[:space:]')" = 1 ] ||
    fail 'single-link conversion retried the provider URL'

conversion_case=anytls
: > "$conversion_source"
_download_config "$downloaded" "$provider_url" "$MIHOMO_BASE_DIR" ||
    fail 'AnyTLS local conversion failed'
[ ! -s "$conversion_source" ] ||
    fail 'AnyTLS local conversion unnecessarily started the stable converter'
grep -Fq "  - name: '测试 ''node'''" "$downloaded" ||
    fail 'AnyTLS display name was not safely decoded and quoted'
grep -Fq "    server: '2001:db8::1'" "$downloaded" ||
    fail 'AnyTLS IPv6 server was not parsed'
grep -Fq '    port: 443' "$downloaded" ||
    fail 'AnyTLS default port was not applied'
grep -Fq "    password: 'p@ss''word'" "$downloaded" ||
    fail 'AnyTLS password was not safely decoded and quoted'
grep -Fq "    sni: 'edge.example'" "$downloaded" ||
    fail 'AnyTLS SNI was not parsed'
grep -Fq '    skip-cert-verify: true' "$downloaded" ||
    fail 'AnyTLS insecure flag was not parsed'
grep -Fq '    udp: true' "$downloaded" ||
    fail 'AnyTLS UDP support was not enabled'
grep -Fq "  - 'MATCH,PROXY'" "$downloaded" ||
    fail 'AnyTLS local conversion did not create a usable rule group'

# Mihomo reserves its built-in proxy names. A valid display fragment must be
# made distinct instead of producing an unusable generated configuration.
_convert_anytls_proxy_link "$downloaded" \
    'anytls://password@example.com:443/#DIRECT' ||
    fail 'AnyTLS reserved-name conversion failed'
grep -Fq "  - name: 'DIRECT (AnyTLS)'" "$downloaded" ||
    fail 'AnyTLS reserved proxy name was not made distinct'
grep -Fq "      - 'DIRECT (AnyTLS)'" "$downloaded" ||
    fail 'AnyTLS group did not reference the renamed proxy'

# Query parsing has a strict item cap, so a small attacker-controlled line
# cannot fork one decoder process per unknown parameter while holding the lock.
many_query_link='anytls://password@example.com:443/?'
many_query_index=1
while [ "$many_query_index" -le 17 ]; do
    many_query_link="${many_query_link}x${many_query_index}=1&"
    many_query_index=$((many_query_index + 1))
done
printf '%s\n' 'original-download' > "$downloaded"
if _convert_anytls_proxy_link "$downloaded" "$many_query_link"; then
    fail 'AnyTLS conversion accepted too many query parameters'
fi
[ "$(cat "$downloaded")" = original-download ] ||
    fail 'oversized AnyTLS query replaced the downloaded snapshot'

# Malformed or control-character-bearing links are rejected without replacing
# the already downloaded snapshot.
printf '%s\n' 'original-download' > "$downloaded"
if _convert_anytls_proxy_link "$downloaded" \
    'anytls://bad%0Apassword@example.com:443/#invalid'; then
    fail 'AnyTLS conversion accepted an encoded control character'
fi
[ "$(cat "$downloaded")" = original-download ] ||
    fail 'invalid AnyTLS conversion replaced the downloaded snapshot'

conversion_case=remote
: > "$conversion_source"
_download_config "$downloaded" "$provider_url" "$MIHOMO_BASE_DIR" ||
    fail 'remote compatibility conversion failed'
[ "$(sed -n '1p' "$conversion_source")" = "$downloaded" ] ||
    fail 'remote fallback did not try the local snapshot first'
[ "$(sed -n '2p' "$conversion_source")" = "$provider_url" ] ||
    fail 'remote fallback did not preserve legacy provider compatibility'
[ "$(wc -l < "$conversion_source" | tr -d '[:space:]')" = 2 ] ||
    fail 'remote fallback made an unexpected number of conversion attempts'

printf '%s\n' 'config validation tests passed'
