#!/bin/bash
# Calibration suite for lock.sh. Every case here is a KNOWN-BAD that must be seen to FAIL —
# the two from the 2026-08-12/13 incidents first, then the refusals added with them.
#
#   ./test-lock.sh          run all
#
# Runs against a throwaway AGENT_LOCK_DIR and a throwaway registry, so it never touches the
# real /tmp/claude-locks or the shipped aliases.conf.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
L="$HERE/lock.sh"
TMP=$(mktemp -d) || exit 2
trap 'rm -rf "$TMP"' EXIT
export AGENT_LOCK_DIR="$TMP/locks"
export AGENT_LOCK_ALIASES="$TMP/aliases.conf"

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check(){ # check <desc> <expected_rc> <actual_rc> [output]
  [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected rc=$2, got rc=$3${4:+ — $4}"; }
has()  { # has <desc> <needle> <haystack>
  case "$3" in *"$2"*) ok "$1";; *) bad "$1" "missing '$2' in: $3";; esac; }
hasnt(){ case "$3" in *"$2"*) bad "$1" "unexpected '$2' in: $3";; *) ok "$1";; esac; }

fresh() { # reset both the store and the registry
  rm -rf "$AGENT_LOCK_DIR"; mkdir -p "$AGENT_LOCK_DIR"
  cat > "$AGENT_LOCK_ALIASES" <<'EOF'
scope: mxo mxo4 mxo44
fugu-rig: rig powerloop
!dmm: ambiguous — this bench has two (dmm6500, hp3458a); name the one you mean
EOF
}

# Another session, simulated: pid 1 is launchd — always alive (so never "stale"), and never
# our own owner pid. This is what makes the two-sessions cases testable in one process.
seed_held_by_other() { # seed_held_by_other <canonical> [note]
  local lp="$AGENT_LOCK_DIR/$1.lock"
  mkdir -p "$lp"
  printf 'resource=%s\npid=1\nuser=other\nsince=2026-01-01 00:00:00\nnote=%s\n' \
    "$1" "${2:-held by a peer session}" > "$lp/info"
}

echo "== 1. THE INCIDENT: two names, one instrument =="
fresh
seed_held_by_other scope "stage-3 loaded ladder"
out=$("$L" acquire mxo4 "my capture run" 2>&1); rc=$?
check "acquiring mxo4 while scope is held FAILS" 1 "$rc" "$out"
has   "  ...and says which lock it resolved to" "lock 'scope'" "$out"
has   "  ...and shows the real holder's note" "stage-3 loaded ladder" "$out"
[ -d "$AGENT_LOCK_DIR/mxo4.lock" ] && bad "no private mxo4 mutex is created" || ok "no private mxo4 mutex is created"

echo "== 2. THE OTHER SHAPE: a typo grants nothing =="
fresh
out=$("$L" acquire scpoe "oops" 2>&1); rc=$?
check "a typo'd name is REFUSED" 2 "$rc" "$out"
has   "  ...and says how to register a real new resource" "--new" "$out"
[ -d "$AGENT_LOCK_DIR/scpoe.lock" ] && bad "no lock dir for a typo" || ok "no lock dir for a typo"

out=$("$L" acquire dmm "which one?" 2>&1); rc=$?
check "an ambiguous name is REFUSED" 2 "$rc" "$out"
has   "  ...with the reason from the registry" "name the one you mean" "$out"

echo "== 3. a genuinely new resource is registerable, once =="
fresh
out=$("$L" acquire newrig "first use" --new 2>&1); rc=$?
check "acquire --new succeeds" 0 "$rc" "$out"
has   "  ...and says it registered" "REGISTERED newrig" "$out"
"$L" release newrig >/dev/null 2>&1
out=$("$L" acquire newrig "second use" 2>&1); rc=$?
check "the second plain acquire needs no --new" 0 "$rc" "$out"

echo "== 4. THE INCIDENT: a note that could not be corrected =="
fresh
"$L" acquire scope "stage-3 loaded ladder 805->859" >/dev/null 2>&1
out=$("$L" note scope "ABANDONED — bench faulted, burning smell" 2>&1); rc=$?
check "note updates a lock we hold" 0 "$rc" "$out"
out=$("$L" list 2>&1)
has   "  ...and list shows the NEW text" "ABANDONED" "$out"
hasnt "  ...and no longer the old text" "805->859" "$out"

echo "== 5. re-acquire no longer discards a differing note =="
fresh
"$L" acquire scope "first note" >/dev/null 2>&1
out=$("$L" acquire scope "second note" 2>&1); rc=$?
check "re-acquire still succeeds (idempotent)" 0 "$rc" "$out"
has   "  ...and reports the update" "NOTE UPDATED" "$out"
has   "  ...and list carries it" "second note" "$("$L" list 2>&1)"

echo "== 6. note refuses on another session's lock =="
fresh
seed_held_by_other scope
out=$("$L" note scope "not mine to amend" 2>&1); rc=$?
check "amending a peer's lock FAILS without --force" 1 "$rc" "$out"

