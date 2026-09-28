#!/bin/bash
# Pure helpers of tests/boot-test.sh (decision 0004: logic apart from
# effect). Same shape as the ones in keel-core, keel-mariadb and
# keel-postgresql, with the checks this layer adds: a client that
# authenticates over IPv6 with the secret the instance description declared,
# the same client with no secret being refused every key, Webmin answering
# over IPv6, and `keel inspect` reading this machine's role back off the
# server. Nothing here starts a container, writes outside a path it is given
# or opens a socket. The two functions that run a command, bt_now and
# bt_container_ipv6, take it from the environment or from PATH so a test can
# replace it. Sourced by boot-test.sh and by tests/boot-test.bats.
# shellcheck disable=SC2034  # the BT_* variables are read by the caller

BT_DEFAULT_TIMEOUT=900
BT_DEFAULT_INTERVAL=5
BT_DEFAULT_BRIDGE=br0
BT_DEFAULT_LAYERS_DIR=/mnt/builds/layers
BT_DEFAULT_CACHE_DIR=/var/cache/keel/layers
BT_DEFAULT_LXC_PATH=/var/lib/lxc
BT_SSH_PORT=22
BT_PASSWORD_LENGTH=24
BT_RANDOM_BYTES=1024
# The secrets tests/instance.yaml references, one file each under
# etc/keel/secrets in the rootfs: the root account and the Redis ACL user,
# which is the one this layer exists for.
BT_SECRETS="root_password db_password"
# The panel core carries. Debian 13 packages no Webmin module for Redis, so
# unlike keel-mariadb and keel-postgresql this test checks that the panel
# answers and claims no module: conf.d/main is where the build finds out if
# one is ever packaged.
BT_WEBMIN_PORT=12321
# The connection the test proves. The client runs inside the container,
# because the server listens on the loopback of both families and nowhere
# else: an appliance above this layer talks to it from the same machine, and
# opening it to the network is that appliance's decision, not this layer's.
#
# The user name is here and the password is not: on Redis the declared secret
# is the password of an ACL user (unit-redis, 20-keel-acl.conf), so a client
# needs both, and the password goes through REDISCLI_AUTH in the environment.
BT_DB_USER="admin"
BT_DB_HOST=::1
BT_DB_PORT=6379
BT_DB_PROBE_ANSWER=PONG
# The key the authenticated client writes and reads back, so the test proves
# an account that can work and not only one that can log in, and the key the
# unauthenticated client must be refused.
BT_DB_MARKER_KEY="keel:boot-test:marker"
BT_DB_DENIED_KEY="keel:boot-test:denied"
# What `keel inspect` must report for database.server.role. Redis answers
# INFO replication and INFO cluster without a secret by design here, which is
# what lets inspect read a role at all, and standalone is the only mode this
# layer configures. The cloud modes of decision 0013 come in their own issue
# and this is the seam they are built on.
BT_ROLE_EXPECTED=standalone
# Where the first boot reads the instance description. inithooks reads
# etc/inithooks.yaml (hook 00declarative), keel reads etc/keel/instance.yaml;
# the final name is a maintainer decision (brief section 11), so the test
# installs the same file at both until then.
BT_SPEC_PATHS="etc/keel/instance.yaml etc/inithooks.yaml"
# What marks the tree as a container build, relative to the rootfs: the
# marker file bt-container writes, the inithooks defaults whose
# REDIRECT_OUTPUT it sets, and the drop-in that keeps the first boot off
# tty1. See bt_mark_container.
BT_CONTAINER_MARKER="var/lib/turnkey-info/inithooks.service/lxc"
BT_INITHOOKS_DEFAULT="etc/default/inithooks"
BT_INITHOOKS_DROPIN="etc/systemd/system/inithooks.service.d/container.conf"

