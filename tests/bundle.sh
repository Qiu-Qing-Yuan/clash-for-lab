#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
manifest="$repo_root/resources/mihomo.lock.tsv"

fail() {
    printf 'test-bundle: %s\n' "$*" >&2
    exit 1
}

[[ $(awk 'END { print NR + 0 }' "$manifest") == 2 ]] || fail 'manifest must contain exactly two records'
[[ $(awk -F '\t' '$1 == "schema" { count++ } END { print count + 0 }' "$manifest") == 1 ]] ||
    fail 'manifest contains an invalid number of schema records'
[[ $(awk -F '\t' '$1 == "schema" && NF == 2 && $2 == 1 { count++ } END { print count + 0 }' "$manifest") == 1 ]] ||
    fail 'manifest schema is invalid'

asset_count=$(awk -F '\t' '$1 == "asset" { count++ } END { print count + 0 }' "$manifest")
[[ $asset_count == 1 ]] || fail 'manifest must contain exactly one asset record'
row_count=$(awk -F '\t' '$1 == "asset" && $2 == "linux" && $3 == "amd64" && $4 == "v1" { count++ } END { print count + 0 }' "$manifest")
[[ $row_count == 1 ]] || fail 'manifest does not contain one Linux amd64 v1 asset'

IFS=$'\t' read -r kind os arch variant version filename expected_size expected_sha256 < <(
    awk -F '\t' '$1 == "asset" && $2 == "linux" && $3 == "amd64" && $4 == "v1" && NF == 8 { print; exit }' "$manifest"
)
[[ $kind == asset && $os == linux && $arch == amd64 && $variant == v1 ]] || fail 'asset fields are invalid'
[[ $version =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
    fail 'asset version is invalid'
[[ $filename == mihomo-linux-amd64-v1.gz ]] || fail 'asset filename is invalid'
[[ $expected_size =~ ^[1-9][0-9]*$ ]] || fail 'asset size is invalid'
[[ $expected_sha256 =~ ^[0-9a-f]{64}$ ]] || fail 'asset SHA256 is invalid'

bundle="$repo_root/resources/zip/$filename"
[[ -f $bundle ]] || fail 'bundle is missing'
actual_size=$(LC_ALL=C wc -c < "$bundle" | tr -d '[:space:]')
[[ $actual_size == "$expected_size" ]] || fail 'bundle size does not match manifest'

if command -v sha256sum >/dev/null 2>&1; then
    actual_sha256=$(sha256sum "$bundle" | awk '{print $1}')
else
    actual_sha256=$(shasum -a 256 "$bundle" | awk '{print $1}')
fi
[[ $actual_sha256 == "$expected_sha256" ]] || fail 'bundle SHA256 does not match manifest'
gzip -t -- "$bundle" || fail 'bundle failed gzip integrity check'

if [[ ${MIHOMO_BUNDLE_EXECUTE:-true} == true && $(uname -s) == Linux && $(uname -m) == x86_64 ]]; then
    temp_dir=$(mktemp -d)
    trap 'rm -rf -- "$temp_dir"' EXIT
    gzip -dc -- "$bundle" > "$temp_dir/mihomo"
    chmod 0755 "$temp_dir/mihomo"
    output=$("$temp_dir/mihomo" -v 2>&1) || fail 'bundle cannot run on Linux amd64'
    actual_version=$(printf '%s\n' "$output" | "$repo_root/tools/parse-mihomo-version.sh" || true)
    [[ $actual_version == "$version" ]] || fail 'bundle version does not match manifest'

    # Transaction candidates live below HomeDir/tmp. Validation must still use
    # the installed HomeDir so bundled GEO data and provider caches remain
    # available when GitHub or the wider internet cannot be reached.
    home_dir="$temp_dir/home"
    staging_dir="$home_dir/tmp/subscription-update.test"
    candidate="$staging_dir/raw.candidate"
    mkdir -p "$staging_dir"
    cp "$repo_root/resources/Country.mmdb" "$home_dir/Country.mmdb"
    (
        cd "$repo_root"
        HOME="$home_dir"
        USER=tester
        export HOME USER
        set +u
        # shellcheck source=../script/common.sh
        . "$repo_root/script/common.sh"
        set -u
        _convert_anytls_proxy_link "$candidate" \
            'anytls://test-password@127.0.0.1:443/?sni=example.com#DIRECT'
    ) || fail 'bundled AnyTLS link conversion failed'
    grep -Fq "  - name: 'DIRECT (AnyTLS)'" "$candidate" ||
        fail 'bundled AnyTLS conversion did not avoid a reserved proxy name'
    grep -Fq '    udp: true' "$candidate" ||
        fail 'bundled AnyTLS conversion did not enable UDP'
    awk '
        $0 == "rules:" {
            print "geox-url:"
            print "  mmdb: http://127.0.0.1:1/Country.mmdb"
            print
            print "  - GEOIP,CN,DIRECT"
            next
        }
        { print }
    ' "$candidate" > "$candidate.with-geodata" ||
        fail 'could not prepare the offline HomeDir fixture'
    mv "$candidate.with-geodata" "$candidate"
    cp "$home_dir/Country.mmdb" "$temp_dir/Country.before"
    (
        cd "$repo_root"
        HOME="$home_dir"
        USER=tester
        export HOME USER
        set +u
        # shellcheck source=../script/common.sh
        . "$repo_root/script/common.sh"
        set -u
        BIN_KERNEL="$temp_dir/mihomo"
        _valid_config "$candidate" "$home_dir"
    ) || fail 'bundle rejected a candidate in the private offline validation HomeDir'
    cmp -s "$temp_dir/Country.before" "$home_dir/Country.mmdb" ||
        fail 'candidate validation changed the installed GEO database'
    root_data_count=$(find "$home_dir" -maxdepth 1 -type f | wc -l | tr -d '[:space:]')
    [[ $root_data_count == 1 ]] ||
        fail 'candidate validation wrote data into the installed HomeDir'
    if timeout --kill-after=5 30 "$temp_dir/mihomo" \
        -d "$staging_dir" -f "$candidate" -t >/dev/null 2>&1; then
        fail 'offline HomeDir fixture did not detect the staging-directory regression'
    fi

    # v1.19.29 keeps providers lazy during `-t`: existing relative caches do
    # not need copying into the validation HomeDir, and an absolute HTTP
    # provider path must not be created in the installed HomeDir.
    mkdir -p "$home_dir/providers"
    printf '%s\n' 'payload:' '  - DOMAIN,example.com' > "$home_dir/providers/cached.yaml"
    provider_target="$home_dir/providers/candidate.yaml"
    provider_candidate="$staging_dir/provider.candidate"
    printf '%s\n' \
        'rule-providers:' \
        '  cached:' \
        '    type: file' \
        '    behavior: classical' \
        '    format: yaml' \
        '    path: ./providers/cached.yaml' \
        '  remote:' \
        '    type: http' \
        '    behavior: classical' \
        '    format: yaml' \
        '    url: http://127.0.0.1:1/rules.yaml' \
        "    path: $provider_target" \
        'rules:' \
        '  - RULE-SET,cached,DIRECT' \
        '  - RULE-SET,remote,DIRECT' \
        '  - MATCH,DIRECT' > "$provider_candidate"
    (
        cd "$repo_root"
        HOME="$home_dir"
        USER=tester
        export HOME USER
        set +u
        # shellcheck source=../script/common.sh
        . "$repo_root/script/common.sh"
        set -u
        BIN_KERNEL="$temp_dir/mihomo"
        _valid_config "$provider_candidate" "$home_dir"
    ) || fail 'private validation rejected lazy provider caches'
    [[ ! -e $provider_target ]] ||
        fail 'candidate validation wrote an HTTP provider into the installed HomeDir'
fi

printf 'bundle tests passed (%s)\n' "$version"
