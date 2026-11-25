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
# A session inherited from the caller's environment would silently change every case below.
unset AGENT_LOCK_SESSION AGENT_LOCK_OWNER_PID CLAUDE_CODE_SESSION_ID PI_SESSION_ID CODEX_SESSION_ID PASEO_AGENT_ID

pass=0; fail=0
ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }
check(){ # check <desc> <expected_rc> <actual_rc> [output]
  [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected rc=$2, got rc=$3${4:+ — $4}"; }
has()  { # has <desc> <needle> <haystack>
  case "$3" in *"$2"*) ok "$1";; *) bad "$1" "missing '$2' in: $3";; esac; }
hasnt(){ case "$3" in *"$2"*) bad "$1" "unexpected '$2' in: $3";; *) ok "$1";; esac; }

# --- portability (the suite also runs on Linux, e.g. hdd) ----------------------------
# The three macOS-only forms this suite used are wrapped here, so they work on both:
#   [macOS-only] `sed -i ''`      -> sed_i (write to a temp file, then mv)
#   [macOS-only] `date -v-3H`     -> hours_ago_stamp (BSD date -v, else GNU date -d)
#   [macOS-only] `/usr/bin/true`  -> plain `true` via /bin/sh
sed_i() { sed "$1" "$2" > "$2.sedi" && mv -f "$2.sedi" "$2"; }   # sed_i '<script>' <file>
hours_ago_stamp() { date -v-"$1"H '+%Y%m%d%H%M' 2>/dev/null || date -d "$1 hours ago" '+%Y%m%d%H%M'; }
now_ms() { perl -MTime::HiRes=time -e 'printf "%d", time*1000' 2>/dev/null || echo $(( $(date +%s) * 1000 )); }

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
# Since 2026-10-06 a flag-shaped note is refused outright (rc 2) before the flag is even
# consulted; what matters is that it is refused and no lock exists.
check "acquire <name> \"--ack\" does NOT bypass the flag" 2 "$rc" "$out"
[ -d "$AGENT_LOCK_DIR/fugu-rig.lock" ] && bad "  ...and took no lock" || ok "  ...and took no lock"
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

echo "== 22. --brief shortens the flag WITHOUT weakening the refusal =="
fresh
# Must be comfortably longer than show_flag's 110-char cut, with a marker PAST it: the
# first version was 109 chars, so nothing was truncated and the test passed vacuously.
LONG="BURNT SMELL do not energise. $(printf 'padding %.0s' $(seq 1 40))TAILMARKER"
"$L" flag scope "$LONG" >/dev/null 2>&1
out=$("$L" status scope 2>&1); rc=$?
case "$out" in *TAILMARKER*) ok "plain status prints the whole reason" ;;
              *) bad "plain status prints the whole reason" ;; esac
out=$("$L" status scope --brief 2>&1); rc=$?
case "$out" in *TAILMARKER*) bad "--brief truncates the reason" ;;
              *) ok "--brief truncates the reason" ;; esac
case "$out" in *full\ text:*) ok "--brief still points at the full flag file" ;;
              *) bad "--brief still points at the full flag file" ;; esac
check "--brief does not change the status exit code" 1 "$rc" "$out"

# The refusal is the whole point of a flag: it must never be summarised, by any argument.
out=$("$L" acquire scope "note" --brief 2>&1); rc=$?
check "acquiring a FLAGGED resource still FAILS with --brief" 1 "$rc" "$out"
case "$out" in *TAILMARKER*) ok "the REFUSAL still prints the flag in full despite --brief" ;;
              *) bad "the REFUSAL still prints the flag in full despite --brief" ;; esac
# --brief must not smuggle in an --ack.
case "$out" in *"acquire refused"*) ok "--brief does not imply --ack" ;;
              *) bad "--brief does not imply --ack" ;; esac
"$L" unflag scope >/dev/null 2>&1

echo "== 23. idle is REPORTED and never acted on =="
fresh
lp="$AGENT_LOCK_DIR/scope.lock"; mkdir -p "$lp"
printf 'resource=scope\npid=1\nuser=peer\nsince=x\nnote=peer holds this\n' > "$lp/info"
out=$("$L" status scope 2>&1)
case "$out" in *idle*) bad "a fresh lock is NOT labelled idle" ;;
              *) ok "a fresh lock is NOT labelled idle" ;; esac
touch -t "$(hours_ago_stamp 3)" "$lp/info"
out=$("$L" status scope 2>&1)
case "$out" in *"idle 3h"*) ok "a 3-hour-quiet lock reports idle" ;;
              *) bad "a 3-hour-quiet lock reports idle (got: $out)" ;; esac
out=$("$L" acquire scope "mine" 2>&1); rc=$?
check "an IDLE lock held by a live pid is still NOT stealable" 1 "$rc" "$out"
case "$out" in *idle*) ok "the BUSY path shows idle, where you need it" ;;
              *) bad "the BUSY path shows idle, where you need it" ;; esac
# A missing/unreadable info file must not abort the status under set -u.
rm -f "$lp/info"
out=$("$L" status scope 2>&1); rc=$?
check "status survives a lock with no info file" 1 "$rc" "$out"

echo "== 24. park: the holder hands a lock over; nothing else may take it =="
fresh
# A lock we hold ourselves: park is a declaration by the holder, so we must be it.
out=$("$L" acquire scope "flashing" 2>&1); rc=$?
check "acquire for the park tests" 0 "$rc" "$out"
out=$("$L" park scope "done with the board, waiting on Fab for the antenna" 2>&1); rc=$?
check "the holder may park its own lock" 0 "$rc" "$out"
out=$("$L" status scope 2>&1)
case "$out" in *PARKED*) ok "status says PARKED, so nobody waits for nothing" ;;
              *) bad "status says PARKED (got: $out)" ;; esac
case "$("$L" list 2>&1)" in *"[parked]"*) ok "list marks it parked" ;;
              *) bad "list marks it parked" ;; esac
# The handover: the reason and the outgoing note must reach the taker, because the
# hardware's physical state lives in them.
lp="$AGENT_LOCK_DIR/scope.lock"
sed_i 's/^pid=.*/pid=1/' "$lp/info"
out=$("$L" acquire scope "taking over" 2>&1); rc=$?
check "a PARKED lock held by a LIVE pid IS takeable" 0 "$rc" "$out"
case "$out" in *"waiting on Fab for the antenna"*) ok "the taker is told why it was parked" ;;
              *) bad "the taker is told why it was parked (got: $out)" ;; esac
case "$out" in *"flashing"*) ok "the taker is told the outgoing note (hardware state)" ;;
              *) bad "the taker is told the outgoing note (got: $out)" ;; esac
# KNOWN-BAD CALIBRATION: the same lock, live pid, NOT parked, must stay untakeable.
# If this passes, park has quietly become a timeout and the whole steal policy is gone.
fresh
lp="$AGENT_LOCK_DIR/scope.lock"; mkdir -p "$lp"
printf 'resource=scope\npid=1\nuser=peer\nsince=x\nnote=peer is using it\n' > "$lp/info"
out=$("$L" acquire scope "mine" 2>&1); rc=$?
check "an UNPARKED lock held by a live pid is still NOT takeable" 1 "$rc" "$out"
# Parking someone else's lock would be a seizure by proxy.
out=$("$L" park scope "not mine to park" 2>&1); rc=$?
check "parking a lock we do NOT hold is REFUSED" 1 "$rc" "$out"
out=$("$L" acquire scope "mine" 2>&1); rc=$?
check "...and the refused park did not make it takeable" 1 "$rc" "$out"
# park needs a reason: an empty one would hand over the board with no state description.
fresh
"$L" acquire scope "held" >/dev/null 2>&1
out=$("$L" park scope "" 2>&1); rc=$?
check "park with no reason is REFUSED" 2 "$rc" "$out"
out=$("$L" unpark scope 2>&1); rc=$?
check "unpark on an unparked lock is harmless" 0 "$rc" "$out"
"$L" park scope "parked" >/dev/null 2>&1
out=$("$L" unpark scope 2>&1); rc=$?
check "unpark cancels the handover" 0 "$rc" "$out"
sed_i 's/^pid=.*/pid=1/' "$AGENT_LOCK_DIR/scope.lock/info"
out=$("$L" acquire scope "mine" 2>&1); rc=$?
check "...and an unparked lock is NOT takeable again" 1 "$rc" "$out"

echo "== 25. run: acquire, work, ALWAYS release =="
fresh
out=$("$L" run scope "working" -- /bin/echo hello 2>&1); rc=$?
check "run returns the command's success" 0 "$rc" "$out"
case "$out" in *hello*) ok "the command actually ran" ;; *) bad "the command actually ran" ;; esac
out=$("$L" status scope 2>&1); rc=$?
check "the lock came back after a normal exit" 0 "$rc" "$out"
# The whole point: the status must be the COMMAND's. The old documented pattern was to
# background `wait`, whose launch returns 0 regardless, so an agent read 0 and touched the
# hardware without the lock.
"$L" run scope "working" -- /bin/sh -c 'exit 42' >/dev/null 2>&1; rc=$?
check "run propagates the command's exit status, not its own" 42 "$rc" ""
out=$("$L" status scope 2>&1); rc=$?
check "the lock came back after a FAILING command" 0 "$rc" "$out"
"$L" run scope "working" -- /bin/sh -c 'kill -9 $$' >/dev/null 2>&1
out=$("$L" status scope 2>&1); rc=$?
check "the lock came back after the command was KILLED" 0 "$rc" "$out"
# KNOWN-BAD CALIBRATION: if the lock is never acquired the command must NOT run. A wrapper
# that runs the work anyway is worse than no wrapper, because it looks like serialisation.
fresh
lp="$AGENT_LOCK_DIR/scope.lock"; mkdir -p "$lp"
printf 'resource=scope\npid=1\nuser=peer\nsince=x\nnote=peer is using it\n' > "$lp/info"
out=$("$L" run scope "mine" --timeout 4 -- /bin/echo SHOULD_NOT_RUN 2>&1); rc=$?
check "run REFUSES when the lock never comes free" 2 "$rc" "$out"
case "$out" in *SHOULD_NOT_RUN*) bad "the command must NOT run without the lock" ;;
              *) ok "the command must NOT run without the lock" ;; esac
# ...and it must not have stolen the peer's lock on the way out.
out=$("$L" status scope 2>&1); rc=$?
check "the peer still holds it afterwards" 1 "$rc" "$out"

echo "== 26. top: live monitor executes cleanly in one-shot mode =="
out=$("$L" top --once 2>&1); rc=$?
check "top --once succeeds" 0 "$rc" "$out"
has   "  ...and displays the held resource" "scope" "$out"
has   "  ...and displays the holder note" "peer is using it" "$out"
out=$("$L" top --once --compact 2>&1); rc=$?
check "top --once --compact succeeds" 0 "$rc" "$out"
has   "  ...and displays the held resource in compact mode" "scope" "$out"

# session reporting: acquire with --session records session and top displays it
fresh
"$L" acquire scope "testing session" --session "sess-alpha" >/dev/null 2>&1
has   "acquire --session writes session to info" "session=sess-alpha" "$(cat "$AGENT_LOCK_DIR/scope.lock/info")"
out=$("$L" top --once --compact 2>&1)
has   "top displays session in holder" "sess-alpha" "$out"
"$L" release scope >/dev/null 2>&1

echo
echo "== 27. mine: HELD is not the question, held BY US is =="
# The 2026-09-15 known-bad. A yield-mode daemon branched on `status` saying HELD -- which is
# equally true when a PEER holds it -- and flashed esp32s3-1588 out from under another
# session's BLE measurement. `mine` must answer with an exit status, and must say NO here.
rm -rf "$AGENT_LOCK_DIR"/scope.lock
seed_held_by_other scope "a live peer session"
out=$("$L" mine scope 2>&1); rc=$?
check "mine REFUSES a lock held by a peer" 1 "$rc" "$out"
out=$("$L" status scope 2>&1)
case "$out" in HELD*) ok "  ...while status still says HELD, which is the trap" ;;
               *) bad "  ...status no longer says HELD" "$out" ;; esac
rm -rf "$AGENT_LOCK_DIR"/scope.lock
out=$("$L" mine scope 2>&1); rc=$?
check "mine REFUSES a lock nobody holds" 1 "$rc" "$out"
"$L" acquire scope "ours" >/dev/null 2>&1
out=$("$L" mine scope 2>&1); rc=$?
check "mine ACCEPTS a lock we actually hold" 0 "$rc" "$out"
out=$("$L" mine scope --quiet 2>&1); rc=$?
check "mine --quiet stays silent and still answers 0" 0 "$rc" "$out"
[ -z "$out" ] && ok "  ...and printed nothing" || bad "  ...--quiet printed something" "$out"

echo "== 28. want/wanted: asking for a board without taking it =="
out=$("$L" wanted scope 2>&1); rc=$?
check "wanted is 1 when nobody asked" 1 "$rc" "$out"
"$L" want scope "another session needs the bench" >/dev/null 2>&1
out=$("$L" wanted scope 2>&1); rc=$?
check "wanted is 0 once somebody asked" 0 "$rc" "$out"
case "$out" in *"needs the bench"*) ok "  ...and carries the requester's note" ;;
               *) bad "  ...lost the note" "$out" ;; esac
[ -d "$AGENT_LOCK_DIR/scope.lock" ] && ok "want did NOT take the lock" || bad "want took the lock"
"$L" release scope >/dev/null 2>&1
out=$("$L" wanted scope 2>&1); rc=$?
check "release clears the request, so the handover is not served twice" 1 "$rc" "$out"