bt_usage() {
    cat <<USAGE
usage: tests/boot-test.sh APPLIANCE [options]

Assembles the layer chain of APPLIANCE (redis) into an LXC rootfs, boots it
headless from tests/instance.yaml, waits for the first boot to finish, then:
authenticates to Redis over IPv6 as the declared ACL user and writes and
reads a key; is refused a key with no secret at all; checks that Webmin
answers over IPv6; checks that keel inspect reads the role back off the
server as $BT_ROLE_EXPECTED; and checks that keel diff reports no drift.
Root only.

options:
  --timeout SECONDS     give up after this long per wait (default $BT_DEFAULT_TIMEOUT)
  --interval SECONDS    poll interval (default $BT_DEFAULT_INTERVAL)
  --bridge NAME         bridge the container joins (default $BT_DEFAULT_BRIDGE)
  --layers-dir DIR|URL  where the layers are published: a directory, or an
                        http(s) URL such as https://mirror.keellinux.org/layers
                        (default $BT_DEFAULT_LAYERS_DIR)
  --cache-dir DIR       keel layer cache (default $BT_DEFAULT_CACHE_DIR)
  --lxc-path DIR        lxcpath for the test container (default $BT_DEFAULT_LXC_PATH)
  --name NAME           container name (default keel-APPLIANCE-boot-test)
  --spec FILE           instance spec (default tests/instance.yaml)
  --keep                leave the container running for inspection
  -h, --help            this text
USAGE
}

bt_is_positive_int() {
    [[ ${1-} =~ ^[1-9][0-9]*$ ]]
}

bt_is_appliance_name() {
    # The name bt-layer and the workflow use: no keel- prefix, lower case.
    [[ ${1-} =~ ^[a-z][a-z0-9-]*$ ]] && [[ $1 != keel-* ]]
}

bt_container_name() {
    printf 'keel-%s-boot-test\n' "$1"
}

bt_is_container_name() {
    # What LXC accepts and what the CI cleanup command allows: lower case
    # letters, digits, dot and dash, starting with a letter or a digit.
    [[ ${1-} =~ ^[a-z0-9][a-z0-9.-]*$ ]]
}

# Sets BT_APPLIANCE, BT_TIMEOUT, BT_INTERVAL, BT_BRIDGE, BT_LAYERS_DIR,
# BT_CACHE_DIR, BT_LXC_PATH, BT_SPEC, BT_KEEP, BT_NAME and BT_ROOTFS.
# Returns 0 when parsed, 2 after printing the usage, 1 on a bad argument
# (message on stderr).
bt_parse_args() {
    BT_APPLIANCE=""
    BT_TIMEOUT=$BT_DEFAULT_TIMEOUT
    BT_INTERVAL=$BT_DEFAULT_INTERVAL
    BT_BRIDGE=$BT_DEFAULT_BRIDGE
    BT_LAYERS_DIR=$BT_DEFAULT_LAYERS_DIR
    BT_CACHE_DIR=$BT_DEFAULT_CACHE_DIR
    BT_LXC_PATH=$BT_DEFAULT_LXC_PATH
    BT_NAME=""
    BT_SPEC=""
    BT_KEEP=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --timeout|--interval)
                bt_is_positive_int "${2-}" || {
                    echo "boot-test: $1 needs a positive number of seconds" >&2
                    return 1
                }
                [ "$1" = --timeout ] && BT_TIMEOUT=$2 || BT_INTERVAL=$2
                shift
                ;;
            --bridge|--layers-dir|--cache-dir|--lxc-path|--name|--spec)
                [ -n "${2-}" ] || {
                    echo "boot-test: $1 needs a value" >&2
                    return 1
                }
                case "$1" in
                    --bridge) BT_BRIDGE=$2 ;;
                    --layers-dir) BT_LAYERS_DIR=$2 ;;
                    --cache-dir) BT_CACHE_DIR=$2 ;;
                    --lxc-path) BT_LXC_PATH=$2 ;;
                    --name) BT_NAME=$2 ;;
                    --spec) BT_SPEC=$2 ;;
                esac
                shift
                ;;
            --keep) BT_KEEP=1 ;;
            -h|--help)
                bt_usage
                return 2
                ;;
            -*)
                echo "boot-test: unknown option $1" >&2
                return 1
                ;;
            *)
                if [ -n "$BT_APPLIANCE" ]; then
                    echo "boot-test: one appliance at a time ($BT_APPLIANCE, $1)" >&2
                    return 1
                fi
                BT_APPLIANCE=$1
                ;;
        esac
        shift
    done
    if [ -z "$BT_APPLIANCE" ]; then
        echo "boot-test: APPLIANCE is required (core, lamp, ...)" >&2
        return 1
    fi
    if ! bt_is_appliance_name "$BT_APPLIANCE"; then
        echo "boot-test: '$BT_APPLIANCE' is not an appliance name (lower case, no keel- prefix)" >&2
        return 1
    fi
    BT_NAME=${BT_NAME:-$(bt_container_name "$BT_APPLIANCE")}
    if ! bt_is_container_name "$BT_NAME"; then
        echo "boot-test: '$BT_NAME' is not a container name (lower case, digits, dot, dash)" >&2
        return 1
    fi
    BT_ROOTFS=$BT_LXC_PATH/$BT_NAME/rootfs
    return 0
}

