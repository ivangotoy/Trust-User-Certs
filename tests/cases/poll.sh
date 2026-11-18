# Poll mode: a change made while a sync runs is synced by the next poll.

test_change_during_a_poll_sync_is_synced() {
  new_device 34
  mkdir -p "$TUC_USER"
  echo 0 >"$TUC_ROOT/syncs"
  # poll_loop with do_live_sync and wait replaced: the first sync sees a
  # certificate arrive while it runs, wait ends the loop after six polls.
  sh -c '
    first=$1 second=$2
    set -- --b64cmd
    . "$0" >/dev/null
    do_live_sync() {
      n=$(cat "$TUC_ROOT/syncs"); n=$((n + 1)); echo "$n" >"$TUC_ROOT/syncs"
      [ "$n" = 1 ] && cp "$TUC_REPO/tests/fixtures/other-ca.pem" "$USER_CERT_DIR/$second"
      return 0
    }
    W=0
    wait() {
      W=$((W + 1))
      [ "$W" = 2 ] && cp "$TUC_REPO/tests/fixtures/test-ca.pem" "$USER_CERT_DIR/$first"
      [ "$W" -gt 5 ] && exit 0
      return 0
    }
    poll_loop
  ' "$TUC_MOD/service.sh" "$TEST_HASH.0" "$OTHER_HASH.0"
  assert_eq "$(cat "$TUC_ROOT/syncs")" 2 "syncs"
}
