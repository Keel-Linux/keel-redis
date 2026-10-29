#!/bin/bash
# Line coverage of the shell this layer writes, measured with kcov over the
# bats suite (decision 0004). The measured files are the logic of the boot
# test, the build time archive check and the build time package check; the
# 95 percent bar of decision 0003 applies to all three. Exits 1 below the
# threshold, 2 when a tool is missing.
#
# What is not measured here, and where it is: the first boot hook, its
# library and the component's conf script belong to keel-linux/unit-redis
# and are measured there, at 100 percent over 65 bats tests. This layer
# writes no first boot hook of its own, because the component carries the
# one that matters and this recipe checks it rather than repeating it.
# tests/boot-test.sh is the thin main that runs keel and LXC as root and is
# exercised by the container run in test-appliance.yml; conf.d/main needs a
# chroot, a network and half an hour.
#
#   tests/coverage.sh [THRESHOLD]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
threshold="${1:-${COVERAGE_THRESHOLD:-95}}"

for tool in kcov bats; do
    if ! command -v "$tool" >/dev/null; then
        echo "$tool not found (apt-get install $tool)" >&2
        exit 2
    fi
done

report="${COVERAGE_DIR:-$(mktemp -d)}"
# The include pattern is the whitelist, so no exclude pattern is needed; an
# exclude of /tests/ would drop tests/lib/boot-test-lib.sh with it.
kcov --include-pattern=/tests/lib/boot-test-lib.sh,/bin/keel-project-packages \
    "$report" bats "$here"

json="$(find "$report" -mindepth 2 -maxdepth 2 -name coverage.json -not -path "*/kcov-merged/*" | head -1)"
echo
echo "kcov line coverage (threshold $threshold percent):"
awk -F'"' -v threshold="$threshold" '
    /^ *\{"file":/ {
        n = split($4, parts, "/")
        printf "%7.2f  %s/%s  %s", $8, $12, $16, parts[n]
        if ($8 + 0 < threshold) { printf "  BELOW THRESHOLD"; below = 1 }
        printf "\n"
        seen = 1
    }
    END {
        if (!seen) { print "no file measured"; exit 1 }
        exit below
    }' "$json"
