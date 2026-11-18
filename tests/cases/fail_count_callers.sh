# Callers of write_fail_count report a failed write; a killed run leaves no
# temp files behind after the next boot.

test_failed_counter_reset_is_reported() {
  new_device 33
  echo 2 >"$TUC_DATA/boot_fail_count"
  echo 'write_fail_count() { return 1; }' >"$TUC_ROOT/hooks.sh"
  out=$(run_mod service.sh --reset-fail)
  assert_eq "$out" "rc=1" "reset rc"
  assert_eq "$(cat "$TUC_DATA/boot_fail_count")" 2 "precondition: write failed"
  assert_grep "could not be reset" "$TUC_LOG" "reset failure logged"
}

test_failed_counter_writes_at_boot_are_logged() {
  new_device 33
  echo 'write_fail_count() { return 1; }' >"$TUC_ROOT/hooks.sh"
  run_mod post-fs-data.sh
  assert_grep "could not be counted" "$TUC_LOG" "post-fs-data failure logged"
  echo 1 >"$TUC_DATA/boot_fail_count"
  run_mod service.sh
  assert_eq "$(cat "$TUC_DATA/boot_fail_count")" 1 "precondition: write failed"
  assert_no_grep "Boot completed - fail counter reset" "$TUC_LOG" "reset claimed"
  assert_grep "could not be reset" "$TUC_LOG" "boot reset failure logged"
}

test_stale_temp_files_are_removed_at_boot() {
  new_device 33
  for f in boot_fail_count.tmp.4242 stats.tmp.4242 stats.tmp.4242.n config.tmp.4242; do
    : >"$TUC_DATA/$f"
  done
  run_mod post-fs-data.sh
  assert_eq "$(ls "$TUC_DATA" | grep -c '\.tmp\.')" 0 "temp files left"
  assert_grep '^LOG_LEVEL=2$' "$TUC_DATA/config" "config kept"
}
