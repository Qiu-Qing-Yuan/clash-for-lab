#!/usr/bin/env bash

set -eu
set -o pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)
converter_pid=''
cleanup() {
    exit_status=$?
    trap - EXIT HUP INT TERM
    [ -z "$converter_pid" ] || kill "$converter_pid" 2>/dev/null || true
    [ -z "$converter_pid" ] || wait "$converter_pid" 2>/dev/null || true
    rm -rf -- "$test_root"
    exit "$exit_status"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'test-download-secrecy: %s\n' "$*" >&2
    exit 1
}

HOME="$test_root/home"
USER=tester
export HOME USER
mkdir -p "$HOME" "$test_root/bin"

# shellcheck source=../script/common.sh
set +u
. "$repo_root/script/common.sh"
set -u

cat > "$test_root/bin/curl" <<'FAKE_CURL'
#!/bin/sh
set -eu

for argument do
    case "$argument" in
    *PROCESS_SECRET*)
        printf '%s\n' 'subscription secret appeared in curl argv' >&2
        exit 90
        ;;
    esac
done

config=$(mktemp)
trap 'rm -f "$config"' EXIT HUP INT TERM
cat > "$config"
if ! grep -Fq 'PROCESS_SECRET' "$config" &&
    ! grep -Fq 'LOCAL_CONVERSION_SOURCE' "$config"; then
    printf '%s\n' 'curl did not receive a recognized private stdin config' >&2
    exit 91
fi
[ "${FAKE_CURL_FAIL:-false}" != true ] || exit 93
[ -z "${FAKE_CURL_CALL_LOG:-}" ] || printf '%s\n' call >> "$FAKE_CURL_CALL_LOG"

output=''
write_effective=false
while [ "$#" -gt 0 ]; do
    case "$1" in
    --output)
        output=$2
        shift 2
        ;;
    --write-out)
        write_effective=true
        shift 2
        ;;
    *) shift ;;
    esac
done

if [ "$write_effective" = true ]; then
    printf '%s' 'http://127.0.0.1:25500/sub?url=PROCESS_SECRET'
else
    [ -n "$output" ] || exit 92
    printf '%s\n' 'proxies: []' > "$output"
fi
FAKE_CURL
chmod 0755 "$test_root/bin/curl"

cat > "$test_root/bin/wget" <<'FAKE_WGET'
#!/bin/sh
set -eu

for argument do
    case "$argument" in
    *PROCESS_SECRET*)
        printf '%s\n' 'subscription secret appeared in wget argv' >&2
        exit 94
        ;;
    esac
done

url=$(cat)
case "$url" in
*PROCESS_SECRET*) ;;
*) exit 95 ;;
esac

output=''
while [ "$#" -gt 0 ]; do
    case "$1" in
    --output-document)
        output=$2
        shift 2
        ;;
    *) shift ;;
    esac
done
[ -n "$output" ] || exit 96
printf '%s\n' 'proxies: []' > "$output"
FAKE_WGET
chmod 0755 "$test_root/bin/wget"

PATH="$test_root/bin:$PATH"
export PATH

secret_url='https://provider.example/sub?token=PROCESS_SECRET'
raw_dest="$test_root/raw.yaml"
converted_dest="$test_root/converted.yaml"
conversion_source="$test_root/LOCAL_CONVERSION_SOURCE"
curl_call_log="$test_root/curl.calls"

_download_raw_config "$raw_dest" "$secret_url" ||
    fail 'private curl-config raw download failed'
grep -Fq 'proxies: []' "$raw_dest" || fail 'raw download did not publish output'

FAKE_CURL_FAIL=true
export FAKE_CURL_FAIL
wget_dest="$test_root/wget.yaml"
_download_raw_config "$wget_dest" "$secret_url" ||
    fail 'private-stdin wget fallback failed'
grep -Fq 'proxies: []' "$wget_dest" || fail 'wget fallback did not publish output'
unset FAKE_CURL_FAIL

BIN_SUBCONVERTER_PORT=25500
_start_convert() { return 0; }
_stop_convert() { return 0; }
printf '%s\n' 'ss://local-source' > "$conversion_source"
: > "$curl_call_log"
FAKE_CURL_CALL_LOG=$curl_call_log
export FAKE_CURL_CALL_LOG
_download_convert_config "$converted_dest" "$conversion_source" ||
    fail 'private curl-config conversion download failed'
unset FAKE_CURL_CALL_LOG
grep -Fq 'proxies: []' "$converted_dest" || fail 'conversion did not publish output'
[ "$(wc -l < "$curl_call_log" | tr -d '[:space:]')" = 1 ] ||
    fail 'local conversion made more than one curl request'

# A failed conversion must leave the downloaded snapshot intact and clean its
# private temporary output so callers can safely try a compatibility fallback.
printf '%s\n' 'original-download' > "$converted_dest"
FAKE_CURL_FAIL=true
export FAKE_CURL_FAIL
if _download_convert_config "$converted_dest" "$conversion_source"; then
    fail 'failed conversion was reported as successful'
fi
unset FAKE_CURL_FAIL
[ "$(cat "$converted_dest")" = original-download ] ||
    fail 'failed conversion replaced the downloaded snapshot'
if find "$test_root" -name 'converted.yaml.convert.*' -print -quit | grep -q .; then
    fail 'failed conversion retained a temporary output'
fi

# Subconverter request diagnostics can contain the full provider URL. Its raw
# stdout/stderr must not be retained even in a private log.
set +u
. "$repo_root/script/common.sh"
set -u
converter_dir="$test_root/converter"
mkdir -p "$converter_dir"
BIN_SUBCONVERTER_DIR="$converter_dir"
BIN_SUBCONVERTER="$converter_dir/subconverter"
BIN_SUBCONVERTER_CONFIG="$converter_dir/pref.yml"
BIN_SUBCONVERTER_LOG="$converter_dir/latest.log"
BIN_YQ="$test_root/bin/fake-yq"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$BIN_YQ"
printf '%s\n' '#!/bin/sh' \
    'printf "%s\\n" PROCESS_SECRET >&2' \
    'trap "exit 0" TERM INT' \
    'while :; do sleep 1; done' > "$BIN_SUBCONVERTER"
chmod 0755 "$BIN_YQ" "$BIN_SUBCONVERTER"
: > "$BIN_SUBCONVERTER_CONFIG"
_is_already_in_use() { return 1; }
_is_bind() { return 0; }
_capture_process_start_id() { printf '%s\n' test-start; }
_wait_for_process_exec_identity() { printf '%s\n' test-executable; }
_start_convert || fail 'converter output suppression fixture did not start'
converter_pid=$BIN_SUBCONVERTER_PID
sleep 0.1
kill "$converter_pid" 2>/dev/null || true
wait "$converter_pid" 2>/dev/null || true
converter_pid=''
if grep -Fq PROCESS_SECRET "$BIN_SUBCONVERTER_LOG"; then
    fail 'subconverter output persisted the subscription token'
fi

printf '%s\n' 'download secrecy tests passed'
