# inject_high builds and checks the new set before it touches the active
# overlay; a failure before the swap leaves the old overlay in place, a failed
# bind after it leaves the stock store and binds nothing else.

active_overlay() { # a booted SDK 34 device with one trusted user cert
  new_device 34
  mkdir -p "$TUC_ROOT/apex/com.android.conscrypt@340000000/cacerts"
  user_cert test-ca.pem "$TEST_HASH.0"
  run_mod post-fs-data.sh
  run_mod service.sh
  : >"$TUC_CALLS"
}

test_short_new_set_keeps_the_old_overlay() {
  active_overlay
  TUC_CP_FAIL_DEST=mnt/tuc_stage TUC_CP_FAIL_MODE=truncate
  export TUC_CP_FAIL_DEST TUC_CP_FAIL_MODE
  in_mod 'inject_high' && fail "inject_high reported success"
  assert_grep "mount -t tmpfs tmpfs $TUC_ROOT/mnt/tuc_stage" "$TUC_CALLS" "new set was built"
  assert_no_grep "umount $TUC_APEX" "$TUC_CALLS" "old overlay torn down"
  assert_grep "bind $TUC_APEX " "$TUC_MOUNTS" "old overlay still mounted"
  assert_file "$TUC_APEX/$TEST_HASH.0" "user cert still trusted"
  assert_no_grep " $TUC_ROOT/mnt/tuc_stage " "$TUC_MOUNTS" "staging tmpfs released"
}

test_new_set_is_ready_before_the_swap() {
  active_overlay
  in_mod 'inject_high' || fail "inject_high failed"
  tmpfs_at=$(grep -n "mount -t tmpfs tmpfs $TUC_ROOT/mnt/tuc_stage" "$TUC_CALLS" | head -n 1 | cut -d: -f1)
  umount_at=$(grep -n "^umount $TUC_APEX" "$TUC_CALLS" | head -n 1 | cut -d: -f1)
  [ -n "$tmpfs_at" ] && [ -n "$umount_at" ] && [ "$tmpfs_at" -lt "$umount_at" ] ||
    fail "old overlay released before the new set existed (tmpfs line $tmpfs_at, umount line $umount_at)"
  assert_eq "$(stat_of INJECT_OK)" 1 "INJECT_OK"
}

test_failed_bind_binds_nothing_else() {
  active_overlay
  TUC_MOUNT_FAIL=bind
  export TUC_MOUNT_FAIL
  in_mod 'inject_high' && fail "inject_high reported success"
  assert_grep "^mount -o bind $TUC_ROOT/mnt/tuc_stage $TUC_APEX" "$TUC_CALLS" "bind was tried"
  assert_no_grep "mount --bind" "$TUC_CALLS" "namespace binds after a failed bind"
  assert_no_grep "^mount -o bind .*conscrypt@340000000/cacerts$" "$TUC_CALLS" "versioned bind after a failed bind"
  assert_no_grep " $TUC_ROOT/mnt/tuc_stage " "$TUC_MOUNTS" "staging tmpfs released"
  assert_eq "$(count "$TUC_APEX")" 3 "stock store shows"
  assert_eq "$(stat_of INJECT_OK)" 0 "INJECT_OK"
}

test_versioned_apex_dir_is_bound() {
  active_overlay
  assert_grep "bind $TUC_ROOT/apex/com.android.conscrypt@340000000/cacerts " "$TUC_MOUNTS" "versioned dir bound"
}
