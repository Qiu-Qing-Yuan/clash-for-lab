#!/usr/bin/env bash

set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'test-log-writer: %s\n' "$*" >&2
    exit 1
}

log_file="$test_root/mihomo.log"
{
    index=0
    while [ "$index" -lt 200 ]; do
        printf 'entry-%03d-abcdefghijklmnopqrstuvwxyz\n' "$index"
        index=$((index + 1))
    done
} | "$repo_root/script/log-writer.sh" "$log_file" 1024

size=$(LC_ALL=C wc -c < "$log_file" | tr -d '[:space:]')
[ "$size" -le 1024 ] || fail "bounded writer produced $size bytes"
grep -Fq 'entry-199-' "$log_file" || fail 'bounded writer did not retain the newest output window'
if grep -Fq 'entry-000-' "$log_file"; then
    fail 'bounded writer retained the oldest output after crossing the limit'
fi
mode=$(stat -c '%a' "$log_file" 2>/dev/null || stat -f '%Lp' "$log_file")
[ "$mode" = 600 ] || fail "log mode is $mode instead of 600"

printf '%2048s\n' x | tr ' ' z | \
    "$repo_root/script/log-writer.sh" "$log_file" 1024
size=$(LC_ALL=C wc -c < "$log_file" | tr -d '[:space:]')
[ "$size" -le 1024 ] || fail 'a single oversized line escaped the byte ceiling'

victim="$test_root/victim"
printf '%s\n' 'do-not-touch' > "$victim"
symlink_log="$test_root/symlink.log"
ln -s "$victim" "$symlink_log"
if printf '%s\n' hostile | "$repo_root/script/log-writer.sh" "$symlink_log" 1024; then
    fail 'writer accepted a symbolic-link log target'
fi
[ "$(cat "$victim")" = 'do-not-touch' ] ||
    fail 'writer followed a symbolic-link log target'

fifo_log="$test_root/log.fifo"
mkfifo "$fifo_log"
if printf '%s\n' hostile | "$repo_root/script/log-writer.sh" "$fifo_log" 1024; then
    fail 'writer accepted a non-regular log target'
fi

printf '%s\n' 'log writer tests passed'
