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
fi

printf 'bundle tests passed (%s)\n' "$version"
