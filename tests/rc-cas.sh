#!/usr/bin/env bash

set -eu
set -o pipefail

script_dir=$(cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)

cleanup() {
    exit_code=$?
    trap - EXIT HUP INT TERM
    rm -rf -- "$test_root"
    exit "$exit_code"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'test-rc: %s\n' "$*" >&2
    exit 1
}

file_mode() {
    if stat -c '%a' "$1" >/dev/null 2>&1; then
        stat -c '%a' "$1"
    else
        stat -f '%Lp' "$1"
    fi
}

# shellcheck source=../script/common.sh
set +u
. "$repo_root/script/common.sh"
set -u

MIHOMO_SCRIPT_DIR="$test_root/script's dir"
SHELL_RC_ZSH=
canonical_line=$(_rc_managed_line)

# Set and unset preserve unrelated content and the original file mode.
normal_dir="$test_root/normal"
mkdir -p "$normal_dir"
SHELL_RC_BASH="$normal_dir/bashrc"
legacy_line="source ${MIHOMO_SCRIPT_DIR}/common.sh && source ${MIHOMO_SCRIPT_DIR}/clashctl.sh && watch_proxy"
printf '%s\n' 'export KEEP=1' "$legacy_line" > "$SHELL_RC_BASH"
chmod 0640 "$SHELL_RC_BASH"

_set_rc || fail 'set failed'
[ "$(file_mode "$SHELL_RC_BASH")" = 640 ] || fail 'set changed file mode'
[ "$(grep -Fxc "$canonical_line" "$SHELL_RC_BASH")" = 1 ] ||
    fail 'set did not write exactly one managed line'
grep -Fxq 'export KEEP=1' "$SHELL_RC_BASH" || fail 'set removed unrelated content'
if grep -Fxq "$legacy_line" "$SHELL_RC_BASH"; then
    fail 'set retained the legacy managed line'
fi

cp "$SHELL_RC_BASH" "$normal_dir/after-first-set"
_set_rc || fail 'second set failed'
cmp -s "$normal_dir/after-first-set" "$SHELL_RC_BASH" || fail 'set is not idempotent'

_set_rc unset || fail 'unset failed'
[ "$(file_mode "$SHELL_RC_BASH")" = 640 ] || fail 'unset changed file mode'
[ "$(cat "$SHELL_RC_BASH")" = 'export KEEP=1' ] || fail 'unset changed unrelated content'

# A dotfile-manager symlink remains a symlink and its target is updated.
link_dir="$test_root/link"
mkdir -p "$link_dir/target"
printf '%s\n' 'export LINK_KEEP=1' > "$link_dir/target/bashrc"
chmod 0600 "$link_dir/target/bashrc"
ln -s target/bashrc "$link_dir/bashrc"
SHELL_RC_BASH="$link_dir/bashrc"

_set_rc || fail 'symlink set failed'
[ -L "$SHELL_RC_BASH" ] || fail 'set replaced the symlink'
[ "$(readlink "$SHELL_RC_BASH")" = target/bashrc ] || fail 'set changed the symlink target'
[ "$(file_mode "$link_dir/target/bashrc")" = 600 ] || fail 'set changed target mode'
grep -Fxq 'export LINK_KEEP=1' "$link_dir/target/bashrc" || fail 'set removed target content'
grep -Fxq "$canonical_line" "$link_dir/target/bashrc" || fail 'set did not update target'

# Unset ignores an absent RC file; set creates it privately.
missing_dir="$test_root/missing"
mkdir -p "$missing_dir"
SHELL_RC_BASH="$missing_dir/bashrc"
_set_rc unset || fail 'unset rejected an absent RC file'
[ ! -e "$SHELL_RC_BASH" ] || fail 'unset created an absent RC file'
_set_rc || fail 'set did not create an absent RC file'
[ "$(file_mode "$SHELL_RC_BASH")" = 600 ] || fail 'new RC file is not private'

# Directories and special files are never rewritten as shell configuration.
bad_dir="$test_root/bad"
mkdir -p "$bad_dir/rc-directory"
SHELL_RC_BASH="$bad_dir/rc-directory"
if _set_rc; then
    fail 'set accepted a directory'
fi

if command -v mkfifo >/dev/null 2>&1; then
    mkfifo "$bad_dir/rc-fifo"
    SHELL_RC_BASH="$bad_dir/rc-fifo"
    if _set_rc; then
        fail 'set accepted a FIFO'
    fi
fi

printf '%s\n' 'RC tests passed'
