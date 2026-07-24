#!/usr/bin/env bash

set -Eeuo pipefail

export LC_ALL=C

readonly MIHOMO_RELEASE_API="https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
readonly STABLE_ASSET_NAME="mihomo-linux-amd64-v1.gz"

fail() {
    printf 'sync-mihomo: %s\n' "$*" >&2
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

sha256_file() {
    local file=$1

    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$file" | awk '{print $1}'
    else
        fail "required command not found: sha256sum or shasum"
    fi
}

is_stable_tag() {
    [[ $1 =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

version_is_older() {
    local candidate=$1
    local current=$2
    local candidate_part current_part
    local -a candidate_parts current_parts
    local index
    local IFS=.

    read -r -a candidate_parts <<<"${candidate#v}"
    read -r -a current_parts <<<"${current#v}"

    for index in 0 1 2; do
        candidate_part=${candidate_parts[$index]}
        current_part=${current_parts[$index]}

        if [[ ${#candidate_part} -lt ${#current_part} ]]; then
            return 0
        fi
        if [[ ${#candidate_part} -gt ${#current_part} ]]; then
            return 1
        fi
        if [[ $candidate_part < $current_part ]]; then
            return 0
        fi
        if [[ $candidate_part > $current_part ]]; then
            return 1
        fi
    done

    return 1
}

read_lock_asset() {
    local lock_file=$1

    awk -F '\t' -v asset_name="$STABLE_ASSET_NAME" '
        NR == 1 {
            if (NF != 2 || $1 != "schema" || $2 != "1") {
                invalid = 1
            }
            next
        }
        NR == 2 {
            if (NF != 8 || $1 != "asset" || $2 != "linux" ||
                $3 != "amd64" || $4 != "v1" || $6 != asset_name) {
                invalid = 1
            } else {
                print $5 "|" $6 "|" $7 "|" $8
            }
            next
        }
        { invalid = 1 }
        END {
            if (NR != 2 || invalid) {
                exit 1
            }
        }
    ' "$lock_file"
}

for command in curl jq gzip mktemp awk; do
    require_command "$command"
done

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
bundle_dir="$repo_root/resources/zip"
bundle_path="$bundle_dir/$STABLE_ASSET_NAME"
lock_path="$repo_root/resources/mihomo.lock.tsv"

mkdir -p -- "$bundle_dir"
temp_dir=$(mktemp -d "$bundle_dir/.sync-mihomo.XXXXXX")
trap 'rm -rf -- "$temp_dir"' EXIT

release_json="$temp_dir/release.json"
downloaded_bundle="$temp_dir/$STABLE_ASSET_NAME"
lock_temp="$temp_dir/mihomo.lock.tsv"

curl_args=(
    --disable
    --fail
    --silent
    --show-error
    --location
    --retry 3
    --retry-all-errors
    --connect-timeout 15
    --proto '=https'
    --tlsv1.2
)

api_curl_args=(
    "${curl_args[@]}"
    --header 'Accept: application/vnd.github+json'
    --header 'X-GitHub-Api-Version: 2022-11-28'
)

if [[ -n ${GITHUB_TOKEN:-} ]]; then
    api_curl_args+=(--header "Authorization: Bearer $GITHUB_TOKEN")
fi

curl "${api_curl_args[@]}" --max-time 120 --output "$release_json" "$MIHOMO_RELEASE_API"

[[ $(jq -r '.draft' "$release_json") == false ]] || fail "latest release is a draft"
[[ $(jq -r '.prerelease' "$release_json") == false ]] || fail "latest release is a prerelease"

tag=$(jq -er '.tag_name | strings' "$release_json") || fail "release tag is missing"
is_stable_tag "$tag" || fail "release tag is not a stable version: $tag"

upstream_asset_name="mihomo-linux-amd64-v1-${tag}.gz"
asset_json=$(
    jq -ce --arg name "$upstream_asset_name" '
        [.assets[]? | select(.name == $name and .state == "uploaded")] as $matches
        | if ($matches | length) == 1
          then $matches[0]
          else error("expected exactly one matching release asset")
          end
    ' "$release_json"
) || fail "release does not contain exactly one $upstream_asset_name asset"

asset_size=$(jq -er '.size | tostring' <<<"$asset_json") || fail "asset size is missing"
[[ $asset_size =~ ^[1-9][0-9]*$ ]] || fail "asset size is invalid: $asset_size"

asset_digest=$(jq -er '.digest | strings' <<<"$asset_json") || fail "asset digest is missing"
[[ $asset_digest =~ ^sha256:([0-9a-fA-F]{64})$ ]] || fail "asset digest is not SHA-256"
expected_sha256=$(printf '%s' "${BASH_REMATCH[1]}" | tr 'A-F' 'a-f')

download_url=$(jq -er '.browser_download_url | strings' <<<"$asset_json") || fail "asset download URL is missing"
expected_download_url="https://github.com/MetaCubeX/mihomo/releases/download/${tag}/${upstream_asset_name}"
[[ $download_url == "$expected_download_url" ]] || fail "asset download URL does not match the official release"

if [[ -f $lock_path ]]; then
    current_lock=$(read_lock_asset "$lock_path") || fail "existing Mihomo lock file is invalid"
    IFS='|' read -r current_tag current_asset_name current_size current_sha256 extra_field \
        <<<"$current_lock"

    [[ -z ${extra_field:-} && $current_asset_name == "$STABLE_ASSET_NAME" ]] ||
        fail "existing Mihomo lock file is invalid"
    is_stable_tag "$current_tag" || fail "existing Mihomo lock tag is invalid: $current_tag"
    [[ $current_size =~ ^[1-9][0-9]*$ ]] ||
        fail "existing Mihomo lock size is invalid: $current_size"
    [[ $current_sha256 =~ ^[0-9a-fA-F]{64}$ ]] ||
        fail "existing Mihomo lock digest is invalid"
    current_sha256=$(printf '%s' "$current_sha256" | tr 'A-F' 'a-f')

    if version_is_older "$tag" "$current_tag"; then
        fail "latest stable release $tag is older than locked release $current_tag"
    fi

    if [[ $tag == "$current_tag" ]] &&
        [[ $asset_size != "$current_size" || $expected_sha256 != "$current_sha256" ]]; then
        fail "release $tag asset metadata changed after it was locked"
    fi
fi

curl "${curl_args[@]}" --max-time 300 --output "$downloaded_bundle" "$download_url"

actual_size=$(LC_ALL=C wc -c <"$downloaded_bundle" | tr -d '[:space:]')
[[ $actual_size == "$asset_size" ]] || fail "asset size mismatch: expected $asset_size, got $actual_size"

actual_sha256=$(sha256_file "$downloaded_bundle" | tr 'A-F' 'a-f')
[[ $actual_sha256 == "$expected_sha256" ]] || fail "asset SHA-256 mismatch"

gzip -t -- "$downloaded_bundle" || fail "asset failed gzip integrity check"

printf 'schema\t1\nasset\tlinux\tamd64\tv1\t%s\t%s\t%s\t%s\n' \
    "$tag" "$STABLE_ASSET_NAME" "$asset_size" "$expected_sha256" >"$lock_temp"
chmod 0644 "$downloaded_bundle" "$lock_temp"

if [[ ! -f $bundle_path ]] || ! cmp -s -- "$downloaded_bundle" "$bundle_path"; then
    mv -f -- "$downloaded_bundle" "$bundle_path"
fi
chmod 0644 "$bundle_path"

mv -f -- "$lock_temp" "$lock_path"

shopt -s nullglob
for old_bundle in "$bundle_dir"/mihomo-linux-amd64*.gz; do
    if [[ $old_bundle != "$bundle_path" ]]; then
        rm -f -- "$old_bundle"
    fi
done
shopt -u nullglob

printf 'Synced Mihomo %s (%s bytes, %s).\n' "$tag" "$asset_size" "$expected_sha256"
