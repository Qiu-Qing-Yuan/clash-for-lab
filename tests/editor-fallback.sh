#!/usr/bin/env bash

set -eu
set -o pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'test-editor-fallback: %s\n' "$*" >&2
    exit 1
}

set +u
. "$repo_root/script/common.sh"
. "$repo_root/script/upgrade.sh"
. "$repo_root/script/clashctl.sh"
set -u

# Extract just the editor-resolution logic from clashmixin so tests
# can exercise it without triggering _merge_config_restart.
_resolve_editor() {
    local editor
    editor=${EDITOR:-}
    [ -n "$editor" ] && command -v "$editor" >/dev/null 2>&1 ||
        editor=vim
    command -v "$editor" >/dev/null 2>&1 ||
        editor=vi
    command -v "$editor" >/dev/null 2>&1 ||
        editor=nano
    command -v "$editor" >/dev/null 2>&1 || return 1
    printf '%s\n' "$editor"
}

# Create fake editor binaries in a controlled PATH
fake_bin="$test_root/bin"
mkdir -p "$fake_bin"

# ── EDITOR env var is respected ─────────────────────────────────────

(
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$fake_bin/my-editor"
    chmod 0755 "$fake_bin/my-editor"

    result=$(EDITOR="$fake_bin/my-editor" _resolve_editor)
    [ "$result" = "$fake_bin/my-editor" ] || fail "EDITOR env var not used: got $result"
    rm -f "$fake_bin/my-editor"
)

# ── Falls back to vim when EDITOR is unset ──────────────────────────

(
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$fake_bin/vim"
    chmod 0755 "$fake_bin/vim"

    result=$(PATH="$fake_bin:/usr/bin:/bin" EDITOR= _resolve_editor)
    [ "$result" = "vim" ] || fail "vim fallback not used: got $result"
    rm -f "$fake_bin/vim"
)

# ── Falls back to vi when vim is missing ────────────────────────────

(
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$fake_bin/vi"
    chmod 0755 "$fake_bin/vi"

    result=$(PATH="$fake_bin" EDITOR= _resolve_editor)
    [ "$result" = "vi" ] || fail "vi fallback not used: got $result"
    rm -f "$fake_bin/vi"
)

# ── Falls back to nano when vi is also missing ─────────────────────

(
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$fake_bin/nano"
    chmod 0755 "$fake_bin/nano"

    result=$(PATH="$fake_bin" EDITOR= _resolve_editor)
    [ "$result" = "nano" ] || fail "nano fallback not used: got $result"
    rm -f "$fake_bin/nano"
)

# ── Error when no editor is available ──────────────────────────────

(
    result=$(PATH="$fake_bin" EDITOR= _resolve_editor 2>/dev/null || true)
    if [ -n "$result" ]; then
        fail "should fail when no editor is available, got: $result"
    fi
)

# ── EDITOR set but not installed falls through ───────────────────

(
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$fake_bin/vim"
    chmod 0755 "$fake_bin/vim"

    result=$(PATH="$fake_bin" EDITOR=nonexistent-editor-xyz _resolve_editor)
    [ "$result" = "vim" ] || fail "should fall through to vim when EDITOR is invalid: got $result"
    rm -f "$fake_bin/vim"
)

printf 'editor fallback tests passed\n'
