# A boot fail counter write that fails keeps the old count: an empty or cut
# file reads as 0 and would clear the bootloop guard.

test_failed_fail_count_write_keeps_the_count() {
  new_device 33
  echo 2 >"$TUC_DATA/boot_fail_count"
  # printf fails after the shell opened its target, as a write on a full /data.
  in_mod 'printf() { return 1; }; write_fail_count 3'
  assert_eq "$(cat "$TUC_DATA/boot_fail_count")" 2 "count kept after a failed write"
  assert_eq "$(ls "$TUC_DATA" | grep -c 'boot_fail_count\.')" 0 "no temp file left"
  in_mod 'write_fail_count 3'
  assert_eq "$(cat "$TUC_DATA/boot_fail_count")" 3 "later write works"
}
