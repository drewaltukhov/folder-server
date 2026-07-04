load test_helper
setup() {
  setup_common
  for l in helpers commands; do . "$REPO_ROOT/lib/$l.sh"; done
  PROJ="$BATS_TEST_TMPDIR/My-App"; mkdir -p "$PROJ"
}

@test "init writes defaults non-interactively" {
  run fs_cmd_init "$PROJ"
  [ "$status" -eq 0 ]
  [ -f "$PROJ/.folderserver" ]
  grep -q "domain=my-app.test" "$PROJ/.folderserver"
  grep -q "php=8.4" "$PROJ/.folderserver"
}

@test "init refuses to overwrite without --force" {
  printf 'domain=existing.test\n' >"$PROJ/.folderserver"
  run fs_cmd_init "$PROJ"
  [ "$status" -ne 0 ]
  grep -q "existing.test" "$PROJ/.folderserver"
}

@test "init --force overwrites" {
  printf 'domain=existing.test\n' >"$PROJ/.folderserver"
  run fs_cmd_init "$PROJ" --force
  [ "$status" -eq 0 ]
  grep -q "domain=my-app.test" "$PROJ/.folderserver"
}
