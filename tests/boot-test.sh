#!/bin/bash
# Boot test of this layer (org-plan section 1), modelled on the ones in
# keel-mariadb and keel-postgresql: assemble the published layer chain into
# an LXC rootfs, boot it headless from tests/instance.yaml, wait for the
# first boot to finish, then prove the declarative path end to end.
#
# What it proves, in the order it proves it, and why each line is there:
#
#   1. The declared secret reaches the server. The description declares
#      secrets.db_password from a file, nothing is configured by hand, and
#      the test authenticates as the ACL user that secret belongs to, over
#      IPv6. A listening port would prove nothing: the server listens
#      whatever secret it ended up with.
#   2. That account can work and not only log in, so a value generated for
#      this run is written and read back under a key.
#   3. Nothing works without the secret. The same client with no account and
#      no password asks for a key and must be refused with NOPERM. Without
#      this, "the secret works" would say nothing about whether it was
#      needed, and on Redis that is a real question: requirepass and an ACL
#      user are two different answers to it and this layer chose one.
#   4. Webmin answers over IPv6 on 12321, because batteries included is a
#      property of this distribution. Debian 13 packages no Webmin module
#      for Redis, so the test checks that too rather than leaving a silence.
#   5. `keel inspect` reads database.server.role back off the running server
#      and says standalone. That is the seam the cloud modes of decision
#      0013 are built on, and it is the reason the declared secret here is
#      an ACL user: requirepass would lock INFO as well, and inspect never
#      reads a secret to get past a refusal.
#   6. `keel diff` reports no drift.
#
# Under all of it, the one Redis behaviour to know: redis-cli exits 0 when
# the server answers with an error. Every check below reads the answer.
#
# Called by the reusable workflow test-appliance.yml after keel pull and
# keel verify; runnable by hand as root on any host with LXC, see
# tests/README.md. It builds nothing: the layers come from the mirror or
# from a directory bt-layer wrote, so the test needs no fab, deck or
# buildtasks. The logic lives in tests/lib/boot-test-lib.sh and is unit
# tested; this file is the thin main that touches the system.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/boot-test-lib.sh
source "$here/lib/boot-test-lib.sh"

bt_parse_args "$@" || { rc=$?; [ "$rc" -eq 2 ] && exit 0; exit 1; }
BT_SPEC=${BT_SPEC:-$here/instance.yaml}
if [ "$(id -u)" -ne 0 ]; then
    echo "boot-test: must run as root (keel assemble, lxc-start)" >&2
    exit 1
fi
for tool in keel lxc-start lxc-info lxc-attach lxc-stop curl; do
    command -v "$tool" >/dev/null || { echo "boot-test: $tool not found" >&2; exit 1; }
done

container_dir=$BT_LXC_PATH/$BT_NAME
log() { printf '%s boot-test: %s\n' "$(date -u +%H:%M:%S)" "$*"; }
lxc() { "lxc-$1" -P "$BT_LXC_PATH" -n "$BT_NAME" "${@:2}"; }

cleanup() {
    local rc=$?
    if [ "$rc" -ne 0 ] && [ -r "$BT_ROOTFS/var/log/inithooks.log" ]; then
        log "last lines of the container's inithooks log:"
        tail -n 40 "$BT_ROOTFS/var/log/inithooks.log"
    fi
    if [ "$BT_KEEP" -eq 1 ]; then
        log "keeping $BT_NAME under $BT_LXC_PATH (--keep); lxc-attach -P $BT_LXC_PATH -n $BT_NAME"
        return
    fi
    lxc stop -k >/dev/null 2>&1 || true
    rm -rf "$container_dir"
}
trap cleanup EXIT

# 1. Assemble the chain from the layers the build host published.
log "assembling $BT_APPLIANCE from $BT_LAYERS_DIR into $BT_ROOTFS"
lxc stop -k >/dev/null 2>&1 || true
rm -rf "$container_dir"
mkdir -p "$BT_ROOTFS"
keel pull "$BT_APPLIANCE" --source "$BT_LAYERS_DIR" --cache-dir "$BT_CACHE_DIR" --non-interactive
keel assemble "$BT_APPLIANCE" --rootfs "$BT_ROOTFS" --cache-dir "$BT_CACHE_DIR" --non-interactive