echo "== 29. AGENT_LOCK_OWNER_PID: a detached daemon can own its own lock =="
# The 2026-09-15 known-bad. nohup reparents a daemon to launchd, so the ancestry walk in
# owner_pid finds no agent and returns "unknown" -- and every ownership test then fails
# closed against a lock the daemon really holds. Two 9-hour soaks each stopped ~60 s in,
# logging "lost the lock to another session" about locks they held, then spun unable to
# re-acquire. A long-lived holder must be able to name itself.
rm -rf "$AGENT_LOCK_DIR"/scope.lock
( AGENT_LOCK_OWNER_PID=$$ "$L" acquire scope "detached" >/dev/null 2>&1 )
hp=$(sed -n 's/^pid=//p' "$AGENT_LOCK_DIR/scope.lock/info" 2>/dev/null)
AGENT_LOCK_OWNER_PID=$hp "$L" mine scope --quiet; rc=$?
check "mine ACCEPTS when the holder names itself via AGENT_LOCK_OWNER_PID" 0 "$rc" ""
out=$(env -u AGENT_LOCK_OWNER_PID "$L" mine scope 2>&1); rc=$?
check "  ...and still fails closed without it (the old, broken reading)" 1 "$rc" "$out"
# a dead pid must never read as ours, or the override becomes a way to steal any lock
dead=99999; while kill -0 $dead 2>/dev/null; do dead=$((dead+1)); done
out=$(AGENT_LOCK_OWNER_PID=$dead "$L" mine scope 2>&1); rc=$?
check "  ...and a DEAD override pid is refused, not honoured" 1 "$rc" "$out"
rm -rf "$AGENT_LOCK_DIR"/scope.lock

# ---------------------------------------------------------------------------------------
# 30-40: holder identity is (pid, session). The 2026-10-06 known-bad: two Claude Code
# sub-agents of ONE parent session share the parent's claude pid, so a FIL agent's `wait
# fab-chrome` returned "already held by this session" about its AIN sibling's lock,
# overwrote the sibling's note, and both drove Fab's real Chrome at once.
# Siblings are simulated by pinning the owner pid to this (live) test shell for every call.
S() { AGENT_LOCK_OWNER_PID=$$ "$L" "$@"; }
info() { cat "$AGENT_LOCK_DIR/$1.lock/info" 2>/dev/null; }

echo "== 30. THE INCIDENT: two sessions under one pid exclude each other =="
fresh
out=$(S acquire scope "AIN research" --session ain-1 2>&1); rc=$?
check "session A acquires" 0 "$rc" "$out"
has   "  ...and the lock records sid=" "sid=ain-1" "$(info scope)"
out=$(S acquire scope "FIL research" --session fil-1 2>&1); rc=$?
check "sibling session B under the SAME pid is BUSY, not 'already held'" 1 "$rc" "$out"
hasnt "  ...never says 'already held by this session'" "already held" "$out"
has   "  ...and explains it is a sibling" "DIFFERENT session" "$out"
has   "  ...and A's note is NOT overwritten" "note=AIN research" "$(info scope)"
out=$(AGENT_LOCK_SESSION=fil-1 S acquire scope "FIL via env" 2>&1); rc=$?
check "the same via \$AGENT_LOCK_SESSION is BUSY too" 1 "$rc" "$out"
out=$(S acquire scope "no session at all" 2>&1); rc=$?
check "a session-LESS caller under the same pid is BUSY (either side has a session)" 1 "$rc" "$out"
has   "  ...and A's note still stands" "note=AIN research" "$(info scope)"
out=$(S wait scope "FIL research" 3 --session fil-1 2>&1); rc=$?
check "wait by the sibling BLOCKS and times out instead of returning 'held'" 1 "$rc" "$out"
has   "  ...with TIMEOUT" "TIMEOUT" "$out"
out=$(S wait scope "FIL research" --timeout 2 --session=fil-1 2>&1); rc=$?
check "wait <name> <note> --timeout --session= form parses (old parser ate --session as timeout)" 1 "$rc" "$out"
has   "  ...note still A's after both waits" "note=AIN research" "$(info scope)"
# reverse direction: a session-less holder vs a session caller
fresh
S acquire scope "parent, no session" >/dev/null 2>&1
out=$(S acquire scope "child" --session sa-x 2>&1); rc=$?
check "a session caller cannot take a session-LESS holder's lock under the same pid" 1 "$rc" "$out"

echo "== 31. same-session re-acquire is idempotent and updates the note =="
fresh
S acquire scope "first" --session ain-1 >/dev/null 2>&1
out=$(S acquire scope "second" --session ain-1 2>&1); rc=$?
check "same (pid, session) re-acquire succeeds" 0 "$rc" "$out"
has   "  ...reports already-held" "already held by this session" "$out"
has   "  ...and updates the note" "note=second" "$(info scope)"
out=$(AGENT_LOCK_SESSION=ain-1 S acquire scope "third" 2>&1); rc=$?
check "  ...also when the session comes from \$AGENT_LOCK_SESSION" 0 "$rc" "$out"
out=$(AGENT_LOCK_SESSION=other S acquire scope "fourth" --session ain-1 2>&1); rc=$?
check "  ...and --session beats \$AGENT_LOCK_SESSION" 0 "$rc" "$out"

echo "== 32. release by the wrong session is refused =="
fresh
S acquire scope "A" --session ain-1 >/dev/null 2>&1
out=$(S release scope --session fil-1 2>&1); rc=$?
check "release by a sibling session is REFUSED" 1 "$rc" "$out"
[ -d "$AGENT_LOCK_DIR/scope.lock" ] && ok "  ...and the lock survives" || bad "  ...the lock was deleted"
out=$(S release scope 2>&1); rc=$?
check "release with NO session is refused too" 1 "$rc" "$out"
out=$(S release scope --session ain-1 2>&1); rc=$?
check "release by the owning session succeeds" 0 "$rc" "$out"
S acquire scope "A" --session ain-1 >/dev/null 2>&1
out=$(S release scope --force --session fil-1 2>&1); rc=$?
check "  ...and --force still breaks it (user-authorised path)" 0 "$rc" "$out"

echo "== 33. mine / note / park / unpark use the same identity =="
fresh
S acquire scope "A" --session ain-1 >/dev/null 2>&1
out=$(S mine scope --session ain-1 2>&1); rc=$?
check "mine is TRUE for the owner" 0 "$rc" "$out"
out=$(S mine scope --quiet --session fil-1 2>&1); rc=$?
check "mine is FALSE for a sibling under the same pid" 1 "$rc" "$out"
out=$(S mine scope 2>&1); rc=$?
check "mine is FALSE for a session-less caller under the same pid" 1 "$rc" "$out"
out=$(S note scope "hijack" --session fil-1 2>&1); rc=$?
check "note by a sibling is REFUSED" 1 "$rc" "$out"
out=$(S note scope "corrected" --session ain-1 2>&1); rc=$?
check "note by the owner works" 0 "$rc" "$out"
out=$(S park scope "not mine" --session fil-1 2>&1); rc=$?
check "park by a sibling is REFUSED" 1 "$rc" "$out"
hasnt "  ...and did not park it" "parked" "$(ls "$AGENT_LOCK_DIR/scope.lock")"
out=$(S park scope "AIN done, Chrome tab left on AIN page" --session ain-1 2>&1); rc=$?
check "park by the owner works (a finished sub-agent hands over)" 0 "$rc" "$out"
out=$(S unpark scope --session fil-1 2>&1); rc=$?
check "unpark by a sibling is REFUSED" 1 "$rc" "$out"
out=$(S acquire scope "FIL research" --session fil-1 2>&1); rc=$?
check "the sibling can now TAKE the parked lock" 0 "$rc" "$out"
has   "  ...and is told the park reason" "AIN done" "$out"
has   "  ...and the lock is now the sibling's" "sid=fil-1" "$(info scope)"
out=$(S status scope 2>&1); rc=$?
has   "status shows the holder's session" "session fil-1" "$out"

echo "== 34. run --session releases on every exit path =="
fresh
out=$(S run scope "work" --session ain-1 -- "$L" mine scope --session ain-1 2>&1); rc=$?
check "inside run, the lock is mine under the run's session" 0 "$rc" "$out"
out=$(S status scope 2>&1); rc=$?
check "  ...and it came back after a normal exit" 0 "$rc" "$out"
S run scope "work" --session ain-1 -- /bin/sh -c 'exit 42' >/dev/null 2>&1; rc=$?
check "run --session propagates the command's status" 42 "$rc" ""
out=$(S status scope 2>&1); rc=$?
check "  ...and released after a FAILING command" 0 "$rc" "$out"
S run scope "work" --session ain-1 -- /bin/sh -c 'kill -9 $$' >/dev/null 2>&1
out=$(S status scope 2>&1); rc=$?
check "  ...and released after the command was KILLED" 0 "$rc" "$out"
AGENT_LOCK_OWNER_PID=$$ "$L" run scope "work" --session ain-1 -- /bin/sh -c 'sleep 2' >/dev/null 2>&1 &
rpid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -d "$AGENT_LOCK_DIR/scope.lock" ] && break; sleep 0.2; done
kill -TERM "$rpid" 2>/dev/null; wait "$rpid"; rc=$?
check "  ...run itself SIGTERMed exits 143" 143 "$rc" ""
out=$(S status scope 2>&1); rc=$?
check "  ...and released after run was SIGTERMed" 0 "$rc" "$out"
AGENT_LOCK_SESSION=ain-1 S run scope "work" -- /bin/true >/dev/null 2>&1
out=$(S status scope 2>&1); rc=$?
check "  ...and released when the session came from \$AGENT_LOCK_SESSION" 0 "$rc" "$out"
# KNOWN-BAD: a run by the sibling must neither start its command nor touch the holder's lock
S acquire scope "AIN holds" --session ain-1 >/dev/null 2>&1
out=$(S run scope "FIL" --session fil-1 --timeout 3 -- /bin/echo SHOULD_NOT_RUN 2>&1); rc=$?
check "run by a sibling session REFUSES" 2 "$rc" "$out"
hasnt "  ...and its command did not run" "SHOULD_NOT_RUN" "$out"
has   "  ...and the holder's lock is intact" "note=AIN holds" "$(info scope)"

echo "== 35. no session anywhere: behaviour unchanged =="
fresh
out=$(S acquire scope "plain") ; rc=$?
check "session-less acquire" 0 "$rc" "$out"
has   "  ...records an EMPTY sid" "sid=
" "$(info scope)
"
out=$(S acquire scope "plain 2" 2>&1); rc=$?
check "session-less re-acquire under the same pid is idempotent (as before)" 0 "$rc" "$out"
out=$(S mine scope 2>&1); rc=$?
check "session-less mine is true (as before)" 0 "$rc" "$out"
out=$(S release scope 2>&1); rc=$?
check "session-less release works (as before)" 0 "$rc" "$out"
# A lock written by the OLD lock.sh has no sid= line at all.
mkdir -p "$AGENT_LOCK_DIR/scope.lock"
printf 'resource=scope\npid=%s\nuser=x\nsession=label-only\nsince=x\nnote=legacy\n' "$$" \
  > "$AGENT_LOCK_DIR/scope.lock/info"
out=$(S mine scope 2>&1); rc=$?
check "a legacy lock (no sid=) is ours to a session-less caller" 0 "$rc" "$out"
out=$(S mine scope --session sa-x 2>&1); rc=$?
check "  ...and NOT ours to a session caller (session= label is not identity)" 1 "$rc" "$out"

echo "== 36. crash recovery is unchanged =="
fresh
dead=99999; while kill -0 $dead 2>/dev/null; do dead=$((dead+1)); done
lp="$AGENT_LOCK_DIR/scope.lock"; mkdir -p "$lp"
printf 'resource=scope\npid=%s\nsid=ain-1\nuser=ghost\nsince=x\nnote=dead\n' "$dead" > "$lp/info"
out=$(S acquire scope "steal" --session fil-1 2>&1); rc=$?
check "a dead-pid lock is stolen by a different session" 0 "$rc" "$out"
has   "  ...and is now ours" "sid=fil-1" "$(info scope)"
fresh
mkdir -p "$lp"; printf 'resource=scope\npid=%s\nuser=ghost\nsince=x\nnote=dead\n' "$dead" > "$lp/info"
out=$(S acquire scope "steal" 2>&1); rc=$?
check "a dead-pid lock is stolen session-less (as before)" 0 "$rc" "$out"

echo "== 37. a flagged resource still refuses, session or not =="
fresh
"$L" flag scope "probe shorted — do not use" >/dev/null 2>&1
out=$(S acquire scope "x" --session ain-1 2>&1); rc=$?
check "acquire --session on a FLAGGED resource FAILS" 1 "$rc" "$out"
out=$(S wait scope "x" 30 --session ain-1 2>&1); rc=$?
check "wait --session on a FLAGGED resource gives up at once" 1 "$rc" "$out"
has   "  ...saying why" "FLAGGED" "$out"
out=$(S run scope "x" --session ain-1 --timeout 5 -- /bin/echo SHOULD_NOT_RUN 2>&1); rc=$?
check "run --session on a FLAGGED resource refuses" 2 "$rc" "$out"
hasnt "  ...without running the command" "SHOULD_NOT_RUN" "$out"
"$L" unflag scope >/dev/null 2>&1

echo "== 38. newsession, and a session that is not really given is an error =="
s1=$("$L" newsession fil); rc=$?
check "newsession succeeds" 0 "$rc" "$s1"
case "$s1" in fil-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f])
  ok "  ...prints label-<10 hex>" ;; *) bad "  ...prints label-<10 hex>" "$s1" ;; esac
s2=$("$L" newsession fil)
[ "$s1" != "$s2" ] && ok "  ...and two calls differ" || bad "  ...and two calls differ" "$s1 = $s2"
s3=$("$L" newsession); case "$s3" in sa-*) ok "  ...default label sa-" ;; *) bad "  ...default label sa-" "$s3";; esac
out=$("$L" newsession 'bad label' 2>&1); rc=$?
check "  ...a bad label is refused" 2 "$rc" "$out"
fresh
out=$(S acquire scope "x" --session "" 2>&1); rc=$?
check "--session \"\" (an unset variable) is an ERROR, not 'no session'" 2 "$rc" "$out"
[ -d "$AGENT_LOCK_DIR/scope.lock" ] && bad "  ...and no lock was taken" || ok "  ...and no lock was taken"
out=$(AGENT_LOCK_SESSION= S acquire scope "x" 2>&1); rc=$?
check "an EMPTY \$AGENT_LOCK_SESSION is an ERROR too" 2 "$rc" "$out"
S acquire scope "A" --session ain-1 >/dev/null 2>&1
out=$(S release scope --sesion ain-1 2>&1); rc=$?
check "a misspelt option is an ERROR, never silently ignored" 2 "$rc" "$out"
[ -d "$AGENT_LOCK_DIR/scope.lock" ] && ok "  ...and the lock survives" || bad "  ...the lock was deleted"
out=$(S release scope --session 2>&1); rc=$?
check "--session with no value is an ERROR" 2 "$rc" "$out"

