#!/usr/bin/env bats
# The appliance manifest the overlay ships: present, named for the file,
# honest about Core as its base. The full schema check is keel's own
# (keel.manifest resolves it on the machine); these checks keep the file
# itself from drifting in this repository, with no dependency beyond grep.
# Found by the 2026-10-13 BR1+BR2 pair test (evidence/2026-10-13-step12-pair-br1-br2.md):
# the image carried only core.yaml, so a spec could not name the appliance
# and the pair flow was unreachable.

bats_require_minimum_version 1.5.0

MANIFEST=overlay/usr/share/keel/appliances/redis.yaml

@test "manifest: the overlay ships it" {
    [[ -f $MANIFEST ]]
}

@test "manifest: the name matches the file, the base is core" {
    grep -qx "name: redis" "$MANIFEST"
    grep -qx "base: core" "$MANIFEST"
    grep -qx "manifest_version: 1" "$MANIFEST"
}

@test "manifest: it declares the mesh port and a check on it" {
    grep -q "port: 6379" "$MANIFEST"
    grep -q "protocol: redis" "$MANIFEST"
}

@test "manifest: it declares the shared database secret" {
    grep -q "name: db_password" "$MANIFEST"
    grep -q "shared: true" "$MANIFEST"
}

@test "manifest: no tabs, no CRLF" {
    run ! grep -q $'\t' "$MANIFEST"
    run ! grep -q $'\r' "$MANIFEST"
}
