#!/bin/bash
set -Eeuo pipefail
umask 077

workdir=$(mktemp -d)
commander_pid=

cleanup() {
    if [[ -n "$commander_pid" ]]; then
        kill "$commander_pid" 2>/dev/null || true
        wait "$commander_pid" 2>/dev/null || true
    fi
    rm -rf -- "$workdir"
}
trap cleanup EXIT

export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
apt-get install -y ca-certificates curl nodejs npm redis-server redis-tools \
    >/dev/null

redis_password=turnkey-v19-upgrade-fixture
redis-server --daemonize yes --bind 127.0.0.1 --protected-mode yes \
    --requirepass "$redis_password"

cd "$workdir"
npm init -y >/dev/null
npm install --save-exact redis-commander@0.8.0 >/dev/null

start_commander() {
    HTTP_USER=admin HTTP_PASSWORD=fixture \
        node node_modules/redis-commander/bin/redis-commander.js \
        --address 127.0.0.1 --port 8082 \
        --redis-user default --redis-password "$redis_password" \
        >commander.log 2>&1 &
    commander_pid=$!
    for _ in {1..30}; do
        if curl --fail --silent --user admin:fixture \
                http://127.0.0.1:8082/ | grep -qi 'redis commander'; then
            return
        fi
        sleep 1
    done
    cat commander.log >&2
    return 1
}

stop_commander() {
    kill "$commander_pid"
    wait "$commander_pid" 2>/dev/null || true
    commander_pid=
}

test "$(redis-cli --no-auth-warning -a "$redis_password" \
    set turnkey:v19:upgrade preserved)" = OK
old_version=$(node -p "require('redis-commander/package.json').version")
start_commander
stop_commander

npm install --save-exact redis-commander@latest >/dev/null
new_version=$(node -p "require('redis-commander/package.json').version")
candidate=$(npm view redis-commander version)
test "$old_version" != "$new_version"
test "$new_version" = "$candidate"
node - <<'NODE'
const lock = require('./package-lock.json');
const commander = lock.packages['node_modules/redis-commander'];
if (!commander || !commander.integrity) process.exit(1);
const dependencies = Object.entries(lock.packages || {})
  .filter(([path]) => path.startsWith('node_modules/'));
if (!dependencies.length || dependencies.some(([, pkg]) => !pkg.integrity)) {
  process.exit(1);
}
NODE

start_commander
test "$(redis-cli --no-auth-warning -a "$redis_password" \
    get turnkey:v19:upgrade)" = preserved

printf 'old_version=%s\nnew_version=%s\nregistry_candidate=%s\n' \
    "$old_version" "$new_version" "$candidate"
