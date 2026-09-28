#!/usr/bin/env bats
# Unit tests of tests/lib/boot-test-lib.sh: argument parsing, address
# discovery from lxc-info, waiting with a deadline, the secret files, the
# client calls and their verdicts, the role keel inspect reports, and the
# Webmin and diff verdicts. Nothing here needs root, a network, a server or
# LXC: lxc-info is a stub first in PATH, the clock and sleep are functions.
#
# The verdicts are where most of this file is, and the reason is one Redis
# behaviour: redis-cli exits 0 when the server answers with an error. Every
# verdict therefore reads the answer, and there is a test for each of the
# answers a wrong secret and a missing secret produce.

bats_require_minimum_version 1.5.0

setup() {
    load lib/boot-test-lib.sh
    STUBS=$(mktemp -d)
    PATH=$STUBS:$PATH
}

teardown() {
    rm -rf "$STUBS"
}

stub_lxc_info() {
    # stub_lxc_info OUTPUT: lxc-info prints OUTPUT and records its arguments
    printf '#!/bin/bash\necho "$*" >> "%s/lxc-info.calls"\ncat <<"OUT"\n%s\nOUT\n' "$STUBS" "$1" > "$STUBS/lxc-info"
    chmod +x "$STUBS/lxc-info"
}

# argument parsing

@test "parse_args: the appliance alone takes every default" {
    bt_parse_args redis
    [ "$BT_APPLIANCE" = redis ]
    [ "$BT_TIMEOUT" = 900 ]
    [ "$BT_INTERVAL" = 5 ]
    [ "$BT_BRIDGE" = br0 ]
    [ "$BT_LAYERS_DIR" = /mnt/builds/layers ]
    [ "$BT_CACHE_DIR" = /var/cache/keel/layers ]
    [ "$BT_LXC_PATH" = /var/lib/lxc ]
    [ -z "$BT_SPEC" ]
    [ "$BT_KEEP" = 0 ]
    [ "$BT_NAME" = keel-redis-boot-test ]
    [ "$BT_ROOTFS" = /var/lib/lxc/keel-redis-boot-test/rootfs ]
}

@test "parse_args: every option is read" {
    bt_parse_args --timeout 60 --interval 2 --bridge lxcbr0 --layers-dir /l \
        --cache-dir /c --lxc-path /x --name lamp-run-7 --spec /s.yaml --keep lamp
    [ "$BT_APPLIANCE" = lamp ]
    [ "$BT_TIMEOUT" = 60 ]
    [ "$BT_INTERVAL" = 2 ]
    [ "$BT_BRIDGE" = lxcbr0 ]
    [ "$BT_LAYERS_DIR" = /l ]
    [ "$BT_CACHE_DIR" = /c ]
    [ "$BT_LXC_PATH" = /x ]
    [ "$BT_SPEC" = /s.yaml ]
    [ "$BT_KEEP" = 1 ]
    [ "$BT_NAME" = lamp-run-7 ]
    [ "$BT_ROOTFS" = /x/lamp-run-7/rootfs ]
}

@test "parse_args: --name is checked as a container name" {
    run bt_parse_args redis --name "Run 7"
    [ "$status" -eq 1 ]
    [[ $output == *"is not a container name"* ]]
    run bt_parse_args redis --name -lead
    [ "$status" -eq 1 ]
}

@test "is_container_name" {
    bt_is_container_name keel-redis-ci-36255612491-1
    bt_is_container_name 7
    run ! bt_is_container_name "keel core"
    run ! bt_is_container_name -x
    run ! bt_is_container_name ""
}

@test "parse_args: the appliance is required" {
    run bt_parse_args --keep
    [ "$status" -eq 1 ]
    [[ $output == *"APPLIANCE is required"* ]]
}

@test "parse_args: one appliance at a time" {
    run bt_parse_args redis lamp
    [ "$status" -eq 1 ]
    [[ $output == *"one appliance at a time"* ]]
}

