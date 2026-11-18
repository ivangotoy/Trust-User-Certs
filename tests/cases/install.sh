# customize.sh (the installer) in the fake root: every literal device path
# is redirected into it, the root manager's helpers are stubs.

run_customize() {
  _rc_copy="$TUC_ROOT/customize.sh"
  sed -e "s|/data/|$TUC_ROOT/data/|g" -e "s|/mnt/|$TUC_ROOT/mnt/|g" "$TUC_REPO/customize.sh" >"$_rc_copy"
  # Refuse to run with any device path left outside the fake root.
  if grep -n -E '(^|[^A-Za-z0-9_.-])/(data|mnt|system|apex|sbin)(/|"|$)' "$_rc_copy" | grep -v '^[0-9]*: *#'; then
    fail "customize.sh copy still holds a device path"
    return 1
  fi
  [ -n "$TUC_MOD" ] && [ -d "$TUC_MOD" ] || { fail "no MODPATH"; return 1; }
  sh -c '
    ui_print() { printf "%s\n" "$1"; }
    set_perm() { :; }
    set_perm_recursive() { :; }
    MODPATH=$1
    . "$2"
  ' sh "$TUC_MOD" "$_rc_copy"
}

test_install_does_not_import_the_shell_writable_dir() {
  new_device 33
  mkdir -p "$TUC_ROOT/data/local/tmp/cert"
  "$TUC_REAL_CP" "$TUC_REPO/tests/fixtures/test-ca.pem" "$TUC_ROOT/data/local/tmp/cert/$TEST_HASH.0"
  out=$(run_customize)
  assert_no_file "$TUC_DATA/certs/$TEST_HASH.0" "imported into the root-only dir"
  assert_file "$TUC_ROOT/data/local/tmp/cert/$TEST_HASH.0" "old dir left alone"
  case "$out" in *"not imported"*) ;; *) fail "no warning in: $out" ;; esac
}
