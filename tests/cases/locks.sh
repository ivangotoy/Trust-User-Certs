# A lock whose holder died before writing its pid is reclaimed.

test_lock_without_owner_is_reclaimed() {
  new_device 33
  mkdir -p "$TUC_DATA/locks/stats.lock"
  in_mod 'write_stats X=1'
  assert_eq "$(stat_of X)" 1 "stats written past an ownerless lock"
}

test_lock_with_owner_is_not_taken() {
  new_device 33
  mkdir -p "$TUC_DATA/locks/stats.lock"
  echo $$ >"$TUC_DATA/locks/stats.lock/pid"
  in_mod 'write_stats X=1'
  assert_eq "$(stat_of X)" "" "stats written past a live owner"
  assert_eq "$(cat "$TUC_DATA/locks/stats.lock/pid")" "$$" "owner kept"
}
