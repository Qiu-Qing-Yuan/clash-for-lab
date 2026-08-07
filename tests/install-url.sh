#!/usr/bin/env bash

set -eu
set -o pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
repo_root=$(cd -- "$script_dir/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() {
    printf 'test-install-url: %s\n' "$*" >&2
    exit 1
}

set +u
. "$repo_root/script/common.sh"
. "$repo_root/script/upgrade.sh"
. "$repo_root/script/clashctl.sh"
set -u

# ── _is_valid_subscription_url accepts valid URLs ──────────────────

_is_valid_subscription_url 'http://example.com/sub' || fail 'http URL rejected'
_is_valid_subscription_url 'https://example.com/sub' || fail 'https URL rejected'
_is_valid_subscription_url 'https://example.com/sub?token=abc&client=mihomo' || fail 'URL with query rejected'
_is_valid_subscription_url 'https://user:pass@example.com/sub' || fail 'URL with auth rejected'

# ── _is_valid_subscription_url rejects invalid URLs ──────────────────

! _is_valid_subscription_url '' || fail 'empty URL accepted'
! _is_valid_subscription_url 'ftp://example.com/sub' || fail 'ftp URL accepted'
! _is_valid_subscription_url 'HTTP://example.com/sub' || fail 'uppercase scheme accepted'
! _is_valid_subscription_url 'example.com/sub' || fail 'scheme-less URL accepted'
! _is_valid_subscription_url 'https:// example.com/sub' || fail 'URL with space accepted'

# ── install.sh --url parameter parsing ──────────────────────────────
# We can't run install.sh end-to-end without a full environment, but
# we can verify the parameter parsing and URL validation logic by
# sourcing the relevant functions and testing the flow.

# Simulate the parameter parsing loop from install.sh
parse_install_args() {
    INSTALL_URL=""
    while [ $# -gt 0 ]; do
        case "$1" in
        --url)
            [ $# -ge 2 ] || { echo "ERROR: --url needs arg"; return 1; }
            INSTALL_URL=$2
            shift 2
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "ERROR: unknown arg $1"
            return 1
            ;;
        esac
    done

    if [ -n "$INSTALL_URL" ]; then
        _is_valid_subscription_url "$INSTALL_URL" || {
            echo "ERROR: invalid url"
            return 1
        }
    fi
    echo "OK"
    return 0
}

# Valid URL
[ "$(parse_install_args --url 'https://example.com/sub')" = "OK" ] ||
    fail 'valid --url rejected'

# URL with special chars (single-quoted by user)
[ "$(parse_install_args --url 'https://example.com/sub?token=abc&client=mihomo')" = "OK" ] ||
    fail 'URL with query params rejected'

# Missing URL argument
if parse_install_args --url 2>/dev/null; then
    fail '--url without argument should fail'
fi

# Unknown argument
if parse_install_args --bogus 2>/dev/null; then
    fail 'unknown argument should fail'
fi

# No arguments — OK (interactive mode)
[ "$(parse_install_args)" = "OK" ] || fail 'no args should be OK'

# Invalid URL format
if parse_install_args --url 'not-a-url' 2>/dev/null; then
    fail 'invalid URL should be rejected'
fi

printf 'install-url tests passed\n'
