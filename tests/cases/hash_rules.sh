# exclude_hashes lines are subject hashes, never paths.

test_hash_rule_cannot_leave_the_stage() {
  new_device 33
  mkdir -p "$TUC_DATA/certs"
  "$TUC_REAL_CP" "$TUC_REPO/tests/fixtures/other-ca.pem" "$TUC_DATA/certs/$OTHER_HASH.0"
  printf '../certs/%s\n' "$OTHER_HASH" >"$TUC_DATA/exclude_hashes"
  in_mod 'stage_certs'
  assert_file "$TUC_DATA/certs/$OTHER_HASH.0" "custom cert deleted by a rule"
}
