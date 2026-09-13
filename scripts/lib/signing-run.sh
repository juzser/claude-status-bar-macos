# Sourceable indirection for mutating openssl/security calls used while
# creating or configuring the local code-signing identity. Executes nothing
# at load time -- it only defines csb_signing_run. Every mutating command
# in scripts/ensure-signing-identity.sh is routed through this one function
# so a single environment variable can turn all of them into a printed,
# never-executed argv instead of a real command.
#
# Under CSB_SIGNING_DRY_RUN=1, csb_signing_run prints argv one token per
# line, each line prefixed literally "csb-dry-run-argv: ", %q-quoted so a
# token containing a newline (or any other shell-special byte) still prints
# as exactly one prefixed line, and runs nothing. Otherwise it executes the
# given command normally and prints nothing of its own.
csb_signing_run() {
  if [ "${CSB_SIGNING_DRY_RUN:-}" = "1" ]
  then
    local token
    for token in "$@"; do
      printf "csb-dry-run-argv: %q\n" "$token"
    done
    return 0
  fi
  "$@"
}
