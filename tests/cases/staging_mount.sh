# No staging tmpfs is left behind or stacked.

test_leftover_staging_tmpfs_is_released() {
  new_device 34
  user_cert test-ca.pem "$TEST_HASH.0"
  mkdir -p "$TUC_ROOT/mnt/tuc_stage"
  mount -t tmpfs tmpfs "$TUC_ROOT/mnt/tuc_stage"
  run_mod post-fs-data.sh
  run_mod service.sh
  assert_no_grep " $TUC_ROOT/mnt/tuc_stage " "$TUC_MOUNTS" "staging tmpfs left mounted"
  assert_eq "$(stat_of INJECT_OK)" 1 "INJECT_OK"
}
