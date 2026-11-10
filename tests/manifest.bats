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
    grep -qF "command: [/usr/bin/redis-cli, -h, '::1', -p, '6379', INFO, server]" "$MANIFEST"
}

@test "manifest: the check is not Monit's redis protocol, which the default account refuses" {
    # Monit's redis test sends PING and takes only +PONG or -NOAUTH. The
    # default account of unit-redis may run INFO only, so Redis answers
    # -NOPERM, and Monit restarts a server that works (Monit 5.34.3 and
    # Redis 8.0.2 of Debian 13, 2026-11-10)
    run ! grep -qE "protocol: *redis" "$MANIFEST"
}

@test "manifest: it declares the shared database secret" {
    grep -q "name: db_password" "$MANIFEST"
    grep -q "shared: true" "$MANIFEST"
}

@test "manifest: no tabs, no CRLF" {
    run ! grep -q $'\t' "$MANIFEST"
    run ! grep -q $'\r' "$MANIFEST"
}

@test "manifest: simple is the only installation mode (0076)" {
    grep -qx 'modes: \[simple\]' "$MANIFEST"
}

# keel_as_root ARGS...: keel from KEEL_SRC as root: keel refuses a hook
# file that root does not own, and the scratch root is the test's own, so a
# test that is not root runs it in a user namespace where it is root
keel_as_root() {
    local wrap=()
    [ "$(id -u)" = 0 ] || wrap=(unshare -r)
    "${wrap[@]}" env PYTHONPATH="$KEEL_SRC" python3 -m keel "$@"
}

@test "manifest: keel resolves it along core (KEEL_SRC and KEEL_MANIFEST_SOURCES)" {
    [ -n "${KEEL_SRC:-}" ] || skip "KEEL_SRC is not set"
    run tests/lib/manifest-root.sh "$BATS_TEST_TMPDIR/root" "$MANIFEST"
    [ "$status" -eq 0 ]
    run keel_as_root manifest validate --root "$BATS_TEST_TMPDIR/root" redis
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "manifest: keel writes a Monit program check of redis-cli INFO, and no redis protocol test" {
    [ -n "${KEEL_SRC:-}" ] || skip "KEEL_SRC is not set"
    run tests/lib/manifest-root.sh "$BATS_TEST_TMPDIR/root" "$MANIFEST"
    [ "$status" -eq 0 ]
    local wrap=()
    [ "$(id -u)" = 0 ] || wrap=(unshare -r)
    run "${wrap[@]}" env PYTHONPATH="$KEEL_SRC" python3 - "$BATS_TEST_TMPDIR/root" <<'PY'
import sys
from keel.manifest.facts import gather
from keel.manifest import monit
found = gather(sys.argv[1], "redis")
states = {name: modes["simple"] for name, modes in found.defaults.items()}
print(monit.render(found.resolved, states, None, ("/usr/bin/keel", "notify"), 120).text)
PY
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *'check program keel-check-redis with path "/usr/bin/redis-cli -h ::1 -p 6379 INFO server"'* ]]
    [[ "$output" != *"protocol redis"* ]]
}

@test "manifest: the commissioning contract's instance holds against it, with no warning" {
    # the runner writes each secret:NAME of instance.secrets as a file
    # (contract.py of keel-commission), so the spec here does the same
    [ -n "${KEEL_SRC:-}" ] || skip "KEEL_SRC is not set"
    run tests/lib/manifest-root.sh "$BATS_TEST_TMPDIR/root" "$MANIFEST"
    [ "$status" -eq 0 ]
    python3 - tests/commission.yaml > "$BATS_TEST_TMPDIR/spec.yaml" <<'PY'
import sys, yaml
spec = yaml.safe_load(open(sys.argv[1]))["instance"]
spec["secrets"] = {key: {"file": "/etc/keel/secrets/" + key} for key in spec["secrets"]}
print(yaml.safe_dump(spec, sort_keys=False))
PY
    run keel_as_root spec validate --spec "$BATS_TEST_TMPDIR/spec.yaml" --no-secret-files --root "$BATS_TEST_TMPDIR/root"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" != *Warning* ]]
}