bt_is_global_ipv6() {
    # Global unicast, which includes ULA (fc00::/7); not link local
    # (fe80::/10), loopback or multicast. IPv4 has no colon.
    local addr=${1,,}
    [[ $addr == *:* ]] || return 1
    [[ $addr == fe[89ab]?:* ]] && return 1
    [[ $addr == ::1 ]] && return 1
    [[ $addr == ff* ]] && return 1
    return 0
}

bt_global_ipv6() {
    # stdin: the output of lxc-info -i ("IP:  ADDRESS" per line). Prints
    # the first global IPv6 address; returns 1 when there is none yet.
    local label addr _
    while read -r label addr _; do
        [ "$label" = "IP:" ] || continue
        if bt_is_global_ipv6 "$addr"; then
            printf '%s\n' "$addr"
            return 0
        fi
    done
    return 1
}

bt_container_ipv6() {
    # bt_container_ipv6 NAME LXCPATH: the container's first global IPv6.
    lxc-info -P "$2" -n "$1" -i 2>/dev/null | bt_global_ipv6
}

bt_now() {
    ${BT_CLOCK:-date +%s}
}

bt_deadline_passed() {
    # bt_deadline_passed START TIMEOUT NOW
    [ $(( $3 - $1 )) -ge "$2" ]
}

bt_wait_for() {
    # bt_wait_for TIMEOUT INTERVAL DESCRIPTION COMMAND [ARGS...]
    # Runs COMMAND until it succeeds; returns 1 once TIMEOUT seconds passed.
    local timeout=$1 interval=$2 what=$3 start now
    shift 3
    start=$(bt_now)
    until "$@"; do
        now=$(bt_now)
        if bt_deadline_passed "$start" "$timeout" "$now"; then
            echo "boot-test: timeout after ${timeout}s waiting for $what" >&2
            return 1
        fi
        ${BT_SLEEP:-sleep} "$interval"
    done
}

bt_is_ssh_banner() {
    [[ ${1-} == SSH-2.0-* ]]
}

bt_firstboot_done_in() {
    # bt_firstboot_done_in FILE: FILE is the rootfs copy of
    # /etc/default/inithooks; 98finalize sets RUN_FIRSTBOOT=false at the end.
    [ -r "$1" ] && grep -q '^RUN_FIRSTBOOT=false' "$1"
}

bt_lxc_config() {
    # bt_lxc_config NAME ROOTFS BRIDGE: an LXC config for a plain rootfs
    # directory on a bridge; the address comes from the bridge (SLAAC or
    # DHCPv6), the spec declares managed_by: host.
    # The apparmor pair is not decoration. Under the stock container
    # profile systemd cannot give a unit a mount namespace, so every unit
    # with ProtectSystem or ProtectHome fails with status=226/NAMESPACE
    # before its own first line runs. Measured in the container this test
    # builds: systemd-journald, systemd-logind, systemd-sysusers,
    # systemd-sysctl and tmp.mount all failed that way, which is why
    # 15regen-sslcert and 95secupdates failed beside the database, and why
    # the container had no journal to read when it was asked why.
    #
    # This layer is the sharpest case of it yet. Debian's
    # redis-server.service carries ProtectSystem=strict, ProtectHome=true,
    # PrivateTmp, PrivateUsers and RestrictNamespaces, so without the pair
    # below the server never starts, firstboot.d/35redispass cannot set the
    # declared secret, and nothing answers on 6379. A generated profile with
    # nesting allowed is what a container running systemd needs, and it is
    # what the appliance containers on the build host have carried all
    # along.
    cat <<CONFIG
lxc.uts.name = $1
lxc.rootfs.path = dir:$2
lxc.include = /usr/share/lxc/config/common.conf
lxc.arch = amd64
lxc.apparmor.profile = generated
lxc.apparmor.allow_nesting = 1
lxc.net.0.type = veth
lxc.net.0.link = $3
lxc.net.0.name = eth0
lxc.net.0.flags = up
lxc.start.auto = 0
CONFIG
}

