# While the bootloop guard is active, no automatic path and no Force Sync
# injects; only Force Inject does.

blocked_device() {
  new_device 34
  user_cert test-ca.pem "$TEST_HASH.0"
  echo 3 >"$TUC_DATA/boot_fail_count"
  run_mod post-fs-data.sh
  run_mod service.sh
  assert_file "$TUC_DATA/blocked" "precondition: guard active"
  assert_eq "$(cat "$TUC_MOUNTS")" "" "precondition: nothing mounted"
}

test_force_sync_does_not_inject_while_blocked() {
  blocked_device
  out=$(run_mod service.sh --sync)
  assert_eq "$out" "rc=1" "sync rc"
  assert_eq "$(cat "$TUC_MOUNTS")" "" "nothing mounted"
  assert_eq "$(stat_of LIVESYNCS)" "" "no sync counted"
  assert_grep "bootloop guard is active" "$TUC_LOG" "skip logged"
}

test_poll_loop_does_not_inject_while_blocked() {
  blocked_device
  sh -c '
    cert=$1
    set -- --b64cmd
    . "$0" >/dev/null
    W=0
    wait() {
      W=$((W + 1))
      [ "$W" = 1 ] && cp "$TUC_REPO/tests/fixtures/other-ca.pem" "$USER_CERT_DIR/$cert"
      [ "$W" -gt 2 ] && exit 0
      return 0
    }
    poll_loop
  ' "$TUC_MOD/service.sh" "$OTHER_HASH.0"
  assert_grep "Poll: change detected" "$TUC_LOG" "change seen"
  assert_eq "$(cat "$TUC_MOUNTS")" "" "nothing mounted"
}