# 2. The container marks, the instance description, the secrets it
#    references and the conf the first boot hooks read. bt_mark_container
#    does what buildtasks' container patch does: the marker under
#    /var/lib/turnkey-info that inspect reads to call the machine a
#    container (managed_by: host), and REDIRECT_OUTPUT=true with a
#    drop-in, without which a hook that prints a lot blocks writing to a
#    tty1 nobody reads. The conf is what makes the first boot headless,
#    and without it 30rootpass and 35redispass wait on a dialog forever.
log "installing the description, the secrets and the conf into $BT_ROOTFS"
bt_mark_container "$BT_ROOTFS"
install -d -m 0700 "$BT_ROOTFS/etc/keel/secrets"
for target in $(bt_secret_targets "$BT_ROOTFS"); do
    bt_random_password > "$target"
    chmod 0600 "$target"
done
for target in $(bt_spec_targets "$BT_ROOTFS"); do
    install -D -m 0600 "$BT_SPEC" "$target"
done
bt_spec_in_rootfs "$BT_SPEC" "$BT_ROOTFS" > "$container_dir/instance-host.yaml"
keel spec apply --spec "$container_dir/instance-host.yaml" \
    --conf "$BT_ROOTFS/etc/inithooks.conf" --non-interactive

# The declared secret, as the description names it. Everything below uses
# this and nothing else: no value is read out of the container, and in
# particular nothing on the machine can print it back, because what the
# server holds is its SHA-256.
declared_secret=$(cat "$BT_ROOTFS/etc/keel/secrets/db_password")

# 3. Boot.
bt_lxc_config "$BT_NAME" "$BT_ROOTFS" "$BT_BRIDGE" > "$container_dir/config"
log "starting $BT_NAME on bridge $BT_BRIDGE"
lxc start -d

# 4. A global IPv6 address from the bridge.
bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "a global IPv6 address on $BT_NAME" \
    bt_container_ipv6 "$BT_NAME" "$BT_LXC_PATH" > /dev/null
addr=$(bt_container_ipv6 "$BT_NAME" "$BT_LXC_PATH")
log "container address $addr"

# 5. First boot finished: 98finalize has cleared RUN_FIRSTBOOT and the
#    machine answers, on the console (confconsole's usage screen) or on
#    SSH. The answer alone is not enough: sshd is up long before the hooks
#    are done, so the flag is what says the first boot ended.
usage_screen() {
    lxc attach -- pgrep -f confconsole > /dev/null 2>&1
}
ssh_answers() {
    local banner
    banner=$(timeout 5 bash -c 'exec 3<>"/dev/tcp/$0/$1" && read -r -t 5 line <&3 && printf "%s" "$line"' \
        "$addr" "$BT_SSH_PORT" 2>/dev/null) || return 1
    bt_is_ssh_banner "$banner"
}
first_boot_done() {
    bt_firstboot_done_in "$BT_ROOTFS/etc/default/inithooks" || return 1
    usage_screen || ssh_answers
}
bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "the first boot of $BT_NAME to finish" \
    first_boot_done
log "first boot finished; ssh root@$addr"

# 6. What the first boot hook reported, quoted here so a failure below is
#    read next to it.
log "the Redis lines of the container's inithooks log:"
grep -E '35redispass|Redis' "$BT_ROOTFS/var/log/inithooks.log" || true

