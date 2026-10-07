#!/usr/bin/env bats
# The unit-redis tag this recipe is built from. Until decision 0010's
# assembly step exists, the pin is the clone line in the Makefile and in
# README.rst, and the layer manifest records what bt-layer read from the
# component's version file as "units redis@<version>". All three have to say
# the same thing, and the pin cannot fall behind the first fix the layer
# depends on.
#
# unit-redis 1.0.3 is that fix: bin/redispass.py draws its password box on
# the terminal. Up to 1.0.2 an interactive first boot froze at the Redis
# password, with the box drawn into the hook's command substitution.

setup() {
    REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    MINIMUM=1.0.3
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

@test "the pin carries the first boot freeze fix of unit-redis 1.0.3" {
    tag=$(clone_tag "$REPO/Makefile")
    [ "$(printf '%s\n%s\n' "$MINIMUM" "$tag" | sort -V | head -n 1)" = "$MINIMUM" ]
}
