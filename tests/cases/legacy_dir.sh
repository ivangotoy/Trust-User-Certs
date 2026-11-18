# The shell-writable pre-v3 drop-in dir is never trusted at boot.

test_boot_does_not_import_the_shell_writable_dir() {
  new_device 33
  mkdir -p "$TUC_ROOT/data/local/tmp/cert"
  "$TUC_REAL_CP" "$TUC_REPO/tests/fixtures/test-ca.pem" "$TUC_ROOT/data/local/tmp/cert/$TEST_HASH.0"
  run_mod post-fs-data.sh
  assert_no_file "$TUC_DATA/certs/$TEST_HASH.0" "imported into the root-only dir"
  assert_no_file "$TUC_SYS/$TEST_HASH.0" "trusted as a system CA"
  assert_grep "not imported" "$TUC_LOG" "warning logged"
}
