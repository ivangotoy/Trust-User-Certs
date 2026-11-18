# --status after a sync that was aborted reports the live store.

test_status_after_an_aborted_sync() {
  new_device 34
  user_cert test-ca.pem "$TEST_HASH.0"
  run_mod post-fs-data.sh
  run_mod service.sh
  user_cert other-ca.pem "$OTHER_HASH.0"
  TUC_CP_FAIL_SRC=cacerts-added
  export TUC_CP_FAIL_SRC
  run_mod service.sh --sync >/dev/null
  unset TUC_CP_FAIL_SRC
  st=$(run_mod service.sh --status)
  assert_eq "$(printf '%s\n' "$st" | sed -n 's/^USER_TRUSTED=//p')" 1 "USER_TRUSTED"
  assert_eq "$(printf '%s\n' "$st" | sed -n 's/^USER_EXCLUDED=//p')" 0 "USER_EXCLUDED"
  assert_eq "$(run_mod service.sh --certs | cut -d'|' -f1,3 | sort | tr '\n' ' ')" \
    "$TEST_HASH.0|1 $OTHER_HASH.0|0 " "cert list"
}
