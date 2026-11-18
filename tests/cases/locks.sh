# Locks: an owner counts only while it is a live process of this module; a
# lock whose holder died before writing its pid is reclaimed; reclaiming
# leaves nothing behind.

test_lock_without_owner_is_reclaimed() {
  new_device 33
  mkdir -p "$TUC_DATA/locks/stats.lock"
  in_mod 'write_stats X=1'
  assert_eq "$(stat_of X)" 1 "stats written past an ownerless lock"
  assert_eq "$(ls "$TUC_DATA/locks")" "" "nothing left in the lock dir"
}

test_lock_with_owner_is_not_taken() {
  new_device 33
  # A live process of this module: its argv names the module dir.
  tail -f /dev/null "$TUC_MOD/module.prop" >/dev/null 2>&1 &
  owner=$!
  mkdir -p "$TUC_DATA/locks/stats.lock"
  echo "$owner" >"$TUC_DATA/locks/stats.lock/pid"
  in_mod 'write_stats X=1'
  got=$(stat_of X)
  kept=$(cat "$TUC_DATA/locks/stats.lock/pid" 2>/dev/null)
  kill "$owner" 2>/dev/null
  assert_eq "$got" "" "stats written past a live owner"
  assert_eq "$kept" "$owner" "owner kept"
}

test_lock_of_a_recycled_pid_is_taken() {
  new_device 33
  # A live process that is not this module, holding a pid from an old lock.
  tail -f /dev/null >/dev/null 2>&1 &
  other=$!
  mkdir -p "$TUC_DATA/locks/stats.lock"
  echo "$other" >"$TUC_DATA/locks/stats.lock/pid"
  in_mod 'write_stats X=1'
  got=$(stat_of X)
  kill "$other" 2>/dev/null
  assert_eq "$got" 1 "stats written past a recycled pid"
  assert_eq "$(ls "$TUC_DATA/locks")" "" "nothing left in the lock dir"
}