echo "== 39. want / wanted carry the requester's session =="
fresh
S acquire scope "AIN" --session ain-1 >/dev/null 2>&1
out=$(S want scope "FIL needs Chrome" --session fil-1 2>&1); rc=$?
check "a sibling can ask for the lock" 0 "$rc" "$out"
has   "  ...and the request names its session" "session=fil-1" "$(cat "$AGENT_LOCK_DIR/scope.want")"
out=$(S wanted scope --session ain-1 2>&1); rc=$?
check "the holder sees the sibling's request" 0 "$rc" "$out"
out=$(S wanted scope --quiet --session fil-1 2>&1); rc=$?
check "the requester's own request does not read as 'wanted' to itself" 1 "$rc" "$out"
out=$(S wanted scope 2>&1); rc=$?
check "session-less wanted behaves as before (any request counts)" 0 "$rc" "$out"
S release scope --session ain-1 >/dev/null 2>&1
out=$(S wanted scope --session ain-1 2>&1); rc=$?
check "release still clears the request" 1 "$rc" "$out"

# ---------------------------------------------------------------------------------------
# 40-47: second review round (2026-10-06). Each is a known-bad found by an independent
# reviewer against the first version of the session fix.
nolock() { [ -d "$AGENT_LOCK_DIR/$1.lock" ] && bad "  ...and NO lock was created" "$(info "$1")" \
                                           || ok "  ...and NO lock was created"; }

echo "== 40. BLOCKER: a flag in the NOTE position must not become the note =="
# `acquire fab-chrome --session=fil-1` stored the note "--session=fil-1" and took the lock
# pid-only -- the incident again. zsh's unquoted empty `--session $S` collapses to the same.
fresh
EMPTY=""
out=$(S acquire scope --session=fil-1 2>&1); rc=$?
check "acquire x --session=S (no note) is REFUSED" 2 "$rc" "$out"
has   "  ...telling you to pass \"\" as the note" 'Pass "" if you have none' "$out"
nolock scope
out=$(S acquire scope --session fil-1 2>&1); rc=$?
check "acquire x --session S (no note) is REFUSED" 2 "$rc" "$out"
nolock scope
# shellcheck disable=SC2086
out=$(S acquire scope --session $EMPTY 2>&1); rc=$?
check "acquire x --session \$EMPTY (unquoted, empty) is REFUSED" 2 "$rc" "$out"
nolock scope
# shellcheck disable=SC2086
out=$(S acquire scope "note" --session $EMPTY 2>&1); rc=$?
check "acquire x note --session \$EMPTY (unquoted, empty) is REFUSED" 2 "$rc" "$out"
nolock scope
if [ -x /bin/zsh ]; then
  out=$(AGENT_LOCK_OWNER_PID=$$ /bin/zsh -fc 'S=""; "$1" acquire scope --session $S' zsh "$L" 2>&1); rc=$?
  check "  ...the same typed in zsh (S=\"\"; --session \$S) is REFUSED" 2 "$rc" "$out"
  nolock scope
fi
out=$(S wait scope --session=fil-1 3 2>&1); rc=$?
check "wait x --session=S (no note) is REFUSED, not waited on" 2 "$rc" "$out"
nolock scope
out=$(S acquire scope "" --session fil-1 2>&1); rc=$?
check "an explicit empty note \"\" with --session works" 0 "$rc" "$out"
has   "  ...and the identity is the session" "sid=fil-1" "$(info scope)"
out=$(S note scope --session=fil-1 2>&1); rc=$?
check "note x --session=S (no text) is REFUSED" 2 "$rc" "$out"
out=$(S park scope --session=fil-1 2>&1); rc=$?
check "park x --session=S (no reason) is REFUSED" 2 "$rc" "$out"
out=$(S want scope --session=fil-2 2>&1); rc=$?
check "want x --session=S (no note) is REFUSED" 2 "$rc" "$out"
[ -e "$AGENT_LOCK_DIR/scope.want" ] && bad "  ...and filed no request" || ok "  ...and filed no request"

echo "== 41. a registry !session marker makes the session MANDATORY =="
fresh
printf 'fab-chrome: chrome !session\n' >> "$AGENT_LOCK_ALIASES"
out=$(S acquire fab-chrome "no session" 2>&1); rc=$?
check "acquire of a !session resource without a session is REFUSED" 2 "$rc" "$out"
has   "  ...and says why" "REQUIRES a session" "$out"
nolock fab-chrome
out=$(S acquire chrome "via alias" 2>&1); rc=$?
check "  ...also via an alias" 2 "$rc" "$out"
s0=$(date +%s)
out=$(S wait fab-chrome "no session" 30 2>&1); rc=$?
check "wait without a session is REFUSED at once (not after the timeout)" 2 "$rc" "$out"
[ $(( $(date +%s) - s0 )) -lt 10 ] && ok "  ...promptly" || bad "  ...promptly" "took $(( $(date +%s) - s0 ))s"
out=$(S run fab-chrome "no session" --timeout 5 -- /bin/echo SHOULD_NOT_RUN 2>&1); rc=$?
check "run without a session is REFUSED" 2 "$rc" "$out"
hasnt "  ...and its command did not run" "SHOULD_NOT_RUN" "$out"
nolock fab-chrome
out=$(S acquire fab-chrome "with session" --session fil-1 2>&1); rc=$?
check "with --session it is granted" 0 "$rc" "$out"
out=$(AGENT_LOCK_SESSION=fil-1 S acquire fab-chrome "via env" 2>&1); rc=$?
check "  ...and \$AGENT_LOCK_SESSION counts as a session" 0 "$rc" "$out"
out=$("$L" resolve chrome 2>&1); rc=$?
check "the marker is not an alias: 'chrome' still resolves" 0 "$rc" "$out"
has   "  ...to fab-chrome" "fab-chrome" "$out"
out=$(S acquire scope "unmarked resource, no session" 2>&1); rc=$?
check "resources WITHOUT the marker still allow pid-only use" 0 "$rc" "$out"
out=$("$L" top --once 2>&1); rc=$?
check "lock-top still runs with a !session marker in the registry" 0 "$rc" "$out"
hasnt "  ...and does not list the marker as a resource name" "!session" "$out"
fresh
printf 'fab-chrome: chrome !sesion\n' >> "$AGENT_LOCK_ALIASES"
out=$(S acquire fab-chrome "x" --session fil-1 2>&1); rc=$?
check "a MISSPELT marker (!sesion) makes the registry unevaluable, not optional" 2 "$rc" "$out"

echo "== 42. MAJOR: no lock may be CREATED with pid=unknown; an orphaned wait gives up =="
fresh
dead=99999; while kill -0 $dead 2>/dev/null; do dead=$((dead+1)); done
out=$(AGENT_LOCK_OWNER_PID=$dead "$L" acquire scope "ownerless" --session x-1 2>&1); rc=$?
check "acquire with no identifiable owner is REFUSED" 2 "$rc" "$out"
has   "  ...and says why" "pid=unknown" "$out"
nolock scope
# Orphan: the wait's caller (a subshell) exits at once, so the wait is reparented.
fresh
S acquire scope "holder" --session h-1 >/dev/null 2>&1
( AGENT_LOCK_OWNER_PID=$$ "$L" wait scope "orphan" 60 --session w-1 >"$TMP/orph.out" 2>&1 &
  echo $! > "$TMP/orph.pid" )
wp=$(cat "$TMP/orph.pid")
for _ in $(seq 1 40); do kill -0 "$wp" 2>/dev/null || break; sleep 0.2; done
kill -0 "$wp" 2>/dev/null && { bad "an orphaned wait exits on its own" "still running"; kill "$wp"; } \
                          || ok "an orphaned wait exits on its own"
has   "  ...saying its caller is gone" "caller" "$(cat "$TMP/orph.out")"
S release scope --session h-1 >/dev/null 2>&1; sleep 3
nolock scope
# Owner gone: the agent process (here a stand-in) dies while the wait is queued.
fresh
S acquire scope "holder" --session h-1 >/dev/null 2>&1
sleep 60 & fake=$!
AGENT_LOCK_OWNER_PID=$fake "$L" wait scope "owner dies" 60 --session w-1 >"$TMP/own.out" 2>&1 & wp=$!
sleep 1; kill "$fake"; wait "$fake" 2>/dev/null
for _ in $(seq 1 40); do kill -0 "$wp" 2>/dev/null || break; sleep 0.2; done
kill -0 "$wp" 2>/dev/null && { bad "a wait whose owning agent died exits" "still running"; kill "$wp"; } \
                          || ok "a wait whose owning agent died exits"
wait "$wp"; rc=$?
check "  ...with rc 2" 2 "$rc" "$(cat "$TMP/own.out")"
S release scope --session h-1 >/dev/null 2>&1; sleep 3
nolock scope

echo "== 43. MAJOR: a signal while run is still WAITING must not leak a lock =="
fresh
S acquire scope "holder" --session h-1 >/dev/null 2>&1
AGENT_LOCK_OWNER_PID=$$ "$L" run scope "term-while-waiting $TMP" --session r-1 --timeout 60 -- \
  /bin/echo SHOULD_NOT_RUN >"$TMP/run43.out" 2>&1 & rp=$!
sleep 1.5; kill -TERM "$rp"; wait "$rp"; rc=$?
check "run TERMed while waiting exits 143" 143 "$rc" "$(cat "$TMP/run43.out")"
S release scope --session h-1 >/dev/null 2>&1; sleep 4
nolock scope
hasnt "  ...and the command never ran" "SHOULD_NOT_RUN" "$(cat "$TMP/run43.out")"
n=$(ps -A -o command= | grep -c "[t]erm-while-waiting $TMP")   # this suite's only: suites may run in parallel
[ "$n" = 0 ] && ok "  ...and no wait process survives it" || bad "  ...and no wait process survives it" "$n left"
fresh
S acquire scope "holder" --session h-1 >/dev/null 2>&1
AGENT_LOCK_OWNER_PID=$$ "$L" run scope "hup-while-waiting" --session r-1 --timeout 60 -- \
  /bin/echo SHOULD_NOT_RUN >"$TMP/run43b.out" 2>&1 & rp=$!
sleep 1.5; kill -HUP "$rp"; wait "$rp"; rc=$?
check "run HUPed while waiting exits 129" 129 "$rc" "$(cat "$TMP/run43b.out")"
S release scope --session h-1 >/dev/null 2>&1; sleep 4
nolock scope
# (SIGINT is not testable this way: a non-interactive shell starts background jobs with
# SIGINT ignored, and an ignored-at-entry signal cannot be trapped. A foreground Ctrl-C
# reaches the same on_sig path.)

echo "== 44. minor: wait passes --ack/--brief through; release forgives one legacy word =="
fresh
"$L" flag scope "known condition" >/dev/null 2>&1
out=$(S wait scope "sweep" 5 --ack 2>&1); rc=$?
check "wait x note 5 --ack acquires a flagged-but-free resource (as the old script did)" 0 "$rc" "$out"
S release scope >/dev/null 2>&1
out=$(S wait scope "sweep" 5 2>&1); rc=$?
check "  ...and without --ack it still refuses" 1 "$rc" "$out"
"$L" unflag scope >/dev/null 2>&1
S acquire scope "job" >/dev/null 2>&1
out=$(S release scope "done" 2>&1); rc=$?
check "release x \"done\" (legacy extra word) still releases" 0 "$rc" "$out"
has   "  ...with a warning" "ignoring 'done'" "$out"
nolock scope

echo "== 45. minor: session id hygiene =="
fresh
out=$(S acquire scope "x" --session a-1 --session b-2 2>&1); rc=$?
check "--session twice with DIFFERENT values is REFUSED" 2 "$rc" "$out"
nolock scope
out=$(S acquire scope "x" --session a-1 --session a-1 2>&1); rc=$?
check "--session twice with the SAME value is fine" 0 "$rc" "$out"
S release scope --session a-1 >/dev/null 2>&1
out=$(S acquire scope "x" --session --ack 2>&1); rc=$?
check "--session followed by a flag (--session --ack) is REFUSED" 2 "$rc" "$out"
nolock scope
out=$(S acquire scope "x" --session "a b" 2>&1); rc=$?
check "a session id with a space is REFUSED" 2 "$rc" "$out"
out=$(S acquire scope "x" --session "$(printf 'fil\n-1')" 2>&1); rc=$?
check "a session id with an embedded newline is REFUSED (was silently 'fil-1')" 2 "$rc" "$out"
nolock scope
out=$(S acquire scope "x" --session "$(printf '\t lead \t')" 2>&1); rc=$?
check "surrounding whitespace is trimmed" 0 "$rc" "$out"
out=$(S mine scope --session lead 2>&1); rc=$?
check "  ...so 'lead' is the same identity" 0 "$rc" "$out"
S release scope --session lead >/dev/null 2>&1
out=$(AGENT_LOCK_SESSION=" " S acquire scope "x" 2>&1); rc=$?
check "a whitespace-only \$AGENT_LOCK_SESSION is REFUSED" 2 "$rc" "$out"
out=$(S acquire scope "x" --session "$(printf 'x%.0s' $(seq 1 65))" 2>&1); rc=$?
check "a 65-char session id is REFUSED" 2 "$rc" "$out"
out=$("$L" newsession -x 2>&1); rc=$?
check "newsession refuses a label starting with '-'" 2 "$rc" "$out"