@test "manifest: the commissioning contract's instance names redis, simple, the five overlays of Core, and no option" {
    python3 - tests/commission.yaml <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))["instance"]
assert d["appliance"]["name"] == "redis", "appliance.name"
assert d["installation"]["mode"] == "simple", "installation.mode"
assert sorted(d["overlays"]) == ["crowdsec", "etcd", "installer", "vip", "wireguard"], d["overlays"]
assert "options" not in (d.get("app") or {}), "app.options: the manifest declares none"
assert sorted(d["secrets"]) == ["db_password", "root_password"], d["secrets"]
assert "instance" not in d, "the machine keeps the name pct create gave it"
PY
}

@test "manifest: the commissioning contract has no cloud part, as the manifest allows simple only" {
    python3 - tests/commission.yaml <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert "cloud" not in d and "nodes" not in d, "a cloud pass of a simple only appliance"
assert "mode" not in [q["id"] for q in d["questions"]], "no Mode screen comes for one mode"
PY
}

@test "manifest: the example spec holds against it, and the boot test's spec too, with no warning" {
    # keel takes a spec that names no appliance with no check of the
    # manifests, and the example then named app.options.db_user, which no
    # manifest of the chain declares: keel refuses it when the spec names
    # redis (keel-postgresql found the same, BR1 and BR2, 2026-11-06)
    [ -n "${KEEL_SRC:-}" ] || skip "KEEL_SRC is not set"
    run tests/lib/manifest-root.sh "$BATS_TEST_TMPDIR/root" "$MANIFEST"
    [ "$status" -eq 0 ]
    for spec in keel/instance.example.yaml tests/instance.yaml; do
        run keel_as_root spec validate --spec "$spec" --no-secret-files --root "$BATS_TEST_TMPDIR/root"
        echo "$spec: $output"
        [ "$status" -eq 0 ]
        [[ "$output" != *Warning* ]]
    done
}

@test "manifest: the example names the redis appliance, its mode and the five overlays of Core, and no option" {
    for spec in keel/instance.example.yaml; do
        python3 - "$spec" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
assert d["appliance"]["name"] == "redis", "appliance.name"
assert d["installation"]["mode"] == "simple", "installation.mode"
assert sorted(d["overlays"]) == ["crowdsec", "etcd", "installer", "vip", "wireguard"], d["overlays"]
assert "options" not in (d.get("app") or {}), "app.options: the manifest declares none"
assert d["secrets"]["db_password"], "secrets.db_password"
PY
    done
}

@test "manifest: the commissioning contract's instance is the example's shape" {
    python3 - keel/instance.example.yaml tests/commission.yaml <<'PY'
import sys, yaml
example = yaml.safe_load(open(sys.argv[1]))
instance = yaml.safe_load(open(sys.argv[2]))["instance"]
for key in ("version", "network", "tls", "appliance", "installation", "overlays", "hub", "first_login_wizard"):
    assert instance[key] == example[key], key
assert sorted(instance["secrets"]) == sorted(example["secrets"]), "secrets"
PY
}

@test "manifest: the contract runs the check that keel prints for redis, and asks no Monit socket" {
    # a single node has a monitor only when its spec turns one on with a
    # channel (decision 0021), so the contract runs the probe itself
    grep -qF 'keel manifest show --resolved redis' tests/commission.yaml
    run ! grep -qF 'monit -B summary' tests/commission.yaml
    run ! grep -qF 'keel-manifest.conf' tests/commission.yaml
}

@test "manifest: the spec of the boot test names no appliance and no option: the host of the test validates it" {
    # the boot test applies its spec with the keel of the CI host, which has
    # no manifest of redis: "appliance.name: redis is not an installed
    # appliance under /usr/share/keel" (CI of this repository, 2026-11-10;
    # keel-postgresql has the same rule)
    run ! grep -qE '^(appliance|installation|overlays):' tests/instance.yaml
    run ! grep -q 'db_user' tests/instance.yaml
    grep -q '^  db_password:' tests/instance.yaml
}