echo "== 7. THE WORST CASE: a warning that outlives the lock =="
fresh
"$L" acquire fugu-rig "ladder run" >/dev/null 2>&1
out=$("$L" flag fugu-rig "over-draw then burning smell — do not energise" 2>&1); rc=$?
check "flag succeeds" 0 "$rc" "$out"
out=$("$L" release fugu-rig 2>&1)
has   "release still warns the flag stands" "still FLAGGED" "$out"
out=$("$L" acquire fugu-rig "next session, unaware" 2>&1); rc=$?
check "acquiring a FLAGGED free resource FAILS" 1 "$rc" "$out"
has   "  ...and shows the reason" "do not energise" "$out"
out=$("$L" acquire fugu-rig "I know, deliberate" --ack 2>&1); rc=$?
check "--ack overrides for one acquire" 0 "$rc" "$out"
has   "  ...loudly" "WARNING" "$out"
"$L" release fugu-rig >/dev/null 2>&1
out=$("$L" unflag fugu-rig 2>&1); rc=$?
check "unflag clears it" 0 "$rc" "$out"
out=$("$L" acquire fugu-rig "now fine" 2>&1); rc=$?
check "acquire works again after unflag" 0 "$rc" "$out"

echo "== 8. a flag is keyed on the INSTRUMENT, not the name used =="
fresh
"$L" flag mxo44 "probe removed from the node" >/dev/null 2>&1
out=$("$L" acquire scope "unaware" 2>&1); rc=$?
check "flag raised on an alias blocks the canonical" 1 "$rc" "$out"
has   "  ...with the reason" "probe removed" "$out"

echo "== 9. fail-closed on an unreadable registry =="
fresh
chmod 000 "$AGENT_LOCK_ALIASES" 2>/dev/null
out=$("$L" acquire scope "x" 2>&1); rc=$?
chmod 644 "$AGENT_LOCK_ALIASES" 2>/dev/null
if [ "$(id -u)" = 0 ]; then
  echo "  skip unreadable-registry case (running as root)"
else
  check "an unreadable registry is an ERROR, not a free lock" 2 "$rc" "$out"
fi

echo "== 10. fail-closed on an unreadable flag =="
fresh
"$L" flag scope "reason" >/dev/null 2>&1
chmod 000 "$AGENT_LOCK_DIR/scope.flag" 2>/dev/null
out=$("$L" acquire scope "x" 2>&1); rc=$?
chmod 644 "$AGENT_LOCK_DIR/scope.flag" 2>/dev/null
if [ "$(id -u)" = 0 ]; then
  echo "  skip unreadable-flag case (running as root)"
else
  check "an unreadable flag REFUSES rather than proceeds" 2 "$rc" "$out"
fi

echo "== 11. regressions: the behaviour that already worked =="
fresh
out=$("$L" status scope 2>&1); rc=$?
check "status of a free resource is 0/FREE" 0 "$rc" "$out"
"$L" acquire scope "mine" >/dev/null 2>&1
out=$("$L" status mxo 2>&1); rc=$?
check "status via an alias sees the same lock" 1 "$rc" "$out"
out=$("$L" release scope 2>&1); rc=$?
check "release of our own lock succeeds" 0 "$rc" "$out"
out=$("$L" release scope 2>&1); rc=$?
check "release of a free resource is a no-op, not an error" 0 "$rc" "$out"
fresh
seed_held_by_other scope
out=$("$L" release scope 2>&1); rc=$?
check "release of a peer's lock FAILS without --force" 1 "$rc" "$out"
out=$("$L" release scope --force 2>&1); rc=$?
check "  ...and succeeds with it" 0 "$rc" "$out"
fresh
lp="$AGENT_LOCK_DIR/scope.lock"; mkdir -p "$lp"
printf 'resource=scope\npid=999999\nuser=ghost\nsince=x\nnote=dead\n' > "$lp/info"
out=$("$L" acquire scope "stealing" 2>&1); rc=$?
check "a lock held by a dead pid is stolen" 0 "$rc" "$out"

echo "== 12. ROLLOUT: a legacy lock under an alias must not be bypassed =="
# The alias map's own worst failure: a session that predates the map holds `mxo4.lock`, so a
# new session resolving mxo4->scope sees no scope.lock and opens a SECOND mutex beside it.
fresh
seed_held_by_other mxo4 "legacy session, predates the alias map"
out=$("$L" acquire scope "unaware" 2>&1); rc=$?
check "acquire REFUSES while a legacy alias lock exists" 2 "$rc" "$out"
has   "  ...and names the legacy lock" "mxo4" "$out"
[ -d "$AGENT_LOCK_DIR/scope.lock" ] && bad "no second mutex is opened" || ok "no second mutex is opened"
out=$("$L" status mxo4 2>&1); rc=$?
check "  ...and the legacy lock is still inspectable" 1 "$rc" "$out"

echo "== 13. a quoted NOTE must never act as a safety override =="
fresh
"$L" flag fugu-rig "burning smell" >/dev/null 2>&1
out=$("$L" acquire fugu-rig "--ack" 2>&1); rc=$?
check "acquire <name> \"--ack\" does NOT bypass the flag" 1 "$rc" "$out"
out=$("$L" acquire scpoe "--new" 2>&1); rc=$?
check "acquire <name> \"--new\" does NOT register a typo" 2 "$rc" "$out"
out=$("$L" acquire fugu-rig "real note" --ack 2>&1); rc=$?
check "  ...while a real 4th-arg --ack still works" 0 "$rc" "$out"

