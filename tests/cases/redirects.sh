# A file that cannot be created makes a call fail; it never ends the script.
# (A failed redirection on the special builtin ':' exits a POSIX shell.)

test_uncreatable_temp_file_does_not_end_the_script() {
  new_device 33
  out=$(in_mod 'STATS_FILE="$R/nodir/stats"; write_stats X=1; echo "stats rc=$?"
    CONFIG_FILE="$R/nodir/config"; write_cfg LOG_LEVEL 2; echo "cfg rc=$?"' 2>/dev/null)
  assert_eq "$(printf '%s\n' "$out" | tr '\n' ' ')" "stats rc=1 cfg rc=1 " "calls return 1"
  out=$(sh -c '
    set -- --b64cmd
    . "$0" >/dev/null
    LOG_FILE="$R/nodir/service.log"
    cmd_clear_log
    echo "after"
  ' "$TUC_MOD/service.sh" 2>/dev/null)
  assert_eq "$(printf '%s\n' "$out" | tail -n 1)" "after" "clear-log returns"
}
