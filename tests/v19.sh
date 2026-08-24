#!/bin/bash
set -Eeuo pipefail
umask 077

result=${TKL_TEST_RESULT:?TKL_TEST_RESULT is required}
admin_password=${TKL_TEST_APP_PASS:?TKL_TEST_APP_PASS is required}
response=/tmp/tkl-redis-response.$$
pm2_state=/tmp/tkl-redis-pm2.$$
policy=/tmp/tkl-redis-policy.$$

cleanup() {
    rm -f -- "$response" "$pm2_state" "$policy"
}
trap cleanup EXIT

systemctl --quiet is-active redis-server.service nginx.service \
    pm2-node.service multi-user.target
systemctl --quiet is-enabled redis-server.service pm2-node.service
nginx -t

redis_version=$(dpkg-query -W -f='${Version}' redis-server)
redis_tools_version=$(dpkg-query -W -f='${Version}' redis-tools)
node_version=$(dpkg-query -W -f='${Version}' nodejs)
npm_version=$(dpkg-query -W -f='${Version}' npm)
nginx_version=$(dpkg-query -W -f='${Version}' nginx)

node_path=$(readlink -f "$(command -v node)")
npm_path=$(readlink -f "$(command -v npm)")
dpkg-query -S "$node_path" | grep -q '^nodejs:'
dpkg-query -S "$npm_path" | grep -q '^npm:'
[[ $(node --version) == v20.* ]]
test "$(su node -s /bin/bash -c 'npm config get cafile')" = \
    /etc/ssl/certs/ca-certificates.crt

grep -Fxq 'bind 0.0.0.0' /etc/redis/redis.conf
grep -Fxq 'protected-mode yes' /etc/redis/redis.conf
redis_password=$(turnkey-redis-pw get)
test -n "$redis_password"
grep -Fxq "requirepass $redis_password" /etc/redis/redis.conf

redis-cli ping >"$response" 2>&1 || true
grep -q 'NOAUTH' "$response"
test "$(redis-cli --no-auth-warning -a "$redis_password" ping)" = PONG

key="turnkey:v19:persistence:$$"
value="redis-v19-main-flow-$$"
test "$(redis-cli --no-auth-warning -a "$redis_password" set "$key" "$value")" = OK
test "$(redis-cli --no-auth-warning -a "$redis_password" save)" = OK
systemctl restart redis-server.service
for _ in {1..20}; do
    if redis-cli --no-auth-warning -a "$redis_password" ping \
            2>/dev/null | grep -qx PONG; then
        break
    fi
    sleep 1
done
test "$(redis-cli --no-auth-warning -a "$redis_password" get "$key")" = \
    "$value"
test "$(redis-cli --no-auth-warning -a "$redis_password" del "$key")" = 1
test "$(redis-cli --no-auth-warning -a "$redis_password" exists "$key")" = 0

unauth_status=$(curl --insecure --silent --output /dev/null \
    --write-out '%{http_code}' https://127.0.0.1/redis-commander/)
test "$unauth_status" = 401
curl --insecure --fail --silent --show-error \
    --user "admin:$admin_password" \
    https://127.0.0.1/redis-commander/ >"$response"
grep -qi 'redis commander' "$response"
curl --insecure --fail --silent --show-error https://127.0.0.1/ \
    >"$response"
grep -q 'Redis GUI' "$response"
grep -q ':12321' "$response"

su node -s /bin/bash -c \
    'PM2_HOME=/home/node/.pm2 /usr/local/lib/node_modules/pm2/bin/pm2 jlist' \
    >"$pm2_state"
python3 - "$pm2_state" <<'PYTHON'
import json
import sys

processes = json.load(open(sys.argv[1]))
names = {
    process.get("name")
    for process in processes
    if process.get("pid", 0) > 0
    and process.get("pm2_env", {}).get("status") == "online"
}
assert "Redis-commander" in names
assert "TurnKey Linux CP" in names
PYTHON

commander_version=$(node -p \
    "require('/opt/tklweb-cp/node_modules/redis-commander/package.json').version")
commander_candidate=$(su node -s /bin/bash -c \
    'cd /opt/tklweb-cp && npm view redis-commander version')
test -n "$commander_candidate"
test -f /opt/tklweb-cp/package-lock.json
node - "$commander_version" <<'NODE'
const lock = require('/opt/tklweb-cp/package-lock.json');
const expected = process.argv[2];
const commander = lock.packages['node_modules/redis-commander'];
if (!commander || commander.version !== expected || !commander.integrity) {
  process.exit(1);
}
const dependencies = Object.entries(lock.packages || {})
  .filter(([path]) => path.startsWith('node_modules/'));
if (!dependencies.length || dependencies.some(([, pkg]) => !pkg.integrity)) {
  process.exit(1);
}
NODE

before="$redis_version|$redis_tools_version|$node_version|$npm_version|$nginx_version"
apt-get update >/dev/null
for package in redis-server redis-tools nodejs npm nginx; do
    apt-cache policy "$package" >"$policy"
    candidate=$(awk '/Candidate:/ {print $2}' "$policy")
    test -n "$candidate"
    test "$candidate" != '(none)'
    grep -Eq 'https?://(deb|security)\.debian\.org/.*trixie' "$policy"
done
after="$(dpkg-query -W -f='${Version}' redis-server)|$(dpkg-query -W -f='${Version}' redis-tools)|$(dpkg-query -W -f='${Version}' nodejs)|$(dpkg-query -W -f='${Version}' npm)|$(dpkg-query -W -f='${Version}' nginx)"
test "$after" = "$before"
grep -Rqs '^Suites: trixie' /etc/apt/sources.list.d
! grep -Rqi bookworm /etc/apt/sources.list.d

cat >"$result" <<EOF
package_source=Debian 13 Trixie APT repositories for Redis Server, Redis tools, Node.js, npm and Nginx; official npm registry for Redis Commander and application dependencies
installed_version=redis-server $redis_version; redis-tools $redis_tools_version; nodejs $node_version; npm $npm_version; nginx $nginx_version; redis-commander $commander_version
runtime_checks=normal init; authenticated Redis PING; unauthenticated denial; configured all-interface bind and protected mode; set, get, synchronous save, service restart, persisted get and delete round trip; Redis Commander HTTP authentication and page; landing page; Redis Commander and TurnKey control panel online under PM2
updater_command=apt-get update; apt-cache policy redis-server redis-tools nodejs npm nginx; npm view redis-commander version; npm install redis-commander@latest
updater_result=signed Debian metadata refreshed; installed packages unchanged; Redis Commander registry candidate $commander_candidate; package-lock integrity fields present
updater_channel=Debian Trixie APT repositories and official npm registry
integrity_evidence=APT accepted signed Debian metadata; npm dependency lock records registry integrity hashes; no Bookworm source remained
EOF