echo "== 46. minor: TIMEOUT names the holder; pid-only labels are marked; status says YOURS =="
fresh
S acquire scope "AIN holds" --session ain-1 >/dev/null 2>&1
out=$(S wait scope "FIL" 2 --session fil-1 2>&1); rc=$?
check "wait times out" 1 "$rc" "$out"
has   "  ...and names the holder" "note=AIN holds" "$out"
has   "  ...and explains the shared pid" "DIFFERENT session" "$out"
out=$(S status scope --session ain-1 2>&1)
has   "status marks the caller's own lock YOURS" "(YOURS)" "$out"
out=$(S status scope --session fil-1 2>&1)
hasnt "  ...and not a sibling's" "(YOURS)" "$out"
fresh
out=$(PASEO_AGENT_ID=deadbeefcafe S acquire scope "no session" 2>&1); rc=$?
check "session-less acquire with a shared PASEO_AGENT_ID" 0 "$rc" "$out"
has   "  ...labels it pid-only, not as an identity" "(pid-only)" "$(info scope)"
has   "  ...and records no sid" "sid=
" "$(info scope)
"

echo "== 47. minor: want/unwant check identity; ~/bin symlink finds its registry =="
fresh
S acquire scope "A" --session a-1 >/dev/null 2>&1
out=$(S want scope "for myself?" --session a-1 2>&1); rc=$?
check "the holder cannot 'want' its own lock" 1 "$rc" "$out"
S want scope "B wants it" --session b-2 >/dev/null 2>&1
out=$(S unwant scope --session c-3 2>&1); rc=$?
check "a third session cannot withdraw B's request" 1 "$rc" "$out"
[ -e "$AGENT_LOCK_DIR/scope.want" ] && ok "  ...and it stands" || bad "  ...and it stands"
out=$(S unwant scope --session b-2 2>&1); rc=$?
check "the requester can withdraw it" 0 "$rc" "$out"
S want scope "B again" --session b-2 >/dev/null 2>&1
out=$(S unwant scope --force --session a-1 2>&1); rc=$?
check "  ...and --force clears anyone's" 0 "$rc" "$out"
fresh
S want scope "pid-only ask" >/dev/null 2>&1
out=$(S unwant scope 2>&1); rc=$?
check "pid-only want/unwant behave as before" 0 "$rc" "$out"
# symlinked launcher: an isolated copy of the skill dir, linked from a fake ~/bin
mkdir -p "$TMP/skill" "$TMP/bin"
cp "$L" "$TMP/skill/lock.sh"; cp "$AGENT_LOCK_ALIASES" "$TMP/skill/aliases.conf"
ln -sf "$TMP/skill/lock.sh" "$TMP/bin/lock.sh"
ln -sf ../skill/lock.sh "$TMP/bin/rel-lock.sh"
out=$(env -u AGENT_LOCK_ALIASES "$TMP/bin/lock.sh" resolve mxo4 2>&1); rc=$?
check "an absolute symlink finds the registry beside its TARGET" 0 "$rc" "$out"
out=$(env -u AGENT_LOCK_ALIASES "$TMP/bin/rel-lock.sh" resolve mxo4 2>&1); rc=$?
check "  ...and so does a relative one" 0 "$rc" "$out"

echo "== 48. race: sibling sessions never overlap; unpark never lies =="
fresh
mkdir -p "$TMP/cs"; : > "$TMP/cs/viol"
racer() { # $1 = session, $2 = iterations
  local s=$1 i=0
  while [ "$i" -lt "$2" ]; do
    if S acquire scope "r $s" --session "$s" >/dev/null 2>&1; then
      : > "$TMP/cs/in.$s"
      for f in "$TMP"/cs/in.*; do
        case "$f" in *"/in.$s") ;; *"/in.*") ;; *) echo "OVERLAP $s with $f" >> "$TMP/cs/viol" ;; esac
      done
      rm -f "$TMP/cs/in.$s"
      S release scope --session "$s" >/dev/null 2>&1
    fi
    i=$((i+1))
  done
}
racer ra-1 25 & racer rb-2 25 & racer rc-3 25 & wait
[ -s "$TMP/cs/viol" ] && bad "three sibling sessions racing never overlap" "$(head -3 "$TMP/cs/viol")" \
                      || ok "three sibling sessions racing never overlap"
lies=0; dbl=0
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
  fresh
  S acquire scope "A" --session a-1 >/dev/null 2>&1; S park scope "done" --session a-1 >/dev/null 2>&1
  ( S acquire scope "B" --session b-2 >/dev/null 2>&1; echo $? > "$TMP/rb" ) &
  ( S acquire scope "C" --session c-3 >/dev/null 2>&1; echo $? > "$TMP/rc" ) &
  ( S unpark scope --session a-1 > "$TMP/ra" 2>&1 ) &
  wait
  holder=$(sed -n 's/^sid=//p' "$AGENT_LOCK_DIR/scope.lock/info" 2>/dev/null)
  [ "$(cat "$TMP/rb")" = 0 ] && [ "$(cat "$TMP/rc")" = 0 ] && dbl=$((dbl+1))
  grep -q '^UNPARKED' "$TMP/ra" && [ "$holder" != a-1 ] && lies=$((lies+1))
done
[ "$dbl" = 0 ] && ok "a parked lock is never handed to TWO takers" || bad "double grants" "$dbl"
[ "$lies" = 0 ] && ok "UNPARKED is never printed for a lock someone else now holds" \
                || bad "unpark lied" "$lies of 15"

# ---------------------------------------------------------------------------------------
# 49-52: final review round (2026-10-06). Known-bads from the reviewer's r2.sh/r4.sh.
reg() { # reg '<registry text, printf %b escapes>' -- replace the registry, empty the store
  rm -rf "$AGENT_LOCK_DIR"; mkdir -p "$AGENT_LOCK_DIR"; printf '%b' "$1" > "$AGENT_LOCK_ALIASES"; }

echo "== 49. MUST: a registry typo can never silently drop !session =="
# (a) the space forgotten: `chrome!session` used to become an ALIAS, so fab-chrome had no
# marker and `acquire fab-chrome x` without a session was ACQUIRED.
reg 'fab-chrome: chrome!session\nscope: mxo\n'
out=$(S acquire fab-chrome "x" 2>&1); rc=$?
check "'chrome!session' (no space): acquire fab-chrome without a session FAILS CLOSED" 2 "$rc" "$out"
has   "  ...naming the bad token" "unknown registry option 'chrome!session'" "$out"
nolock fab-chrome
out=$(S acquire fab-chrome "x" --session fil-1 2>&1); rc=$?
check "  ...even WITH a session (the registry is unevaluable, not merely strict)" 2 "$rc" "$out"
nolock fab-chrome
out=$(S acquire 'chrome!session' "x" 2>&1); rc=$?
check "  ...and the token is not an alias" 2 "$rc" "$out"
out=$(S acquire scope "x" 2>&1); rc=$?
check "  ...and the rest of the registry fails closed with it" 2 "$rc" "$out"
nolock scope
for tok in 'chrome!' '!session!' 'x!y' '!' '!SESSION' '!sesion'; do
  reg "fab-chrome: chrome $tok\n"
  out=$(S acquire fab-chrome "x" 2>&1); rc=$?
  check "  ...'$tok' in an alias field fails closed too" 2 "$rc" "$out"
done
nolock fab-chrome
# (b) the marker on ANOTHER line than the alias: resolve() read the marker only from the line
# where the name matched, so `acquire chrome x` with no session returned rc=0.
for order in 'fab-chrome: chrome\nfab-chrome: !session\n' 'fab-chrome: !session\nfab-chrome: chrome\n'; do
  reg "$order"
  what=$(printf '%b' "$order" | tr '\n' '|')
  out=$(S acquire chrome "x" 2>&1); rc=$?
  check "marker on another line ($what): acquire chrome without a session is REFUSED" 2 "$rc" "$out"
  has   "  ...because the RESOURCE requires one" "REQUIRES a session" "$out"
  nolock fab-chrome
  out=$(S acquire fab-chrome "x" 2>&1); rc=$?
  check "  ...and fab-chrome itself is refused" 2 "$rc" "$out"
  s0=$(date +%s)
  out=$(S wait chrome "x" 30 2>&1); rc=$?
  check "  ...wait chrome without a session is refused at once" 2 "$rc" "$out"
  [ $(( $(date +%s) - s0 )) -lt 10 ] && ok "  ...promptly" || bad "  ...promptly" "took $(( $(date +%s) - s0 ))s"
  out=$(S run chrome "x" --timeout 5 -- /bin/echo SHOULD_NOT_RUN 2>&1); rc=$?
  check "  ...run chrome without a session is refused" 2 "$rc" "$out"
  hasnt "  ...without running the command" "SHOULD_NOT_RUN" "$out"
  nolock fab-chrome
  out=$(S acquire chrome "x" --session fil-1 2>&1); rc=$?
  check "  ...with a session, chrome is granted as fab-chrome" 0 "$rc" "$out"
  has   "  ...under the canonical lock" "sid=fil-1" "$(info fab-chrome)"
done

echo "== 50. the rest of the reviewer's r2.sh registry variants =="
reg 'fab-chrome: !sesion chrome\nrig:\n'
out=$(S acquire rig "x" 2>&1); rc=$?
check "'!sesion' anywhere makes EVERY name unevaluable (rig too)" 2 "$rc" "$out"
nolock rig
reg 'fab-chrome: ! session\n'
out=$(S acquire fab-chrome "x" 2>&1); rc=$?
check "'! session' (space after the bang) fails closed" 2 "$rc" "$out"
for r in 'fab-chrome: !session !session\n' 'fab-chrome:!session\n' \
         'fab-chrome: !session # require session\n' 'fab-chrome: !session\r\n'; do
  reg "$r"
  what=$(printf '%b' "$r" | tr -d '\r' | tr '\n' '|')
  out=$(S acquire fab-chrome "x" 2>&1); rc=$?
  check "'$what' still REQUIRES a session" 2 "$rc" "$out"
  has   "  ...says so" "REQUIRES a session" "$out"
  out=$(S acquire fab-chrome "x" --session fil-1 2>&1); rc=$?
  check "  ...and grants with one" 0 "$rc" "$out"
done
# An alias that is another resource's canonical name: `browser` used to be granted
# session-less while the registry also called it fab-chrome.
reg 'fab-chrome: !session\nbrowser: fab-chrome\n'
out=$(S acquire browser "x" 2>&1); rc=$?
check "'browser: fab-chrome' beside a !session fab-chrome: acquire browser FAILS CLOSED" 2 "$rc" "$out"
has   "  ...as an ambiguous registry" "ambiguous" "$out"
nolock browser
out=$(S acquire fab-chrome "x" --session fil-1 2>&1); rc=$?
check "  ...and fab-chrome is ambiguous too" 2 "$rc" "$out"
nolock fab-chrome
reg 'scope: mxo\nbench2: mxo\n'
out=$(S acquire scope "x" 2>&1); rc=$?
check "an alias shared by two resources makes BOTH canonicals unevaluable" 2 "$rc" "$out"
reg 'scope: mxo\nmxo-old: scope\n'
out=$(S acquire mxo "x" 2>&1); rc=$?
check "an alias whose canonical is another resource's alias is ambiguous" 2 "$rc" "$out"
reg 'fab-chrome: !session\n!chrome: use fab-chrome\n'
out=$(S acquire chrome "x" 2>&1); rc=$?
check "a ban beside a !session resource still refuses with its reason" 2 "$rc" "$out"
has   "  ...the reason" "use fab-chrome" "$out"
out=$(S acquire fab-chrome "x" 2>&1); rc=$?
check "  ...and the marked resource still requires a session" 2 "$rc" "$out"
reg 'fab-chrome: !session\n'
out=$(S acquire fab-chrome "x" --new 2>&1); rc=$?
check "--new does not bypass !session" 2 "$rc" "$out"
out=$("$L" resolve '!session' 2>&1); rc=$?
check "the marker itself is not a resource name" 2 "$rc" "$out"
reg 'scope: mxo mxo4\nfab-chrome: chrome !session\n!dmm: two of them\n'
for n in scope mxo mxo4; do
  out=$("$L" resolve "$n" 2>&1); rc=$?
  check "a clean registry still resolves $n" 0 "$rc" "$out"
done

echo "== 51. minor: run --timeout is validated by run; session ids start alphanumeric =="
fresh
out=$(S run scope "n" --session r-1 --timeout abc -- /bin/echo SHOULD_NOT_RUN 2>&1); rc=$?
check "run --timeout abc is REFUSED" 2 "$rc" "$out"
has   "  ...naming the timeout" "bad --timeout 'abc'" "$out"
hasnt "  ...not the misleading wait error" "unknown argument for wait" "$out"
hasnt "  ...and the command did not run" "SHOULD_NOT_RUN" "$out"
nolock scope
out=$(S run scope "n" --session r-1 --timeout -- /bin/echo SHOULD_NOT_RUN 2>&1); rc=$?
check "run --timeout with no value is REFUSED" 2 "$rc" "$out"
hasnt "  ...and the command did not run" "SHOULD_NOT_RUN" "$out"
out=$(S run scope "n" --session r-1 --timeout 5 -- /bin/echo RAN 2>&1); rc=$?
check "run --timeout 5 still works" 0 "$rc" "$out"
for sid in . .. _ .x _x ._; do
  out=$(S acquire scope "x" --session "$sid" 2>&1); rc=$?
  check "session id '$sid' (not starting alphanumeric) is REFUSED" 2 "$rc" "$out"
done
out=$(S acquire scope "x" --session=. 2>&1); rc=$?
check "  ...also as --session=." 2 "$rc" "$out"
out=$(AGENT_LOCK_SESSION=_x S acquire scope "x" 2>&1); rc=$?
check "  ...and from \$AGENT_LOCK_SESSION" 2 "$rc" "$out"
nolock scope
if [ -x /bin/zsh ]; then
  out=$(AGENT_LOCK_OWNER_PID=$$ /bin/zsh -fc 'S=fil-1; "$1" acquire scope "" --session=$S:h' zsh "$L" 2>&1); rc=$?
  check "zsh '--session=\$S:h' (the id '.') is REFUSED" 2 "$rc" "$out"
  nolock scope
