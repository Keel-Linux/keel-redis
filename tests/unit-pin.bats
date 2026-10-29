#!/usr/bin/env bats
# The unit-redis tag this recipe is built from. Until decision 0010's
# assembly step exists, the pin is the clone line in the Makefile and in
# README.rst, and the layer manifest records what bt-layer read from the
# component's version file as "units redis@<version>". All three have to say
# the same thing, and the pin cannot fall behind the first fix the layer
# depends on.
#
# unit-redis 1.0.4 is that fix: the ACL fragment its first boot hook writes
# is valid Redis configuration. 1.0.3 wrote a line of its comment without
# the "#", and redis-server refused to start on the published 19.0-7.
# (1.0.3 itself fixed the first boot freeze at the Redis password, where
# bin/redispass.py drew its box into the hook's command substitution.)

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    MINIMUM=1.0.4
}

# clone_tag FILE: the tag of the unit-redis clone line FILE documents
clone_tag() {
    grep -oE -- '--branch v[0-9]+(\.[0-9]+)+' "$1" | head -n 1 | sed 's/^--branch v//'
}

@test "the Makefile and README.rst clone the same unit-redis tag" {
    make_tag=$(clone_tag "$REPO/Makefile")
    readme_tag=$(clone_tag "$REPO/README.rst")
    [ -n "$make_tag" ]
    [ "$make_tag" = "$readme_tag" ]
}

@test "README.rst names the manifest entry of the tag it clones" {
    tag=$(clone_tag "$REPO/README.rst")
    grep -qF "units redis@$tag\`\`" "$REPO/README.rst"
    run grep -oE 'units redis@[0-9.]+' "$REPO/README.rst"
    [ "$(printf '%s\n' "${lines[@]}" | sort -u)" = "units redis@$tag" ]
}

@test "the pin carries the ACL fragment fix of unit-redis 1.0.4" {
    tag=$(clone_tag "$REPO/Makefile")
    [ "$(printf '%s\n%s\n' "$MINIMUM" "$tag" | sort -V | head -n 1)" = "$MINIMUM" ]
}
