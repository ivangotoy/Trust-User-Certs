# The deferred boot inject (Android 14+) holds the sync lock, so a sync or
# Force Inject started meanwhile waits; it is never skipped for the lock, and
# it leaves no lock behind on any path.

test_boot_inject_holds_the_sync_lock() {
  new_device 34
  user_cert test-ca.pem "$TEST_HASH.0"
  run_mod post-fs-data.sh
  # Runs inside inject_high, after the new set is bound: a competing sync
  # (guarded against running the hook itself) must find the lock taken.
  cat >"$TUC_ROOT/hooks.sh" <<'H'
apply_selinux_context() {
  [ -n "${TUC_HOOKED:-}" ] && return 0
  printf '%s %s\n' "$(cat "$SYNC_LOCK/pid" 2>/dev/null)" "$$" >"$R/lock.at.inject"
  TUC_HOOKED=1 sh "$MODDIR/service.sh" --sync >"$R/competing.out" 2>&1
  return 0
}
H
  run_mod service.sh
  read -r holder me <"$TUC_ROOT/lock.at.inject"
  assert_eq "$holder" "$me" "lock owner during the boot inject"
  assert_grep "^rc=1" "$TUC_ROOT/competing.out" "competing sync refused"
  assert_file "$TUC_APEX/$TEST_HASH.0" "injected"
  assert_no_file "$TUC_DATA/locks/sync.lock" "lock left after the boot"
  rm -f "$TUC_ROOT/hooks.sh"
  assert_eq "$(run_mod service.sh --sync)" "rc=0" "sync after the boot"
}

test_boot_inject_runs_while_a_live_owner_holds_the_lock() {
  new_device 34
  user_cert test-ca.pem "$TEST_HASH.0"
  run_mod post-fs-data.sh
  tail -f /dev/null "$TUC_MOD/module.prop" >/dev/null 2>&1 &
  owner=$!
  mkdir -p "$TUC_DATA/locks/sync.lock"
  echo "$owner" >"$TUC_DATA/locks/sync.lock/pid"
  run_mod service.sh
  kept=$(cat "$TUC_DATA/locks/sync.lock/pid" 2>/dev/null)
  kill "$owner" 2>/dev/null
  assert_file "$TUC_APEX/$TEST_HASH.0" "injected despite the held lock"
  assert_eq "$kept" "$owner" "other owner's lock kept"
}

test_boot_leaves_no_sync_lock_on_failure_or_block() {
  new_device 34
  user_cert test-ca.pem "$TEST_HASH.0"
  run_mod post-fs-data.sh
  TUC_MOUNT_FAIL=all
  export TUC_MOUNT_FAIL
  run_mod service.sh
  unset TUC_MOUNT_FAIL
  assert_grep "Deferred inject failed" "$TUC_LOG" "precondition: inject failed"
  assert_no_file "$TUC_DATA/locks/sync.lock" "lock left after a failed inject"
  new_device 34
  echo 3 >"$TUC_DATA/boot_fail_count"
  run_mod post-fs-data.sh
  run_mod service.sh
  assert_grep "Deferred inject skipped" "$TUC_LOG" "precondition: blocked"
  assert_no_file "$TUC_DATA/locks/sync.lock" "lock left after a blocked boot"
}
