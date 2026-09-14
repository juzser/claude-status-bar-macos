#!/bin/bash
# Static + differential test harness for the signing scripts (plan v2).
# Static assertions read source text only, via THE ANCHORED-LINE ROUTINE
# (grep -nE select, then normalise, then grep -F token search) -- no
# tokenising parser. Dynamic assertions run only: the dry-run indirection
# in isolation (never touches a keychain); and the two subprocesses
# functional clause 7(B) permits, both under THE CLEAN LAUNCH (env -i with
# an explicit allowlist), gated on every static prerequisite passing first
# and on the read-only identity-present probe. No security(1) mutating
# subcommand and no openssl invocation ever runs from this harness.
set -u
cd "$(dirname "$0")/.."
FAILURES=0
IDFILE=scripts/ensure-signing-identity.sh
APPFILE=scripts/make-app.sh

check() { # <desc> <exit_code>
  if [[ "$2" -ne 0 ]]; then echo "FAIL: $1"; FAILURES=$((FAILURES+1)); else echo "ok: $1"; fi
}
# THE ANCHORED-LINE ROUTINE (criterion 1): normalise a selected physical
# line -- trim, collapse internal whitespace, one trailing space.
norm() { sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[[:space:]]+/ /g; s/$/ /'; }
has() { grep -qF -- "$1" <<<"$2"; } # fixed-string token search

IDENTITY_PRESENT=1
security find-certificate -c "ClaudeStatusBar Local Signing" \
  "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || IDENTITY_PRESENT=0
CLEAN=(env -i "HOME=$HOME" "PATH=$PATH" "TMPDIR=${TMPDIR:-/tmp}")

# ---------------------------------------------------------------------
# Criteria 1 & 2 (SEC-2, static): the set-key-partition-list argv.
# ---------------------------------------------------------------------
c1c2() {
  local file="$1"
  local ere='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*[[:space:]]+)?security[[:space:]]+set-key-partition-list[[:space:]]'
  local matches; matches="$(grep -nE "$ere" "$file")"
  [[ -z "$matches" ]] && { echo "no set-key-partition-list command found in $file"; return 1; }
  local n; n="$(wc -l <<<"$matches" | tr -d ' ')"
  if [[ "$n" -gt 1 ]]; then
    echo "set-key-partition-list is invoked $n times in $file: this criterion grades exactly one command"; return 1
  fi
  local lno="${matches%%:*}" raw="${matches#*:}"
  if [[ "$raw" == *'\' ]]; then
    echo "$file:$lno is a continued line: v2 grades signing invocations as single physical lines"; return 1
  fi
  local nl; nl="$(norm <<<"$raw")"
  if has '[@]}' "$nl" || has '[*]}' "$nl"; then
    echo "set-key-partition-list argv at $file:$lno is array-assembled: v2 grades this line as literal text"; return 1
  fi
  local lmsg="" smsg=""
  if ! has ' -l "$SIGNING_IDENTITY_NAME" ' "$nl" && ! has ' -l $SIGNING_IDENTITY_NAME ' "$nl"; then
    lmsg="no -l in set-key-partition-list argv: the partition list is unbounded"
  fi
  has ' -s ' "$nl" && smsg="found -s in set-key-partition-list argv: -s takes no operand and swallows the next word"
  if [[ -n "$lmsg" || -n "$smsg" ]]; then
    [[ -n "$lmsg" ]] && echo "$lmsg"
    [[ -n "$smsg" ]] && echo "$smsg"
    return 1
  fi
  if ! has ' -S apple-tool:,apple:,codesign: ' "$nl" || [[ "$(grep -oF ' -S ' <<<"$nl" | wc -l)" -ne 1 ]]; then
    echo "set-key-partition-list argv has no single -S apple-tool:,apple:,codesign: operand"; return 1
  fi
  has ' -k ' "$nl" && { echo "found -k in set-key-partition-list argv: -k takes the keychain unlock password"; return 1; }
  if [[ "${nl%\"\$LOGIN_KEYCHAIN\" }" == "$nl" && "${nl%\$LOGIN_KEYCHAIN }" == "$nl" ]]; then
    echo 'set-key-partition-list argv does not end in "$LOGIN_KEYCHAIN": keychain is not the trailing positional'; return 1
  fi
  echo 'ok: partition list bounded to identity "$SIGNING_IDENTITY_NAME"'
  return 0
}
OUT="$(c1c2 "$IDFILE")"; RC=$?; echo "$OUT"
check "criteria 1+2: set-key-partition-list argv is bounded (-l, one -S, no -s/-k, trailing keychain)" $RC

FDIR="$(mktemp -d)"; FS="$FDIR/fs.sh"
sed -E 's/-l "\$SIGNING_IDENTITY_NAME"/-s/' "$IDFILE" > "$FS"
FOUT="$(c1c2 "$FS")"; FRC=$?
[[ "$FRC" -ne 0 && "$FOUT" == *"no -l in set-key-partition-list argv"* ]]
check "fixture F-s: -s in place of -l is rejected with the unbounded-partition-list null" $?
[[ "$FRC" -ne 0 && "$FOUT" == *"found -s in set-key-partition-list argv"* ]]
check "fixture F-s: -s in place of -l also surfaces criterion 2's own -s null" $?
rm -rf "$FDIR"

FDIR="$(mktemp -d)"; FSCAP="$FDIR/fS.sh"
sed -E 's/ -S apple-tool:,apple:,codesign://' "$IDFILE" > "$FSCAP"
FOUT="$(c1c2 "$FSCAP")"; FRC=$?
[[ "$FRC" -ne 0 && "$FOUT" == *"has no single -S apple-tool:,apple:,codesign: operand"* ]]
check "fixture F-S: missing -S operand is rejected" $?
rm -rf "$FDIR"

FDIR="$(mktemp -d)"; FK="$FDIR/fk.sh"
sed -E 's/set-key-partition-list /set-key-partition-list -k /' "$IDFILE" > "$FK"
FOUT="$(c1c2 "$FK")"; FRC=$?
[[ "$FRC" -ne 0 && "$FOUT" == *"found -k in set-key-partition-list argv"* ]]
check "fixture F-k: -k inserted after the command is rejected" $?
rm -rf "$FDIR"

FDIR="$(mktemp -d)"; FTAIL="$FDIR/ftail.sh"
sed -E 's/-l "\$SIGNING_IDENTITY_NAME" "\$LOGIN_KEYCHAIN"/"\$LOGIN_KEYCHAIN" -l "\$SIGNING_IDENTITY_NAME"/' "$IDFILE" > "$FTAIL"
FOUT="$(c1c2 "$FTAIL")"; FRC=$?
[[ "$FRC" -ne 0 && "$FOUT" == *'does not end in "$LOGIN_KEYCHAIN": keychain is not the trailing positional'* ]]
check "fixture F-tail: keychain and -l swapped so keychain is no longer trailing is rejected" $?
rm -rf "$FDIR"

# ---------------------------------------------------------------------
# The -l selector's two static preconditions (SEC-2, static): the p12 must
# name the identity, and a non-matching selector must not abort the build.
# ---------------------------------------------------------------------
cname() {
  local file="$1"
  local m; m="$(grep -nE '^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*[[:space:]]+)?openssl[[:space:]]+pkcs12[[:space:]]+-export[[:space:]]' "$file" | head -1)"
  [[ -z "$m" ]] && { echo "no openssl pkcs12 -export command found in $file"; return 1; }
  local nl; nl="$(norm <<<"${m#*:}")"
  if ! has ' -name "$SIGNING_IDENTITY_NAME" ' "$nl" && ! has ' -name $SIGNING_IDENTITY_NAME ' "$nl"; then
    echo "p12 export at $file:${m%%:*} carries no -name: security import then leaves the imported key's print name at macOS's placeholder <key>, so -l \"\$SIGNING_IDENTITY_NAME\" selects no key and the partition list is never set"; return 1
  fi
  echo 'ok: the p12 export names the identity, so the imported key print name is what -l selects on'
  return 0
}
OUT="$(cname "$IDFILE")"; RC=$?; echo "$OUT"
check "the p12 export carries -name \"\$SIGNING_IDENTITY_NAME\", the print name -l selects on" $RC

FDIR="$(mktemp -d)"; FN="$FDIR/fname.sh"
sed -E 's/ -name "\$SIGNING_IDENTITY_NAME"//' "$IDFILE" > "$FN"
FOUT="$(cname "$FN")"; FRC=$?
[[ "$FRC" -ne 0 && "$FOUT" == *"carries no -name"* ]]
check "fixture F-name: dropping -name from the p12 export is rejected with the placeholder-print-name null" $?
rm -rf "$FDIR"

cabort() {
  local file="$1"
  local ere='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*[[:space:]]+)?security[[:space:]]+set-key-partition-list[[:space:]]'
  local lno; lno="$(grep -nE "$ere" "$file" | head -1 | cut -d: -f1)"
  [[ -z "$lno" ]] && { echo "no set-key-partition-list command found in $file"; return 1; }
  local before after restore tail
  before="$(sed -n "$((lno-1))p" "$file" | norm)"
  after="$(sed -n "$((lno+1))p" "$file" | norm)"
  restore="$(sed -n "$((lno+2))p" "$file" | norm)"
  tail="$(sed -n "$((lno+3)),$((lno+7))p" "$file")"
  if [[ "$before" != 'set +e ' || "$after" != 'CSB_PARTITION_RC=$? ' || "$restore" != 'set -e ' ]]; then
    echo "set-key-partition-list at $file:$lno is not wrapped in set +e / rc capture / set -e: under set -euo pipefail a selector that matches no key aborts the script after the cert and key are already imported"; return 1
  fi
  if ! grep -qF 'CSB_PARTITION_RC' <<<"$tail" || ! grep -qF '>&2' <<<"$tail"; then
    echo "the captured set-key-partition-list exit status is never reported on stderr at $file:$lno: a selector that matched nothing would fail silently"; return 1
  fi
  echo 'ok: a non-zero set-key-partition-list exit is reported on stderr and does not abort the build'
  return 0
}
OUT="$(cabort "$IDFILE")"; RC=$?; echo "$OUT"
check "a non-matching -l selector warns instead of aborting the build" $RC

FDIR="$(mktemp -d)"; FA="$FDIR/fabort.sh"
sed -E '/^[[:space:]]*set \+e[[:space:]]*$/d' "$IDFILE" > "$FA"
FOUT="$(cabort "$FA")"; FRC=$?
[[ "$FRC" -ne 0 && "$FOUT" == *"is not wrapped in set +e"* ]]
check "fixture F-abort: removing the set +e wrapper is rejected as a partition-list call that can kill the build" $?
rm -rf "$FDIR"

# ---------------------------------------------------------------------
# THE CONSTRUCT WALK + GUARD FORM at grep strength (criteria 3, 5(e)):
# shared between ensure-signing-identity.sh's and make-app.sh's guards.
# ---------------------------------------------------------------------
guard_first() { # <file> <guard-regex> <preamble-pattern...> -- echoes guard line no. or "BAD:<lno>:<text>"
  local file="$1" re="$2"; shift 2
  local gno; gno="$(grep -nE "$re" "$file" | head -1 | cut -d: -f1)"
  [[ -z "$gno" ]] && { echo "NOGUARD"; return 1; }
  local eff; eff="$(grep -nE -v '^[[:space:]]*(#|$)' "$file")"
  while IFS= read -r l; do
    local lno="${l%%:*}" txt="${l#*:}"
    [[ "$lno" -ge "$gno" ]] && break
    local n; n="$(norm <<<"$txt")" ok=0
    for p in "$@"; do [[ "$n" == "$p" ]] && { ok=1; break; }; done
    [[ "$ok" -eq 0 ]] && { echo "BAD:$lno:$txt"; return 1; }
  done <<<"$eff"
  echo "$gno"; return 0
}
guard_form() { # <file> <guard_no> <diagnostic-text> <cond-pattern...> -- echoes "ok" or "BADCOND"/"BADCOUNT"/"BADDIAG"/"BADEXIT"
  local file="$1" gno="$2" diag="$3"; shift 3
  local block; block="$(sed -n "${gno},/^[[:space:]]*fi\$/p" "$file")"
  local cond; cond="$(norm <<<"$(sed -n '1p' <<<"$block")")"
  local ok=0; for c in "$@"; do [[ "$cond" == "$c" ]] && { ok=1; break; }; done
  [[ "$ok" -eq 0 ]] && { echo "BADCOND:$cond"; return 1; }
  local eff; eff="$(grep -nE -v '^[[:space:]]*(#|$)' <<<"$block" | tail -n +2)"
  local body=()
  while IFS= read -r l; do
    local n; n="$(norm <<<"${l#*:}")"
    [[ "$n" == 'then ' || "$n" == 'fi ' || "$n" == 'else ' ]] && continue
    body+=("$l")
  done <<<"$eff"
  [[ "${#body[@]}" -ne 2 ]] && { echo "BADCOUNT"; return 1; }
  local n1; n1="$(norm <<<"${body[0]#*:}")"
  [[ "$n1" != "$diag " ]] && { echo "BADDIAG:${body[0]}"; return 1; }
  local n2; n2="$(norm <<<"${body[1]#*:}")"
  [[ ! "$n2" =~ ^exit\ ([1-9][0-9]{0,2})\ $ ]] && { echo "BADEXIT:${body[1]}"; return 1; }
  echo "ok"; return 0
}

ID_PRE=(
  'set -euo pipefail ' 'then ' 'else ' 'fi '
  'if [ "${CSB_SIGNING_DRY_RUN:-}" = "1" ] ' 'if [ "${CSB_SIGNING_DRY_RUN-}" = "1" ] '
  'SIGNING_IDENTITY_NAME="${CSB_SIGNING_IDENTITY_NAME-ClaudeStatusBar Local Signing}" '
  'SIGNING_IDENTITY_NAME="ClaudeStatusBar Local Signing" '
  'LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db" '
)
GR="$(guard_first "$IDFILE" '^[[:space:]]*if[[:space:]].*-z[[:space:]]+"?\$\{?SIGNING_IDENTITY_NAME' "${ID_PRE[@]}")"; RC=$?
if [[ "$RC" -eq 0 ]]; then echo "ok: the empty-name guard is the first executable construct"; else echo "empty-name guard is not first: $GR"; fi
check "criterion 3: empty-name guard is the first executable construct" $RC
GUARD_NO="$GR"
FR="$(guard_form "$IDFILE" "$GUARD_NO" 'echo "ensure-signing-identity: refusing to run set-key-partition-list with an empty identity name" >&2' \
  'if [ -z "$SIGNING_IDENTITY_NAME" ] ' 'if [ -z "${SIGNING_IDENTITY_NAME:-}" ] ' 'if [ -z "${SIGNING_IDENTITY_NAME-}" ] ' \
  'if [[ -z "$SIGNING_IDENTITY_NAME" ]] ' 'if [[ -z "${SIGNING_IDENTITY_NAME:-}" ]] ')"; FRC=$?
if [[ "$FRC" -eq 0 ]]; then echo "ok: the empty-name guard refuses: condition, stderr diagnostic, non-zero exit"; else echo "guard cannot refuse: $FR"; fi
check "criterion 3: empty-name guard form refuses" $FRC
G3RC="$FRC"

FDIR="$(mktemp -d)"; FG="$FDIR/g1.sh"
awk -v g="$GUARD_NO" 'NR>=g && /^[[:space:]]*exit [0-9]+$/ {next} {print}' "$IDFILE" > "$FG"
FGOUT="$(guard_form "$FG" "$GUARD_NO" 'echo "ensure-signing-identity: refusing to run set-key-partition-list with an empty identity name" >&2' \
  'if [ -z "$SIGNING_IDENTITY_NAME" ] ')"; FGRC=$?
[[ "$FGRC" -ne 0 && "$FGOUT" == "BADCOUNT" ]]
check "fixture G1: guard exit removed is rejected as present-but-not-refusing" $?
rm -rf "$FDIR"

# Behavioural half of criterion 3 -- functional clause 7(B1)'s ONE permitted
# subprocess, gated on the static gate above and the identity-present probe.
if [[ "$RC" -eq 0 && "$G3RC" -eq 0 ]]; then
  if [[ "$IDENTITY_PRESENT" -eq 1 ]]; then
    B1OUT="$("${CLEAN[@]}" CSB_SIGNING_DRY_RUN=1 CSB_SIGNING_IDENTITY_NAME= /bin/bash "$IDFILE" 2>&1)"; B1RC=$?
    [[ "$B1RC" -ne 0 ]] && has "ensure-signing-identity: refusing to run set-key-partition-list with an empty identity name" "$B1OUT" && ! has "csb-dry-run-argv:" "$B1OUT"
    check "B1 (clean launch): empty identity name refused before argv assembly" $?
  else
    echo "skipped: B1 needs the signing identity present; static certification passed"
  fi
else
  echo "skipped: B1 not launched -- static gate did not pass"
fi

# ---------------------------------------------------------------------
# Criterion 4 (SEC-2, the dry-run-only override seam).
# ---------------------------------------------------------------------
c4() {
  local file="$1"
  local hits; hits="$(grep -n 'CSB_SIGNING_IDENTITY_NAME' "$file" | grep -vE '^[0-9]+:[[:space:]]*#')"
  local n; n="$( [[ -z "$hits" ]] && echo 0 || wc -l <<<"$hits" | tr -d ' ')"
  if [[ "$n" -gt 1 ]]; then
    echo "CSB_SIGNING_IDENTITY_NAME is referenced on $n code lines: only the dry-run assignment is permitted"; return 1
  fi
  if [[ "$n" -eq 1 ]]; then
    local txt="${hits#*:}" n1; n1="$(norm <<<"$txt")"
    if [[ "$n1" != 'SIGNING_IDENTITY_NAME="${CSB_SIGNING_IDENTITY_NAME-ClaudeStatusBar Local Signing}" ' ]]; then
      if has ':-' "$n1"; then
        echo "dry-run assignment uses \":-\": that substitutes the default for an explicitly-empty override, so the empty-name guard can never fire"
      else
        echo "dry-run assignment is not the single permitted assignment SIGNING_IDENTITY_NAME=\"\${CSB_SIGNING_IDENTITY_NAME-ClaudeStatusBar Local Signing}\""
      fi
      return 1
    fi
  fi
  local bare_n; bare_n="$(grep -nE '^[[:space:]]*SIGNING_IDENTITY_NAME=' "$file" | while IFS=: read -r l t; do
      nt="$(norm <<<"$t")"
      [[ "$nt" == 'SIGNING_IDENTITY_NAME="ClaudeStatusBar Local Signing" ' || "$nt" == 'SIGNING_IDENTITY_NAME="${CSB_SIGNING_IDENTITY_NAME-ClaudeStatusBar Local Signing}" ' ]] || echo "$l"
    done)"
  [[ -n "$bare_n" ]] && { echo "identity name override reachable in the real path: the environment can choose which CN a real build creates"; return 1; }
  grep -qF 'SIGNING_IDENTITY_NAME="ClaudeStatusBar Local Signing"' "$file" || { echo "the bare-literal real-path assignment is absent"; return 1; }
  echo 'ok: identity name is a literal outside dry-run, and the dry-run assignment is exactly the permitted "-" expansion'
  return 0
}
OUT="$(c4 "$IDFILE")"; RC=$?; echo "$OUT"
check "criterion 4: identity-name override is reachable only under dry-run, via '-'" $RC

FDIR="$(mktemp -d)"; FC1="$FDIR/c1.sh"
sed -E 's/(CSB_SIGNING_IDENTITY_NAME-ClaudeStatusBar Local Signing)\}"/\1-test}"/' "$IDFILE" > "$FC1"
FOUT="$(c4 "$FC1")"; FRC=$?
[[ "$FRC" -ne 0 && "$FOUT" == *"not the single permitted assignment"* ]]
check "fixture C1: concatenated -test suffix on the dry-run assignment is rejected" $?
rm -rf "$FDIR"

FDIR="$(mktemp -d)"; FC2="$FDIR/c2.sh"
sed -E "s/SIGNING_IDENTITY_NAME=\"(\\\$\{CSB_SIGNING_IDENTITY_NAME-ClaudeStatusBar Local Signing\})\"/SIGNING_IDENTITY_NAME='\1'/" "$IDFILE" > "$FC2"
FOUT="$(c4 "$FC2")"; FRC=$?
[[ "$FRC" -ne 0 && "$FOUT" == *"not the single permitted assignment"* ]]
check "fixture C2: single-quoted expansion of the dry-run assignment is rejected" $?
rm -rf "$FDIR"

# ---------------------------------------------------------------------
# Criterion 5: the dry-run default. (a)-(c) exercise the indirection alone.
# ---------------------------------------------------------------------
OUT="$(bash -c 'source scripts/lib/signing-run.sh' 2>&1)"
[[ -z "$OUT" ]]
check "sourcing signing-run.sh at load time produces no output (functional clause 4)" $?

OUT="$(bash -c 'source scripts/lib/signing-run.sh; csb_signing_run /bin/echo csb-indirection-probe')"
grep -qx 'csb-indirection-probe' <<<"$OUT" && ! grep -q '^csb-dry-run-argv: ' <<<"$OUT"
check "(a) default-executes: indirection executed with CSB_SIGNING_DRY_RUN unset" $?

OUT="$(bash -c 'source scripts/lib/signing-run.sh; CSB_SIGNING_DRY_RUN= csb_signing_run /bin/echo csb-indirection-probe')"
grep -qx 'csb-indirection-probe' <<<"$OUT" && ! grep -q '^csb-dry-run-argv: ' <<<"$OUT"
check "(b) explicit-empty-executes: indirection executed with CSB_SIGNING_DRY_RUN set but empty" $?

OUT="$(bash -c 'source scripts/lib/signing-run.sh; CSB_SIGNING_DRY_RUN=1 csb_signing_run /bin/echo csb-indirection-probe')"
! grep -qx 'csb-indirection-probe' <<<"$OUT" && grep -qx 'csb-dry-run-argv: /bin/echo' <<<"$OUT" && grep -qx 'csb-dry-run-argv: csb-indirection-probe' <<<"$OUT"
check "(c) dry-run-suppresses: dry run printed argv and executed nothing" $?

OUT="$(bash -c 'source scripts/lib/signing-run.sh; CSB_SIGNING_DRY_RUN=1 csb_signing_run /bin/echo "$(printf "a\nb")"')"
[[ "$(wc -l <<<"$OUT" | tr -d ' ')" -eq 2 ]] && [[ "$(grep -vc '^csb-dry-run-argv: ' <<<"$OUT")" -eq 0 ]] && ! grep -qx 'b' <<<"$OUT"
check "(d) newline token is printed as one escaped line" $?

OUT="$(bash -c 'source scripts/lib/signing-run.sh; declare -a ARGV_IN=("a b" "\$HOME" "it'\''s" "back\slash" "-n"); CSB_SIGNING_DRY_RUN=1 csb_signing_run "${ARGV_IN[@]}"')"
RT_ARGV_IN=('a b' '$HOME' "it's" 'back\slash' '-n')
RT_GOT=()
while IFS= read -r rt_line; do
  RT_REST="${rt_line#csb-dry-run-argv: }"
  eval "RT_GOT+=($RT_REST)"
done <<<"$OUT"
RT_OK=1
[[ "${#RT_GOT[@]}" -eq "${#RT_ARGV_IN[@]}" ]] || RT_OK=0
for rt_i in "${!RT_ARGV_IN[@]}"; do
  [[ "${RT_GOT[$rt_i]-__csb_missing__}" == "${RT_ARGV_IN[$rt_i]}" ]] || RT_OK=0
done
[[ "$RT_OK" -eq 1 ]]
check "(f) %q round-trips a token with a space, a dollar, a quote, a backslash and a leading dash" $?

OUT="$(bash -c 'source scripts/lib/signing-run.sh; CSB_SIGNING_DRY_RUN=1 csb_signing_run /bin/echo ""')"
[[ "$(wc -l <<<"$OUT" | tr -d ' ')" -eq 2 ]] && [[ "$(grep -vc '^csb-dry-run-argv: ' <<<"$OUT")" -eq 0 ]]
check "(g) empty token still prints exactly one prefixed line" $?

OUT="$(bash -c 'source scripts/lib/signing-run.sh; CSB_SIGNING_DRY_RUN=1 csb_signing_run /bin/echo "$(printf "a\nb")" plain "$(printf "c\nd\ne")"')"
[[ "$(wc -l <<<"$OUT" | tr -d ' ')" -eq 4 ]] && [[ "$(grep -vc '^csb-dry-run-argv: ' <<<"$OUT")" -eq 0 ]]
check "(h) line count equals a 4-token argv with two newline-bearing tokens" $?

c5d() { # no-leak: CSB_SIGNING_DRY_RUN assigned/exported only in the signing-test target
  local bad=()
  for f in Makefile "$APPFILE" "$IDFILE"; do
    local intarget=1
    [[ "$f" == "Makefile" ]] && intarget=0
    while IFS= read -r l; do
      local lno="${l%%:*}" txt="${l#*:}"
      if [[ "$f" == "Makefile" ]]; then
        [[ "$txt" =~ ^signing-test: ]] && { intarget=1; continue; }
        [[ "$intarget" -eq 1 && "$txt" =~ ^[^[:space:]] && ! "$txt" =~ ^signing-test: ]] && intarget=0
      fi
      [[ "$txt" =~ ^[[:space:]]*# ]] && continue
      if [[ "$intarget" -eq 0 ]] && [[ "$txt" =~ (^|[^A-Za-z_])CSB_SIGNING_DRY_RUN= || "$txt" =~ ^[[:space:]]*export[[:space:]]+CSB_SIGNING_DRY_RUN ]]; then
        bad+=("$f:$lno")
      fi
    done < <(grep -n '' "$f")
  done
  [[ "${#bad[@]}" -gt 0 ]] && { echo "CSB_SIGNING_DRY_RUN assigned/exported outside signing-test at ${bad[*]}"; return 1; }
  echo "ok: CSB_SIGNING_DRY_RUN is assigned or exported only in the signing-test target"
  return 0
}
OUT="$(c5d)"; RC=$?; echo "$OUT"
check "(d) no-leak: CSB_SIGNING_DRY_RUN is scoped to the signing-test target" $RC

APP_PRE=('set -euo pipefail ')
GR="$(guard_first "$APPFILE" '^[[:space:]]*if[[:space:]].*CSB_SIGNING_DRY_RUN' "${APP_PRE[@]}")"; RC=$?
if [[ "$RC" -eq 0 ]]; then echo "ok: make-app refusal guard is the first executable construct"; else echo "make-app guard is not first: $GR"; fi
check "(e) static part one: make-app refusal guard is first" $RC
AGUARD_NO="$GR"
FR="$(guard_form "$APPFILE" "$AGUARD_NO" 'echo "make-app: refusing to build a real artifact with CSB_SIGNING_DRY_RUN set" >&2' \
  'if [ "${CSB_SIGNING_DRY_RUN:-}" = "1" ] ' 'if [ "${CSB_SIGNING_DRY_RUN-}" = "1" ] ')"; FRC=$?
if [[ "$FRC" -eq 0 ]]; then echo "ok: make-app refusal guard refuses: condition, stderr diagnostic, non-zero exit"; else echo "guard cannot refuse: $FR"; fi
check "(e) static part two: make-app refusal guard form refuses" $FRC

FDIR="$(mktemp -d)"
awk -v g="$AGUARD_NO" 'NR==g{print ": csb-fixture-silent-statement"} {print}' "$APPFILE" > "$FDIR/m1.sh"
M1OUT="$(guard_first "$FDIR/m1.sh" '^[[:space:]]*if[[:space:]].*CSB_SIGNING_DRY_RUN' "${APP_PRE[@]}")"; M1RC=$?
[[ "$M1RC" -ne 0 && "$M1OUT" == BAD:* ]]
check "fixture M1: silent statement above the guard breaks first-construct placement" $?

awk -v g="$AGUARD_NO" 'NR>=g && /^[[:space:]]*exit [0-9]+$/ {next} {print}' "$APPFILE" > "$FDIR/m2.sh"
M2OUT="$(guard_form "$FDIR/m2.sh" "$AGUARD_NO" 'echo "make-app: refusing to build a real artifact with CSB_SIGNING_DRY_RUN set" >&2' \
  'if [ "${CSB_SIGNING_DRY_RUN:-}" = "1" ] ' 'if [ "${CSB_SIGNING_DRY_RUN-}" = "1" ] ')"; M2RC=$?
[[ "$M2RC" -ne 0 && "$M2OUT" == "BADCOUNT" ]]
check "fixture M2: make-app guard exit removed is rejected as present-but-not-refusing" $?

sed -E "${AGUARD_NO}s/= \"1\" \]/!= \"1\" ]/" "$APPFILE" > "$FDIR/m3.sh"
M3OUT="$(guard_form "$FDIR/m3.sh" "$AGUARD_NO" 'echo "make-app: refusing to build a real artifact with CSB_SIGNING_DRY_RUN set" >&2' \
  'if [ "${CSB_SIGNING_DRY_RUN:-}" = "1" ] ' 'if [ "${CSB_SIGNING_DRY_RUN-}" = "1" ] ')"; M3RC=$?
[[ "$M3RC" -ne 0 && "$M3OUT" == BADCOND:* ]]
check "fixture M3: inverted guard condition is rejected" $?
rm -rf "$FDIR"

if [[ "$RC" -eq 0 && "$FRC" -eq 0 && "$IDENTITY_PRESENT" -eq 1 ]]; then
  # ff55736f: never touch the repository's own dist/ here -- launch a copy
  # of make-app.sh from a mktemp scaffold instead, since make-app.sh:20
  # cd's to its own parent and therefore resolves "dist" inside whichever
  # tree the copy lives in.
  SCAFFOLD="$(mktemp -d)"
  mkdir -p "$SCAFFOLD/scripts"
  cp "$APPFILE" "$SCAFFOLD/scripts/make-app.sh"
  START=$(date +%s)
  ( "${CLEAN[@]}" CSB_SIGNING_DRY_RUN=1 /bin/bash "$SCAFFOLD/scripts/make-app.sh" >/tmp/csb-e-out.$$ 2>&1 & PID=$!
    ( sleep 5; kill -TERM "$PID" 2>/dev/null; sleep 1; kill -KILL "$PID" 2>/dev/null ) & WPID=$!
    wait "$PID"; echo $? > /tmp/csb-e-rc.$$; kill "$WPID" 2>/dev/null )
  ELAPSED=$(( $(date +%s) - START ))
  E5OUT="$(cat /tmp/csb-e-out.$$)"; E5RC="$(cat /tmp/csb-e-rc.$$)"; rm -f /tmp/csb-e-out.$$ /tmp/csb-e-rc.$$
  if [[ "$ELAPSED" -ge 5 ]]; then
    echo "SAFETY CONTRADICTION: static analysis certified the guard as first and refusing, but the launch did not exit within the watchdog"
    check "(e) behavioural: make-app refuses under dry-run within the watchdog" 1
  else
    [[ "$E5RC" -ne 0 ]] && has "make-app: refusing to build a real artifact with CSB_SIGNING_DRY_RUN set" "$E5OUT" && ! has 'Compiling' "$E5OUT" && [[ ! -e "$SCAFFOLD/dist" ]]
    check "(e) behavioural (clean launch, watchdog): make-app refuses to build with CSB_SIGNING_DRY_RUN set" $?
  fi
  rm -rf "$SCAFFOLD"
elif [[ "$RC" -eq 0 && "$FRC" -eq 0 ]]; then
  echo "skipped: (e) behavioural half needs the signing identity present; static certification passed"
else
  echo "skipped: (e) behavioural half not launched -- static gate did not pass"
fi

# ---------------------------------------------------------------------
# Criteria 8 & 9 (ARCH-10 / SEC-3, static half): the codesign invocations.
# ---------------------------------------------------------------------
c89() {
  local set; set="$(grep -nE '^[[:space:]]*codesign([[:space:]]|$)' "$APPFILE")"
  local bad_deep=() bad_shape=() bad_ts=() bad_swallow=()
  while IFS= read -r l; do
    [[ -z "$l" ]] && continue
    local lno="${l%%:*}" txt="${l#*:}" n; n="$(norm <<<"$txt")"
    if [[ "$txt" == *'\' ]] || has '[@]}' "$n" || has '[*]}' "$n"; then bad_shape+=("$lno:$txt"); continue; fi
    if has ' --sign ' "$n"; then
      has ' --deep ' "$n" && bad_deep+=("$lno")
      ! has ' --timestamp ' "$n" && bad_ts+=("$lno")
      if has '--timestamp=none' "$n" || has '|| true' "$n" || has '|| :' "$n"; then
        bad_swallow+=("$lno:$txt")
      elif has '||' "$n"; then
        local after="${n#*||}"
        [[ "$after" =~ ^[[:space:]]*exit[[:space:]]+[1-9][0-9]*[[:space:]]*$ ]] || bad_swallow+=("$lno:$txt")
      fi
    elif ! has ' --verify ' "$n"; then
      bad_shape+=("$lno:$txt")
    fi
  done <<<"$set"
  local rc=0
  [[ "${#bad_shape[@]}" -gt 0 ]] && { echo "codesign invocation at $APPFILE:${bad_shape[0]%%:*} is not a plain single physical line: array/indirected args hide flags from every check here"; rc=1; }
  [[ "${#bad_deep[@]}" -gt 0 ]] && { echo "codesign signs with --deep at $APPFILE:${bad_deep[0]}: nested code must be signed inside-out, one explicit invocation each"; rc=1; }
  [[ "${#bad_ts[@]}" -gt 0 ]] && { echo "codesign signs without --timestamp at $APPFILE:${bad_ts[0]}: signature stops validating once the certificate expires"; rc=1; }
  [[ "${#bad_swallow[@]}" -gt 0 ]] && { echo "codesign timestamp failure is swallowed at $APPFILE:${bad_swallow[0]%%:*}: a ||-handler must end in an unconditional nonzero exit"; rc=1; }
  [[ "$rc" -eq 0 ]] && echo "ok: no codesign signing invocation carries --deep, all sign with --timestamp, no failure is swallowed"
  return $rc
}
OUT="$(c89)"; RC=$?; echo "$OUT"
check "criteria 8+9: codesign invocations sign inside-out, no --deep, --timestamp present and fatal" $RC

FDIR="$(mktemp -d)"; APPFILE_SAVE="$APPFILE"
sed -E 's/(codesign --force) (--options runtime --timestamp --sign "\$SIGNING_IDENTITY" "\$APP")/\1 --deep \2/' "$APPFILE_SAVE" > "$FDIR/d1.sh"
APPFILE="$FDIR/d1.sh"; FOUT="$(c89)"; FRC=$?; APPFILE="$APPFILE_SAVE"
[[ "$FRC" -ne 0 && "$FOUT" == *"signs with --deep"* ]]
check "fixture D1: re-adding --deep to the outer signing line is rejected" $?
sed -E 's/--timestamp --sign "\$SIGNING_IDENTITY" "\$APP"$/--timestamp=none --sign "\$SIGNING_IDENTITY" "\$APP"/' "$APPFILE_SAVE" > "$FDIR/e2.sh"
APPFILE="$FDIR/e2.sh"; FOUT="$(c89)"; FRC=$?; APPFILE="$APPFILE_SAVE"
[[ "$FRC" -ne 0 && "$FOUT" == *"without --timestamp"* ]]
check "fixture E2: --timestamp=none on the outer signing line is rejected" $?
sed -E 's/(--timestamp --sign "\$SIGNING_IDENTITY" "\$APP")$/\1 || true/' "$APPFILE_SAVE" > "$FDIR/e1.sh"
APPFILE="$FDIR/e1.sh"; FOUT="$(c89)"; FRC=$?; APPFILE="$APPFILE_SAVE"
[[ "$FRC" -ne 0 && "$FOUT" == *"timestamp failure is swallowed"* ]]
check "fixture E1: || true on the outer signing line is rejected as a swallowed failure" $?
rm -rf "$FDIR"

echo "---"
if [[ "$FAILURES" -eq 0 ]]; then echo "signing-argv-test: all checks passed"; else echo "signing-argv-test: $FAILURES check(s) failed"; fi
exit "$FAILURES"
