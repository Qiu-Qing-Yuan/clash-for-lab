#!/usr/bin/env bash

set -Eeuo pipefail

# Mihomo prints its version as a whitespace-delimited token. Accept exactly one
# canonical stable token and reject suffixes such as -alpha, -rc.1, or .1.
awk '
    {
        for (field = 1; field <= NF; field++) {
            if ($field ~ /^v[0-9]+\.[0-9]+\.[0-9]+/ &&
                $field !~ /^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/) {
                invalid = 1
            }
            if ($field ~ /^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/) {
                count++
                version = $field
            }
        }
    }
    END {
        if (invalid || count != 1) {
            exit 1
        }
        print version
    }
'
