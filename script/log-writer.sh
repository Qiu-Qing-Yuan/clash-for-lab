#!/usr/bin/env bash

set -Eeuo pipefail

log_file=${1:-}
max_bytes=${2:-8388608}

case "$max_bytes" in
''|*[!0-9]*) exit 2 ;;
esac
[ "$max_bytes" -ge 1024 ] && [ "$max_bytes" -le 67108864 ] || exit 2
[ -n "$log_file" ] || exit 2

umask 077
log_dir=$(dirname "$log_file")
mkdir -p "$log_dir"
[ -d "$log_dir" ] && [ ! -L "$log_dir" ] || exit 3

if [ -e "$log_file" ] || [ -L "$log_file" ]; then
    [ -f "$log_file" ] && [ ! -L "$log_file" ] || exit 3
else
    # Do not overwrite a path created before log initialization finishes.
    (set -C; : > "$log_file") || exit 3
fi
chmod 0600 "$log_file"

# Keep only the newest complete lines and cap the file at max_bytes. Replacing
# files concurrently from the same Unix account is outside the supported use
# model; normal clash commands are serialized by the operation lock.
LC_ALL=C awk -v destination="$log_file" -v maximum="$max_bytes" '
    function reset_log() {
        close(destination)
        printf "%s", "" > destination
        close(destination)
        used = 0
    }
    BEGIN { reset_log() }
    {
        line = $0 ORS
        size = length(line)
        if (size > maximum) {
            line = substr(line, size - maximum + 1)
            size = length(line)
        }
        if (used + size > maximum) reset_log()
        printf "%s", line >> destination
        fflush(destination)
        used += size
    }
    END { close(destination) }
'
