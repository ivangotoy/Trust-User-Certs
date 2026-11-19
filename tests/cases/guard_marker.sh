# The bootloop guard also holds through a marker file, so one dropped stats
# write cannot clear it.

test_guard_holds_when_the_stats_write_is_dropped() {
  new_device 34
  user_cert test-ca.pem "$TEST_HASH.0"
  printf 'INJECT_OK=1\n' >"$TUC_DATA/stats"
  echo 3 >"$TUC_DATA/boot_fail_count"
  TUC_CP_FAIL_DEST=stats.tmp
  export TUC_CP_FAIL_DEST
  run_mod post-fs-data.sh
  unset TUC_CP_FAIL_DEST
  assert_eq "$(stat_of BLOCKED)" "" "stats write was dropped"
  assert_file "$TUC_DATA/blocked" "marker written"
  run_mod service.sh
  assert_eq "$(cat "$TUC_DATA/boot_fail_count")" 3 "counter kept"
  assert_eq "$(cat "$TUC_MOUNTS")" "" "nothing injected"
  assert_eq "$(run_mod service.sh --status | sed -n 's/^BLOCKED=//p')" 1 "status says blocked"
}

test_reset_clears_the_marker() {
  new_device 33
  echo 3 >"$TUC_DATA/boot_fail_count"
  run_mod post-fs-data.sh
  assert_file "$TUC_DATA/blocked" "marker written"
  out=$(run_mod service.sh --reset-fail)
  assert_eq "$out" "rc=0" "reset rc"
  assert_no_file "$TUC_DATA/blocked" "marker removed by --reset-fail"
  # A counter reset by hand (README: echo 0 > boot_fail_count) also counts.
  echo 3 >"$TUC_DATA/boot_fail_count"
  run_mod post-fs-data.sh
  echo 0 >"$TUC_DATA/boot_fail_count"
  user_cert test-ca.pem "$TEST_HASH.0"
  run_mod post-fs-data.sh
  assert_no_file "$TUC_DATA/blocked" "marker removed on an unblocked boot"
  assert_file "$TUC_SYS/$TEST_HASH.0" "injected again"
}

test_force_inject_clears_the_marker() {
  new_device 34
  user_cert test-ca.pem "$TEST_HASH.0"
  echo 3 >"$TUC_DATA/boot_fail_count"
  run_mod post-fs-data.sh
  run_mod service.sh
  out=$(run_mod service.sh --force-inject)
  assert_eq "$out" "rc=0" "force inject rc"
  assert_no_file "$TUC_DATA/blocked" "marker removed"
  assert_eq "$(cat "$TUC_DATA/boot_fail_count")" 0 "counter cleared"
}

test_reset_that_leaves_the_guard_active_is_reported() {
  new_device 33
  echo 3 >"$TUC_DATA/boot_fail_count"
  run_mod post-fs-data.sh
  assert_eq "$(stat_of BLOCKED)" 1 "precondition: blocked"
  TUC_CP_FAIL_DEST=stats.tmp
  export TUC_CP_FAIL_DEST
  out=$(run_mod service.sh --reset-fail)
  unset TUC_CP_FAIL_DEST
  assert_eq "$(stat_of BLOCKED)" 1 "precondition: stats write dropped"
  assert_eq "$(run_mod service.sh --status | sed -n 's/^BLOCKED=//p')" 1 "status still blocked"
  assert_eq "$out" "rc=1" "reset rc"
  assert_grep "guard is still active" "$TUC_LOG" "failure logged"
}