fi
out=$(S acquire scope "x" --session 9a.b_c-d 2>&1); rc=$?
check "an id starting with a digit, with . _ - inside, is fine" 0 "$rc" "$out"
S release scope --session 9a.b_c-d >/dev/null 2>&1
long=$(printf 'L%.0s' $(seq 1 32))
okn=0; tot=0
for lab in "" a 9 a.b_c-d "$long" fil sa; do
  for _ in 1 2 3; do
    sid=$("$L" newsession $lab 2>/dev/null); tot=$((tot+1))
    [[ "$sid" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] && okn=$((okn+1)) || echo "    bad id: '$sid'"
  done
done
check "every newsession id satisfies the session-id rule ($okn/$tot)" "$tot" "$okn"
sid=$("$L" newsession "$long")
out=$(S acquire scope "x" --session "$sid" 2>&1); rc=$?
check "  ...and the longest one (32-char label) is accepted by acquire" 0 "$rc" "$out"
S release scope --session "$sid" >/dev/null 2>&1
for lab in .x _x -x; do
  out=$("$L" newsession "$lab" 2>&1); rc=$?
  check "newsession refuses label '$lab'" 2 "$rc" "$out"
done

echo "== 52. documented: run releases a lock the same session held BEFORE run started =="
fresh
S acquire scope "outer" --session r-1 >/dev/null 2>&1
out=$(S run scope "inner" --session r-1 -- /bin/sh -c true 2>&1); rc=$?
check "run inside the same session's hold runs the command" 0 "$rc" "$out"
nolock scope
S acquire scope "outer" --session r-1 >/dev/null 2>&1
out=$(S run scope "other" --session r-2 --timeout 2 -- /bin/echo SHOULD_NOT_RUN 2>&1); rc=$?
check "  ...but a DIFFERENT session's run neither runs nor releases it" 2 "$rc" "$out"
has   "  ...the outer hold survives" "sid=r-1" "$(info scope)"

echo "== 53. round 4: a '!' in the NAME field fails closed, so --new cannot open a second mutex =="
for r in 'fab-chrome!session: chrome\nscope: mxo\n' 'fab-chrome !session:\nscope: mxo\n' 'scope: mxo\n!!x: reason\n'; do
  reg "$r"
  what=$(printf '%b' "$r" | tr '\n' '|')
  before=$(cat "$AGENT_LOCK_ALIASES")
  out=$(S acquire fab-chrome "x" --new 2>&1); rc=$?
  check "'$what': acquire fab-chrome --new FAILS CLOSED" 2 "$rc" "$out"
  [ "$(cat "$AGENT_LOCK_ALIASES")" = "$before" ] && ok "  ...and registers nothing" \
                                                  || bad "  ...and registers nothing" "$(cat "$AGENT_LOCK_ALIASES")"
  nolock fab-chrome
  out=$(S acquire fab-chrome "x" --session fil-1 2>&1); rc=$?
  check "  ...plain acquire with a session fails closed too" 2 "$rc" "$out"
  out=$(S acquire scope "x" 2>&1); rc=$?
  check "  ...and the whole registry is unevaluable" 2 "$rc" "$out"
  nolock scope
done
reg 'fab-chrome!session: chrome\n'
out=$(S acquire chrome "x" 2>&1); rc=$?
check "the alias of a '!'-named canonical is refused" 2 "$rc" "$out"
has   "  ...naming the name-field problem" "name field" "$out"
reg '!dmm: two of them\nscope: mxo\n'
out=$(S acquire dmm "x" 2>&1); rc=$?
check "a normal leading-! ban still refuses with its reason" 2 "$rc" "$out"
has   "  ...the reason" "two of them" "$out"
out=$(S acquire scope "x" 2>&1); rc=$?
check "  ...and leaves the rest of the registry usable" 0 "$rc" "$out"

echo "== 54. round 4: the documented example session id is refused =="
fresh
EX=fil-3f9a0c71d2
out=$(S acquire scope "x" --session $EX 2>&1); rc=$?
check "acquire --session <the SKILL.md example id> is REFUSED" 2 "$rc" "$out"
has   "  ...saying it is the example" "EXAMPLE id" "$out"
out=$(S acquire scope "x" --session " $EX " 2>&1); rc=$?
check "  ...also with surrounding whitespace" 2 "$rc" "$out"
out=$(S acquire scope "x" --session=$EX 2>&1); rc=$?
check "  ...also as --session=" 2 "$rc" "$out"
out=$(AGENT_LOCK_SESSION=$EX S acquire scope "x" 2>&1); rc=$?
check "  ...also from \$AGENT_LOCK_SESSION" 2 "$rc" "$out"
out=$(S wait scope "x" 5 --session $EX 2>&1); rc=$?
check "  ...wait refuses it" 2 "$rc" "$out"
out=$(S run scope "x" --session $EX -- /bin/echo SHOULD_NOT_RUN 2>&1); rc=$?
check "  ...run refuses it" 2 "$rc" "$out"
hasnt "  ...without running the command" "SHOULD_NOT_RUN" "$out"
nolock scope
out=$(S acquire scope "x" --session fil-3f9a0c71d3 2>&1); rc=$?
check "a neighbouring id is fine (only the exact sample is refused)" 0 "$rc" "$out"
S release scope --session fil-3f9a0c71d3 >/dev/null 2>&1
n=$(grep -E '^"\$L" .*--session +'"$EX" "$HERE/SKILL.md" | wc -l | tr -d ' ')
check "SKILL.md has no runnable command that uses the example id" 0 "$n" ""

# ---------------------------------------------------------------------------------------
# 55-63: LEASES. The 2026-10-06 known-bad: a session limit killed every sub-agent at ~18:05;
# FARTCOIN held fab-chrome under its session, its pid was the LIVE parent, so the lock never
# went stale and CRV waited 66+ minutes behind a dead holder.
leasereg() { reg "fab-chrome: chrome !session !lease=${1:-60}\nscope: mxo\nrig: !lease=60\n"; }
setlease() { # setlease <canonical> <offset s from now>: move lease_until, as time passing would
  local f="$AGENT_LOCK_DIR/$1.lock/info"
  sed "s/^lease_until=.*/lease_until=$(( $(date +%s) + $2 ))/" "$f" > "$f.t" && mv -f "$f.t" "$f"; }
until_of() { sed -n 's/^lease_until=//p' "$AGENT_LOCK_DIR/$1.lock/info" 2>/dev/null; }
fresh_enough() { # fresh_enough <desc> <canonical> <min seconds left>
  local u; u=$(until_of "$2")
  [ -n "$u" ] && [ $(( u - $(date +%s) )) -ge "$3" ] && ok "$1" || bad "$1" "lease_until=$u now=$(date +%s)"; }

echo "== 55. !lease=N registry option: digits, bounds, fail closed =="
for v in '!lease=' '!lease=abc' '!lease=15m' '!lease=59' '!lease=86401' '!lease=0900' '!lease=-5' \
         '!lease' '!LEASE=900' '!lease=9e2' '!lease=900!' '!lease==900'; do
  reg "fab-chrome: !session $v\nscope: mxo\n"
  out=$(S acquire fab-chrome "x" --session fil-1 2>&1); rc=$?
  check "malformed '$v' makes the registry unevaluable" 2 "$rc" "$out"
done
nolock fab-chrome
out=$(S acquire scope "x" 2>&1); rc=$?
check "  ...for every name, not only the marked one" 2 "$rc" "$out"
for v in 60 900 86400; do
  reg "fab-chrome: !session !lease=$v\n"
  out=$("$L" resolve fab-chrome 2>&1); rc=$?
  check "!lease=$v is accepted" 0 "$rc" "$out"
done
reg 'fab-chrome: !session !lease=900\nfab-chrome: !lease=600\n'
out=$(S acquire fab-chrome "x" --session fil-1 2>&1); rc=$?
check "two DIFFERENT leases for one resource are unevaluable" 2 "$rc" "$out"
reg 'fab-chrome: !session !lease=900\nfab-chrome: chrome !lease=900\n'
out=$(S acquire chrome "x" --session fil-1 2>&1); rc=$?
check "the same lease twice is fine (and applies via the alias)" 0 "$rc" "$out"
has   "  ...recorded from the other line" "lease_s=900" "$(info fab-chrome)"
reg 'fab-chrome: !session !lease=2\n'
out=$(AGENT_LOCK_MIN_LEASE=abc S acquire fab-chrome "x" --session fil-1 2>&1); rc=$?
check "a malformed AGENT_LOCK_MIN_LEASE keeps the 60 s floor (!lease=2 refused)" 2 "$rc" "$out"
out=$(S acquire fab-chrome "x" --session fil-1 2>&1); rc=$?
check "  ...and so does no knob at all" 2 "$rc" "$out"

echo "== 56. a lease is recorded only for a SESSION lock on a !lease resource =="
leasereg
t0=$(date +%s)
S acquire fab-chrome "A" --session a-1 >/dev/null 2>&1
has   "session acquire records lease_s" "lease_s=60" "$(info fab-chrome)"
u=$(until_of fab-chrome); d=$(( u - t0 ))
[ "$d" -ge 59 ] && [ "$d" -le 61 ] && ok "  ...and lease_until = now + 60" || bad "  ...and lease_until = now + 60" "d=$d"
out=$(S acquire rig "pid-only" 2>&1); rc=$?
check "a session-LESS acquire of a !lease resource (no !session) works" 0 "$rc" "$out"
hasnt "  ...and records NO lease (the pid already frees it)" "lease_" "$(info rig)"
S acquire scope "x" --session a-1 >/dev/null 2>&1
hasnt "a resource WITHOUT !lease records no lease, session or not" "lease_" "$(info scope)"

echo "== 57. expiry: the old holder loses it; another session takes it, loudly =="
leasereg
S acquire fab-chrome "FARTCOIN: dexscreener pages" --session fartcoin-1 >/dev/null 2>&1
setlease fab-chrome 30
out=$(S acquire fab-chrome "CRV" --session crv-1 2>&1); rc=$?
check "an UNEXPIRED lease under a live pid is still BUSY" 1 "$rc" "$out"
has   "  ...and BUSY shows the time left" "left]" "$out"
setlease fab-chrome -125
out=$(S mine fab-chrome --session fartcoin-1 2>&1); rc=$?
check "the holder's mine says NO once its lease expired" 1 "$rc" "$out"
has   "  ...saying it lost the lock" "LOST" "$out"
out=$(S mine fab-chrome --session fartcoin-1 --quiet 2>&1); rc=$?
check "  ...also with --quiet" 1 "$rc" "$out"
[ -z "$out" ] && ok "  ...and --quiet stays silent" || bad "  ...and --quiet stays silent" "$out"
out=$(S status fab-chrome 2>&1)
has   "status marks the lease EXPIRED" "EXPIRED" "$out"
case "$("$L" list 2>&1)" in *"[expired]"*) ok "list marks it [expired]" ;; *) bad "list marks it [expired]" ;; esac
out=$(S acquire fab-chrome "CRV" --session crv-1 2>&1); rc=$?
check "another session TAKES the expired lease though the pid is alive" 0 "$rc" "$out"
has   "  ...loudly" "TAKING OVER AN EXPIRED LEASE" "$out"
has   "  ...naming the old holder's session" "session fartcoin-1" "$out"
has   "  ...its note" "FARTCOIN: dexscreener pages" "$out"
has   "  ...and how long it had been expired" "EXPIRED 2m ago" "$out"
has   "  ...and the lock is now the taker's" "sid=crv-1" "$(info fab-chrome)"
has   "  ...with a fresh lease" "lease_s=60" "$(info fab-chrome)"
out=$(S mine fab-chrome --session fartcoin-1 2>&1); rc=$?
check "the old holder's mine stays NO" 1 "$rc" "$out"
out=$(S note fab-chrome "still here" --session fartcoin-1 2>&1); rc=$?
check "the old holder's note is refused" 1 "$rc" "$out"
out=$(S release fab-chrome --session fartcoin-1 2>&1); rc=$?
check "the old holder's release exits 1" 1 "$rc" "$out"
has   "  ...saying it no longer held it" "you did NOT hold it" "$out"
has   "  ...and the taker keeps the lock" "sid=crv-1" "$(info fab-chrome)"
# expired but nobody took it
leasereg
S acquire fab-chrome "A" --session a-1 >/dev/null 2>&1; setlease fab-chrome -5
out=$(S release fab-chrome --session a-1 2>&1); rc=$?
check "release of OUR expired, untaken lease exits 1" 1 "$rc" "$out"
has   "  ...saying we no longer held it" "no longer held it" "$out"
nolock fab-chrome
S acquire fab-chrome "A" --session a-1 >/dev/null 2>&1; setlease fab-chrome -5
out=$(S note fab-chrome "late" --session a-1 2>&1); rc=$?
check "note on our own EXPIRED lease is refused" 1 "$rc" "$out"
out=$(S acquire fab-chrome "A again" --session a-1 2>&1); rc=$?
check "re-acquire by the SAME session of its expired, untaken lease succeeds" 0 "$rc" "$out"
has   "  ...warning it was unprotected in between" "NOT protected" "$out"
fresh_enough "  ...with the lease renewed" fab-chrome 55
S release fab-chrome --session a-1 >/dev/null 2>&1
# wait takes an expired lease too
S acquire fab-chrome "A" --session a-1 >/dev/null 2>&1; setlease fab-chrome -10
out=$(S wait fab-chrome "B" 10 --session b-2 2>&1); rc=$?
check "wait by another session takes an expired lease" 0 "$rc" "$out"
has   "  ...loudly" "TAKING OVER AN EXPIRED LEASE" "$out"

echo "== 58. renewal by acquire, wait, note, mine, mine --quiet (same session only) =="
leasereg
S acquire fab-chrome "A" --session a-1 >/dev/null 2>&1
for c in 'acquire fab-chrome A' 'wait fab-chrome A 5' 'note fab-chrome A2' 'mine fab-chrome' 'mine fab-chrome --quiet'; do
  setlease fab-chrome 5
  # shellcheck disable=SC2086
  out=$(S $c --session a-1 2>&1); rc=$?
  check "'$c' by the holder succeeds" 0 "$rc" "$out"
  fresh_enough "  ...and renews the lease" fab-chrome 55
done
setlease fab-chrome 5; u=$(until_of fab-chrome)
S mine fab-chrome --session b-2 >/dev/null 2>&1; S status fab-chrome --session b-2 >/dev/null 2>&1
S acquire fab-chrome "B" --session b-2 >/dev/null 2>&1; S note fab-chrome "B" --session b-2 >/dev/null 2>&1
[ "$(until_of fab-chrome)" = "$u" ] && ok "another session's mine/status/acquire/note renew NOTHING" \
                                    || bad "another session's calls renewed the lease"
