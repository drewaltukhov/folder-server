load test_helper
setup() {
  setup_common
  . "$REPO_ROOT/lib/helpers.sh"
  . "$REPO_ROOT/lib/caddy.sh"
  . "$REPO_ROOT/lib/process.sh"
  . "$REPO_ROOT/lib/commands.sh"
  fs_ensure_home
  PROJ="$BATS_TEST_TMPDIR/My-App"
  mkdir -p "$PROJ"
}

# A mysql stub: the readiness probe (`-e`) succeeds instantly; the provisioning
# call reads SQL from stdin and logs it.
_stub_mysql() {
  local dir="$BATS_TEST_TMPDIR/stubbin"
  mkdir -p "$dir"
  cat >"$dir/mysql" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "-e" ] && exit 0; done
cat >>"$BATS_TEST_TMPDIR/mysql.sql"
EOF
  chmod +x "$dir/mysql"
  export PATH="$dir:$PATH"
  export FS_MYSQL_BIN=mysql
  make_stub brew "$BATS_TEST_TMPDIR/brew.log"
  export FS_BREW_BIN=brew FS_MYSQL_FORMULA=mysql
}

@test "fs_default_dbname sanitizes the folder name" {
  run fs_default_dbname "$BATS_TEST_TMPDIR/My-Cool.App"
  [ "$output" = "my_cool_app" ]
}

@test "fs_db_enabled truthiness" {
  fs_db_enabled on
  fs_db_enabled true
  run fs_db_enabled off
  [ "$status" -ne 0 ]
  run fs_db_enabled ''
  [ "$status" -ne 0 ]
}

@test "resolve/load expose db fields with a defaulted db_name" {
  printf 'db=on\ndb_user=shopuser\ndb_pass=secret\n' >"$PROJ/.folderserver"
  _fs_load_config "$PROJ"
  [ "$FS_DB" = "on" ]
  [ "$FS_DB_USER" = "shopuser" ]
  [ "$FS_DB_PASS" = "secret" ]
  [ "$FS_DB_NAME" = "my_app" ]
}

@test "fs_write_config writes the db block only when enabled" {
  fs_write_config "$PROJ" app.test 8.4 "" "" on shop app secret
  grep -q '^db=on$' "$PROJ/.folderserver"
  grep -q '^db_name=shop$' "$PROJ/.folderserver"
  grep -q '^db_user=app$' "$PROJ/.folderserver"
  grep -q '^db_pass=secret$' "$PROJ/.folderserver"

  fs_write_config "$PROJ" app.test 8.4 "" "" off shop app secret
  run grep -q '^db' "$PROJ/.folderserver"
  [ "$status" -ne 0 ]
}

@test "fs_db_provision starts mysql and runs the create/grant SQL" {
  _stub_mysql
  run fs_db_provision shopdb shopuser 'p@ss'
  [ "$status" -eq 0 ]
  grep -q 'services start mysql' "$BATS_TEST_TMPDIR/brew.log"
  grep -q 'CREATE DATABASE IF NOT EXISTS `shopdb`' "$BATS_TEST_TMPDIR/mysql.sql"
  grep -q "CREATE USER IF NOT EXISTS 'shopuser'@'%' IDENTIFIED BY 'p@ss'" "$BATS_TEST_TMPDIR/mysql.sql"
  grep -q "ALTER USER 'shopuser'@'localhost' IDENTIFIED BY 'p@ss'" "$BATS_TEST_TMPDIR/mysql.sql"
  grep -q "GRANT ALL PRIVILEGES ON \`shopdb\`.\* TO 'shopuser'@'%'" "$BATS_TEST_TMPDIR/mysql.sql"
}

@test "fs_db_provision refuses to use the admin account as the app user" {
  _stub_mysql
  FS_MYSQL_ADMIN=root
  run fs_db_provision shopdb root secret
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot be 'root'"* ]]
  [ ! -f "$BATS_TEST_TMPDIR/mysql.sql" ]
}

@test "fs_db_provision escapes single quotes in the password" {
  _stub_mysql
  fs_db_provision shopdb shopuser "pa'ss"
  grep -q "IDENTIFIED BY 'pa''ss'" "$BATS_TEST_TMPDIR/mysql.sql"
}

@test "fs_db_provision rejects unsafe db name/user and dangerous passwords" {
  _stub_mysql
  run fs_db_provision 'bad-name' user pass
  [ "$status" -ne 0 ]
  run fs_db_provision db 'bad user' pass
  [ "$status" -ne 0 ]
  run fs_db_provision db user 'has`backtick'
  [ "$status" -ne 0 ]
}

@test "up provisions the database when db=on" {
  _stub_mysql
  make_stub caddy "$BATS_TEST_TMPDIR/caddy.log"; export FS_CADDY_BIN=caddy
  export FS_CADDY_CONFIG="$BATS_TEST_TMPDIR/Caddyfile"
  mkdir -p "$FS_BREW_OPT/php@8.4/bin"
  printf '#!/usr/bin/env bash\nexec sleep 30\n' >"$FS_BREW_OPT/php@8.4/bin/php"
  chmod +x "$FS_BREW_OPT/php@8.4/bin/php"
  printf 'domain=app.test\ndb=on\ndb_name=shopdb\ndb_user=shopuser\ndb_pass=secret\n' >"$PROJ/.folderserver"

  run fs_cmd_up "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"MySQL ready"* ]]
  [[ "$output" == *"host      127.0.0.1"* ]]
  [[ "$output" == *"port      3306"* ]]
  [[ "$output" == *"database  shopdb"* ]]
  [[ "$output" == *"user      shopuser"* ]]
  [[ "$output" == *"password  secret"* ]]
  grep -q 'CREATE DATABASE IF NOT EXISTS `shopdb`' "$BATS_TEST_TMPDIR/mysql.sql"

  fs_stop_php app.test >/dev/null 2>&1 || true
}
