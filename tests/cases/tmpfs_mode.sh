# A new tmpfs is 0755 from the moment it is mounted (the default 1777 lets
# any uid add a file until the permissions are fixed); a mount that refuses
# the option still gets a tmpfs, by the plain call.

tmpfs_calls() { grep -c "^mount -t tmpfs .*$1\$" "$TUC_CALLS"; }

test_tmpfs_is_mounted_with_mode_0755() {
  new_device 33
  user_cert test-ca.pem "$TEST_HASH.0"
  run_mod post-fs-data.sh
  assert_grep "^mount -t tmpfs -o mode=0755 tmpfs $TUC_SYS\$" "$TUC_CALLS" "SDK 33: store tmpfs mode"
  assert_eq "$(tmpfs_calls "$TUC_SYS")" 1 "SDK 33: tmpfs mount calls"
  assert_file "$TUC_SYS/$TEST_HASH.0" "SDK 33: injected"
  new_device 34
  user_cert test-ca.pem "$TEST_HASH.0"
  run_mod post-fs-data.sh
  run_mod service.sh
  assert_grep "^mount -t tmpfs -o mode=0755 tmpfs $TUC_ROOT/mnt/tuc_stage\$" "$TUC_CALLS" "SDK 34: staging tmpfs mode"
  assert_eq "$(tmpfs_calls "$TUC_ROOT/mnt/tuc_stage")" 1 "SDK 34: tmpfs mount calls"
  assert_file "$TUC_APEX/$TEST_HASH.0" "SDK 34: injected"
}

test_refused_mode_option_falls_back_to_a_plain_tmpfs() {
  new_device 33
  user_cert test-ca.pem "$TEST_HASH.0"
  TUC_MOUNT_FAIL=mode
  export TUC_MOUNT_FAIL
  run_mod post-fs-data.sh
  assert_grep "^mount -t tmpfs tmpfs $TUC_SYS\$" "$TUC_CALLS" "SDK 33: plain call after the refused option"
  assert_eq "$(grep -c " $TUC_SYS " "$TUC_MOUNTS")" 1 "SDK 33: one tmpfs on the store"
  assert_file "$TUC_SYS/$TEST_HASH.0" "SDK 33: injected"
  assert_eq "$(stat_of INJECT_OK)" 1 "SDK 33: inject ok"
  new_device 34
  user_cert test-ca.pem "$TEST_HASH.0"
  TUC_MOUNT_FAIL=mode
  export TUC_MOUNT_FAIL
  run_mod post-fs-data.sh
  run_mod service.sh
  assert_grep "^mount -t tmpfs tmpfs $TUC_ROOT/mnt/tuc_stage\$" "$TUC_CALLS" "SDK 34: plain call after the refused option"
  assert_file "$TUC_APEX/$TEST_HASH.0" "SDK 34: injected"
  assert_eq "$(stat_of INJECT_OK)" 1 "SDK 34: inject ok"
}
