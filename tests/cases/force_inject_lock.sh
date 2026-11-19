# Force Inject and Live Sync both rebuild the stage: they never run at once.

test_force_inject_waits_for_a_running_sync() {
  new_device 33
  user_cert test-ca.pem "$TEST_HASH.0"
  run_mod post-fs-data.sh
  # A sync of this module holds the lock: its argv names the module dir.
  tail -f /dev/null "$TUC_MOD/module.prop" >/dev/null 2>&1 &
  owner=$!
  mkdir -p "$TUC_DATA/locks/sync.lock"
  echo "$owner" >"$TUC_DATA/locks/sync.lock/pid"
  : >"$TUC_LOG"
  out=$(run_mod service.sh --force-inject)
  kept=$(cat "$TUC_DATA/locks/sync.lock/pid" 2>/dev/null)
  kill "$owner" 2>/dev/null
  assert_eq "$out" "rc=1" "force inject rc"
  assert_eq "$kept" "$owner" "lock owner kept"
  assert_no_grep "Staged" "$TUC_LOG" "stage rebuilt during the sync"
  assert_grep "a sync is still running" "$TUC_LOG" "skip logged"
  assert_eq "$(count "$TUC_SYS")" 4 "live store"
}

test_force_inject_releases_the_sync_lock() {
  new_device 33
  user_cert test-ca.pem "$TEST_HASH.0"
  run_mod post-fs-data.sh
  out=$(run_mod service.sh --force-inject)
  assert_eq "$out" "rc=0" "force inject rc"
  assert_no_file "$TUC_DATA/locks/sync.lock" "sync lock left behind"
  out=$(run_mod service.sh --sync)
  assert_eq "$out" "rc=0" "sync after a force inject"
}
