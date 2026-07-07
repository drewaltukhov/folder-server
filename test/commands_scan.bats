load test_helper
setup() {
  setup_common
  for l in helpers commands; do . "$REPO_ROOT/lib/$l.sh"; done
  ROOT="$BATS_TEST_TMPDIR/projects"
  mkdir -p "$ROOT/alpha" "$ROOT/nested/beta"
  printf 'domain=alpha.test\ntype=static\n' >"$ROOT/alpha/.folderserver"
  printf 'domain=beta.test\ntype=static\n'  >"$ROOT/nested/beta/.folderserver"
}

@test "scan registers every discovered site (nested included)" {
  run fs_cmd_scan "$ROOT"
  [ "$status" -eq 0 ]
  run fs_registry_field alpha.test 2; [ "$output" = "$ROOT/alpha" ]
  run fs_registry_field beta.test 2; [ "$output" = "$ROOT/nested/beta" ]
}

@test "scan leaves the port blank and records the runtime label" {
  fs_cmd_scan "$ROOT" >/dev/null
  run fs_registry_field alpha.test 3; [ -z "$output" ]
  run fs_registry_field alpha.test 4; [ "$output" = "static" ]
}

@test "scan is idempotent — re-scan reports unchanged and makes no duplicates" {
  fs_cmd_scan "$ROOT" >/dev/null
  run fs_cmd_scan "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"unchanged"* ]]
  [ "$(fs_registry_domains | grep -c .)" -eq 2 ]
}

@test "scan skips a domain already registered to a different dir (keeps original)" {
  fs_registry_set alpha.test /somewhere/else "" static
  run fs_cmd_scan "$ROOT"
  [ "$status" -eq 0 ]
  # original mapping preserved, not re-pointed
  run fs_registry_field alpha.test 2; [ "$output" = "/somewhere/else" ]
  # the non-conflicting site still gets added
  run fs_registry_field beta.test 2; [ "$output" = "$ROOT/nested/beta" ]
}

@test "scan skips a config with a missing or invalid domain" {
  printf 'type=static\n' >"$ROOT/alpha/.folderserver"   # no domain
  run fs_cmd_scan "$ROOT"
  [ "$status" -eq 0 ]
  run fs_registry_field alpha.test 2; [ "$status" -ne 0 ]
  run fs_registry_field beta.test 2;  [ "$output" = "$ROOT/nested/beta" ]
}

@test "scan prunes node_modules and .git" {
  mkdir -p "$ROOT/node_modules/pkg" "$ROOT/.git"
  printf 'domain=dep.test\ntype=static\n' >"$ROOT/node_modules/pkg/.folderserver"
  printf 'domain=git.test\ntype=static\n' >"$ROOT/.git/.folderserver"
  run fs_cmd_scan "$ROOT"
  [ "$status" -eq 0 ]
  run fs_registry_field dep.test 2; [ "$status" -ne 0 ]
  run fs_registry_field git.test 2; [ "$status" -ne 0 ]
}

@test "scan on a tree with no configs reports nothing found (clean exit)" {
  local empty="$BATS_TEST_TMPDIR/empty"; mkdir -p "$empty"
  run fs_cmd_scan "$empty"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no .folderserver"* ]]
}

@test "scan errors on a non-directory argument" {
  run fs_cmd_scan "$ROOT/alpha/.folderserver"
  [ "$status" -ne 0 ]
}
