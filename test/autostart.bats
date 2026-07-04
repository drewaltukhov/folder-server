load test_helper
setup() {
  setup_common
  . "$REPO_ROOT/lib/helpers.sh"
  . "$REPO_ROOT/lib/commands.sh"
  fs_ensure_home
  export FS_AUTOSTART_PLIST="$BATS_TEST_TMPDIR/com.folderserver.restore.plist"
  export FS_SELF="/opt/homebrew/bin/fs"
  make_stub launchctl "$BATS_TEST_TMPDIR/launchctl.log"; export FS_LAUNCHCTL_BIN=launchctl
}

@test "autostart on writes a plist that runs 'fs up --all' and bootstraps it" {
  run fs_cmd_autostart on
  [ "$status" -eq 0 ]
  [ -f "$FS_AUTOSTART_PLIST" ]
  grep -q "<string>/opt/homebrew/bin/fs</string>" "$FS_AUTOSTART_PLIST"
  grep -q "<string>up</string>" "$FS_AUTOSTART_PLIST"
  grep -q -- "<string>--all</string>" "$FS_AUTOSTART_PLIST"
  grep -q "bootstrap" "$BATS_TEST_TMPDIR/launchctl.log"
}

@test "autostart off removes the plist and boots it out" {
  fs_cmd_autostart on
  run fs_cmd_autostart off
  [ "$status" -eq 0 ]
  [ ! -f "$FS_AUTOSTART_PLIST" ]
  grep -q "bootout" "$BATS_TEST_TMPDIR/launchctl.log"
}

@test "autostart status reflects whether the plist exists" {
  run fs_cmd_autostart status
  [ "$status" -eq 0 ]; [ "$output" = "autostart: off" ]
  fs_cmd_autostart on
  run fs_cmd_autostart status
  [ "$output" = "autostart: on" ]
}

@test "autostart with no/unknown action is a usage error" {
  run fs_cmd_autostart bogus
  [ "$status" -eq 2 ]
}
