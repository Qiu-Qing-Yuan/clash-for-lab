#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
test_dir=$(mktemp -d)
trap 'rm -rf -- "$test_dir"' EXIT

fail() {
    printf 'test-sync-mihomo: %s\n' "$*" >&2
    exit 1
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

workflow="$repo_root/.github/workflows/sync-mihomo.yml"
grep -Eq '^[[:space:]]+repository_dispatch:' "$workflow" ||
    fail 'sync workflow has no default-branch-only manual event'
if grep -Eq '^[[:space:]]+workflow_dispatch:' "$workflow"; then
    fail 'sync workflow permits a caller-selected ref'
fi
grep -Fq 'ref: refs/heads/main' "$workflow" ||
    fail 'sync workflow does not resolve its base from main'
resolved_ref='ref: ${{ needs.resolve-main.outputs.sha }}'
resolved_ref_count=$(grep -Fc "$resolved_ref" "$workflow" || true)
[[ $resolved_ref_count == 2 ]] ||
    fail 'verify and publish are not pinned to the same resolved main commit'
if grep -Fq 'github.sha' "$workflow"; then
    fail 'sync workflow trusts the event ref instead of the resolved main commit'
fi
if grep -Eq 'git (rebase|merge)' "$workflow"; then
    fail 'sync workflow can incorporate code that was not verified in this run'
fi
grep -Fq 'if [ "$remote_sha" != "$base_sha" ]' "$workflow" ||
    fail 'sync workflow does not refuse publication after main advances'

version_parser="$repo_root/tools/parse-mihomo-version.sh"
stable_version=$(printf '%s\n' 'Mihomo Meta v1.19.29 linux amd64' | "$version_parser") ||
    fail 'strict version parser rejected a stable version'
[[ $stable_version == v1.19.29 ]] || fail 'strict version parser returned the wrong version'
for invalid_output in \
    'Mihomo Meta v1.19.29-alpha linux amd64' \
    'Mihomo Meta v1.19.29-rc.1 linux amd64' \
    'Mihomo Meta v1.19.29.1 linux amd64' \
    'Mihomo Meta v01.19.29 linux amd64' \
    'Mihomo Meta v1.19.29 linux amd64 v1.19.29'; do
    if printf '%s\n' "$invalid_output" | "$version_parser" >/dev/null 2>&1; then
        fail "strict version parser accepted: $invalid_output"
    fi
done

worktree="$test_dir/repo"
fixture_dir="$test_dir/fixtures"
fake_bin="$test_dir/bin"
mkdir -p "$worktree/tools" "$worktree/resources/zip" "$fixture_dir" "$fake_bin"
cp "$repo_root/tools/sync-mihomo.sh" "$worktree/tools/sync-mihomo.sh"

candidate="$fixture_dir/mihomo"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "Mihomo Meta v1.10.0 linux amd64\\n"' >"$candidate"
chmod 0755 "$candidate"
gzip -n -c "$candidate" >"$fixture_dir/asset.gz"
asset_size=$(LC_ALL=C wc -c <"$fixture_dir/asset.gz" | tr -d '[:space:]')
asset_sha256=$(sha256_file "$fixture_dir/asset.gz")

write_release() {
    local prerelease=$1
    local digest=$2
    local copies=${3:-1}
    local tag=${4:-v1.10.0}
    local size=${5:-$asset_size}
    local asset_name="mihomo-linux-amd64-v1-${tag}.gz"
    local download_url="https://github.com/MetaCubeX/mihomo/releases/download/${tag}/${asset_name}"

    jq -n \
        --argjson prerelease "$prerelease" \
        --arg tag "$tag" \
        --arg name "$asset_name" \
        --argjson size "$size" \
        --arg digest "sha256:$digest" \
        --arg url "$download_url" \
        --argjson copies "$copies" '
            {
                tag_name: $tag,
                draft: false,
                prerelease: $prerelease,
                assets: [range(0; $copies) | {
                    name: $name,
                    state: "uploaded",
                    size: $size,
                    digest: $digest,
                    browser_download_url: $url
                }]
            }
        ' >"$fixture_dir/release.json"
}

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

output=''
url=''
while (($#)); do
    case $1 in
        --output | --header | --retry | --connect-timeout | --proto | --max-time)
            output_value=${2-}
            if [[ $1 == --output ]]; then
                output=$output_value
            fi
            shift 2
            ;;
        --*)
            shift
            ;;
        *)
            url=$1
            shift
            ;;
    esac
done

case $url in
    https://api.github.com/repos/MetaCubeX/mihomo/releases/latest)
        cp "$SYNC_TEST_FIXTURES/release.json" "$output"
        ;;
    https://github.com/MetaCubeX/mihomo/releases/download/*)
        cp "$SYNC_TEST_FIXTURES/asset.gz" "$output"
        ;;
    *)
        printf 'unexpected URL: %s\n' "$url" >&2
        exit 1
        ;;
esac
EOF
chmod 0755 "$fake_bin/curl"

printf 'old bundle\n' >"$worktree/resources/zip/mihomo-linux-amd64-compatible-v1.0.0.gz"
write_release false "$asset_sha256"

