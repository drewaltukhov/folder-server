load test_helper
setup() {
  setup_common
  for l in helpers process commands; do . "$REPO_ROOT/lib/$l.sh"; done
  . "$REPO_ROOT/lib/caddy.sh"
  fs_ensure_home
}

@test "list shows registered sites with status" {
  fs_registry_set a.test /p/a 8000 8.4
  run fs_cmd_list
  [ "$status" -eq 0 ]
  [[ "$output" == *"a.test"* ]]
  [[ "$output" == *"stopped"* ]]
  [[ "$output" == *"https://a.test"* ]]
}

@test "open invokes the opener with the url" {
  fs_registry_set a.test /p/a 8000 8.4
  make_stub open "$BATS_TEST_TMPDIR/open.log"; export FS_OPEN_BIN=open
  PROJ="$BATS_TEST_TMPDIR/a"; mkdir -p "$PROJ"
  printf 'domain=a.test\n' >"$PROJ/.folderserver"
  run fs_cmd_open "$PROJ"
  [ "$status" -eq 0 ]
  grep -q "https://a.test" "$BATS_TEST_TMPDIR/open.log"
}

@test "logs notices when no log exists" {
  PROJ="$BATS_TEST_TMPDIR/b"; mkdir -p "$PROJ"
  printf 'domain=b.test\n' >"$PROJ/.folderserver"
  run fs_cmd_logs "$PROJ"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no log"* ]]
}