@test "parse_args: the keel- prefix and upper case are rejected" {
    run bt_parse_args keel-redis
    [ "$status" -eq 1 ]
    [[ $output == *"not an appliance name"* ]]
    run bt_parse_args NodeBB
    [ "$status" -eq 1 ]
}

@test "parse_args: an unknown option fails" {
    run bt_parse_args redis --verbose
    [ "$status" -eq 1 ]
    [[ $output == *"unknown option --verbose"* ]]
}

@test "parse_args: timeout and interval must be positive integers" {
    run bt_parse_args redis --timeout 0
    [ "$status" -eq 1 ]
    [[ $output == *"--timeout needs a positive number"* ]]
    run bt_parse_args redis --interval abc
    [ "$status" -eq 1 ]
    run bt_parse_args redis --timeout
    [ "$status" -eq 1 ]
}

@test "parse_args: an option with a value refuses an empty one" {
    run bt_parse_args redis --bridge
    [ "$status" -eq 1 ]
    [[ $output == *"--bridge needs a value"* ]]
    run bt_parse_args redis --spec ""
    [ "$status" -eq 1 ]
}

@test "parse_args: --help prints the usage and returns 2" {
    run bt_parse_args --help
    [ "$status" -eq 2 ]
    [[ ${lines[0]} == "usage: tests/boot-test.sh APPLIANCE"* ]]
    [[ $output == *"--keep"* ]]
    run bt_parse_args -h
    [ "$status" -eq 2 ]
}

@test "is_positive_int and is_appliance_name" {
    bt_is_positive_int 1
    bt_is_positive_int 900
    run ! bt_is_positive_int 0
    run ! bt_is_positive_int 07
    run ! bt_is_positive_int -5
    run ! bt_is_positive_int ""
    bt_is_appliance_name nginx-php-fastcgi
    run ! bt_is_appliance_name keel-core
    run ! bt_is_appliance_name 9core
    run ! bt_is_appliance_name ""
}

# address discovery

@test "is_global_ipv6: global and ULA yes, link local, loopback, multicast, IPv4 no" {
    bt_is_global_ipv6 2001:db8:1::10
    bt_is_global_ipv6 fd00:1::10
    bt_is_global_ipv6 2001:DB8::1
    run ! bt_is_global_ipv6 fe80::216:3eff:fe00:1
    run ! bt_is_global_ipv6 FEBF::1
    run ! bt_is_global_ipv6 ::1
    run ! bt_is_global_ipv6 ff02::1
    run ! bt_is_global_ipv6 192.0.2.10
    run ! bt_is_global_ipv6 ""
}

@test "global_ipv6: picks the first global address out of lxc-info output" {
    output=$(printf 'IP:             fe80::216:3eff:fe00:1\nIP:             192.0.2.10\nIP:             2001:db8:1::10\nIP:             2001:db8:1::11\n' | bt_global_ipv6)
    [ "$output" = 2001:db8:1::10 ]
}

@test "global_ipv6: ignores lines that are not addresses" {
    output=$(printf 'Name:           keel-redis-boot-test\nState:          RUNNING\nPID:            4242\nIP:             fd00::10\nLink:           veth0\n' | bt_global_ipv6)
    [ "$output" = fd00::10 ]
}

@test "global_ipv6: returns 1 while only link local or IPv4 addresses exist" {
    run bt_global_ipv6 <<< $'IP:             fe80::1\nIP:             192.0.2.10'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run bt_global_ipv6 < /dev/null
    [ "$status" -eq 1 ]
}

@test "container_ipv6: calls lxc-info with the lxcpath and the name" {
    stub_lxc_info $'Name:           keel-redis-boot-test\nIP:             fe80::1\nIP:             2001:db8:1::10'
    output=$(bt_container_ipv6 keel-redis-boot-test /var/lib/lxc)
    [ "$output" = 2001:db8:1::10 ]
    [ "$(cat "$STUBS/lxc-info.calls")" = "-P /var/lib/lxc -n keel-redis-boot-test -i" ]
}

