# Live Sync labels the certificates it adds, on every SDK.

test_sync_relabels_on_sdk34() {
  new_device 34
  user_cert test-ca.pem "$TEST_HASH.0"
  run_mod post-fs-data.sh
  run_mod service.sh
  : >"$TUC_CALLS"
  user_cert other-ca.pem "$OTHER_HASH.0"
  out=$(run_mod service.sh --sync)
  assert_eq "$out" "rc=0" "sync rc"
  assert_file "$TUC_APEX/$OTHER_HASH.0" "cert added"
  assert_grep "^chcon -R .* $TUC_APEX\$" "$TUC_CALLS" "store relabeled"
}
