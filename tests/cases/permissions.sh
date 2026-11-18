# The store directory stays searchable while its files are fixed up.

test_store_dir_never_loses_search_permission() {
  new_device 34
  user_cert test-ca.pem "$TEST_HASH.0"
  run_mod post-fs-data.sh
  run_mod service.sh
  run_mod service.sh --sync >/dev/null
  assert_no_grep "chmod -R 644 $TUC_APEX\$" "$TUC_CALLS" "store dir chmod 644"
  assert_no_grep "chmod -R 644 $TUC_ROOT/mnt/tuc_stage\$" "$TUC_CALLS" "staging dir chmod 644"
  assert_grep "chmod 755 $TUC_APEX\$" "$TUC_CALLS" "store dir 755"
  assert_eq "$(stat -c %a "$TUC_APEX/$TEST_HASH.0")" 644 "cert file mode"
  assert_eq "$(stat -c %a "$TUC_APEX")" 755 "store dir mode"
}
