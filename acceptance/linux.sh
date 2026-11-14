#!/usr/bin/env bash
set -euo pipefail
umask 077
check_dir=$(cd "$(dirname "$0")" && pwd)
test "$(uname -m)" = x86_64
root=$(mktemp -d)
mysql_container="workbench-clean-${GITHUB_RUN_ID:-$$}"
pids=()
cleanup() {
  rc=$?
  trap - EXIT
  if (( rc != 0 )); then
    for log in temporal worker harness channels; do
      if [[ -f $root/$log.log ]]; then
        printf '\n%s log tail\n' "$log"
        tail -25 "$root/$log.log" | sed -E 's/(\?token=)[^[:space:]]+/\1[redacted]/g'
      fi
    done
    docker logs --tail 15 "$mysql_container" 2>/dev/null || true
  fi
  for pid in "${pids[@]}"; do kill "$pid" 2>/dev/null || true; done
  docker rm -f "$mysql_container" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT

mkdir "$root/app"
tar -xzf "$1" -C "$root/app"
cd "$root/app"
export PATH="$PWD/node/bin:$PATH"

docker run -d --name "$mysql_container" -p 127.0.0.1:3306:3306 -e MYSQL_ALLOW_EMPTY_PASSWORD=yes mysql:8.4
for i in {1..90}; do
  if docker exec "$mysql_container" mysqladmin --protocol=TCP ping -uroot --silent >/dev/null 2>&1; then break; fi
  sleep 2
done
sql() { docker exec -i "$mysql_container" mysql --protocol=TCP -uroot --batch --skip-column-names "$@"; }
sql <<'SQL'
CREATE DATABASE workbench CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE DATABASE temporal CHARACTER SET utf8mb4;
CREATE DATABASE temporal_visibility CHARACTER SET utf8mb4;
CREATE USER 'workbench'@'%' IDENTIFIED BY 'isolated-test-only';
GRANT ALL ON workbench.* TO 'workbench'@'%';
GRANT ALL ON temporal.* TO 'workbench'@'%';
GRANT ALL ON temporal_visibility.* TO 'workbench'@'%';
SQL
test "$(sql -e 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema IN ("workbench","temporal","temporal_visibility")')" = 0
echo 'Three empty MySQL databases verified'

for pair in temporal:temporal temporal_visibility:visibility; do
  database=${pair%:*}
  schema=${pair#*:}
  sql "$database" <<'SQL'
CREATE TABLE schema_version (version_partition INT NOT NULL, db_name VARCHAR(255) NOT NULL, creation_time DATETIME(6), curr_version VARCHAR(64), min_compatible_version VARCHAR(64), PRIMARY KEY(version_partition,db_name));
SQL
  version=1.19
  if [[ $schema == visibility ]]; then version=1.14; fi
  curl --retry 3 -fsSL "https://raw.githubusercontent.com/temporalio/temporal/v1.32.2/schema/mysql/v8/$schema/schema.sql" | sql "$database"
  sql "$database" -e "INSERT INTO schema_version VALUES (0,'$database',NOW(6),'$version','0.0')"
done

python3 "$check_dir/temporal-config.py" > "$root/temporal.json"
temporal/temporal-server --config-file "$root/temporal.json" start >"$root/temporal.log" 2>&1 &
pids+=("$!")
for i in {1..90}; do
  if (echo >/dev/tcp/127.0.0.1/7233) 2>/dev/null; then break; fi
  kill -0 "${pids[-1]}" 2>/dev/null
  sleep 1
done

export WORKBENCH_HOST_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
export WORKBENCH_CONNECTOR_TOKEN="$(python3 -c 'import secrets; print(secrets.token_hex(32))')"
echo "::add-mask::$WORKBENCH_HOST_TOKEN"
echo "::add-mask::$WORKBENCH_CONNECTOR_TOKEN"
export DSH_HOME="$PWD/data/harness"
export WORKBENCH_PERSONAL_WORKSPACE="$PWD/data/today"
export WORKBENCH_VAULT_ROOT="$PWD/data/vaults"
export WORKBENCH_CHANNEL_LINK_DIR="$PWD/data/channels"
export WORKBENCH_CHANNEL_CONFIG="$PWD/data/channels.json"
export WORKBENCH_RESOURCE_ACL_EDIT=1
export WORKBENCH_MYSQL_DSN='workbench:isolated-test-only@tcp(127.0.0.1:3306)/workbench'
export WORKBENCH_SOURCE_INSTALL_MYSQL_DSN="$WORKBENCH_MYSQL_DSN"
export TEMPORAL_ADDRESS=127.0.0.1:7233 TEMPORAL_NAMESPACE=workbench
export WORKBENCH_PUBLIC_HOST=127.0.0.1 DSH_BUNDLED_SKILL_DIR="$PWD/skills"
export WORKBENCH_DEPLOYMENT_MARKER="$root/.deploying"
curl --retry 3 -fsSL 'https://github.com/temporalio/cli/releases/download/v1.10.0/temporal_cli_1.10.0_linux_amd64.tar.gz' -o "$root/temporal-cli.tar.gz"
printf '521f461f3d108902763bb71e85cd0fd382dc9357b59604ae03da6ae734d16890  %s\n' "$root/temporal-cli.tar.gz" | sha256sum -c
mkdir "$root/temporal-cli"
tar -xzf "$root/temporal-cli.tar.gz" -C "$root/temporal-cli"
"$root/temporal-cli/temporal" operator namespace create --address "$TEMPORAL_ADDRESS" --namespace "$TEMPORAL_NAMESPACE" --retention 168h
for i in {1..60}; do
  if "$root/temporal-cli/temporal" operator namespace describe --address "$TEMPORAL_ADDRESS" --namespace "$TEMPORAL_NAMESPACE" >/dev/null 2>&1; then break; fi
  sleep 1
done
export DEEPSEEK_BASE_URL=http://127.0.0.1:17770 DEEPSEEK_API_KEY=local-fixture-provider-key
mkdir -p "$DSH_HOME" "$WORKBENCH_PERSONAL_WORKSPACE" "$WORKBENCH_VAULT_ROOT" "$WORKBENCH_CHANNEL_LINK_DIR"
ln -sfn "$PWD/runtime/node_modules" "$DSH_HOME/node_modules"
printf '[]\n' > "$WORKBENCH_CHANNEL_CONFIG"
sql workbench -e 'CREATE TABLE install_fixture (id INT PRIMARY KEY, title VARCHAR(100)); INSERT INTO install_fixture VALUES (1,"clean-install-marker"), (2,"second-row");'
python3 "$check_dir/model-fixture.py" >"$root/model.log" 2>&1 &
pids+=("$!")

start_app() {
  bin/workbench-worker >"$root/worker.log" 2>&1 &
  worker_pid=$!
  pids+=("$worker_pid")
  for i in {1..90}; do
    if curl -fsS http://127.0.0.1:7381/health 2>/dev/null | grep -q '"backgroundReady":true'; then break; fi
    kill -0 "$worker_pid" 2>/dev/null
    sleep 1
  done
  curl -fsS http://127.0.0.1:7381/health | grep -q '"backgroundReady":true'
  node runtime/node_modules/@deepseek-ai/dsh/lib/bin.js web --patch "$PWD/runtime/harness/cordis.patch.yml" --no-open --host 127.0.0.1 --port 3082 >"$root/harness.log" 2>&1 &
  host_pid=$!
  pids+=("$host_pid")
  for i in {1..90}; do
    if grep -q 'http://127.0.0.1:3082/?token=' "$root/harness.log"; then break; fi
    kill -0 "$host_pid"
    sleep 1
  done
  export TEST_LAUNCH_URL
  TEST_LAUNCH_URL=$(grep -o 'http://127.0.0.1:3082/?token=[^[:space:]]*' "$root/harness.log" | tail -1)
  echo "::add-mask::${TEST_LAUNCH_URL#*token=}"
  node runtime/connectors/server.mjs >"$root/channels.log" 2>&1 &
  connector_pid=$!
  pids+=("$connector_pid")
  for i in {1..60}; do
    if curl -fsS -H "Authorization: Bearer $WORKBENCH_CONNECTOR_TOKEN" http://127.0.0.1:7383/health 2>/dev/null | grep -q '"ready":true'; then return; fi
    kill -0 "$connector_pid"
    sleep 1
  done
  return 1
}
start_app
echo 'Packaged Worker, Harness and channels started'
python3 "$check_dir/smoke.py" "$root" first
npm install --prefix "$root/playwright" --no-audit --no-fund --save-exact playwright@1.65.1
"$root/playwright/node_modules/.bin/playwright" install --with-deps chromium
cp "$check_dir/browser.mjs" "$root/playwright/browser.mjs"
node "$root/playwright/browser.mjs"
kill "$connector_pid" "$host_pid" "$worker_pid"
wait "$connector_pid" "$host_pid" "$worker_pid" || true
kill "${pids[0]}"
wait "${pids[0]}" || true
temporal/temporal-server --config-file "$root/temporal.json" start >"$root/temporal.log" 2>&1 &
pids+=("$!")
for i in {1..90}; do
  if (echo >/dev/tcp/127.0.0.1/7233) 2>/dev/null; then break; fi
  kill -0 "${pids[-1]}" 2>/dev/null
  sleep 1
done
start_app
python3 "$check_dir/smoke.py" "$root" restart
echo 'Clean Linux installation accepted'