setlease fab-chrome 58; u=$(until_of fab-chrome)
S mine fab-chrome --session a-1 --quiet; rc=$?
check "mine on a FRESH lease says yes" 0 "$rc" ""
[ "$(until_of fab-chrome)" = "$u" ] && ok "  ...without rewriting info (cheap)" || bad "  ...without rewriting info (cheap)"
s0=$(now_ms)
for _ in 1 2 3 4 5 6 7 8 9 10; do S mine fab-chrome --session a-1 --quiet; done
e0=$(now_ms)
ms=$(( (e0 - s0) / 10 ))
[ "$ms" -lt 300 ] && ok "  ...and costs ${ms} ms per call (< 300)" || bad "  ...mine is slow" "${ms} ms per call"

echo "== 59. race: N sessions on ONE expired lease -> exactly one winner =="
multi=0; none=0; loud=0
for round in 1 2 3 4 5 6 7 8; do
  leasereg
  S acquire fab-chrome "dead sub-agent" --session dead-1 >/dev/null 2>&1; setlease fab-chrome -60
  for k in 1 2 3 4 5 6; do
    ( S acquire fab-chrome "taker $k" --session tk-$k > "$TMP/race.$k" 2>&1; echo $? > "$TMP/race.$k.rc" ) &
  done
  wait
  w=0; for k in 1 2 3 4 5 6; do [ "$(cat "$TMP/race.$k.rc")" = 0 ] && w=$((w+1)); done
  [ "$w" -gt 1 ] && multi=$((multi+1)); [ "$w" = 0 ] && none=$((none+1))
  n=$(cat "$TMP"/race.[1-6] | grep -c 'TAKING OVER AN EXPIRED LEASE')
  [ "$n" = 1 ] || loud=$((loud+1))
  # the lock's sid must be the one winner
  sid=$(sed -n 's/^sid=//p' "$AGENT_LOCK_DIR/fab-chrome.lock/info")
  for k in 1 2 3 4 5 6; do [ "$(cat "$TMP/race.$k.rc")" = 0 ] && [ "tk-$k" != "$sid" ] && multi=$((multi+1)); done
done
[ "$multi" = 0 ] && ok "six takers x 8 rounds: never two winners" || bad "double grants" "$multi"
[ "$none" = 0 ] && ok "  ...and never zero (somebody always gets it)" || bad "  ...rounds with no winner" "$none"
[ "$loud" = 0 ] && ok "  ...and exactly one takeover message per round" || bad "  ...takeover messages" "$loud rounds off"

echo "== 60. real time: a slow holder loses it; a renewing holder never does =="
export AGENT_LOCK_MIN_LEASE=2
leasereg 2
S acquire fab-chrome "slow" --session slow-1 >/dev/null 2>&1
sleep 3.3
out=$(S mine fab-chrome --session slow-1 --quiet 2>&1); rc=$?
check "after 3.3 s without renewal a 2 s lease is lost (mine says NO)" 1 "$rc" "$out"
out=$(S acquire fab-chrome "fast" --session fast-2 2>&1); rc=$?
check "  ...another session takes it" 0 "$rc" "$out"
out=$(S release fab-chrome --session slow-1 2>&1); rc=$?
check "  ...the slow holder's release exits 1" 1 "$rc" "$out"
has   "  ...and the taker still holds it" "sid=fast-2" "$(info fab-chrome)"
leasereg 3
S acquire fab-chrome "renewing" --session ren-1 >/dev/null 2>&1
( for _ in 1 2 3 4 5 6 7; do S mine fab-chrome --session ren-1 --quiet || echo LOST; sleep 1; done ) > "$TMP/ren.out" 2>&1 &
rp=$!; got=0
for _ in $(seq 1 16); do S acquire fab-chrome "thief" --session th-2 >/dev/null 2>&1 && got=$((got+1)); sleep 0.4; done
wait "$rp"
[ "$got" = 0 ] && ok "a holder calling mine every 1 s keeps a 3 s lease for 7 s" || bad "it was taken" "$got times"
hasnt "  ...and mine never said lost" "LOST" "$(cat "$TMP/ren.out")"
S release fab-chrome --session ren-1 >/dev/null 2>&1

echo "== 61. run keeps its lease alive while the command runs =="
leasereg 3
# The command checks, every second, that it still holds the lock it is running under.
AGENT_LOCK_OWNER_PID=$$ "$L" run fab-chrome "long job $TMP" --session run-1 -- /bin/sh -c \
  'i=0; while [ $i -lt 8 ]; do sleep 1; "$0" mine fab-chrome --session run-1 --quiet || echo CMD-LOST; i=$((i+1)); done' \
  "$L" > "$TMP/run61.out" 2>&1 & rp=$!
sleep 1; got=0; tries=0
while kill -0 "$rp" 2>/dev/null; do
  if out=$(S acquire fab-chrome "thief" --session th-2 2>&1); then
    case "$out" in *"TAKING OVER"*) got=$((got+1)) ;; esac
    S release fab-chrome --session th-2 >/dev/null 2>&1    # after run released: a normal grant
  fi
  tries=$((tries+1)); sleep 0.4
done
wait "$rp"; rc=$?
check "an 8 s run under a 3 s lease exits with the command's status" 0 "$rc" "$(cat "$TMP/run61.out")"
[ "$got" = 0 ] && ok "  ...and was NEVER taken over ($tries attempts while it ran)" || bad "  ...it was taken over" "$got times"
hasnt "  ...the command held it at every one of its 8 checks" "CMD-LOST" "$(cat "$TMP/run61.out")"
hasnt "  ...its renewer never reported a loss" "LOST the lock" "$(cat "$TMP/run61.out")"
nolock fab-chrome
sleep 1.5
n=$(ps -A -o command= | grep -c "[l]ock.sh run fab-chrome long job $TMP")
[ "$n" = 0 ] && ok "  ...and no renewer survives it" || bad "  ...renewer left running" "$n"
AGENT_LOCK_OWNER_PID=$$ "$L" run fab-chrome "killed $TMP" --session run-2 -- /bin/sleep 7 > "$TMP/run61b.out" 2>&1 & rp=$!
sleep 1.5; kill -TERM "$rp"; wait "$rp"; rc=$?
check "a run TERMed mid-command exits 143" 143 "$rc" "$(cat "$TMP/run61b.out")"
nolock fab-chrome
sleep 1.5
n=$(ps -A -o command= | grep -c "[l]ock.sh run fab-chrome killed $TMP")
[ "$n" = 0 ] && ok "  ...and its renewer dies with it" || bad "  ...renewer left running" "$n"
unset AGENT_LOCK_MIN_LEASE

echo "== 62. expiry does not change parked, flagged or pid-dead locks =="
leasereg
S acquire fab-chrome "A" --session a-1 >/dev/null 2>&1; S park fab-chrome "done, tab on page X" --session a-1 >/dev/null 2>&1
setlease fab-chrome -10
out=$(S acquire fab-chrome "B" --session b-2 2>&1); rc=$?
check "a parked lock with an expired lease is taken over AS PARKED" 0 "$rc" "$out"
has   "  ...with the park reason" "done, tab on page X" "$out"
leasereg
S acquire fab-chrome "A" --session a-1 >/dev/null 2>&1; setlease fab-chrome -10
"$L" flag fab-chrome "browser profile corrupted" >/dev/null 2>&1
out=$(S acquire fab-chrome "B" --session b-2 2>&1); rc=$?
check "a FLAGGED resource stays refused even with an expired lease" 1 "$rc" "$out"
has   "  ...and the expired lock is untouched" "sid=a-1" "$(info fab-chrome)"
"$L" unflag fab-chrome >/dev/null 2>&1
leasereg
dead=99999; while kill -0 $dead 2>/dev/null; do dead=$((dead+1)); done
mkdir -p "$AGENT_LOCK_DIR/fab-chrome.lock"
printf 'resource=fab-chrome\npid=%s\nsid=a-1\nnote=dead\nlease_s=60\nlease_until=%s\n' "$dead" $(( $(date +%s) + 50 )) \
  > "$AGENT_LOCK_DIR/fab-chrome.lock/info"
out=$(S acquire fab-chrome "B" --session b-2 2>&1); rc=$?
check "a pid-DEAD holder is still stolen at once, lease or not" 0 "$rc" "$out"
has   "  ...as a stale lock" "stale lock (holder pid dead)" "$out"

echo "== 63. backward compatibility: locks and resources without a lease never expire =="
leasereg
mkdir -p "$AGENT_LOCK_DIR/fab-chrome.lock"   # a lock taken before the registry had !lease
printf 'resource=fab-chrome\npid=%s\nsid=old-1\nuser=x\nsince=2026-10-06 10:00:00\nnote=pre-lease hold\n' "$$" \
  > "$AGENT_LOCK_DIR/fab-chrome.lock/info"
touch -t 202610060900 "$AGENT_LOCK_DIR/fab-chrome.lock/info"
out=$(S acquire fab-chrome "B" --session b-2 2>&1); rc=$?
check "a pre-lease lock (no lease_until) on a !lease resource is NOT takeable" 1 "$rc" "$out"
out=$(S mine fab-chrome --session old-1 2>&1); rc=$?
check "  ...and stays its holder's" 0 "$rc" "$out"
hasnt "  ...and mine does not bolt a lease onto it" "lease_" "$(info fab-chrome)"
out=$(S release fab-chrome --session old-1 2>&1); rc=$?
check "  ...and releases normally" 0 "$rc" "$out"
printf 'resource=fab-chrome\npid=%s\nsid=old-1\nnote=x\nlease_until=soon\n' "$$" > "$TMP/i"
mkdir -p "$AGENT_LOCK_DIR/fab-chrome.lock"; cp "$TMP/i" "$AGENT_LOCK_DIR/fab-chrome.lock/info"
out=$(S acquire fab-chrome "B" --session b-2 2>&1); rc=$?
check "an UNPARSEABLE lease_until never reads as expired" 1 "$rc" "$out"
fresh
S acquire scope "pid-only, old style" >/dev/null 2>&1
sed_i 's/^since=.*/since=2020-01-01 00:00:00/' "$AGENT_LOCK_DIR/scope.lock/info"
out=$(S acquire scope "other" --session b-2 2>&1); rc=$?
check "a resource without !lease: an old lock is never taken by age" 1 "$rc" "$out"
hasnt "  ...and shows no lease" "lease" "$out"

# ---------------------------------------------------------------------------------------
# 64-69: lease review (2026-10-06). Known-bads from the reviewer's a3/a4/a5 repros.
gate_on()  { mkdir "$AGENT_LOCK_DIR/$1.lock.steal"; }      # simulate a busy .steal gate
gate_off() { rmdir "$AGENT_LOCK_DIR/$1.lock.steal" 2>/dev/null; }

echo "== 64. mine: a busy gate is 'cannot tell' (3), never a false loss or a false yes =="
leasereg
S acquire fab-chrome "A" --session a-1 >/dev/null 2>&1
setlease fab-chrome 20; gate_on fab-chrome
out=$(S mine fab-chrome --session a-1 2>&1); rc=$?
check "gate busy, renewal due (20 s of 60 left): mine exits 3" 3 "$rc" "$out"
has   "  ...saying it cannot tell" "CANNOT TELL" "$out"
out=$(S mine fab-chrome --session a-1 --quiet 2>&1); rc=$?
check "  ...also with --quiet (and silently)" 3 "$rc" "$out"
setlease fab-chrome 40; u=$(until_of fab-chrome)
out=$(S mine fab-chrome --session a-1 2>&1); rc=$?
check "gate busy, but >= half the lease left: mine still says yes" 0 "$rc" "$out"
has   "  ...renewal deferred" "deferred" "$out"
[ "$(until_of fab-chrome)" = "$u" ] && ok "  ...and nothing was written" || bad "  ...and nothing was written"
setlease fab-chrome -5
out=$(S mine fab-chrome --session a-1 --quiet 2>&1); rc=$?
check "gate busy and the lease EXPIRED: mine says lost (1), not 'cannot tell'" 1 "$rc" "$out"
gate_off fab-chrome
setlease fab-chrome 20
out=$(S mine fab-chrome --session a-1 --quiet 2>&1); rc=$?
check "gate free again: mine renews and says yes" 0 "$rc" "$out"
fresh_enough "  ...renewed" fab-chrome 55

echo "== 65. run: a real loss TERMs the command and exits 75; a busy gate is not a loss =="
export AGENT_LOCK_MIN_LEASE=2
leasereg 3
cmd65='trap "echo CMD-GOT-TERM; exit 143" TERM; i=0; while [ $i -lt 30 ]; do sleep 1; i=$((i+1)); done; echo CMD-FINISHED'
t0=$(date +%s)
AGENT_LOCK_OWNER_PID=$$ "$L" run fab-chrome "force $TMP" --session r-1 -- /bin/sh -c "$cmd65" > "$TMP/r65a.out" 2>&1 & rp=$!
sleep 1.5; "$L" release fab-chrome --force >/dev/null 2>&1
wait "$rp"; rc=$?
check "release --force mid-command: run exits 75 (was 0)" 75 "$rc" "$(cat "$TMP/r65a.out")"
has   "  ...the command got TERM" "CMD-GOT-TERM" "$(cat "$TMP/r65a.out")"
hasnt "  ...and did not run to the end" "CMD-FINISHED" "$(cat "$TMP/r65a.out")"
has   "  ...run says it LOST the lock" "LOCK LOST: lock.sh run lost fab-chrome" "$(cat "$TMP/r65a.out")"
[ $(( $(date +%s) - t0 )) -lt 15 ] && ok "  ...promptly" || bad "  ...promptly" "$(( $(date +%s) - t0 ))s"
leasereg 3
AGENT_LOCK_OWNER_PID=$$ "$L" run fab-chrome "gate $TMP" --session r-2 -- /bin/sh -c "$cmd65" > "$TMP/r65b.out" 2>&1 & rp=$!
sleep 0.5; gate_on fab-chrome; sleep 5; gate_off fab-chrome
S acquire fab-chrome "taker" --session t-2 >/dev/null 2>&1
wait "$rp"; rc=$?
check "gate held PAST the lease expiry: a real loss -> run exits 75" 75 "$rc" "$(cat "$TMP/r65b.out")"
has   "  ...the command got TERM" "CMD-GOT-TERM" "$(cat "$TMP/r65b.out")"
S release fab-chrome --session t-2 >/dev/null 2>&1
leasereg 9
AGENT_LOCK_OWNER_PID=$$ "$L" run fab-chrome "brief gate $TMP" --session r-3 -- /bin/sleep 8 > "$TMP/r65c.out" 2>&1 & rp=$!
sleep 2.5; gate_on fab-chrome; sleep 3; gate_off fab-chrome
wait "$rp"; rc=$?
check "gate busy 3 s under a 9 s lease: NOT a loss, run exits with the command's 0" 0 "$rc" "$(cat "$TMP/r65c.out")"
hasnt "  ...and never reported LOST" "LOST" "$(cat "$TMP/r65c.out")"
nolock fab-chrome
leasereg 3
out=$(printf 'stdin-reaches-the-command\n' | S run fab-chrome "stdin" --session r-4 -- /bin/cat 2>&1); rc=$?
check "a leased run still passes stdin to the command" 0 "$rc" "$out"
has   "  ...(the command read it)" "stdin-reaches-the-command" "$out"
out=$(S run fab-chrome "rc" --session r-5 -- /bin/sh -c 'exit 7' 2>&1); rc=$?
check "  ...and returns the command's own status (7)" 7 "$rc" "$out"
unset AGENT_LOCK_MIN_LEASE

