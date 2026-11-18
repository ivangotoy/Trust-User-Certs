# A certificate that did not reach the live store whole is taken out of it
# again, so status does not count a cut file as trusted.

test_cut_cert_is_removed_from_the_store() {
  for mode in empty truncate; do
    new_device 34
    user_cert test-ca.pem "$TEST_HASH.0"
    run_mod post-fs-data.sh
    run_mod service.sh
    user_cert other-ca.pem "$OTHER_HASH.0"
    TUC_CP_FAIL_DEST=com.android.conscrypt/cacerts TUC_CP_FAIL_MODE=$mode
    export TUC_CP_FAIL_DEST TUC_CP_FAIL_MODE
    out=$(run_mod service.sh --sync)
    unset TUC_CP_FAIL_DEST TUC_CP_FAIL_MODE
    assert_eq "$out" "rc=1" "$mode: precondition: sync failed"
    assert_no_file "$TUC_APEX/$OTHER_HASH.0" "$mode: cut cert left in the store"
    st=$(run_mod service.sh --status)
    assert_eq "$(printf '%s\n' "$st" | sed -n 's/^USER_TRUSTED=//p')" 1 "$mode: USER_TRUSTED"
    assert_eq "$(run_mod service.sh --certs | grep "^$OTHER_HASH.0|" | cut -d'|' -f3)" 0 "$mode: cut cert listed as not trusted"
    assert_eq "$(cat "$TUC_APEX/0000000a.0")" "stock 0000000a" "$mode: stock cert intact"
  done
}
