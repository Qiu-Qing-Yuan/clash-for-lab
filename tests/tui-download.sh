#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT

fail() {
    printf 'test-tui-download: %s\n' "$*" >&2
    exit 1
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

fixtures="$test_dir/fixtures"
fake_bin="$test_dir/bin"
mkdir -p "$fixtures" "$fake_bin"

printf '#!/usr/bin/env bash\nprintf "verified tui\\n"\n' >"$fixtures/clashctl-Linux"
chmod 0755 "$fixtures/clashctl-Linux"
asset_size=$(LC_ALL=C wc -c <"$fixtures/clashctl-Linux" | tr -d '[:space:]')
asset_sha256=$(sha256_file "$fixtures/clashctl-Linux")
canonical_url='https://github.com/SaladDay/clashctl/releases/download/v0.3.6/clashctl-Linux'

write_release() {
    local draft=$1 prerelease=$2 digest=$3 size=$4 url=$5 copies=${6:-1} state=${7:-uploaded}
    local digest_is_null=false
    [ "$digest" = null ] && digest_is_null=true

    jq -n \
        --argjson draft "$draft" \
        --argjson prerelease "$prerelease" \
        --arg digest "$digest" \
        --argjson digest_is_null "$digest_is_null" \
        --arg size "$size" \
        --arg url "$url" \
        --arg state "$state" \
        --argjson copies "$copies" '
            {
                tag_name: "v0.3.6",
                draft: $draft,
                prerelease: $prerelease,
                assets: [range(0; $copies) | {
                    name: "clashctl-Linux",
                    state: $state,
                    size: ($size | tonumber? // $size),
                    digest: (if $digest_is_null then null else $digest end),
                    browser_download_url: $url
                }]
            }
        ' >"$fixtures/release.json"
}

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

output=''
url=''
while (($#)); do
    case $1 in
        --output)
            output=${2-}
            shift 2
            ;;
        --proto | --proto-redir | --connect-timeout | --max-time | --retry | -H)
            shift 2
            ;;
        --disable | --silent | --show-error | --fail | --location | --tlsv1.2)
            shift
            ;;
        *)
            url=$1
            shift
            ;;
    esac
done

printf '%s\t%s\n' "$url" "$output" >>"$TUI_TEST_CURL_LOG"
case $url in
    https://api.github.com/repos/saladday/clashctl/releases/latest)
        cp "$TUI_TEST_FIXTURES/release.json" "$output"
        ;;
    https://github.com/SaladDay/clashctl/releases/download/v0.3.6/clashctl-Linux)
        [ "${TUI_TEST_ASSET_FAILURE:-false}" = false ] || exit 22
        cp "$TUI_TEST_DOWNLOAD" "$output"
        ;;
    *)
        printf 'unexpected URL: %s\n' "$url" >&2
        exit 1
        ;;
esac
EOF
chmod 0755 "$fake_bin/curl"

cat >"$fake_bin/mv" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${1-} == -f ]]; then
    shift
fi
source_path=${1-}
dest_path=${2-}

if [[ $dest_path == */clashctl-tui ]]; then
    [[ $(dirname "$source_path") == "$(dirname "$dest_path")" ]] || {
        printf 'publish crossed filesystems\n' >&2
        exit 1
    }
    [[ $(basename "$source_path") == .clashctl-tui.* ]] || {
        printf 'publish source was not a unique TUI temporary file\n' >&2
        exit 1
    }
    [[ -x $source_path ]] || {
        printf 'publish source was not executable\n' >&2
        exit 1
    }
    cmp -s "$TUI_TEST_EXPECTED_ASSET" "$source_path" || {
        printf 'publish source was incomplete\n' >&2
        exit 1
    }
    printf '%s\t%s\n' "$source_path" "$dest_path" >>"$TUI_TEST_MV_LOG"
fi

/bin/mv -f "$source_path" "$dest_path"
EOF
chmod 0755 "$fake_bin/mv"

