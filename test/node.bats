load test_helper
setup() {
  setup_common
  . "$REPO_ROOT/lib/helpers.sh"
  . "$REPO_ROOT/lib/caddy.sh"
  . "$REPO_ROOT/lib/process.sh"
  . "$REPO_ROOT/lib/commands.sh"
  fs_ensure_home
  make_stub caddy "$BATS_TEST_TMPDIR/caddy.log"; export FS_CADDY_BIN=caddy
  export FS_CADDY_CONFIG="$BATS_TEST_TMPDIR/Caddyfile"
  export FS_NODE_PORT_WAIT=1   # don't wait long for a log port in tests
  PROJ="$BATS_TEST_TMPDIR/proj"; mkdir -p "$PROJ"
}
teardown() { fs_stop_proc app.test >/dev/null 2>&1 || true; }

# --- detection ---

@test "fs_detect_node true only with package.json" {
  run fs_detect_node "$PROJ"; [ "$status" -ne 0 ]
  : >"$PROJ/package.json"
  run fs_detect_node "$PROJ"; [ "$status" -eq 0 ]
}

@test "fs_detect_pm from lockfiles" {
  : >"$PROJ/package.json"
  [ "$(fs_detect_pm "$PROJ")" = npm ]
  : >"$PROJ/pnpm-lock.yaml"; [ "$(fs_detect_pm "$PROJ")" = pnpm ]
  rm "$PROJ/pnpm-lock.yaml"; : >"$PROJ/yarn.lock"; [ "$(fs_detect_pm "$PROJ")" = yarn ]
  rm "$PROJ/yarn.lock"; : >"$PROJ/bun.lockb"; [ "$(fs_detect_pm "$PROJ")" = bun ]
}

@test "fs_detect_command per package manager" {
  : >"$PROJ/package.json"
  [ "$(fs_detect_command "$PROJ" dev)" = "npm run dev" ]
  [ "$(fs_detect_command "$PROJ" build)" = "npm run build" ]
  : >"$PROJ/pnpm-lock.yaml"
  [ "$(fs_detect_command "$PROJ" dev)" = "pnpm dev" ]
}

@test "fs_detect_port from framework" {
  printf '{"devDependencies":{"vite":"5"}}' >"$PROJ/package.json"
  [ "$(fs_detect_port "$PROJ")" = 5173 ]
  printf '{"dependencies":{"astro":"4"}}' >"$PROJ/package.json"
  [ "$(fs_detect_port "$PROJ")" = 4321 ]
  printf '{"dependencies":{"next":"14"}}' >"$PROJ/package.json"
  [ "$(fs_detect_port "$PROJ")" = 3000 ]
}

# --- config round-trip ---

@test "write + resolve node dev config" {
  fs_write_config "$PROJ" app.test 8.4 "" "" off "" "" "" node dev "npm run dev" "npm run build" 5173
  grep -q '^type=node$' "$PROJ/.folderserver"
  grep -q '^mode=dev$' "$PROJ/.folderserver"
  grep -q '^command=npm run dev$' "$PROJ/.folderserver"
  grep -q '^port=5173$' "$PROJ/.folderserver"
  run grep -q '^php=' "$PROJ/.folderserver"; [ "$status" -ne 0 ]   # no php for node
  _fs_load_config "$PROJ"
  [ "$FS_TYPE" = node ]; [ "$FS_MODE" = dev ]; [ "$FS_COMMAND" = "npm run dev" ]; [ "$FS_PORT" = 5173 ]
}

@test "write node build config keeps docroot + rewrite" {
  fs_write_config "$PROJ" b.test 8.4 dist index.html off "" "" "" node build "" "npm run build" ""
  grep -q '^type=node$' "$PROJ/.folderserver"
  grep -q '^mode=build$' "$PROJ/.folderserver"
  grep -q '^build=npm run build$' "$PROJ/.folderserver"
  grep -q '^docroot=dist$' "$PROJ/.folderserver"
  grep -q '^rewrite=index.html$' "$PROJ/.folderserver"
}

@test "init (non-interactive) writes a node config in a node folder" {
  : >"$PROJ/package.json"; : >"$PROJ/pnpm-lock.yaml"
  run fs_cmd_init "$PROJ"
  [ "$status" -eq 0 ]
  grep -q '^type=node$' "$PROJ/.folderserver"
  grep -q '^command=pnpm dev$' "$PROJ/.folderserver"
}

# --- serving ---

@test "caddy static render has root + file_server + spa fallback" {
  run fs_render_static_site app.test /srv/out index.html
  [[ "$output" == *"root * /srv/out"* ]]
  [[ "$output" == *"file_server"* ]]
  [[ "$output" == *"try_files {path} /index.html"* ]]
}