@test "container_ipv6: fails when lxc-info has no global address yet" {
    stub_lxc_info $'Name:           keel-redis-boot-test\nState:          RUNNING'
    run bt_container_ipv6 keel-redis-boot-test /var/lib/lxc
    [ "$status" -eq 1 ]
}

# timeouts

fake_clock() { echo "$FAKE_NOW"; }
fake_sleep() { FAKE_NOW=$(( FAKE_NOW + $1 )); echo "sleep $1" >> "$STUBS/sleeps"; }
succeed_on_third() { CALLS=$(( CALLS + 1 )); [ "$CALLS" -ge 3 ]; }
never() { return 1; }

@test "deadline_passed" {
    run ! bt_deadline_passed 100 30 129
    bt_deadline_passed 100 30 130
    bt_deadline_passed 100 30 500
}

@test "now: the default clock is epoch seconds and BT_CLOCK replaces it" {
    [[ $(bt_now) =~ ^[0-9]{10}$ ]]
    BT_CLOCK=fake_clock FAKE_NOW=42
    [ "$(bt_now)" = 42 ]
}

@test "wait_for: polls at the interval until the command succeeds" {
    BT_CLOCK=fake_clock BT_SLEEP=fake_sleep FAKE_NOW=1000 CALLS=0
    bt_wait_for 60 5 "three calls" succeed_on_third
    [ "$CALLS" -eq 3 ]
    [ "$(cat "$STUBS/sleeps")" = $'sleep 5\nsleep 5' ]
}

@test "wait_for: gives up with a message once the timeout has passed" {
    # shellcheck disable=SC2034  # read by bt_now and bt_wait_for
    BT_CLOCK=fake_clock BT_SLEEP=fake_sleep FAKE_NOW=1000
    run bt_wait_for 12 5 "something that never happens" never
    [ "$status" -eq 1 ]
    [[ $output == *"timeout after 12s waiting for something that never happens"* ]]
    [ "$(wc -l < "$STUBS/sleeps")" -eq 3 ]
}

# readiness and verdicts

@test "is_ssh_banner" {
    bt_is_ssh_banner "SSH-2.0-OpenSSH_10.0p2 Debian-7"
    run ! bt_is_ssh_banner "HTTP/1.1 400 Bad Request"
    run ! bt_is_ssh_banner ""
}

@test "firstboot_done_in: RUN_FIRSTBOOT=false in the rootfs copy of /etc/default/inithooks" {
    printf 'INITHOOKS_CONF=/etc/inithooks.conf\nRUN_FIRSTBOOT=false\n' > "$STUBS/done"
    printf 'RUN_FIRSTBOOT=true\n' > "$STUBS/pending"
    bt_firstboot_done_in "$STUBS/done"
    run ! bt_firstboot_done_in "$STUBS/pending"
    run ! bt_firstboot_done_in "$STUBS/missing"
}

@test "lxc_config: names the container, the rootfs and the bridge" {
    output=$(bt_lxc_config keel-redis-boot-test /var/lib/lxc/keel-redis-boot-test/rootfs br0)
    [[ $output == *"lxc.uts.name = keel-redis-boot-test"* ]]
    [[ $output == *"lxc.rootfs.path = dir:/var/lib/lxc/keel-redis-boot-test/rootfs"* ]]
    [[ $output == *"lxc.net.0.link = br0"* ]]
    [[ $output == *"lxc.net.0.type = veth"* ]]
}

@test "lxc_config: the apparmor pair a container running systemd needs" {
    output=$(bt_lxc_config keel-redis-boot-test /r/rootfs br0)
    [[ $output == *"lxc.apparmor.profile = generated"* ]]
    [[ $output == *"lxc.apparmor.allow_nesting = 1"* ]]
}

