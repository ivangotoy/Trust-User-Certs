# --status prints STAGE_CERTS empty while a live sync owns the lock: the stage
# is being rebuilt then, so its count means nothing. --status never touches
# the lock itself, not even a dead owner's.

test_stage_count_is_empty_during_a_sync() {
  new_device 34
  user_cert test-ca.pem "$TEST_HASH.0"
  run_mod post-fs-data.sh
  run_mod service.sh
  n=$(run_mod service.sh --status | sed -n 's/^STAGE_CERTS=//p')
  [ -n "$n" ] && [ "$n" -gt 0 ] || fail "precondition: stage count '$n'"
  tail -f /dev/null "$TUC_MOD/module.prop" >/dev/null 2>&1 &
  owner=$!
  mkdir -p "$TUC_DATA/locks/sync.lock"
  echo "$owner" >"$TUC_DATA/locks/sync.lock/pid"
  st=$(run_mod service.sh --status)
  kill "$owner" 2>/dev/null
  assert_eq "$(printf '%s\n' "$st" | grep -c '^STAGE_CERTS=')" 1 "STAGE_CERTS key printed"
  assert_eq "$(printf '%s\n' "$st" | sed -n 's/^STAGE_CERTS=//p')" "" "STAGE_CERTS during a sync"
}

test_status_leaves_a_dead_owners_lock_alone() {
  new_device 34
  user_cert test-ca.pem "$TEST_HASH.0"
  run_mod post-fs-data.sh
  run_mod service.sh
  sh -c 'exit 0' &
  dead=$!
  wait "$dead"
  mkdir -p "$TUC_DATA/locks/sync.lock"
  echo "$dead" >"$TUC_DATA/locks/sync.lock/pid"
  n=$(run_mod service.sh --status | sed -n 's/^STAGE_CERTS=//p')
  [ -n "$n" ] && [ "$n" -gt 0 ] || fail "STAGE_CERTS with a dead owner: '$n'"
  assert_eq "$(cat "$TUC_DATA/locks/sync.lock/pid" 2>/dev/null)" "$dead" "dead owner's lock untouched by --status"
}