@test "up node-dev runs the command and proxies to its port" {
  printf 'domain=app.test\ntype=node\ncommand=sleep 30\nport=9191\n' >"$PROJ/.folderserver"
  run fs_cmd_up "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"node dev"* ]]
  fs_is_running app.test
  grep -q "reverse_proxy 127.0.0.1:9191" "$FS_CADDY_SITES/app.test.caddy"
  # Host rewritten to loopback so the dev server doesn't block the proxied host
  grep -q "header_up Host 127.0.0.1:9191" "$FS_CADDY_SITES/app.test.caddy"
  [ "$(fs_registry_field app.test 4)" = "node dev" ]
}

@test "fs_detect_running_port reads the port from the dev log" {
  local log; log="$(fs_logfile x.test)"
  printf ' astro  v5 ready\n Local  http://localhost:4329/\n' >"$log"
  [ "$(fs_detect_running_port x.test 8001)" = 4329 ]
  # falls back when the log has no URL
  : >"$(fs_logfile y.test)"
  [ "$(fs_detect_running_port y.test 8001)" = 8001 ]
}

@test "up node-build runs build and serves the output statically (no process)" {
  printf 'domain=b.test\ntype=node\nmode=build\nbuild=mkdir -p out && echo hi > out/index.html\ndocroot=out\nrewrite=index.html\n' >"$PROJ/.folderserver"
  run fs_cmd_up "$PROJ"
  [ "$status" -eq 0 ]
  [ -f "$PROJ/out/index.html" ]                                   # build ran
  grep -q "file_server" "$FS_CADDY_SITES/b.test.caddy"
  grep -q "root \* $PROJ/out" "$FS_CADDY_SITES/b.test.caddy"
  run fs_is_running b.test; [ "$status" -ne 0 ]                   # no process
  [ "$(fs_site_status b.test)" = served ]                         # but served
}

@test "up node errors clearly when dependencies aren't installed" {
  : >"$PROJ/package.json"                      # node folder, no node_modules/
  printf 'domain=app.test\ntype=node\ncommand=sleep 30\n' >"$PROJ/.folderserver"
  run fs_cmd_up "$PROJ"
  [ "$status" -ne 0 ]
  [[ "$output" == *"dependencies not installed"* ]]
  [[ "$output" == *"npm install"* ]]
}

@test "fs_node_install_hint per package manager" {
  : >"$PROJ/package.json"
  [ "$(fs_node_install_hint "$PROJ")" = "npm install" ]
  : >"$PROJ/yarn.lock"; [ "$(fs_node_install_hint "$PROJ")" = "yarn" ]
  rm "$PROJ/yarn.lock"; : >"$PROJ/pnpm-lock.yaml"; [ "$(fs_node_install_hint "$PROJ")" = "pnpm install" ]
}

@test "up node with install=on auto-installs missing deps then serves" {
  : >"$PROJ/package.json"
  # stub npm so 'npm install' creates node_modules
  local sb="$BATS_TEST_TMPDIR/stubbin"; mkdir -p "$sb"
  cat >"$sb/npm" <<EOF
#!/usr/bin/env bash
[ "\$1" = install ] && mkdir -p "$PROJ/node_modules"
exit 0
EOF
  chmod +x "$sb/npm"; export PATH="$sb:$PATH"
  printf 'domain=app.test\ntype=node\ninstall=on\ncommand=sleep 30\nport=9292\n' >"$PROJ/.folderserver"
  run fs_cmd_up "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installing dependencies"* ]]
  [ -d "$PROJ/node_modules" ]
}

@test "init in a node folder enables auto-install by default" {
  : >"$PROJ/package.json"
  run fs_cmd_init "$PROJ"
  [ "$status" -eq 0 ]
  grep -q '^install=on$' "$PROJ/.folderserver"
}

@test "fs_site_status: running / served / stopped" {
  # stopped: nothing
  [ "$(fs_site_status ghost.test)" = stopped ]
  # served: snippet exists, no process
  fs_write_static_site s.test /srv index.html
  [ "$(fs_site_status s.test)" = served ]
}

@test "fs_kill_tree kills a parent and its child" {
  bash -c 'sleep 30 & echo $! >"'"$BATS_TEST_TMPDIR"'/child.pid"; sleep 30' &
  local parent=$!
  sleep 0.5
  local child; child="$(cat "$BATS_TEST_TMPDIR/child.pid")"
  kill -0 "$child" 2>/dev/null   # child alive
  fs_kill_tree "$parent"
  sleep 0.5
  run kill -0 "$child" 2>/dev/null
  [ "$status" -ne 0 ]            # child gone too
}