echo "== 14. a ban with no reason text is still a ban =="
fresh
printf '!foo:\n' >> "$AGENT_LOCK_ALIASES"
out=$("$L" acquire foo "x" --new 2>&1); rc=$?
check "an empty ban reason does not fall through to --new" 2 "$rc" "$out"
[ -d "$AGENT_LOCK_DIR/foo.lock" ] && bad "no lock for a banned name" || ok "no lock for a banned name"

echo "== 15. a registry cannot point the store outside itself =="
fresh
printf '../../../tmp/pwned: scope2\n' >> "$AGENT_LOCK_ALIASES"
out=$("$L" acquire scope2 "x" 2>&1); rc=$?
check "a traversing canonical is REFUSED" 2 "$rc" "$out"
[ -e /tmp/pwned.lock ] && bad "nothing created outside the store" || ok "nothing created outside the store"

echo "== 16. alias fields are not glob-expanded =="
fresh
printf 'globrig: *\n' >> "$AGENT_LOCK_ALIASES"
mkdir -p "$TMP/cwd" && : > "$TMP/cwd/scope"
out=$(cd "$TMP/cwd" && "$L" resolve totally-unrelated 2>&1); rc=$?
check "a '*' alias does not match via the caller's cwd" 2 "$rc" "$out"

echo "== 17. an ambiguous or malformed registry refuses, it does not guess =="
fresh
printf 'otherscope: mxo4\n' >> "$AGENT_LOCK_ALIASES"
out=$("$L" acquire mxo4 "x" 2>&1); rc=$?
check "a name under two canonicals is REFUSED" 2 "$rc" "$out"
has   "  ...and says it is ambiguous" "ambiguous" "$out"
fresh
printf 'this line has no colon\n' >> "$AGENT_LOCK_ALIASES"
out=$("$L" acquire scope "x" 2>&1); rc=$?
check "a malformed registry line is REFUSED, not skipped" 2 "$rc" "$out"

echo "== 18. a note rewrite may not destroy ownership =="
fresh
"$L" acquire scope "mine" >/dev/null 2>&1
printf 'garbage with no keys\n' > "$AGENT_LOCK_DIR/scope.lock/info"
out=$("$L" note scope "new text" 2>&1); rc=$?
check "an info with no pid= reads as not-ours, so note REFUSES" 1 "$rc" "$out"
out=$("$L" note scope "new text" --force 2>&1); rc=$?
check "  ...and even --force will not rewrite it into an ownerless lock" 2 "$rc" "$out"
has   "  ...and the lock is left intact" "garbage" "$(cat "$AGENT_LOCK_DIR/scope.lock/info")"

echo "== 19. a non-directory at the lock path is not 'free' =="
fresh
: > "$AGENT_LOCK_DIR/scope.lock"
out=$("$L" status scope 2>&1); rc=$?
check "status of an occupied-but-not-a-lock path is an ERROR" 2 "$rc" "$out"
hasnt "  ...and never says FREE" "FREE" "$out"

echo "== 20. a ps that cannot answer must not condemn a live holder =="
# `! ps -p $pid` read every nonzero ps result as proof of death. The verdict deletes a lock,
# so a ps that cannot run handed two sessions the same instrument.
fresh
seed_held_by_other scope "a live peer session"
mkdir -p "$TMP/badbin"
printf '#!/bin/sh\nexit 3\n' > "$TMP/badbin/ps"        # ps exists but always fails
chmod +x "$TMP/badbin/ps"
out=$(PATH="$TMP/badbin:$PATH" "$L" acquire scope "steal it?" 2>&1); rc=$?
check "a broken ps does NOT steal the lock" 1 "$rc" "$out"
has   "  ...and says why it could not verify" "assuming ALIVE" "$out"
[ -d "$AGENT_LOCK_DIR/scope.lock" ] || bad "the peer's lock still exists" "it was deleted"
[ -d "$AGENT_LOCK_DIR/scope.lock" ] && ok "the peer's lock still exists"

printf '#!/bin/sh\nexit 0\n' > "$TMP/badbin/ps"        # ps "succeeds" but names nothing
out=$(PATH="$TMP/badbin:$PATH" "$L" acquire scope "steal it?" 2>&1); rc=$?
check "a ps that succeeds but names nothing does NOT steal either" 1 "$rc" "$out"

echo "== 21. the control must not block a GENUINE steal =="
fresh
lp="$AGENT_LOCK_DIR/scope.lock"; mkdir -p "$lp"
printf 'resource=scope\npid=999999\nuser=ghost\nsince=x\nnote=dead\n' > "$lp/info"
out=$("$L" acquire scope "stealing a real corpse" 2>&1); rc=$?
check "a provably dead holder is still stolen with ps working" 0 "$rc" "$out"

echo
echo "passed $pass, failed $fail"
[ "$fail" = 0 ] || exit 1
