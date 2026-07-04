load test_helper
setup() { setup_common; . "$REPO_ROOT/lib/helpers.sh"; fs_ensure_home; }

@test "fs_free_port returns a port in range" {
  run fs_free_port
  [ "$status" -eq 0 ]
  [ "$output" -ge 8000 ]
  [ "$output" -le 8999 ]
}

@test "fs_free_port skips ports already in the registry" {
  # Occupy 8000 via registry; free_port must not return it.
  fs_registry_set a.test /p/a 8000 8.4
  # Force the live check to always say 'free' so only registry matters.
  fs_port_in_use() { fs_registry_domains >/dev/null; grep -q "|$1|" "$(fs_registry_file)"; }
  run fs_free_port
  [ "$output" != "8000" ]
}

@test "fs_php_binary returns path when installed" {
  mkdir -p "$FS_BREW_OPT/php@8.4/bin"
  printf '#!/bin/sh\n' >"$FS_BREW_OPT/php@8.4/bin/php"
  chmod +x "$FS_BREW_OPT/php@8.4/bin/php"
  run fs_php_binary 8.4
  [ "$status" -eq 0 ]
  [ "$output" = "$FS_BREW_OPT/php@8.4/bin/php" ]
}

@test "fs_php_binary errors when not installed" {
  run fs_php_binary 9.9
  [ "$status" -ne 0 ]
  [[ "$output" == *"brew install php@9.9"* ]]
}