fake_rootfs() {
    # fake_rootfs [VALUE]: a scratch rootfs with an inithooks defaults file,
    # REDIRECT_OUTPUT set to VALUE (default false), printed on stdout
    local rootfs="$BATS_TEST_TMPDIR/rootfs-$RANDOM"
    mkdir -p "$rootfs/etc/default"
    cat > "$rootfs/$BT_INITHOOKS_DEFAULT" <<DEF
INITHOOKS_CONF=/etc/inithooks.conf
RUN_FIRSTBOOT=true
REDIRECT_OUTPUT=${1-false}
SUDOADMIN=false
DEF
    printf '%s\n' "$rootfs"
}

@test "mark_container: writes the marker the unit conditions and inspect read" {
    rootfs=$(fake_rootfs)
    run bt_mark_container "$rootfs"
    [ "$status" -eq 0 ]
    [ -f "$rootfs/var/lib/turnkey-info/inithooks.service/lxc" ]
}

@test "mark_container: turns REDIRECT_OUTPUT on, so no hook blocks writing to tty1" {
    rootfs=$(fake_rootfs false)
    run bt_mark_container "$rootfs"
    [ "$status" -eq 0 ]
    grep -q '^REDIRECT_OUTPUT=true$' "$rootfs/$BT_INITHOOKS_DEFAULT"
    # the rest of the file is left alone
    grep -q '^RUN_FIRSTBOOT=true$' "$rootfs/$BT_INITHOOKS_DEFAULT"
    grep -q '^SUDOADMIN=false$' "$rootfs/$BT_INITHOOKS_DEFAULT"
}

@test "mark_container: takes the first boot off tty1 with a systemd drop-in" {
    rootfs=$(fake_rootfs)
    run bt_mark_container "$rootfs"
    [ "$status" -eq 0 ]
    dropin="$rootfs/$BT_INITHOOKS_DROPIN"
    [ -f "$dropin" ]
    grep -q '^\[Service\]$' "$dropin"
    grep -q '^StandardOutput=journal$' "$dropin"
    grep -q '^StandardError=journal$' "$dropin"
}

@test "mark_container: a tree that already redirects is left redirecting" {
    rootfs=$(fake_rootfs true)
    run bt_mark_container "$rootfs"
    [ "$status" -eq 0 ]
    [ "$(grep -c '^REDIRECT_OUTPUT=true$' "$rootfs/$BT_INITHOOKS_DEFAULT")" -eq 1 ]
}

@test "mark_container: a rootfs with no inithooks defaults fails loudly" {
    rootfs="$BATS_TEST_TMPDIR/bare"
    mkdir -p "$rootfs"
    run bt_mark_container "$rootfs"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not in the rootfs"* ]]
}

@test "mark_container: defaults that declare no REDIRECT_OUTPUT fail loudly" {
    rootfs=$(fake_rootfs)
    grep -v REDIRECT_OUTPUT "$rootfs/$BT_INITHOOKS_DEFAULT" > "$rootfs/trimmed"
    mv "$rootfs/trimmed" "$rootfs/$BT_INITHOOKS_DEFAULT"
    run bt_mark_container "$rootfs"
    [ "$status" -eq 1 ]
    [[ "$output" == *"declares no REDIRECT_OUTPUT"* ]]
}

@test "spec_targets: both paths the first boot reads, under the rootfs" {
    output=$(bt_spec_targets /r)
    [ "$output" = $'/r/etc/keel/instance.yaml\n/r/etc/inithooks.yaml' ]
}

@test "secret_targets: the two secret files the spec references" {
    output=$(bt_secret_targets /r)
    [ "$output" = $'/r/etc/keel/secrets/root_password\n/r/etc/keel/secrets/db_password' ]
}

@test "webmin_verdict: the login page or a challenge is an answer" {
    run bt_webmin_verdict 200
    [ "$status" -eq 0 ]
    [[ $output == *"webmin answered 200 on port 12321"* ]]
    run bt_webmin_verdict 401
    [ "$status" -eq 0 ]
    run bt_webmin_verdict 000
    [ "$status" -eq 1 ]
    [[ $output == *"not 200 or 401"* ]]
    run bt_webmin_verdict 502
    [ "$status" -eq 1 ]
    run bt_webmin_verdict
    [ "$status" -eq 1 ]
    [[ $output == *"answered ''"* ]]
}