echo "== 66. lease_until must be a plain epoch; anything else never expires and never errors =="
for v in 0999 "0$(( $(date +%s) + 500 ))" 99999999999999999999 9223372036854775808 18446744073709551615 \
         abc "" -5 " $(( $(date +%s) - 100 ))" "$(( $(date +%s) - 100 ))x" 1e12 0; do
  leasereg
  S acquire fab-chrome "h" --session h-1 >/dev/null 2>&1
  f="$AGENT_LOCK_DIR/fab-chrome.lock/info"
  { grep -v '^lease_until=' "$f"; printf 'lease_until=%s\n' "$v"; } > "$f.x" && mv -f "$f.x" "$f"
  m=$(S mine fab-chrome --session h-1 2>&1); mr=$?
  a=$(S acquire fab-chrome "t" --session t-2 2>&1); ar=$?
  if [ "$mr" = 0 ] && [ "$ar" = 1 ]; then ok "lease_until='$v': unreadable -> holder keeps it, taker BUSY"
  else bad "lease_until='$v': unreadable -> holder keeps it, taker BUSY" "mine=$mr taker=$ar"; fi
  case "$m$a" in *"value too great"*|*"syntax error"*|*"invalid number"*)
    bad "  ...arithmetic error leaked for '$v'" "$m$a" ;; esac
done

echo "== 67. park and note --force on an EXPIRED lease; park never lands in a taker's lock =="
leasereg
S acquire fab-chrome "h" --session h-1 >/dev/null 2>&1; setlease fab-chrome -5
out=$(S park fab-chrome "done" --session h-1 2>&1); rc=$?
check "park of our EXPIRED lease is refused" 1 "$rc" "$out"
[ -e "$AGENT_LOCK_DIR/fab-chrome.lock/parked" ] && bad "  ...and nothing was parked" || ok "  ...and nothing was parked"
u=$(until_of fab-chrome)
out=$(S note fab-chrome "keep going" --session h-1 --force 2>&1); rc=$?
check "note --force on our expired lease amends the text" 0 "$rc" "$out"
has   "  ...says it was NOT renewed" "NOT renewed" "$out"
[ "$(until_of fab-chrome)" = "$u" ] && ok "  ...and did not revive the lease" || bad "  ...and did not revive the lease"
out=$(S mine fab-chrome --session h-1 --quiet 2>&1); rc=$?
check "  ...mine still says lost" 1 "$rc" "$out"
export AGENT_LOCK_MIN_LEASE=2
hit=0
for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
  leasereg 2
  S acquire fab-chrome "h" --session h-1 >/dev/null 2>&1; sleep 2.6
  ( for k in 1 2 3 4 5 6 7 8; do S acquire fab-chrome "t" --session t-2 >/dev/null 2>&1 && break; done ) &
  ( S park fab-chrome "h parked" --session h-1 >/dev/null 2>&1 ) &
  wait
  [ "$(sed -n 's/^sid=//p' "$AGENT_LOCK_DIR/fab-chrome.lock/info" 2>/dev/null)" = t-2 ] && \
    [ -e "$AGENT_LOCK_DIR/fab-chrome.lock/parked" ] && hit=$((hit+1))
done
[ "$hit" = 0 ] && ok "a park racing a takeover never lands in the taker's lock (12 rounds)" \
               || bad "the taker's lock carries the old holder's park" "$hit of 12"
unset AGENT_LOCK_MIN_LEASE

echo "== 68. AGENT_LOCK_MIN_LEASE can only LOWER the floor =="
reg 'fab-chrome: !session !lease=900\n'
for v in 99999 100000 60 0 05 -1 abc; do
  out=$(AGENT_LOCK_MIN_LEASE=$v "$L" resolve fab-chrome 2>&1); rc=$?
  check "MIN_LEASE=$v cannot make the real !lease=900 unevaluable" 0 "$rc" "$out"
done
reg 'fab-chrome: !session !lease=5\n'
out=$(AGENT_LOCK_MIN_LEASE=2 "$L" resolve fab-chrome 2>&1); rc=$?
check "MIN_LEASE=2 admits a 5 s test lease" 0 "$rc" "$out"
out=$("$L" resolve fab-chrome 2>&1); rc=$?
check "  ...and without it a 5 s lease is refused" 2 "$rc" "$out"

echo "== 69. holder writes are gated; a busy gate never makes release leak a plain lock =="
leasereg
S acquire fab-chrome "h" --session h-1 >/dev/null 2>&1; gate_on fab-chrome
out=$(S release fab-chrome --session h-1 2>&1); rc=$?
check "release of a LEASED lock while the gate is busy: 'retry' (3), nothing changed" 3 "$rc" "$out"
has   "  ...and the lock is still there" "sid=h-1" "$(info fab-chrome)"
out=$(S park fab-chrome "x" --session h-1 2>&1); rc=$?
check "  ...park likewise (3)" 3 "$rc" "$out"
gate_off fab-chrome
out=$(S release fab-chrome --session h-1 2>&1); rc=$?
check "  ...and works once the gate is free" 0 "$rc" "$out"
fresh
S acquire scope "plain" >/dev/null 2>&1; gate_on scope
out=$(S release scope 2>&1); rc=$?
check "a lock WITHOUT a lease still releases under a stuck gate (no regression)" 0 "$rc" "$out"
nolock scope
gate_off scope

# ---------------------------------------------------------------------------------------
# 70-75: round-6 review (2026-10-06). Known-bads from the reviewer's b1/b3/b5 repros.
dead_all() { # dead_all <file of pids>: every listed pid is gone
  local p; for p in $(cat "$1" 2>/dev/null); do kill -0 "$p" 2>/dev/null && return 1; done; return 0; }
kill_all() { local p; for p in $(cat "$1" 2>/dev/null); do kill "$p" 2>/dev/null; done; }

echo "== 70. MAJOR: leased run stops the command's WHOLE process group =="
export AGENT_LOCK_MIN_LEASE=2
gc='sleep 300 & echo $! >> "$0"; sleep 301 & echo $! >> "$0"; wait'
leasereg 6; : > "$TMP/gc70a"
AGENT_LOCK_OWNER_PID=$$ "$L" run fab-chrome "gc $TMP" --session g-1 -- /bin/sh -c "$gc" "$TMP/gc70a" > "$TMP/r70a.out" 2>&1 & rp=$!
sleep 1.5; "$L" release fab-chrome --force >/dev/null 2>&1; wait "$rp"; rc=$?
check "force-release mid-command: run exits 75" 75 "$rc" "$(cat "$TMP/r70a.out")"
[ -s "$TMP/gc70a" ] && dead_all "$TMP/gc70a" && ok "  ...and NO grandchild survives (was: sleep 41 kept running)" \
  || { bad "  ...a grandchild survived" "$(cat "$TMP/gc70a" | tr '\n' ' ')"; kill_all "$TMP/gc70a"; }
leasereg 6; : > "$TMP/gc70b"
AGENT_LOCK_OWNER_PID=$$ "$L" run fab-chrome "gc $TMP" --session g-2 -- /bin/sh -c "$gc" "$TMP/gc70b" > "$TMP/r70b.out" 2>&1 & rp=$!
sleep 1.5; kill -TERM "$rp"; wait "$rp"; rc=$?
check "TERM to run mid-command exits 143" 143 "$rc" "$(cat "$TMP/r70b.out")"
[ -s "$TMP/gc70b" ] && dead_all "$TMP/gc70b" && ok "  ...and NO grandchild survives" \
  || { bad "  ...a grandchild survived" "$(cat "$TMP/gc70b" | tr '\n' ' ')"; kill_all "$TMP/gc70b"; }
nolock fab-chrome
leasereg 6; : > "$TMP/gc70c"
# The leftover must not hold our $(...) pipe open, or the capture itself would wait for it and
# the "gone" check below would pass vacuously (it did, in the first calibration run).
out=$(S run fab-chrome "left behind" --session g-3 -- /bin/sh -c 'sleep 300 </dev/null >/dev/null 2>&1 & echo $! >> "$0"; exit 0' "$TMP/gc70c" 2>&1); rc=$?
check "a command that exits leaving a background child: run still exits 0" 0 "$rc" "$out"
has   "  ...says it stops the leftovers" "left processes running" "$out"
[ -s "$TMP/gc70c" ] && dead_all "$TMP/gc70c" && ok "  ...and they are gone before the lock is released" \
  || { bad "  ...the leftover survived the release" "$(cat "$TMP/gc70c")"; kill_all "$TMP/gc70c"; }
nolock fab-chrome
if command -v python3 >/dev/null 2>&1; then
  # INT is forwarded AS INT: started under job control so run itself can trap SIGINT
  # (a plain `&` in a script would start run with SIGINT ignored, untrappable).
  leasereg 6
  set -m
  AGENT_LOCK_OWNER_PID=$$ "$L" run fab-chrome "int $TMP" --session g-4 -- python3 -c \
    'import time
try:
    time.sleep(30)
except KeyboardInterrupt:
    print("GOT-KEYBOARDINTERRUPT", flush=True)' > "$TMP/r70d.out" 2>&1 & rp=$!
  set +m
  sleep 2; kill -INT "$rp"; wait "$rp"; rc=$?
  check "INT to run is forwarded as INT: exits 130" 130 "$rc" "$(cat "$TMP/r70d.out")"
  has   "  ...and the command sees a KeyboardInterrupt" "GOT-KEYBOARDINTERRUPT" "$(cat "$TMP/r70d.out")"
  nolock fab-chrome
fi

echo "== 71. MAJOR: the leased command starts with DEFAULT SIGINT, not ignored =="
if command -v python3 >/dev/null 2>&1; then
  leasereg 6
  out=$(S run fab-chrome "sig" --session g-5 -- python3 -c 'import signal;print("INT:", signal.getsignal(signal.SIGINT))' 2>&1)
  has   "leased command: SIGINT is Python's default handler" "default_int_handler" "$out"
  hasnt "  ...not SIG_IGN" "Handlers.SIG_IGN" "$out"
else ok "(python3 missing: SIGINT disposition check skipped)"; fi
unset AGENT_LOCK_MIN_LEASE

echo "== 72. MEDIUM: mine never says yes to the old holder after a takeover =="
# The lock changes hands WITHOUT the gate while mine waits on it. (Since round 7 `release
# --force` itself waits for the gate, so the takeover is simulated by removing the lock
# directly, as an external rm or an older lock.sh would.)
for round in 1 2 3; do
  leasereg
  S acquire fab-chrome "h" --session h-1 >/dev/null 2>&1; setlease fab-chrome 40; gate_on fab-chrome
  ( S mine fab-chrome --session h-1 --quiet; echo $? > "$TMP/m72" ) &
  sleep 0.4
  rm -rf "$AGENT_LOCK_DIR/fab-chrome.lock"
  S acquire fab-chrome "t-2 drives" --session t-2 >/dev/null 2>&1
  wait; gate_off fab-chrome
  check "round $round: the old holder's mine during a busy gate + ungated takeover says NO" 1 "$(cat "$TMP/m72")" ""
done
out=$(S mine fab-chrome --session t-2 --quiet 2>&1); rc=$?
check "  ...while the new holder's says yes" 0 "$rc" "$out"

echo "== 73. MEDIUM: a taker whose stdout is a closed pipe never leaves the gate behind =="
export AGENT_LOCK_MIN_LEASE=2
for kind in lease parked; do
  leasereg 3
  S acquire fab-chrome "h" --session h-1 >/dev/null 2>&1
  if [ "$kind" = lease ]; then setlease fab-chrome -5; else S park fab-chrome "parked, tab open" --session h-1 >/dev/null 2>&1; fi
  S acquire fab-chrome "t" --session t-2 2>/dev/null | true
  [ -d "$AGENT_LOCK_DIR/fab-chrome.lock.steal" ] && bad "$kind takeover into a closed pipe: the .steal gate was left behind" \
                                                  || ok "$kind takeover into a closed pipe: no .steal gate left behind"
  o=$(sed -n 's/^sid=//p' "$AGENT_LOCK_DIR/fab-chrome.lock/info" 2>/dev/null)
  [ "$o" != h-1 ] && ok "  ...and the old $kind lock is gone (owner now: ${o:-none})" || bad "  ...the old lock stayed" "owner=$o"
  if [ -z "$o" ]; then out=$(S acquire fab-chrome "u" --session u-3 2>&1); rc=$?
    check "  ...so the next taker gets it at once" 0 "$rc" "$out"; fi
done
unset AGENT_LOCK_MIN_LEASE

