load test_helper
setup() {
  setup_common
  for l in helpers commands; do . "$REPO_ROOT/lib/$l.sh"; done
  PROJ="$BATS_TEST_TMPDIR/My-App"; mkdir -p "$PROJ"
}

@test "init writes php defaults non-interactively when php is installed" {
  install_php_stub 8.4
  run fs_cmd_init "$PROJ"
  [ "$status" -eq 0 ]
  [ -f "$PROJ/.folderserver" ]
  grep -q "domain=my-app.test" "$PROJ/.folderserver"
  grep -q "php=8.4" "$PROJ/.folderserver"
}

@test "init defaults to static non-interactively when no php is installed" {
  # no install_php_stub → fs_have_php is false → static default
  run fs_cmd_init "$PROJ"
  [ "$status" -eq 0 ]
  grep -q "domain=my-app.test" "$PROJ/.folderserver"
  grep -q "^type=static$" "$PROJ/.folderserver"
  run grep -qE '^(php=|type=node)' "$PROJ/.folderserver"; [ "$status" -ne 0 ]
}

@test "init in a node folder stays node even with no php" {
  printf '{}\n' >"$PROJ/package.json"
  run fs_cmd_init "$PROJ"
  [ "$status" -eq 0 ]
  grep -q "^type=node$" "$PROJ/.folderserver"
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

@test "init registers the site (dir set, port blank) so it is known without a prior up" {
  install_php_stub 8.4
  run fs_cmd_init "$PROJ"
  [ "$status" -eq 0 ]
  run fs_registry_field my-app.test 2
  [ "$status" -eq 0 ]
  [ "$output" = "$PROJ" ]
  # port stays blank until the first 'fs up'
  run fs_registry_field my-app.test 3
  [ -z "$output" ]
}

@test "init records a runtime label matching the site type" {
  # no php installed -> static
  run fs_cmd_init "$PROJ"
  [ "$status" -eq 0 ]
  run fs_registry_field my-app.test 4
  [ "$output" = "static" ]
}

@test "init --force with a changed domain drops the stale registry row" {
  install_php_stub 8.4
  # simulate a site previously init'd under a different domain
  printf 'domain=old.test\ntype=static\n' >"$PROJ/.folderserver"
  fs_registry_set old.test "$PROJ" "" static
  # re-init: the default domain becomes my-app.test (from the folder name)
  run fs_cmd_init "$PROJ" --force
  [ "$status" -eq 0 ]
  # the new domain is registered...
  run fs_registry_field my-app.test 2; [ "$output" = "$PROJ" ]
  # ...and the old one is gone (no orphan row)
  run fs_registry_field old.test 2; [ "$status" -ne 0 ]
}
