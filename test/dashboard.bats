load test_helper
setup() {
  setup_common
  for l in helpers caddy process commands dashboard; do . "$REPO_ROOT/lib/$l.sh"; done
  fs_ensure_home
}

@test "render marks the selected row and lists sites" {
  fs_registry_set a.test /p/a 8000 8.4
  fs_registry_set b.test /p/b 8001 8.5
  run fs_dash_render 1
  [[ "$output" == *"a.test"* ]]
  [[ "$output" == *"b.test"* ]]
  # second row (index 1) is selected
  [[ "$output" == *"> b.test"* ]]
}

@test "dash_action open triggers the opener" {
  fs_registry_set a.test /p/a 8000 8.4
  make_stub open "$BATS_TEST_TMPDIR/open.log"; export FS_OPEN_BIN=open
  run fs_dash_action o a.test
  [ "$output" = "open" ]
  grep -q "https://a.test" "$BATS_TEST_TMPDIR/open.log"
}

@test "dash_action q returns quit" {
  run fs_dash_action q a.test
  [ "$output" = "quit" ]
}