PATH="$fake_bin:$PATH" SYNC_TEST_FIXTURES="$fixture_dir" \
    "$worktree/tools/sync-mihomo.sh" >/dev/null

stable_bundle="$worktree/resources/zip/mihomo-linux-amd64-v1.gz"
[[ -f $stable_bundle ]] || fail "stable bundle was not created"
cmp -s "$fixture_dir/asset.gz" "$stable_bundle" || fail "stable bundle content changed"
[[ ! -e $worktree/resources/zip/mihomo-linux-amd64-compatible-v1.0.0.gz ]] ||
    fail "old bundle was not removed"

expected_lock=$(printf 'schema\t1\nasset\tlinux\tamd64\tv1\tv1.10.0\tmihomo-linux-amd64-v1.gz\t%s\t%s' \
    "$asset_size" "$asset_sha256")
actual_lock=$(cat "$worktree/resources/mihomo.lock.tsv")
[[ $actual_lock == "$expected_lock" ]] || fail "lock file does not match the protocol"

published_lock="$test_dir/published.lock.tsv"
published_bundle="$test_dir/published.gz"
cp "$worktree/resources/mihomo.lock.tsv" "$published_lock"
cp "$stable_bundle" "$published_bundle"

assert_published_files_unchanged() {
    local label=$1

    cmp -s "$published_lock" "$worktree/resources/mihomo.lock.tsv" ||
        fail "$label changed the published lock file"
    cmp -s "$published_bundle" "$stable_bundle" ||
        fail "$label changed the published bundle"
}

write_release false "$asset_sha256"
PATH="$fake_bin:$PATH" SYNC_TEST_FIXTURES="$fixture_dir" \
    "$worktree/tools/sync-mihomo.sh" >/dev/null
assert_published_files_unchanged "idempotent sync"

changed_digest=$(printf '0%.0s' {1..64})
write_release false "$changed_digest"
if PATH="$fake_bin:$PATH" SYNC_TEST_FIXTURES="$fixture_dir" \
    "$worktree/tools/sync-mihomo.sh" >"$test_dir/changed-digest.log" 2>&1; then
    fail "changed digest for an existing tag was accepted"
fi
grep -q 'asset metadata changed after it was locked' "$test_dir/changed-digest.log" ||
    fail "same-tag digest rejection did not explain the error"
assert_published_files_unchanged "same-tag digest rejection"

write_release false "$asset_sha256" 1 v1.10.0 "$((asset_size + 1))"
if PATH="$fake_bin:$PATH" SYNC_TEST_FIXTURES="$fixture_dir" \
    "$worktree/tools/sync-mihomo.sh" >"$test_dir/changed-size.log" 2>&1; then
    fail "changed size for an existing tag was accepted"
fi
grep -q 'asset metadata changed after it was locked' "$test_dir/changed-size.log" ||
    fail "same-tag size rejection did not explain the error"
assert_published_files_unchanged "same-tag size rejection"

write_release false "$asset_sha256" 1 v1.9.99
if PATH="$fake_bin:$PATH" SYNC_TEST_FIXTURES="$fixture_dir" \
    "$worktree/tools/sync-mihomo.sh" >"$test_dir/downgrade.log" 2>&1; then
    fail "older stable release was accepted"
fi
grep -q 'latest stable release v1.9.99 is older than locked release v1.10.0' \
    "$test_dir/downgrade.log" || fail "downgrade rejection did not explain the error"
assert_published_files_unchanged "downgrade rejection"

write_release true "$asset_sha256"
if PATH="$fake_bin:$PATH" SYNC_TEST_FIXTURES="$fixture_dir" \
    "$worktree/tools/sync-mihomo.sh" >"$test_dir/prerelease.log" 2>&1; then
    fail "prerelease was accepted"
fi
grep -q 'latest release is a prerelease' "$test_dir/prerelease.log" ||
    fail "prerelease rejection did not explain the error"
assert_published_files_unchanged "prerelease rejection"

write_release false "$changed_digest" 1 v1.10.1
if PATH="$fake_bin:$PATH" SYNC_TEST_FIXTURES="$fixture_dir" \
    "$worktree/tools/sync-mihomo.sh" >"$test_dir/digest.log" 2>&1; then
    fail "bad digest was accepted"
fi
grep -q 'asset SHA-256 mismatch' "$test_dir/digest.log" ||
    fail "digest rejection did not explain the error"
assert_published_files_unchanged "download digest rejection"

write_release false "$asset_sha256" 2 v1.10.1
if PATH="$fake_bin:$PATH" SYNC_TEST_FIXTURES="$fixture_dir" \
    "$worktree/tools/sync-mihomo.sh" >"$test_dir/duplicate.log" 2>&1; then
    fail "duplicate asset was accepted"
fi
grep -q 'does not contain exactly one' "$test_dir/duplicate.log" ||
    fail "duplicate asset rejection did not explain the error"
assert_published_files_unchanged "duplicate asset rejection"

printf 'sync-mihomo tests passed\n'
