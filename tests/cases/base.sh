# Behaviour of the module as shipped.

test_cert_name_hash_pem_and_der() {
  new_device 33
  assert_eq "$(in_mod "cert_name_hash '$TUC_REPO/tests/fixtures/test-ca.pem'")" "$TEST_HASH" "PEM hash"
  sed -n '/-----BEGIN/,/-----END/p' "$TUC_REPO/tests/fixtures/other-ca.pem" | grep -v -- ----- |
    base64 -d >"$TUC_ROOT/other.der"
  assert_eq "$(in_mod "cert_name_hash '$TUC_ROOT/other.der'")" "$OTHER_HASH" "DER hash"
  printf 'not a certificate\n' >"$TUC_ROOT/junk.0"
  in_mod "cert_name_hash '$TUC_ROOT/junk.0'" >/dev/null && fail "junk file got a hash"
  return 0
}

test_cert_name_ok() {
  new_device 33
  user_cert test-ca.pem "$TEST_HASH.0"
  user_cert test-ca.pem 12345678.0
  user_cert test-ca.pem mycert.pem
  in_mod "cert_name_ok '$TUC_USER/$TEST_HASH.0'" || fail "right name rejected"
  in_mod "cert_name_ok '$TUC_USER/12345678.0'" && fail "wrong hash accepted"
  in_mod "cert_name_ok '$TUC_USER/mycert.pem'" && fail "non-hash name accepted"
  return 0
}

test_stats_round_trip() {
  new_device 33
  in_mod 'write_stats A=1 B=two; write_stats A=3; del_stat B'
  assert_eq "$(stat_of A)" 3 "A"
  assert_eq "$(stat_of B)" "" "B deleted"
  assert_eq "$(ls "$TUC_DATA/locks" 2>/dev/null)" "" "no lock left"
}

test_exclusion_rules() {
  new_device 33
  user_cert test-ca.pem "$TEST_HASH.0"
  user_cert other-ca.pem "$OTHER_HASH.0"
  printf '# comment\r\n%s\r\n' "$OTHER_HASH" >"$TUC_DATA/exclude_hashes"
  printf 'TUC Test Root\r\n' >"$TUC_DATA/exclude_subjects"
  in_mod 'stage_certs'
  assert_no_file "$TUC_DATA/cert_stage/$OTHER_HASH.0" "hash rule (CRLF)"
  assert_no_file "$TUC_DATA/cert_stage/$TEST_HASH.0" "subject rule on a PEM (CRLF)"
  assert_eq "$(count "$TUC_DATA/cert_stage")" 3 "stock certs kept"
}

test_config_validation() {
  new_device 33
  out=$(run_mod service.sh --config LOG_LEVEL 7)
  assert_eq "$out" "rc=1" "bad level"
  out=$(run_mod service.sh --config NOPE 1)
  assert_eq "$out" "rc=1" "bad key"
  out=$(run_mod service.sh --config LOG_LEVEL 0)
  assert_eq "$out" "rc=0" "good level"
  assert_grep '^LOG_LEVEL=0$' "$TUC_DATA/config" "level written"
}

test_boot_low_sdk_injects_user_cert() {
  new_device 33
  user_cert test-ca.pem "$TEST_HASH.0"
  run_mod post-fs-data.sh
  assert_file "$TUC_SYS/$TEST_HASH.0" "user cert in the store"
  assert_eq "$(count "$TUC_SYS")" 4 "store size"
  assert_eq "$(stat_of INJECT_OK)" 1 "INJECT_OK"
  assert_eq "$(cat "$TUC_DATA/boot_fail_count")" 1 "fail counter armed"
  assert_grep "tmpfs $TUC_SYS " "$TUC_MOUNTS" "tmpfs over the store"
  run_mod service.sh
  assert_eq "$(cat "$TUC_DATA/boot_fail_count")" 0 "fail counter cleared after boot"
}

test_boot_high_sdk_injects_user_cert() {
  new_device 34
  user_cert test-ca.pem "$TEST_HASH.0"
  run_mod post-fs-data.sh
  assert_eq "$(stat_of DEFERRED)" 1 "deferred"
  run_mod service.sh
  assert_file "$TUC_APEX/$TEST_HASH.0" "user cert in the apex store"
  assert_eq "$(stat_of INJECT_OK)" 1 "INJECT_OK"
  assert_grep "bind $TUC_APEX " "$TUC_MOUNTS" "bind over the apex store"
  assert_no_grep "$TUC_ROOT/mnt/tuc_stage " "$TUC_MOUNTS" "staging tmpfs released"
  assert_eq "$(cat "$TUC_DATA/boot_fail_count")" 0 "fail counter cleared after boot"
}

test_live_sync_propagates_add_and_remove() {
  new_device 34
  user_cert test-ca.pem "$TEST_HASH.0"
  run_mod post-fs-data.sh
  run_mod service.sh
  rm -f "$TUC_USER/$TEST_HASH.0"
  user_cert other-ca.pem "$OTHER_HASH.0"
  out=$(run_mod service.sh --sync)
  assert_eq "$out" "rc=0" "sync rc"
  assert_no_file "$TUC_APEX/$TEST_HASH.0" "removed cert gone"
  assert_file "$TUC_APEX/$OTHER_HASH.0" "added cert present"
  assert_eq "$(count "$TUC_APEX")" 4 "store size"
}

test_guard_blocks_at_limit() {
  new_device 33
  user_cert test-ca.pem "$TEST_HASH.0"
  mkdir -p "$TUC_DATA"
  echo 3 >"$TUC_DATA/boot_fail_count"
  run_mod post-fs-data.sh
  assert_eq "$(stat_of BLOCKED)" 1 "BLOCKED"
  assert_eq "$(cat "$TUC_MOUNTS")" "" "nothing mounted"
  out=$(run_mod service.sh --reset-fail)
  assert_eq "$out" "rc=0" "reset rc"
  assert_eq "$(cat "$TUC_DATA/boot_fail_count")" 0 "reset"
}
