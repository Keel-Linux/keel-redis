# Tests of keel-redis

Two gates, and they need different machines.

## tests/coverage.sh: the shell, on a hosted runner

    apt-get install bats kcov shellcheck
    COVERAGE_THRESHOLD=100 tests/coverage.sh

Runs the whole bats suite under kcov and fails below the threshold. Nothing
in it needs root, a network, a server or LXC: `lxc-info` is a stub first in
PATH, the clock and sleep are functions, and the two build time checks run
against scratch trees. The workflow calls it through the organization's
`test-shell.yml` and the check is `tests / coverage`.

| File | What it covers |
| --- | --- |
| `boot-test.bats` | the logic of the boot test: argument parsing, address discovery, deadlines, the container marks, the client calls, the verdicts and the role reading |
| `archive-check.bats` | `bin/keel-archive-check`: the copy of the project archive proved against the live one and verified with gpgv |
| `project-packages.bats` | `conf.d/zz-project-packages`: what is installed checked against what the archive offers |

The first boot hook, its library and the component's conf script are not
here. They belong to `keel-linux/unit-redis` and are measured there.

## tests/boot-test.sh: the machine, on the self-hosted runner

    tests/boot-test.sh redis --bridge lxcbr0 --layers-dir /mnt/builds/layers

Root only, and executable: `test-appliance.yml` refuses to run a
`tests/boot-test.sh` that is not, with a message that names
`git update-index --chmod=+x`. Git keeps the bit, an editor that rewrites the
file does not. Assembles the published layer chain into an LXC rootfs, boots it
headless from `tests/instance.yaml` and checks the six things COVERAGE.md
lists. `--keep` leaves the container up for inspection; `--help` prints every
option.

It builds nothing: the layers come from the mirror or from a directory
`bt-layer` wrote, so the test needs no fab, deck or buildtasks. The
organization's `test-appliance.yml` calls it after `keel pull` and
`keel verify`, and the check is `appliance / boot-published-layer`.

Two things that have cost time before and are handled in `bt_lxc_config` and
`bt_mark_container`, both in `tests/lib/boot-test-lib.sh`:

- **The apparmor pair.** Debian's `redis-server.service` carries
  `ProtectSystem=strict`, `ProtectHome=true`, `PrivateTmp`, `PrivateUsers`
  and `RestrictNamespaces`. Under the stock LXC container profile systemd
  cannot give a unit a mount namespace, so the server would fail with
  `status=226/NAMESPACE` before its own first line ran, the first boot hook
  could not set the declared secret, and nothing would answer on 6379.
  `lxc.apparmor.profile = generated` and `lxc.apparmor.allow_nesting = 1`
  are what a container running systemd needs.
- **The container marks.** The marker under `/var/lib/turnkey-info` and
  `REDIRECT_OUTPUT=true` with a drop-in, without which a first boot hook that
  prints more than the terminal buffer holds blocks writing to a `tty1`
  nobody reads.

## The convention the verdicts follow

`redis-cli` exits 0 when the server answers with an error: a wrong password
prints `AUTH failed: WRONGPASS ...` and exits 0, and a refused command prints
`NOPERM ...` and exits 0. So every verdict in the library reads the answer,
and every one of them has a unit test driving it with the text a real refusal
produces. A check written on `$?` would pass against a server that refused
everything.