bt_mark_container() {
    # bt_mark_container ROOTFS: make the tree look like the container build
    # buildtasks produces, which is two things, both from its
    # patches/container/conf:
    #
    #   the marker under /var/lib/turnkey-info, which inithooks' unit
    #   conditions read and which `keel inspect` reads to call the machine a
    #   container (network.managed_by: host), and
    #
    #   REDIRECT_OUTPUT=true in /etc/default/inithooks, which sends first
    #   boot output to the log with a tail on the active console instead of
    #   writing it straight to tty1,
    #
    # and a drop-in that keeps the first boot off tty1.
    #
    # The last two are not cosmetic. The layer ships the plain appliance
    # inithooks.service, which runs the hooks with StandardOutput=tty on
    # /dev/tty1; the unit a container image gets instead logs to syslog and
    # the console. Nothing reads tty1 in a container nobody has attached to,
    # so a hook that prints more than the terminal buffer holds blocks in
    # the write and never returns. keel-nodebb found it the hard way, with
    # `./nodebb setup` asleep in n_tty_write and a first boot that never
    # finished; this is the same function, so the next hook that prints a
    # lot does not find it again.
    local rootfs=$1 defaults=$1/$BT_INITHOOKS_DEFAULT
    install -D -m 0644 /dev/null "$rootfs/$BT_CONTAINER_MARKER" || return 1
    if [ ! -f "$defaults" ]; then
        echo "boot-test: $defaults is not in the rootfs" >&2
        return 1
    fi
    sed -i '/REDIRECT_OUTPUT/ s/=.*/=true/' "$defaults" || return 1
    if ! grep -q '^REDIRECT_OUTPUT=true$' "$defaults"; then
        echo "boot-test: $defaults declares no REDIRECT_OUTPUT to set" >&2
        return 1
    fi
    install -D -m 0644 /dev/stdin "$rootfs/$BT_INITHOOKS_DROPIN" <<DROPIN || return 1
[Service]
StandardOutput=journal
StandardError=journal
DROPIN
}

bt_spec_targets() {
    # bt_spec_targets ROOTFS: the paths the spec is installed at.
    local relative
    for relative in $BT_SPEC_PATHS; do
        printf '%s/%s\n' "$1" "$relative"
    done
}

bt_spec_in_rootfs() {
    # bt_spec_in_rootfs SPEC ROOTFS: the spec with its secret references
    # pointed inside ROOTFS, printed on stdout. `keel spec apply` runs on
    # the host and resolves a secret path against the host, so the copy it
    # reads has to name the files this test wrote into the container.
    sed -E "s#^([[:space:]]*file:[[:space:]]*)(/etc/keel/secrets/)#\1$2\2#" "$1"
}

bt_random_password() {
    # A fixed block is read first and filtered afterwards. The other way
    # round, "tr < source | head -c N", leaves tr killed by SIGPIPE when
    # head has its N characters, and the set -o pipefail of boot-test.sh
    # turns that into exit 141 before the container is ever started.
    local pool source=${BT_RANDOM_SOURCE:-/dev/urandom}
    pool=$(head -c "$BT_RANDOM_BYTES" "$source" | LC_ALL=C tr -dc 'A-Za-z0-9')
    if [ "${#pool}" -lt "$BT_PASSWORD_LENGTH" ]; then
        echo "boot-test: $source gave only ${#pool} usable characters" >&2
        return 1
    fi
    printf '%s\n' "${pool:0:BT_PASSWORD_LENGTH}"
}

