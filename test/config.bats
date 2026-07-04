load test_helper
setup() {
  setup_common
  . "$REPO_ROOT/lib/helpers.sh"
  PROJ="$BATS_TEST_TMPDIR/My-Project"
  mkdir -p "$PROJ"
}

@test "fs_config_get reads a key" {
  printf 'domain=foo.test\nphp=8.5\n' >"$PROJ/.folderserver"
  run fs_config_get "$PROJ/.folderserver" php
  [ "$output" = "8.5" ]
}

@test "fs_config_get ignores comments and blanks and trims spaces" {
  printf '# comment\n\n  domain = bar.test \n' >"$PROJ/.folderserver"
  run fs_config_get "$PROJ/.folderserver" domain
  [ "$output" = "bar.test" ]
}

@test "fs_config_get returns empty for missing key" {
  printf 'domain=foo.test\n' >"$PROJ/.folderserver"
  run fs_config_get "$PROJ/.folderserver" php
  [ -z "$output" ]
}

@test "fs_default_domain lowercases basename and adds .test" {
  run fs_default_domain "$PROJ"
  [ "$output" = "my-project.test" ]
}

@test "fs_resolve_config fills defaults when file absent" {
  run fs_resolve_config "$PROJ"
  [[ "$output" == *"domain=my-project.test"* ]]
  [[ "$output" == *"php=8.4"* ]]
  [[ "$output" == *"docroot=$PROJ"* ]]
}

@test "fs_resolve_config honors file values" {
  printf 'domain=custom.test\nphp=8.5\ndocroot=public\n' >"$PROJ/.folderserver"
  run fs_resolve_config "$PROJ"
  [[ "$output" == *"domain=custom.test"* ]]
  [[ "$output" == *"php=8.5"* ]]
  [[ "$output" == *"docroot=$PROJ/public"* ]]
}
