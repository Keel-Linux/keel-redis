# Coverage

Standard: decisions 0003 (90 percent per repository, 95 for code the project
writes) and 0004 (bats plus kcov for shell; a build and a boot on LXC as the
acceptance test of a recipe, docs/org-plan.md section 1).

## Measured 2026-09-28

| File | Test | Lines | Note |
| --- | --- | --- | --- |
| tests/lib/boot-test-lib.sh | tests/boot-test.bats (52 tests) | 100 percent (187/187) under kcov | argument parsing, address discovery, deadlines, the container marks, the client calls, the four verdicts, the role keel inspect reports, and the Webmin and diff verdicts |
| bin/keel-archive-check | tests/archive-check.bats (27 tests) | 100 percent (54/54) under kcov | the build time check that the archive copy in the build tree is the live archive, verified with gpgv and never trusted |
| conf.d/zz-project-packages | tests/project-packages.bats (15 tests) | 100 percent (33/33) under kcov | the build time check that each project package is the candidate of the archive, and a project build; then that no apt file of the image names the build time archive |
| Makefile, README.rst | tests/unit-pin.bats (3 tests) | static | the unit-redis tag cloned is the same in both, matches the manifest entry, and carries 1.0.3's first boot fix |
| overlay, conf.d/main | tests/apt-files.bats (3 tests) | static | no Keel source or 1001 pin in the overlay; the build time pin on the staging Label is written before the upgrade |
| conf.d/main | the build | integration only | build time script, 0004 pragmatic limits |
| tests/boot-test.sh | itself | integration only | the thin main of the acceptance test: keel and LXC as root |
| the first boot hook, its library, the component's conf | keel-linux/unit-redis | not this repository | 100 percent over 65 bats tests there |

Total over the three measured shell files: **100 percent (270/270)**,
92 bats tests. `tests/coverage.sh` fails below `COVERAGE_THRESHOLD`, which
the workflow sets to 100, the measured number. It is only ever raised
(decision 0006).

    $ COVERAGE_THRESHOLD=100 tests/coverage.sh
    kcov line coverage (threshold 100 percent):
     100.00  33/33  zz-project-packages
     100.00  187/187  boot-test-lib.sh
     100.00  54/54  keel-archive-check

This layer writes no first boot hook of its own, which is the difference
between its coverage table and keel-mariadb's or keel-postgresql's. The hook
that matters is `firstboot.d/35redispass` of the `unit.d/redis` component,
and it is measured in the repository that owns it. What this recipe writes
is the boot test's logic and the two build time checks, and all three are at
100 percent.

`bin/keel-archive-check` and `conf.d/zz-project-packages` are the fifth copy
of themselves in this organization, which is what tracker#8 is for: they
belong in `keel-linux/common` next to the removelist that already undoes
their work for every recipe at once. Copied here unchanged rather than
refactored, so that this layer lands with the archive verified rather than
waiting for a five repository change.

## What the boot test proves, line by line

`appliance / boot-published-layer` runs through the organization's
`test-appliance.yml` on the self-hosted `keel-lxc` runner, which fetches the
published layer from `https://mirror.keellinux.org/layers`, verifies it,
assembles it, boots it in LXC and runs `tests/boot-test.sh`. Nothing is built
there, so what boots is the published layer and not this branch: a pull request
that changes the recipe is not exercised by this check, which is why the job is
`boot-published-layer` and not the old `build-and-boot`. Until the layer is on
the mirror the check fails rather than passing, which is where this repository
stands today (keel-linux/.github pull request 12).

1. **The declared secret reaches the server.** The description declares
   `secrets.db_password` from a file, nothing is configured by hand, and the
   test authenticates as the ACL user that secret belongs to on `[::1]:6379`.
2. **The account can work, not only log in.** A value generated for the run
   is written and read back under a key.
3. **Nothing works without the secret.** The same client, with no account and
   no password, asks for a key and must be refused with `NOPERM`.
4. **Webmin answers over IPv6 on 12321**, and dpkg on the machine reports no
   Webmin module for Redis, which is checked rather than assumed. It is
   asked of dpkg and not of apt-cache: the image carries no package lists,
   because `conf.d/zz-project-packages` removes them with the build time
   archive, so a search here would answer nothing whatever the archive
   holds. Whether the archive offers one has an answer only at build time,
   and `conf.d/main` is where it is asked.
5. **`keel inspect` reads `database.server.role` off the running server** and
   says `standalone`. This is the seam the cloud modes of decision 0013 are
   built on, and it is why the declared secret is an ACL user: `requirepass`
   would lock `INFO` too, and inspect never reads a secret to get past a
   refusal.
6. **`keel diff` reports no drift.** Exit 13 is the expected code: the diff
   runs against the container's rootfs as an offline root, which cannot ask
   a server what it is, so the declared `database.server` section is unknown
   there rather than drift. The role itself is checked live, in step 5.

Every one of those verdicts reads the answer and never the exit code,
because **redis-cli exits 0 when the server replies with an error**. One unit
test drives each verdict with the text a wrong secret really produces.
