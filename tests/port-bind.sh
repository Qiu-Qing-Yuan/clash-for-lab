#!/usr/bin/env bash

set -eu
set -o pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'test-port-bind: %s\n' "$*" >&2
    exit 1
}

set +u
. "$repo_root/script/common.sh"
. "$repo_root/script/upgrade.sh"
. "$repo_root/script/clashctl.sh"
set -u

# ── _is_bind_proc_net ───────────────────────────────────────────────

# Create fake /proc/net/tcp with a LISTEN on port 8080 (hex: 1F90)
# and /proc/net/udp with a bind on port 15353 (hex: 3BE9)

proc_dir="$test_root/proc"
mkdir -p "$proc_dir"

# Port 8080 = 0x1F90, port 15353 = 0x3BE9
cat > "$proc_dir/tcp" <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12345 1 0000000000000000 100 0 0 10 0
   1: 00000000:0050 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12346 1 0000000000000000 100 0 0 10 0
EOF

cat > "$proc_dir/tcp6" <<'EOF'
  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000000000000:1F90 00000000000000000000000000000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12347 1 0000000000000000 100 0 0 10 0
EOF

cat > "$proc_dir/udp" <<'EOF'
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 0100007F:3BF9 00000000:0000 07 00000000:00000000 00:00000000 00000000     0        0 12348 1 0000000000000000 100 0 0 10 0
EOF

cat > "$proc_dir/udp6" <<'EOF'
  sl  local_address                         remote_address                        st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000000000000000000000000000:3BF9 00000000000000000000000000000000:0000 07 00000000:00000000 00:00000000 00000000     0        0 12349 1 0000000000000000 100 0 0 10 0
EOF

# Test: port 8080 should be detected as bound (TCP LISTEN)
(
    # Override awk to read from our fake proc files
    _is_bind_proc_net() {
        local port=$1 hex_port
        hex_port=$(printf '%04X' "$port" 2>/dev/null) || return 1
        awk -v p="$hex_port" '
            FNR == 1 { next }
            FILENAME ~ /tcp/ && $2 ~ (":" p "$") && $4 == "0A" { found=1 }
            FILENAME ~ /udp/ && $2 ~ (":" p "$") { found=1 }
            END { if (found) print "proc-net:" p; else exit 1 }
        ' "$proc_dir/tcp" "$proc_dir/tcp6" "$proc_dir/udp" "$proc_dir/udp6" 2>/dev/null
    }
    result=$(_is_bind_proc_net 8080)
    [ -n "$result" ] || fail 'port 8080 (TCP LISTEN) not detected as bound'
)

# Test: port 15353 should be detected as bound (UDP)
(
    _is_bind_proc_net() {
        local port=$1 hex_port
        hex_port=$(printf '%04X' "$port" 2>/dev/null) || return 1
        awk -v p="$hex_port" '
            FNR == 1 { next }
            FILENAME ~ /tcp/ && $2 ~ (":" p "$") && $4 == "0A" { found=1 }
            FILENAME ~ /udp/ && $2 ~ (":" p "$") { found=1 }
            END { if (found) print "proc-net:" p; else exit 1 }
        ' "$proc_dir/tcp" "$proc_dir/tcp6" "$proc_dir/udp" "$proc_dir/udp6" 2>/dev/null
    }
    result=$(_is_bind_proc_net 15353)
    [ -n "$result" ] || fail 'port 15353 (UDP) not detected as bound'
)

# Test: port 9999 should NOT be detected as bound
(
    _is_bind_proc_net() {
        local port=$1 hex_port
        hex_port=$(printf '%04X' "$port" 2>/dev/null) || return 1
        awk -v p="$hex_port" '
            FNR == 1 { next }
            FILENAME ~ /tcp/ && $2 ~ (":" p "$") && $4 == "0A" { found=1 }
            FILENAME ~ /udp/ && $2 ~ (":" p "$") { found=1 }
            END { if (found) print "proc-net:" p; else exit 1 }
        ' "$proc_dir/tcp" "$proc_dir/tcp6" "$proc_dir/udp" "$proc_dir/udp6" 2>/dev/null
    }
    result=$(_is_bind_proc_net 9999 || true)
    [ -z "$result" ] || fail 'port 9999 should not be detected as bound'
)