bt_secret_targets() {
    # bt_secret_targets ROOTFS: the secret files the spec references.
    local name
    for name in $BT_SECRETS; do
        printf '%s/etc/keel/secrets/%s\n' "$1" "$name"
    done
}
bt_webmin_verdict() {
    # bt_webmin_verdict CODE: Webmin comes from core and is the panel this
    # layer would add a database module to if Debian packaged one, so the
    # boot test checks that it answers over IPv6 on 12321. It asks for
    # credentials, so 200 (the login page) and 401 are both an answer; 000
    # is curl failing to connect at all.
    case "${1-}" in
        200|401)
            echo "boot-test: webmin answered $1 on port $BT_WEBMIN_PORT"
            ;;
        *)
            echo "boot-test: webmin answered '${1-}' on port $BT_WEBMIN_PORT, not 200 or 401" >&2
            return 1
            ;;
    esac
}

bt_db_client_argv() {
    # bt_db_client_argv USER HOST PORT COMMAND...: the client command the
    # boot test runs inside the container, one argument per line. The
    # password is not here: it goes through REDISCLI_AUTH in the
    # environment, so it never appears in the container's process list.
    local user=$1 host=$2 port=$3
    shift 3
    [ -n "$user" ] && [ -n "$host" ] && [ $# -gt 0 ] || return 1
    case "$port" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' redis-cli -h "$host" -p "$port" --user "$user" "$@"
}

bt_db_denied_argv() {
    # bt_db_denied_argv HOST PORT: the same client with no account and no
    # password, asking for a key. What it must get back is a refusal.
    local host=$1 port=$2
    [ -n "$host" ] || return 1
    case "$port" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' redis-cli -h "$host" -p "$port" GET "$BT_DB_DENIED_KEY"
}

bt_db_verdict() {
    # bt_db_verdict OUTPUT: what the client printed when it authenticated
    # with the declared secret and sent PING. The whole point of this
    # appliance is that a declared secret reaches the server, so the answer
    # is the verdict.
    #
    # The answer and never the exit code, and this is the Redis trap the
    # whole test is shaped around: redis-cli exits 0 when the server
    # replies with an error. A wrong password prints "AUTH failed:
    # WRONGPASS ..." and exits 0, so a check on $? would call that a pass.
    local output
    output=$(printf '%s' "${1-}" | tr -d '[:space:]')
    if [ "$output" = "$BT_DB_PROBE_ANSWER" ]; then
        echo "boot-test: $BT_DB_USER authenticated on [$BT_DB_HOST]:$BT_DB_PORT with the declared secret"
        return 0
    fi
    echo "boot-test: the client answered '${1-}', not '$BT_DB_PROBE_ANSWER': the declared secret did not reach the server" >&2
    return 1
}

bt_db_marker_verdict() {
    # bt_db_marker_verdict EXPECTED OUTPUT: the value read back from the
    # key the same account wrote. An account that can authenticate and not
    # write would pass the check above and be useless, so the value
    # generated for this run is written and read as itself.
    local expected=${1-} got
    got=$(printf '%s' "${2-}" | tr -d '[:space:]')
    if [ -n "$expected" ] && [ "$got" = "$expected" ]; then
        echo "boot-test: $BT_DB_USER wrote and read $BT_DB_MARKER_KEY ($got)"
        return 0
    fi
    echo "boot-test: $BT_DB_MARKER_KEY read back as '$got', not '$expected'" >&2
    return 1
}

bt_db_denied_verdict() {
    # bt_db_denied_verdict OUTPUT: what a client with no secret was
    # answered for a key. NOPERM is the server refusing the command to the
    # default account, which is the other end of the same claim: the
    # declared secret means something only if nothing works without it.
    case "${1-}" in
        NOPERM*)
            echo "boot-test: a client with no secret is refused every key"
            return 0
            ;;
        *)
            echo "boot-test: a client with no secret was answered '${1-}' for a key, not NOPERM: this server hands its data to anyone who can reach it" >&2
            return 1
            ;;
    esac
}

