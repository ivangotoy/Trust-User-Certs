# Module scripts reach the sleep stub in every shell: mksh has a builtin sleep
# that a PATH stub cannot shadow, and a real wait would cost seconds per test.

test_module_sleep_reaches_the_stub() {
  new_device 33
  export TUC_BOOT_COMPLETED=0
  in_mod 'wait_for_prop sys.boot_completed 1 2'
  assert_eq "$(grep -c '^sleep 1$' "$TUC_CALLS")" 2 "sleeps logged by the stub"
}
