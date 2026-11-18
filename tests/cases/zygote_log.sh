# The boot log tells a zygote timeout from a ready zygote.

test_zygote_timeout_is_not_logged_as_ready() {
  new_device 33
  run_mod service.sh
  assert_no_grep "Zygote ready" "$TUC_LOG" "timeout logged as ready"
  assert_grep "Zygote not seen" "$TUC_LOG" "timeout logged"
  new_device 33
  TUC_ZYGOTE_PIDS=4242
  export TUC_ZYGOTE_PIDS
  run_mod service.sh
  assert_grep "Zygote ready" "$TUC_LOG" "ready logged"
}
