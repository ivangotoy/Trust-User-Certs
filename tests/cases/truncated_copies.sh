# A copy cut short part way counts as failed, like a missing or empty one.

test_truncated_copies_mount_nothing() {
  for dest in cert_stage base_certs; do
    new_device 33
    user_cert test-ca.pem "$TEST_HASH.0"
    TUC_CP_FAIL_DEST=$dest TUC_CP_FAIL_MODE=truncate
    export TUC_CP_FAIL_DEST TUC_CP_FAIL_MODE
    run_mod post-fs-data.sh
    assert_eq "$(cat "$TUC_MOUNTS")" "" "$dest: nothing mounted"
    assert_eq "$(stat_of INJECT_OK)" 0 "$dest: INJECT_OK"
    assert_grep "not copied whole" "$TUC_LOG" "$dest: truncation detected"
  done
}

test_truncated_stage_keeps_the_live_store() {
  new_device 34
  user_cert test-ca.pem "$TEST_HASH.0"
  run_mod post-fs-data.sh
  run_mod service.sh
  user_cert other-ca.pem "$OTHER_HASH.0"
  TUC_CP_FAIL_DEST=cert_stage TUC_CP_FAIL_MODE=truncate
  export TUC_CP_FAIL_DEST TUC_CP_FAIL_MODE
  out=$(run_mod service.sh --sync)
  assert_eq "$out" "rc=1" "sync reports the failure"
  assert_no_file "$TUC_APEX/$OTHER_HASH.0" "truncated cert not in the store"
  assert_eq "$(wc -c <"$TUC_APEX/$TEST_HASH.0" | tr -d ' ')" "$(wc -c <"$TUC_USER/$TEST_HASH.0" | tr -d ' ')" "trusted cert intact"
}

test_user_cert_with_a_stock_name_stages() {
  new_device 34
  user_cert test-ca.pem 0000000a.0
  run_mod post-fs-data.sh
  run_mod service.sh
  assert_eq "$(stat_of INJECT_OK)" 1 "INJECT_OK"
  assert_eq "$(cat "$TUC_APEX/0000000a.0")" "$(cat "$TUC_USER/0000000a.0")" "user version wins"
}
