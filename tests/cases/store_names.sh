# A removed user certificate that carried a stock name gives the stock file
# back to the store at the next sync.

test_removed_user_cert_with_a_stock_name_is_replaced() {
  new_device 34
  user_cert test-ca.pem 0000000a.0
  run_mod post-fs-data.sh
  run_mod service.sh
  cmp -s "$TUC_APEX/0000000a.0" "$TUC_USER/0000000a.0" || fail "user version not live"
  rm -f "$TUC_USER/0000000a.0"
  out=$(run_mod service.sh --sync)
  assert_eq "$out" "rc=0" "sync rc"
  assert_eq "$(cat "$TUC_APEX/0000000a.0")" "stock 0000000a" "stock version back"
}

test_size_check_without_awk() {
  new_device 33
  mkdir -p "$TUC_ROOT/a" "$TUC_ROOT/b" "$TUC_ROOT/d"
  printf 'one\n' >"$TUC_ROOT/a/x.0"
  printf 'two-two\n' >"$TUC_ROOT/b/x.0"
  printf 'three\n' >"$TUC_ROOT/a/y.0"
  "$TUC_REAL_CP" "$TUC_ROOT/b/x.0" "$TUC_ROOT/a/y.0" "$TUC_ROOT/d/"
  for awk_mode in with without; do
    pre=""
    [ "$awk_mode" = without ] && pre='CMD_AWK=""; '
    in_mod "${pre}sizes_match '$TUC_ROOT/d' '$TUC_ROOT/a' '$TUC_ROOT/b'" >/dev/null ||
      fail "$awk_mode awk: whole copy reported short"
    head -c 3 "$TUC_ROOT/a/y.0" >"$TUC_ROOT/d/y.0"
    assert_eq "$(in_mod "${pre}sizes_match '$TUC_ROOT/d' '$TUC_ROOT/a' '$TUC_ROOT/b'")" y.0 "$awk_mode awk: cut file named"
    "$TUC_REAL_CP" "$TUC_ROOT/a/y.0" "$TUC_ROOT/d/"
  done
}