bt_inspected_role() {
    # stdin: the spec `keel inspect` wrote. Prints the value of
    # database.server.role, and fails when the section is not there.
    #
    # keel writes the document with yaml.safe_dump at two spaces per level
    # (keel/inspect/emit.py), so database.server.role is a line at four
    # spaces under a "server:" at two under a "database:" at none. Read it
    # that way, in the shell, rather than with a YAML parser: this function
    # is measured line by line, and the indentation is the whole grammar
    # that matters. A "role:" anywhere else in the document is not this one,
    # which a grep would not have known.
    local line top="" inserver=0
    while IFS= read -r line; do
        case "$line" in
            [!\ ]*)
                top=${line%%:*}:
                inserver=0
                ;;
            "  server:")
                [ "$top" = "database:" ] && inserver=1
                ;;
            "  "[!\ ]*)
                inserver=0
                ;;
            "    role: "*)
                if [ "$inserver" = 1 ]; then
                    printf '%s\n' "${line#*: }"
                    return 0
                fi
                ;;
        esac
    done
    return 1
}

bt_role_verdict() {
    # bt_role_verdict ROLE: what `keel inspect` read back off the server.
    #
    # This is the check the next issue is built on. inspect reads the role
    # from INFO replication and INFO cluster, it never reads a secret to get
    # past a refusal, and a Redis it cannot ask is reported as a role it
    # could not infer: an appliance that cannot say it is standalone cannot
    # later say it is a primary or a replica either. It is also why the
    # declared secret here is an ACL user and not requirepass (unit-redis,
    # 20-keel-acl.conf).
    if [ "${1-}" = "$BT_ROLE_EXPECTED" ]; then
        echo "boot-test: keel inspect read database.server.role $1 off the server"
        return 0
    fi
    echo "boot-test: keel inspect read database.server.role '${1:-nothing}', not $BT_ROLE_EXPECTED (see the report above)" >&2
    return 1
}

bt_no_webmin_module_verdict() {
    # bt_no_webmin_module_verdict STATUS: what dpkg on the booted machine
    # says about a Webmin module for Redis, which must be nothing.
    #
    # keel-mariadb and keel-postgresql both check that theirs is installed.
    # Debian 13 packages no equivalent for Redis, so the absence is checked
    # rather than left as a silence somebody would have to go and confirm.
    #
    # dpkg and not apt-cache, and the difference matters: the image carries
    # no package lists at all, because conf.d/zz-project-packages removes
    # them with the build time archive, so an apt-cache search here would
    # answer nothing whatever the archive holds and would pass for the
    # wrong reason. Whether the archive offers one is a question with an
    # answer only at build time, and conf.d/main is where it is asked.
    if [ -z "$(printf '%s' "${1-}" | tr -d '[:space:]')" ]; then
        echo "boot-test: no Webmin module for Redis is installed, and Debian 13 packages none"
        return 0
    fi
    echo "boot-test: dpkg reports a Webmin module for Redis ('${1-}'), which this layer does not install" >&2
    return 1
}

bt_diff_verdict() {
    # bt_diff_verdict CODE: interprets the exit code of keel diff
    # (docs/diff.md of the keel repository). 0 and 13 mean no drift.
    #
    # 13 is the expected answer here and is worth knowing why: this test
    # runs keel diff against the container's rootfs as a directory, which
    # is an offline root, and an offline root cannot ask a server what it
    # is. So the whole database.server section the description declares is
    # unknown rather than drift. The role itself is checked live, on the
    # running machine, by bt_role_verdict.
    case "$1" in
        0) echo "keel diff: no drift"; return 0 ;;
        13) echo "keel diff: no drift, but a declared field could not be observed offline (see the report above)"; return 0 ;;
        14) echo "keel diff: drift found" >&2; return 1 ;;
        2|3) echo "keel diff: the spec is unreadable or invalid (exit $1)" >&2; return 1 ;;
        *) echo "keel diff: failed with exit $1" >&2; return 1 ;;
    esac
}
