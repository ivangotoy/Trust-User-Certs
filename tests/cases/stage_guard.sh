# A failed or partial copy never reaches the live trust store.

test_failed_stage_copy_keeps_the_live_store() {
  for mode in full partial; do
    new_device 34
    user_cert test-ca.pem "$TEST_HASH.0"
    run_mod post-fs-data.sh
    run_mod service.sh
    TUC_CP_FAIL_DEST=cert_stage TUC_CP_FAIL_MODE=$mode
    export TUC_CP_FAIL_DEST TUC_CP_FAIL_MODE
    out=$(run_mod service.sh --sync)
    assert_eq "$out" "rc=1" "$mode: sync reports the failure"
    assert_eq "$(count "$TUC_APEX")" 4 "$mode: live store intact after sync"
    out=$(run_mod service.sh --force-inject)
    assert_eq "$out" "rc=1" "$mode: force inject reports the failure"
    assert_eq "$(count "$TUC_APEX")" 4 "$mode: live store intact after force inject"
    assert_grep "bind $TUC_APEX " "$TUC_MOUNTS" "$mode: overlay still mounted"
  done
}

test_failed_stage_copy_mounts_nothing_low_sdk() {
  new_device 33
  user_cert test-ca.pem "$TEST_HASH.0"
  TUC_CP_FAIL_DEST=cert_stage
  export TUC_CP_FAIL_DEST
  run_mod post-fs-data.sh
  assert_eq "$(cat "$TUC_MOUNTS")" "" "no tmpfs over the store"
  assert_eq "$(count "$TUC_SYS")" 3 "stock store visible"
  assert_eq "$(stat_of INJECT_OK)" 0 "INJECT_OK"
}

test_failed_base_snapshot_mounts_nothing() {
  for dest in base_certs /adb/trust-user-certs/; do
    new_device 33
    user_cert test-ca.pem "$TEST_HASH.0"
    TUC_CP_FAIL_DEST=$dest TUC_CP_FAIL_MODE=partial
    export TUC_CP_FAIL_DEST TUC_CP_FAIL_MODE
    run_mod post-fs-data.sh
    assert_eq "$(cat "$TUC_MOUNTS")" "" "$dest: no tmpfs over the store"
    assert_eq "$(count "$TUC_SYS")" 3 "$dest: stock store visible"
    assert_eq "$(stat_of INJECT_OK)" 0 "$dest: INJECT_OK"
  done
}

test_failed_user_cert_copy_is_reported() {
  new_device 34
  user_cert test-ca.pem "$TEST_HASH.0"
  run_mod post-fs-data.sh
  run_mod service.sh
  user_cert other-ca.pem "$OTHER_HASH.0"
  TUC_CP_FAIL_SRC=cacerts-added
  export TUC_CP_FAIL_SRC
  out=$(run_mod service.sh --sync)
  assert_eq "$out" "rc=1" "sync reports the failure"
  assert_file "$TUC_APEX/$TEST_HASH.0" "trusted user cert kept"
  assert_eq "$(count "$TUC_APEX")" 4 "live store intact"
}

test_hash_rule_on_a_stock_cert_still_verifies() {
  new_device 34
  user_cert test-ca.pem "$TEST_HASH.0"
  printf '0000000a\n' >"$TUC_DATA/exclude_hashes"
  run_mod post-fs-data.sh
  run_mod service.sh
  assert_eq "$(stat_of INJECT_OK)" 1 "INJECT_OK"
  assert_no_file "$TUC_APEX/0000000a.0" "excluded stock cert"
  assert_eq "$(count "$TUC_APEX")" 3 "store size"
  out=$(run_mod service.sh --sync)
  assert_eq "$out" "rc=0" "sync rc"
}