@test "no_webmin_module_verdict: Debian packages none, and that is checked" {
    run bt_no_webmin_module_verdict ""
    [ "$status" -eq 0 ]
    [[ $output == *"no Webmin module for Redis is packaged"* ]]
    run bt_no_webmin_module_verdict $'\n  \n'
    [ "$status" -eq 0 ]
    run bt_no_webmin_module_verdict
    [ "$status" -eq 0 ]
    run bt_no_webmin_module_verdict "webmin-redis - Webmin module - Redis"
    [ "$status" -eq 1 ]
    [[ $output == *"add it to plan/main"* ]]
}

@test "db_verdict: PONG passes, and every refusal redis-cli exits 0 on fails" {
    run bt_db_verdict PONG
    [ "$status" -eq 0 ]
    [[ $output == *"admin authenticated on [::1]:6379 with the declared secret"* ]]
    run bt_db_verdict $'\nPONG\n'
    [ "$status" -eq 0 ]
    # What a wrong password really prints, with exit 0 under it
    run bt_db_verdict "AUTH failed: WRONGPASS invalid username-password pair or user is disabled."
    [ "$status" -eq 1 ]
    [[ $output == *"did not reach the server"* ]]
    run bt_db_verdict "NOPERM User default has no permissions to run the 'ping' command"
    [ "$status" -eq 1 ]
    run bt_db_verdict
    [ "$status" -eq 1 ]
    [[ $output == *"answered ''"* ]]
}

@test "db_marker_verdict: the value read back is the value written" {
    run bt_db_marker_verdict abc123 abc123
    [ "$status" -eq 0 ]
    [[ $output == *"wrote and read keel:boot-test:marker (abc123)"* ]]
    run bt_db_marker_verdict abc123 $'abc123\n'
    [ "$status" -eq 0 ]
    run bt_db_marker_verdict abc123 "(nil)"
    [ "$status" -eq 1 ]
    [[ $output == *"not 'abc123'"* ]]
    run bt_db_marker_verdict "" ""
    [ "$status" -eq 1 ]
}

@test "db_denied_verdict: a key without a secret must be refused" {
    run bt_db_denied_verdict "NOPERM User default has no permissions to run the 'get' command"
    [ "$status" -eq 0 ]
    [[ $output == *"refused every key"* ]]
    # A server that answers is a server that hands its data to anybody, and
    # "(nil)" is what an unrestricted default account answers for a key that
    # is not there, which is the shape this has to catch.
    run bt_db_denied_verdict "(nil)"
    [ "$status" -eq 1 ]
    [[ $output == *"hands its data to anyone who can reach it"* ]]
    run bt_db_denied_verdict ""
    [ "$status" -eq 1 ]
    run bt_db_denied_verdict "somevalue"
    [ "$status" -eq 1 ]
}

@test "db_client_argv: the client call, with no secret on the line" {
    output=$(bt_db_client_argv admin ::1 6379 PING)
    [ "$output" = $'redis-cli\n-h\n::1\n-p\n6379\n--user\nadmin\nPING' ]
    [[ $output != *"REDISCLI_AUTH"* ]]
    [[ $output != *"-a"* ]]
}

@test "db_client_argv: a command with arguments is passed through" {
    output=$(bt_db_client_argv admin ::1 6379 SET keel:k value)
    [ "$output" = $'redis-cli\n-h\n::1\n-p\n6379\n--user\nadmin\nSET\nkeel:k\nvalue' ]
}

@test "db_client_argv: an empty user or host, a bad port or no command fails" {
    run ! bt_db_client_argv "" ::1 6379 PING
    run ! bt_db_client_argv admin "" 6379 PING
    run ! bt_db_client_argv admin ::1 "" PING
    run ! bt_db_client_argv admin ::1 sixthreeseveNnine PING
    run ! bt_db_client_argv admin ::1 6379
}

