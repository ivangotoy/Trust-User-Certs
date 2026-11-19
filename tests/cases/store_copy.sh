# A copy into the live store that comes up short never costs a stock
# certificate: a tmpfs this run mounted is removed again, and stock files
# already in an active overlay are never rewritten.

stock_intact() { # stock_intact <store> - all three made-up stock certs whole
  for s in 0000000a 0000000b 0000000c; do
    [ "$(cat "$1/$s.0" 2>/dev/null)" = "stock $s" ] || return 1
  done
}

test_short_copy_into_a_fresh_tmpfs_unmounts_it() {
  for mode in partial empty truncate; do
    new_device 33
    user_cert test-ca.pem "$TEST_HASH.0"
    TUC_CP_FAIL_DEST=/system/etc/security/cacerts TUC_CP_FAIL_MODE=$mode
    export TUC_CP_FAIL_DEST TUC_CP_FAIL_MODE
    run_mod post-fs-data.sh
    assert_grep "mount -t tmpfs .*tmpfs $TUC_SYS" "$TUC_CALLS" "$mode: tmpfs was mounted"
    assert_eq "$(cat "$TUC_MOUNTS")" "" "$mode: tmpfs removed again"
    stock_intact "$TUC_SYS" || fail "$mode: stock store not intact"
    assert_eq "$(stat_of INJECT_OK)" 0 "$mode: INJECT_OK"
  done
}

test_short_copy_into_an_active_overlay_keeps_stock_certs() {
  # Only new or changed files are copied here, one by one, so "partial" (the
  # first file of a multi-file copy) would be a whole copy: not a shortfall.
  for mode in empty truncate; do
    new_device 34
    user_cert test-ca.pem "$TEST_HASH.0"
    run_mod post-fs-data.sh
    run_mod service.sh
    user_cert other-ca.pem "$OTHER_HASH.0"
    TUC_CP_FAIL_DEST=com.android.conscrypt/cacerts TUC_CP_FAIL_MODE=$mode
    export TUC_CP_FAIL_DEST TUC_CP_FAIL_MODE
    out=$(run_mod service.sh --sync)
    assert_eq "$out" "rc=1" "$mode: sync reports the failure"
    stock_intact "$TUC_APEX" || fail "$mode: stock certs damaged"
    cmp -s "$TUC_APEX/$TEST_HASH.0" "$TUC_USER/$TEST_HASH.0" || fail "$mode: trusted user cert damaged"
    assert_eq "$(stat_of INJECT_OK)" 0 "$mode: INJECT_OK"
  done
}
