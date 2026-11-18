# Without a stage (a sync failed), --status and --certs still report
# certificates excluded by a rule as excluded, exactly as with one.

status_and_certs() {
  run_mod service.sh --status | grep -E '^(USER|CUSTOM)_'
  run_mod service.sh --certs | cut -d'|' -f1-3 | sort
}

test_rule_exclusions_survive_an_aborted_sync() {
  for rule in hash subject; do
    new_device 34
    user_cert test-ca.pem "$TEST_HASH.0"
    user_cert other-ca.pem "$OTHER_HASH.0"
    if [ "$rule" = hash ]; then
      printf '%s\n' "$OTHER_HASH" >"$TUC_DATA/exclude_hashes"
    else
      printf 'TUC Other CA\n' >"$TUC_DATA/exclude_subjects"
    fi
    run_mod post-fs-data.sh
    run_mod service.sh
    before=$(status_and_certs)
    printf '%s\n' "$before" | grep -q '^USER_EXCLUDED=1$' || fail "$rule: precondition: one excluded"
    TUC_CP_FAIL_SRC=cacerts-added
    export TUC_CP_FAIL_SRC
    run_mod service.sh --sync >/dev/null
    unset TUC_CP_FAIL_SRC
    [ -d "$TUC_DATA/cert_stage" ] && fail "$rule: precondition: stage removed"
    assert_eq "$(status_and_certs)" "$before" "$rule: status and cert list"
  done
}
