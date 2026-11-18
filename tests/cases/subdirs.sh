# A directory inside a certificate source is not a certificate: it is skipped
# by the copies and must not count as a shortfall.

test_subdirs_in_cert_sources_are_ignored() {
  for sdk in 33 34; do
    new_device "$sdk"
    user_cert test-ca.pem "$TEST_HASH.0"
    mkdir -p "$TUC_DATA/certs/backup" "$TUC_USER/old"
    "$TUC_REAL_CP" "$TUC_REPO/tests/fixtures/other-ca.pem" "$TUC_DATA/certs/$OTHER_HASH.0"
    run_mod post-fs-data.sh
    run_mod service.sh
    assert_eq "$(stat_of INJECT_OK)" 1 "SDK $sdk: INJECT_OK"
    out=$(run_mod service.sh --sync)
    assert_eq "$out" "rc=0" "SDK $sdk: sync rc"
  done
}