# 7. The declarative path, end to end: a client connection with the secret
#    the description declared. The client runs inside the container over TCP
#    on [::1], because the server listens on the loopback of both families
#    and nowhere else, and the secret reaches it in the environment so it
#    never appears in the container's process list.
#
#    The answer is the verdict, never the exit code: redis-cli exits 0 when
#    the server refuses it.
mapfile -t client < <(bt_db_client_argv "$BT_DB_USER" "$BT_DB_HOST" "$BT_DB_PORT" PING)
log "authenticating as $BT_DB_USER on [$BT_DB_HOST]:$BT_DB_PORT with the declared secret"
answer=$(lxc attach --set-var "REDISCLI_AUTH=$declared_secret" -- "${client[@]}" 2>&1) \
    || { echo "boot-test: redis-cli could not reach the server at all" >&2; exit 1; }
bt_db_verdict "$answer"

# 8. And that the account can work, not only log in. The value is generated
#    on the host for this run alone, so reading it back can only mean the
#    write happened.
marker=$(bt_random_password)
mapfile -t writer < <(bt_db_client_argv "$BT_DB_USER" "$BT_DB_HOST" "$BT_DB_PORT" \
    SET "$BT_DB_MARKER_KEY" "$marker")
mapfile -t reader < <(bt_db_client_argv "$BT_DB_USER" "$BT_DB_HOST" "$BT_DB_PORT" \
    GET "$BT_DB_MARKER_KEY")
lxc attach --set-var "REDISCLI_AUTH=$declared_secret" -- "${writer[@]}" > /dev/null
read_back=$(lxc attach --set-var "REDISCLI_AUTH=$declared_secret" -- "${reader[@]}" 2>&1)
bt_db_marker_verdict "$marker" "$read_back"

# 9. The other end of the same claim: with no secret, no data. This is what
#    makes the check above mean something, and on Redis it is the difference
#    between the two answers the vocabulary allows: a requirepass would lock
#    everything including INFO, and an ACL user leaves INFO open on purpose
#    and every key shut.
mapfile -t denied < <(bt_db_denied_argv "$BT_DB_HOST" "$BT_DB_PORT")
refusal=$(lxc attach -- "${denied[@]}" 2>&1 || true)
bt_db_denied_verdict "$refusal"

# 10. The panel core carries. No Webmin module for Redis is packaged in
#     Debian 13, which is checked rather than assumed: the day one appears
#     the build says so too (conf.d/main).
offered=$(lxc attach -- apt-cache --names-only search '^webmin-redis$' 2>/dev/null || true)
bt_no_webmin_module_verdict "$offered"
code=""
webmin_answers() {
    code=$(curl -6 -k -s -o /dev/null -w '%{http_code}' \
        "https://[$addr]:$BT_WEBMIN_PORT/" || true)
    [ "$code" = 200 ] || [ "$code" = 401 ]
}
bt_wait_for "$BT_TIMEOUT" "$BT_INTERVAL" "webmin on https://[$addr]:$BT_WEBMIN_PORT/" \
    webmin_answers
bt_webmin_verdict "$code"

# 11. What the machine says it is, read off the server and not off a file.
#     `keel inspect` runs INFO replication, INFO cluster and INFO server
#     through redis-cli with no credentials, which is exactly what
#     20-keel-acl.conf of the component leaves possible, and reports
#     database.server.role. Run inside the container, because an offline
#     root cannot ask a server anything.
log "asking keel inspect what this machine is"
inspected=$(lxc attach -- keel inspect --report /dev/null) || {
    echo "boot-test: keel inspect failed on the machine" >&2
    exit 1
}
role=$(printf '%s\n' "$inspected" | bt_inspected_role) || true
if ! bt_role_verdict "$role"; then
    echo "boot-test: the report keel inspect wrote:" >&2
    lxc attach -- keel inspect --output /dev/null || true
    exit 1
fi

# 12. No drift between the declared description and the booted root. The
#     database section reads as unknown here and not as drift, because an
#     offline root cannot ask the server: exit 13 is the expected answer and
#     the role itself was checked live in step 11.
set +e
keel diff --root "$BT_ROOTFS" --spec "$BT_SPEC"
code=$?
set -e
bt_diff_verdict "$code"
log "$BT_APPLIANCE boot test passed"