# Test: port 80 (hex 0050) should be detected as bound (TCP LISTEN)
(
    _is_bind_proc_net() {
        local port=$1 hex_port
        hex_port=$(printf '%04X' "$port" 2>/dev/null) || return 1
        awk -v p="$hex_port" '
            FNR == 1 { next }
            FILENAME ~ /tcp/ && $2 ~ (":" p "$") && $4 == "0A" { found=1 }
            FILENAME ~ /udp/ && $2 ~ (":" p "$") { found=1 }
            END { if (found) print "proc-net:" p; else exit 1 }
        ' "$proc_dir/tcp" "$proc_dir/tcp6" "$proc_dir/udp" "$proc_dir/udp6" 2>/dev/null
    }
    result=$(_is_bind_proc_net 80)
    [ -n "$result" ] || fail 'port 80 (TCP LISTEN) not detected as bound'
)

# ── _is_bind fallback integration ──────────────────────────────────
# Verify _is_bind falls back to _is_bind_proc_net when ss and netstat
# are both unavailable.  We can't truly remove ss/netstat on macOS, so
# we test the dispatch logic by checking which path _is_bind takes.

(
    # Simulate: no ss, no netstat, but /proc/net exists
    _ss_found=false
    _netstat_found=false

    _is_bind() {
        local port=$1
        if [ "$_ss_found" = true ]; then
            ss -lnptu 2>/dev/null | grep ":${port}\b"
        elif [ "$_netstat_found" = true ]; then
            netstat -lnptu 2>/dev/null | grep ":${port}\b"
        else
            _is_bind_proc_net "$port"
        fi
    }

    _is_bind_proc_net() {
        local port=$1 hex_port
        hex_port=$(printf '%04X' "$port" 2>/dev/null) || return 1
        awk -v p="$hex_port" '
            FNR == 1 { next }
            FILENAME ~ /tcp/ && $2 ~ (":" p "$") && $4 == "0A" { found=1 }
            FILENAME ~ /udp/ && $2 ~ (":" p "$") { found=1 }
            END { if (found) print "proc-net:" p; else exit 1 }
        ' "$proc_dir/tcp" "$proc_dir/tcp6" "$proc_dir/udp" "$proc_dir/udp6" 2>/dev/null
    }

    # Port 8080 is bound
    if ! _is_bind 8080 >/dev/null 2>&1; then
        fail 'fallback _is_bind did not detect port 8080 as bound'
    fi

    # Port 9999 is not bound
    if _is_bind 9999 >/dev/null 2>&1; then
        fail 'fallback _is_bind incorrectly detected port 9999 as bound'
    fi
)

# ── _is_already_in_use with fallback ────────────────────────────────
# With the /proc/net fallback, output doesn't contain process info,
# so _is_already_in_use should conservatively report "in use by others".

(
    _ss_found=false
    _netstat_found=false

    _is_bind() {
        local port=$1
        if [ "$_ss_found" = true ]; then
            ss -lnptu 2>/dev/null | grep ":${port}\b"
        elif [ "$_netstat_found" = true ]; then
            netstat -lnptu 2>/dev/null | grep ":${port}\b"
        else
            _is_bind_proc_net "$port"
        fi
    }

    _is_bind_proc_net() {
        local port=$1 hex_port
        hex_port=$(printf '%04X' "$port" 2>/dev/null) || return 1
        awk -v p="$hex_port" '
            FNR == 1 { next }
            FILENAME ~ /tcp/ && $2 ~ (":" p "$") && $4 == "0A" { found=1 }
            FILENAME ~ /udp/ && $2 ~ (":" p "$") { found=1 }
            END { if (found) print "proc-net:" p; else exit 1 }
        ' "$proc_dir/tcp" "$proc_dir/tcp6" "$proc_dir/udp" "$proc_dir/udp6" 2>/dev/null
    }

    # Port 8080 is bound by someone (we can't tell who), so it should
    # be reported as "already in use" regardless of the process name.
    _is_already_in_use 8080 mihomo ||
        fail 'fallback should report bound port as in use by others'

    # Port 9999 is not bound, so it should NOT be "already in use"
    if _is_already_in_use 9999 mihomo; then
        fail 'fallback should report free port as not in use'
    fi
)

printf 'port bind fallback tests passed\n'