run_download() (
    local case_dir=$1
    mkdir -p "$case_dir/home" "$case_dir/tmp"
    export HOME="$case_dir/home"
    export USER=tui-test
    export TMPDIR="$case_dir/tmp"
    export TMP="$TMPDIR"
    export TEMP="$TMPDIR"
    export PATH="$fake_bin:$PATH"
    export TUI_TEST_FIXTURES="$fixtures"
    export TUI_TEST_DOWNLOAD="${TUI_TEST_DOWNLOAD:-$fixtures/clashctl-Linux}"
    export TUI_TEST_EXPECTED_ASSET="$fixtures/clashctl-Linux"
    export TUI_TEST_CURL_LOG="$case_dir/curl.log"
    export TUI_TEST_MV_LOG="$case_dir/mv.log"
    export ZSH_VERSION=''
    export fish_version=''

    set +u
    # shellcheck source=../script/common.sh
    . "$repo_root/script/common.sh"
    set -u

    _okcat() { :; }
    _failcat() {
        printf '%s\n' "$*" >&2
        return 1
    }

    _download_tui
)

assert_no_temps() {
    local bin_dir=$1
    if find "$bin_dir" -maxdepth 1 -type f \( -name '.clashctl-release.*' -o -name '.clashctl-tui.*' \) | grep -q .; then
        fail "temporary download files were left in $bin_dir"
    fi
}

assert_failure_preserves_target() {
    local name=$1
    local case_dir="$test_dir/$name"
    local dest="$case_dir/home/tools/mihomo/bin/clashctl-tui"
    mkdir -p "$(dirname "$dest")"
    printf 'existing tui\n' >"$dest"
    chmod 0755 "$dest"

    if run_download "$case_dir" >"$case_dir/output.log" 2>&1; then
        fail "$name was accepted"
    fi
    [[ $(cat "$dest") == 'existing tui' ]] || fail "$name overwrote the existing TUI"
    [[ -x $dest ]] || fail "$name changed the existing TUI mode"
    assert_no_temps "$(dirname "$dest")"
}

write_release false false "sha256:$asset_sha256" "$asset_size" "$canonical_url"
success_dir="$test_dir/success"
success_dest="$success_dir/home/tools/mihomo/bin/clashctl-tui"
mkdir -p "$(dirname "$success_dest")"
printf 'existing tui\n' >"$success_dest"
chmod 0755 "$success_dest"
run_download "$success_dir" >/dev/null
cmp -s "$fixtures/clashctl-Linux" "$success_dest" || fail 'verified TUI was not published'
[[ -x $success_dest ]] || fail 'published TUI is not executable'
[[ $(wc -l <"$success_dir/mv.log" | tr -d '[:space:]') == 1 ]] || fail 'TUI was not published with one atomic rename'
[[ $(wc -l <"$success_dir/curl.log" | tr -d '[:space:]') == 2 ]] || fail 'unexpected number of GitHub requests'
awk -F '\t' -v dir="$(dirname "$success_dest")" '$2 !~ "^" dir "/\\.clashctl-" { exit 1 }' "$success_dir/curl.log" ||
    fail 'download temporary files were not created beside the target'
grep -Fq $'https://api.github.com/repos/saladday/clashctl/releases/latest\t' "$success_dir/curl.log" ||
    fail 'latest release API URL was not used'
grep -Fq "$canonical_url" "$success_dir/curl.log" || fail 'canonical GitHub asset URL was not used'
assert_no_temps "$(dirname "$success_dest")"

write_release false true "sha256:$asset_sha256" "$asset_size" "$canonical_url"
assert_failure_preserves_target prerelease

write_release true false "sha256:$asset_sha256" "$asset_size" "$canonical_url"
assert_failure_preserves_target draft

write_release false false null "$asset_size" "$canonical_url"
assert_failure_preserves_target missing-digest

write_release false false 'sha256:not-a-hash' "$asset_size" "$canonical_url"
assert_failure_preserves_target malformed-digest

write_release false false "sha256:$asset_sha256" "$((asset_size + 1))" "$canonical_url"
assert_failure_preserves_target size-mismatch

bad_sha=$(printf '0%.0s' {1..64})
write_release false false "sha256:$bad_sha" "$asset_size" "$canonical_url"
assert_failure_preserves_target checksum-mismatch

write_release false false "sha256:$asset_sha256" "$asset_size" 'https://example.com/clashctl-Linux'
assert_failure_preserves_target foreign-url

write_release false false "sha256:$asset_sha256" "$asset_size" "$canonical_url" 2
assert_failure_preserves_target duplicate-asset

write_release false false "sha256:$asset_sha256" "$asset_size" "$canonical_url" 1 new
assert_failure_preserves_target non-uploaded-asset

write_release false false "sha256:$asset_sha256" "$asset_size" "$canonical_url"
export TUI_TEST_ASSET_FAILURE=true
assert_failure_preserves_target download-failure
unset TUI_TEST_ASSET_FAILURE

printf 'tui download tests passed\n'
