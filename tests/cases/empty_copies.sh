# A copy that leaves empty files behind counts as failed.

test_empty_copies_mount_nothing() {
  for dest in cert_stage base_certs; do
    new_device 33
    user_cert test-ca.pem "$TEST_HASH.0"
    TUC_CP_FAIL_DEST=$dest TUC_CP_FAIL_MODE=empty
    export TUC_CP_FAIL_DEST TUC_CP_FAIL_MODE
    run_mod post-fs-data.sh
    assert_eq "$(cat "$TUC_MOUNTS")" "" "$dest: nothing mounted"
    assert_eq "$(stat_of INJECT_OK)" 0 "$dest: INJECT_OK"
  done
}

test_empty_copies_keep_the_live_store() {
  new_device 34
  user_cert test-ca.pem "$TEST_HASH.0"
  run_mod post-fs-data.sh
  run_mod service.sh
  TUC_CP_FAIL_DEST=cert_stage TUC_CP_FAIL_MODE=empty
  export TUC_CP_FAIL_DEST TUC_CP_FAIL_MODE
  out=$(run_mod service.sh --sync)
  assert_eq "$out" "rc=1" "sync reports the failure"
  assert_eq "$(find "$TUC_APEX" -type f -size +0 | wc -l | tr -d ' ')" 4 "live certs keep their content"
}