@test "db_denied_argv: the same client with no account and no password" {
    output=$(bt_db_denied_argv ::1 6379)
    [ "$output" = $'redis-cli\n-h\n::1\n-p\n6379\nGET\nkeel:boot-test:denied' ]
    [[ $output != *"--user"* ]]
    run ! bt_db_denied_argv "" 6379
    run ! bt_db_denied_argv ::1 nope
}

@test "inspected_role: the role keel inspect wrote, out of its YAML" {
    output=$(bt_inspected_role <<'SPEC'
# Written by keel inspect from /: redis
version: 1
instance:
  hostname: redis
database:
  server:
    engine: redis
    role: standalone
    listen:
    - ::1
    - 127.0.0.1
locale:
  timezone: Etc/UTC
SPEC
)
    [ "$output" = standalone ]
}

@test "inspected_role: a client section alone is not a role" {
    run ! bt_inspected_role <<'SPEC'
version: 1
database:
  client:
    engine: redis
    primary:
      host: ::1
SPEC
}

@test "inspected_role: no database section at all fails rather than guessing" {
    run ! bt_inspected_role <<'SPEC'
version: 1
instance:
  hostname: redis
SPEC
}

@test "inspected_role: a role of some other section is not this one" {
    # app.role would be a different field entirely, and a grep for "role:"
    # would have found it.
    run ! bt_inspected_role <<'SPEC'
version: 1
app:
  server:
    role: primary
SPEC
}

@test "role_verdict: standalone is what this layer is, and nothing else is" {
    run bt_role_verdict standalone
    [ "$status" -eq 0 ]
    [[ $output == *"read database.server.role standalone off the server"* ]]
    run bt_role_verdict primary
    [ "$status" -eq 1 ]
    [[ $output == *"not standalone"* ]]
    run bt_role_verdict ""
    [ "$status" -eq 1 ]
    [[ $output == *"read database.server.role 'nothing'"* ]]
    run bt_role_verdict
    [ "$status" -eq 1 ]
}

@test "spec_in_rootfs: secret references are pointed inside the rootfs" {
    printf 'secrets:\n  root_password:\n    file: /etc/keel/secrets/root_password\ntls:\n  acme:\n    enabled: false\n' > "$STUBS/spec"
    output=$(bt_spec_in_rootfs "$STUBS/spec" /r/rootfs)
    [[ $output == *"file: /r/rootfs/etc/keel/secrets/root_password"* ]]
    [[ $output == *"enabled: false"* ]]
    [[ $output != *"file: /etc/keel"* ]]
}

@test "random_password: 24 alphanumeric characters from the random source" {
    output=$(bt_random_password)
    [[ $output =~ ^[A-Za-z0-9]{24}$ ]]
    printf 'ab!!cd%%%%efghijklmnopqrstuvwxyz0123456789' > "$STUBS/random"
    output=$(BT_RANDOM_SOURCE=$STUBS/random bt_random_password)
    [ "$output" = abcdefghijklmnopqrstuvwx ]
}

@test "random_password: a source too poor to fill the password fails loudly" {
    printf '!!!!short!!!!' > "$STUBS/poor"
    BT_RANDOM_SOURCE="$STUBS/poor"
    run bt_random_password
    [ "$status" -eq 1 ]
    [[ $output == *"gave only 5 usable characters"* ]]
}

@test "diff_verdict: 0 and 13 pass, everything else fails with a message" {
    run bt_diff_verdict 0
    [ "$status" -eq 0 ]
    [ "$output" = "keel diff: no drift" ]
    run bt_diff_verdict 13
    [ "$status" -eq 0 ]
    [[ $output == *"could not be observed offline"* ]]
    run bt_diff_verdict 14
    [ "$status" -eq 1 ]
    [[ $output == *"drift found"* ]]
    run bt_diff_verdict 2
    [ "$status" -eq 1 ]
    [[ $output == *"unreadable or invalid (exit 2)"* ]]
    run bt_diff_verdict 3
    [ "$status" -eq 1 ]
    run bt_diff_verdict 127
    [ "$status" -eq 1 ]
    [[ $output == *"failed with exit 127"* ]]
}
