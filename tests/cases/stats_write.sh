# A stats or config update that cannot read the current file keeps it.

test_failed_stats_copy_keeps_the_stats() {
  new_device 33
  printf 'BLOCKED=1\nINJECT_OK=1\n' >"$TUC_DATA/stats"
  TUC_CP_FAIL_DEST=stats.tmp
  export TUC_CP_FAIL_DEST
  in_mod 'write_stats X=1'
  TUC_CP_FAIL_DEST="" TUC_GREP_FAIL=stats.tmp
  export TUC_GREP_FAIL
  in_mod 'write_stats Y=1'
  assert_eq "$(stat_of Y)" "" "Y dropped after a read error"
  unset TUC_GREP_FAIL
  assert_eq "$(stat_of BLOCKED)" 1 "BLOCKED kept"
  assert_eq "$(stat_of INJECT_OK)" 1 "INJECT_OK kept"
  assert_eq "$(ls "$TUC_DATA" | grep -c 'stats.tmp')" 0 "no temp file left"
  unset TUC_CP_FAIL_DEST
  in_mod 'write_stats X=2'
  assert_eq "$(stat_of X)" 2 "later write works"
  assert_eq "$(stat_of BLOCKED)" 1 "BLOCKED still kept"
}

test_failed_config_or_stats_read_keeps_the_file() {
  new_device 33
  printf 'LIVE_SYNC=1\nLOG_LEVEL=1\n' >"$TUC_DATA/config"
  printf 'BLOCKED=1\nDEFERRED=1\n' >"$TUC_DATA/stats"
  TUC_GREP_FAIL=/trust-user-certs/
  export TUC_GREP_FAIL
  in_mod 'write_cfg LOG_LEVEL 2; del_stat DEFERRED'
  unset TUC_GREP_FAIL
  assert_grep '^LIVE_SYNC=1$' "$TUC_DATA/config" "LIVE_SYNC kept"
  assert_grep '^BLOCKED=1$' "$TUC_DATA/stats" "BLOCKED kept"
  assert_eq "$(ls "$TUC_DATA" | grep -c '\.tmp')" 0 "no temp file left"
  in_mod 'write_cfg LOG_LEVEL 2; del_stat DEFERRED'
  assert_grep '^LOG_LEVEL=2$' "$TUC_DATA/config" "later config write works"
  assert_no_grep '^DEFERRED=' "$TUC_DATA/stats" "later delete works"
  assert_grep '^BLOCKED=1$' "$TUC_DATA/stats" "BLOCKED still kept"
}
