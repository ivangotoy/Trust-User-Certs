# The bootloop guard stays tripped until it is reset by hand.

test_guard_survives_a_blocked_boot() {
  for sdk in 33 34; do
    new_device "$sdk"
    user_cert test-ca.pem "$TEST_HASH.0"
    echo 3 >"$TUC_DATA/boot_fail_count"
    run_mod post-fs-data.sh
    run_mod service.sh
    assert_eq "$(cat "$TUC_DATA/boot_fail_count")" 3 "SDK $sdk: counter kept after the blocked boot"
    run_mod post-fs-data.sh
    run_mod service.sh
    assert_eq "$(stat_of BLOCKED)" 1 "SDK $sdk: next boot still blocked"
    assert_eq "$(cat "$TUC_MOUNTS")" "" "SDK $sdk: nothing mounted"
  done
}