echo "== 74. MINOR: a busy gate is 'retry' (3) for a healthy holder, 'lost' (1) otherwise =="
leasereg
S acquire fab-chrome "h" --session h-1 >/dev/null 2>&1; gate_on fab-chrome
for c in 'release fab-chrome' 'note fab-chrome n' 'park fab-chrome p'; do
  # shellcheck disable=SC2086
  out=$(S $c --session h-1 2>&1); rc=$?
  check "'$c' with the gate busy: exit 3" 3 "$rc" "$out"
  has   "  ...says retry, not 'not yours'" "retry in a moment" "$out"
done
has   "  ...and nothing changed" "sid=h-1" "$(info fab-chrome)"
setlease fab-chrome -5
out=$(S release fab-chrome --session h-1 2>&1); rc=$?
check "with the gate busy and the lease EXPIRED: release says lost (1)" 1 "$rc" "$out"
gate_off fab-chrome
export AGENT_LOCK_MIN_LEASE=2
leasereg 6
( sleep 1.5; gate_on fab-chrome; sleep 3; gate_off fab-chrome ) &
out=$(S run fab-chrome "ends while gate busy" --session g-6 -- /bin/sleep 2 2>&1); rc=$?
wait
check "a leased run that ends while the gate is busy exits 0" 0 "$rc" "$out"
nolock fab-chrome
unset AGENT_LOCK_MIN_LEASE
gate_off fab-chrome

echo "== 75. MINOR: exit 75 from a lost lock is marked; a command's own 75 is not =="
leasereg
out=$(S run fab-chrome "own 75" --session g-7 -- /bin/sh -c 'exit 75' 2>&1); rc=$?
check "a command's own exit 75 passes through" 75 "$rc" "$out"
hasnt "  ...WITHOUT the LOCK LOST line" "LOCK LOST" "$out"
has   "  ...and the loss case HAS it (see 65/70)" "LOCK LOST" "$(cat "$TMP/r70a.out")"

# ---------------------------------------------------------------------------------------
# 76-77: round-7 review (2026-10-06): c4/c5 -- run said RELEASED with rc 0 while the lock was
# still HELD, after retrying 100-120 s; and release --force ran outside the gate.
echo "== 76. run reports a FAILED release: exit 76, NOT RELEASED, ~20 s bound =="
leasereg
( sleep 1.5; gate_on fab-chrome; sleep 4; gate_off fab-chrome ) &
out=$(S run fab-chrome "short gate" --session n-1 -- /bin/sleep 2 2>&1); rc=$?; wait
check "gate busy 4 s at the end: the release just waits, run exits 0" 0 "$rc" "$out"
has   "  ...RELEASED" "RELEASED fab-chrome" "$out"
nolock fab-chrome
leasereg
( sleep 1.5; gate_on fab-chrome; sleep 27; gate_off fab-chrome ) & gp=$!
t0=$(date +%s)
out=$(S run fab-chrome "stuck gate" --session n-2 -- /bin/sh -c 'sleep 2; exit 7' 2>&1); rc=$?
el=$(( $(date +%s) - t0 ))
check "gate busy past the retry window: run exits 76 (was 0)" 76 "$rc" "$out"
has   "  ...says NOT RELEASED" "NOT RELEASED: fab-chrome" "$out"
hasnt "  ...and never claims RELEASED" "RELEASED fab-chrome (lock.sh run" "$out"
has   "  ...keeps the command's own rc in the message" "the command exited 7" "$out"
has   "  ...names the lease time left" "lease ends in" "$out"
has   "  ...and the exact retry command" "retry 'lock.sh release fab-chrome --session n-2'" "$out"
[ "$el" -le 30 ] && ok "  ...within the ~20 s retry bound (${el}s, was 100-120 s)" || bad "  ...retry bound" "${el}s"
has   "  ...and the lock really is still held" "sid=n-2" "$(info fab-chrome)"
wait "$gp"
out=$(S release fab-chrome --session n-2 2>&1); rc=$?
check "  ...the printed retry works once the gate is free" 0 "$rc" "$out"

echo "== 77. release --force goes through the gate (with a timeout) =="
leasereg
S acquire fab-chrome "h" --session h-1 >/dev/null 2>&1; gate_on fab-chrome
( sleep 1; gate_off fab-chrome ) &
t0=$(now_ms); out=$("$L" release fab-chrome --force 2>&1); rc=$?; t1=$(now_ms); wait
check "--force with a briefly busy gate succeeds" 0 "$rc" "$out"
[ $(( t1 - t0 )) -ge 700 ] && ok "  ...after WAITING for the gate ($(( t1 - t0 )) ms), not interleaving with it" \
                           || bad "  ...it did not wait for the gate" "$(( t1 - t0 )) ms"
hasnt "  ...without a forcing warning" "forcing the release without it" "$out"
nolock fab-chrome
leasereg
S acquire fab-chrome "h" --session h-1 >/dev/null 2>&1; gate_on fab-chrome
out=$("$L" release fab-chrome --force 2>&1); rc=$?
check "--force with a STUCK gate still forces (the override must not be blocked)" 0 "$rc" "$out"
has   "  ...and says so" "forcing the release without it" "$out"
nolock fab-chrome
gate_off fab-chrome

echo "== 78. !maxhold caps ONE acquisition, renewals included (Mouser crawl, 2026-10-14) =="
for v in 'x' '0' '10m' ''; do
  reg "fab-chrome: !session !lease=60 !maxhold=$v\n"
  out=$("$L" resolve fab-chrome 2>&1); rc=$?
  check "!maxhold=$v is unevaluable (exit 2)" 2 "$rc" "$out"
done
reg 'fab-chrome: !session !maxhold=600\n'
out=$("$L" resolve fab-chrome 2>&1); rc=$?
check "!maxhold without !lease is unevaluable (exit 2)" 2 "$rc" "$out"
reg 'fab-chrome: !session !lease=60 !maxhold=600\nfab-chrome: !maxhold=900\n'
out=$("$L" resolve fab-chrome 2>&1); rc=$?
check "two different max holds are unevaluable (exit 2)" 2 "$rc" "$out"
export AGENT_LOCK_MIN_LEASE=2
reg 'fab-chrome: !session !lease=3 !maxhold=5\n'
S acquire fab-chrome "crawl" --session crawl-1 >/dev/null 2>&1
has "the lock records hold_until" "hold_until=" "$(info fab-chrome)"
( for _ in 1 2 3 4 5 6 7 8 9; do S mine fab-chrome --session crawl-1 --quiet && echo HELD || echo LOST; sleep 1; done ) > "$TMP/mh.out" 2>&1
has   "a holder renewing every 1 s still loses a 5 s max hold" "LOST" "$(cat "$TMP/mh.out")"
has   "  ...after holding it first" "HELD" "$(head -1 "$TMP/mh.out")"
out=$(S acquire fab-chrome "crawl again" --session crawl-1 2>&1); rc=$?
check "  ...re-acquire past the hold is refused (rc 1)" 1 "$rc" "$out"
has   "  ...with HOLD LIMIT" "HOLD LIMIT" "$out"
hasnt "  ...and the note is unchanged" "note=crawl again" "$(info fab-chrome)"
out=$(S mine fab-chrome --session crawl-1 2>&1); rc=$?
check "  ...mine says LOST" 1 "$rc" "$out"
has   "  ...and blames the max hold, not a missed renewal" "max hold" "$out"
t0=$(date +%s); out=$(S wait fab-chrome "crawl" 30 --session crawl-1 2>&1); rc=$?; t1=$(date +%s)
check "  ...wait by the same session gives up (rc 1)" 1 "$rc" "$out"
[ $(( t1 - t0 )) -le 5 ] && ok "  ...at once ($(( t1 - t0 )) s), not after its timeout" || bad "  ...wait spun" "$(( t1 - t0 )) s"
hasnt "  ...without calling itself a DIFFERENT session" "DIFFERENT session" "$out"
S release fab-chrome --session crawl-1 >/dev/null 2>&1
S acquire fab-chrome "crawl" --session crawl-1 >/dev/null 2>&1
out=$(S acquire fab-chrome "other" --session other-2 2>&1); rc=$?
check "  ...while within the hold another session is refused" 1 "$rc" "$out"
sleep 6.2
out=$(S acquire fab-chrome "other" --session other-2 2>&1); rc=$?
check "  ...after the max hold another session TAKES it although the holder renewed" 0 "$rc" "$out"
S release fab-chrome --session other-2 >/dev/null 2>&1
reg 'fab-chrome: !session !lease=10 !maxhold=3\n'
S acquire fab-chrome "short hold" --session sh-1 >/dev/null 2>&1
l=$(sed -n 's/^lease_until=//p' "$AGENT_LOCK_DIR/fab-chrome.lock/info"); h=$(sed -n 's/^hold_until=//p' "$AGENT_LOCK_DIR/fab-chrome.lock/info")
[ "$l" -le "$h" ] && ok "lease > maxhold: the first lease already ends at the hold" || bad "lease past hold" "$l > $h"
S release fab-chrome --session sh-1 >/dev/null 2>&1
reg 'fab-chrome: !session !lease=60 !maxhold=10\n'
S acquire fab-chrome "x" --session ml-1 >/dev/null 2>&1
out=$(S mine fab-chrome --session ml-1 --min-left 5 2>&1); rc=$?
check "mine --min-left 5 with ~10 s of hold left: yes" 0 "$rc" "$out"
out=$(S mine fab-chrome --session ml-1 --min-left 30 2>&1); rc=$?
check "mine --min-left 30 with ~10 s of hold left: NO" 1 "$rc" "$out"
has   "  ...says NOT ENOUGH" "NOT ENOUGH" "$out"
out=$(S mine fab-chrome --session ml-1 --min-left x 2>&1); rc=$?
check "  ...a bad --min-left is an error" 2 "$rc" "$out"
for v in '0123' 'abc' ''; do
  sed_i "s/^hold_until=.*/hold_until=$v/" "$AGENT_LOCK_DIR/fab-chrome.lock/info"
  sed_i "s/^lease_until=.*/lease_until=$(( $(date +%s) - 1 ))/" "$AGENT_LOCK_DIR/fab-chrome.lock/info"
  out=$(S acquire fab-chrome "x" --session ml-1 2>&1); rc=$?
  check "malformed hold_until='$v' fails CLOSED (re-acquire refused)" 1 "$rc" "$out"
done
S release fab-chrome --session ml-1 >/dev/null 2>&1
reg 'fab-chrome: !session !lease=30 !maxhold=4\n'
t0=$(date +%s)
AGENT_LOCK_OWNER_PID=$$ "$L" run fab-chrome "run $TMP" --session rn-1 -- /bin/sleep 25 > "$TMP/run78.out" 2>&1; rc=$?
t1=$(date +%s)
check "run past its max hold exits 75" 75 "$rc" "$(cat "$TMP/run78.out")"
[ $(( t1 - t0 )) -le 9 ] && ok "  ...stopped near the hold end ($(( t1 - t0 )) s for a 4 s hold), not lease/3 later" \
                         || bad "  ...stopped late" "$(( t1 - t0 )) s"
nolock fab-chrome
reg 'fab-chrome: !session !lease=4\n'
S acquire fab-chrome "no cap" --session nc-1 >/dev/null 2>&1
hasnt "without !maxhold no hold_until is recorded" "hold_until=" "$(info fab-chrome)"
S release fab-chrome --session nc-1 >/dev/null 2>&1
unset AGENT_LOCK_MIN_LEASE

echo "== 79. Claude Code lock label is the ListAgents name + sid, not a Paseo id (2026-11-25) =="
# A Paseo agent id won the label, so the bench-139c holder could not be found by session name.
fresh
printf '#!/bin/sh\necho "other-1  uds:/y pid 2 busy title mentions $1 x"\necho "fugu-test-9f  uds:/x pid 1 busy $1"\n' > "$TMP/sfind"; chmod +x "$TMP/sfind"
CLAUDE_CODE_SESSION_ID=73170243-aaaa PASEO_AGENT_ID=8fd849ce-bbbb AGENT_LOCK_SESSION_FIND="$TMP/sfind" \
  S acquire fugu-rig "label test" >/dev/null 2>&1
info=$(cat "$AGENT_LOCK_DIR/fugu-rig.lock/info" 2>/dev/null)
has   "79a label carries the session name" "session=fugu-test-9f (73170243) (pid-only)" "$info"
hasnt "79b Paseo id is not the label" "8fd849ce" "$info"
S release fugu-rig >/dev/null 2>&1
CLAUDE_CODE_SESSION_ID=73170243-aaaa AGENT_LOCK_SESSION_FIND=/nonexistent S acquire fugu-rig "label test" >/dev/null 2>&1
has   "79c no session-find: sid prefix only" "session=(73170243) (pid-only)" "$(cat "$AGENT_LOCK_DIR/fugu-rig.lock/info" 2>/dev/null)"
S release fugu-rig >/dev/null 2>&1

echo "== 80. ancestry walk finds Claude Code installed as .../claude/versions/<ver> (2026-11-25) =="
# Its process name is the version ("2.1.329"), so plain acquire from Claude Code got pid=unknown.
fresh
# A symlink keeps the path as the process name (a copied /bin/bash is killed by code signing);
# the second command stops bash from exec'ing lock.sh in its place.
mkdir -p "$TMP/claude/versions"; ln -sf /bin/bash "$TMP/claude/versions/9.9.9"
# Run from Claude Code, a missed match would climb on to the real claude process: assert the pid.
out=$(env -u AGENT_LOCK_OWNER_PID "$TMP/claude/versions/9.9.9" -c 'echo "inner=$$"; "$0" acquire fugu-rig "walk test"; r=$?; exit $r' "$L" 2>&1); rc=$?
check "80a acquire under a versioned claude binary succeeds" 0 "$rc" "$out"
inner=$(printf '%s\n' "$out" | sed -n 's/^inner=//p')
info=$(cat "$AGENT_LOCK_DIR/fugu-rig.lock/info" 2>/dev/null)
has   "80b owner is that very process" "pid=$inner"$'\n' "$info"
has   "80c agent is claude" "agent=claude" "$info"
rm -rf "$AGENT_LOCK_DIR/fugu-rig.lock"

echo "passed $pass, failed $fail"
[ "$fail" = 0 ] || exit 1
