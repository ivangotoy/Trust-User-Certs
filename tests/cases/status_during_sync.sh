# --status and --certs while a sync rebuilds the stage (or the stage is
# older than the certificates): a certificate counts as excluded only when
# it is not in the store and a rule drops it, never because a stage being
# rebuilt lacks it. Neither command waits for the sync.

test_status_while_a_sync_rebuilds_the_stage() {
  new_device 34
  run_mod post-fs-data.sh
  run_mod service.sh
  user_cert test-ca.pem "$TEST_HASH.0"
  user_cert other-ca.pem "$OTHER_HASH.0"
  printf '%s\n' "$OTHER_HASH" >"$TUC_DATA/exclude_hashes"
  # A sync of this module holds the lock and has staged the stock set only.
  tail -f /dev/null "$TUC_MOD/module.prop" >/dev/null 2>&1 &
  owner=$!
  mkdir -p "$TUC_DATA/locks/sync.lock"
  echo "$owner" >"$TUC_DATA/locks/sync.lock/pid"
  rm -f "$TUC_DATA/cert_stage"/*
  "$TUC_REAL_CP" "$TUC_APEX"/0000000a.0 "$TUC_DATA/cert_stage/"
  : >"$TUC_CALLS"
  st=$(run_mod service.sh --status)
  certs=$(run_mod service.sh --certs | cut -d'|' -f1,3 | sort | tr '\n' ' ')
  kill "$owner" 2>/dev/null
  assert_eq "$(printf '%s\n' "$st" | sed -n 's/^USER_EXCLUDED=//p')" 1 "USER_EXCLUDED (only the rule-matched one)"
  assert_eq "$(printf '%s\n' "$st" | sed -n 's/^USER_TRUSTED=//p')" 0 "USER_TRUSTED"
  assert_eq "$certs" "$TEST_HASH.0|0 $OTHER_HASH.0|x " "cert list"
  assert_eq "$(grep -c '^sleep' "$TUC_CALLS")" 0 "waits by status/certs"
}
