load test_helper
setup() { setup_common; . "$REPO_ROOT/lib/helpers.sh"; fs_ensure_home; }

@test "set then get returns the line" {
  fs_registry_set foo.test /p/foo 8000 8.4
  run fs_registry_get foo.test
  [ "$status" -eq 0 ]
  [ "$output" = "foo.test|/p/foo|8000|8.4" ]
}

@test "get missing returns nonzero" {
  run fs_registry_get nope.test
  [ "$status" -ne 0 ]
}

@test "set upserts (no duplicate lines)" {
  fs_registry_set foo.test /p/foo 8000 8.4
  fs_registry_set foo.test /p/foo 8001 8.5
  run bash -c "grep -c '^foo.test|' \"$FS_HOME/registry\""
  [ "$output" = "1" ]
  run fs_registry_field foo.test 3
  [ "$output" = "8001" ]
}

@test "field extracts the requested column" {
  fs_registry_set bar.test /p/bar 8002 8.3
  run fs_registry_field bar.test 4
  [ "$output" = "8.3" ]
}

@test "remove deletes the line" {
  fs_registry_set foo.test /p/foo 8000 8.4
  fs_registry_remove foo.test
  run fs_registry_get foo.test
  [ "$status" -ne 0 ]
}

@test "domains lists all" {
  fs_registry_set a.test /p/a 8000 8.4
  fs_registry_set b.test /p/b 8001 8.4
  run fs_registry_domains
  [[ "$output" == *"a.test"* ]]
  [[ "$output" == *"b.test"* ]]
}
