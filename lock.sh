#!/bin/bash
# lock.sh — system-wide named resource locks for agents (scope, rig, dmm, ...).
# Lock = directory $DIR/<canonical>.lock (mkdir is the atomic primitive).
# Exit codes: 0 = ok/free, 1 = busy/held/flagged, 2 = error/unknown (treat as BUSY).
set -u
DIR=${AGENT_LOCK_DIR:-/tmp/claude-locks}
# Resolve symlinks before taking the directory: ~/bin/lock.sh -> the skill dir used to make the
# registry ~/bin/aliases.conf, which does not exist, so every name was refused.
_src=$0
while [ -L "$_src" ]; do
  _d=$(cd "$(dirname "$_src")" && pwd); _src=$(readlink "$_src")
  case "$_src" in /*) ;; *) _src=$_d/$_src ;; esac
done
HERE=$(cd "$(dirname "$_src")" && pwd)
ALIASES=${AGENT_LOCK_ALIASES:-$HERE/aliases.conf}
mkdir -p "$DIR" || exit 2
cmd=${1:-}; name=${2:-}

sanitize() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad resource name: $1" >&2; exit 2; }; }
lockpath() { echo "$DIR/$1.lock"; }
flagpath() { echo "$DIR/$1.flag"; }
wantpath() { echo "$DIR/$1.want"; }

# --- resource identity -------------------------------------------------------------
# One instrument, one lock. An unregistered name is refused rather than granted: a typo
# that creates its own private mutex is the same absence-reads-as-fine shape as a check
# that passes when it cannot run. See aliases.conf for the incident this comes from.

# resolve() sets the globals CANON and banned_reason and returns a status. It deliberately
# does NOT echo the answer: `c=$(resolve x)` runs in a subshell, so a banned name's reason
# died there and every ban degraded to the generic "not registered" message. Caught by
# test-lock.sh case 2 — the same absence-reads-as-fine shape this whole change is about.
CANON=""
banned_reason=""
# Per-resource options live in the alias field as `!word` tokens, never as aliases:
#   fab-chrome: chrome !session     -> acquire/wait/run REFUSE without a session id
# Fail closed on anything that is not EXACTLY a known marker: a token that merely CONTAINS a
# `!` (`chrome!session`, the space forgotten) used to be read as an ALIAS, and `!sesion` as
# nothing, so a one-character typo silently dropped the requirement. Both now make the
# registry unevaluable (exit 2 for every caller).
# The marker belongs to the CANONICAL resource, not to the line it sits on: with
# `fab-chrome: chrome` and `fab-chrome: !session` on two lines, `acquire chrome` used to read
# only the line where `chrome` matched and took the lock with no session (review 2026-10-06).
#
# `!lease=<seconds>` (e.g. `fab-chrome: !session !lease=900`): a lock taken WITH a session on
# such a resource expires unless its holder renews it (see "leases" below). Whole seconds,
# LEASE_MIN..86400; anything else -- `!lease=`, `!lease=15m`, `!lease=10` -- is unevaluable.
# Two different leases for one resource are unevaluable too.
#
# `!maxhold=<seconds>` (e.g. `fab-chrome: !session !lease=900 !maxhold=1200`): a cap on how long
# ONE acquisition may last, renewals included. Measured 2026-10-13/14: a 24-h Mouser crawl held
# fab-chrome for 22+ h, renewing every 4 min while it sat behind a challenge doing nothing, and
# every other session starved. The lock records hold_until=<acquired + N>; renewals never push
# lease_until past it, so once it passes the lease expires and the lock is takeable like any
# expired lease. Same range as !lease, and only valid next to a !lease (it works through it).
NEEDS_SESSION=no
LEASE_S=""
MAXHOLD_S=""
KNOWN_MARKERS=" !session !lease=<seconds> !maxhold=<seconds> "
# The floor exists so a registry typo cannot make a lease that expires mid-command. Tests may
# LOWER it (AGENT_LOCK_MIN_LEASE=2) to exercise real expiry in seconds; the knob only lets the
# registry say less -- it can never make anyone's existing lease expire early.
LEASE_MIN=60
[[ "${AGENT_LOCK_MIN_LEASE:-}" =~ ^[1-9][0-9]?$ ]] && [ "$AGENT_LOCK_MIN_LEASE" -lt 60 ] && LEASE_MIN=$AGENT_LOCK_MIN_LEASE
lease_ok() { [[ "$1" =~ ^[1-9][0-9]{0,5}$ ]] && [ "$1" -ge "$LEASE_MIN" ] && [ "$1" -le 86400 ]; }

resolve() { # set CANON for $1; return 0 ok / 1 unknown / 3 explicitly banned / 4 unevaluable
  # Globbing OFF for the whole parse: `for a in $rest` would otherwise pathname-expand, so a
  # stray `*` in an alias field resolves differently depending on the caller's cwd. Restored
  # here on EVERY return path, so no early return can leave the caller with globbing off.
  local rrc
  set -f; _resolve "$@"; rrc=$?; set +f
  return "$rrc"
}

_resolve() {
  local want=$1 line canon rest a i n=0 hit="" ban="" is_banned=no needs=no names lease="" maxhold=""
  local -a r_canon r_rest
  banned_reason=""; CANON=""; NEEDS_SESSION=no; LEASE_S=""; MAXHOLD_S=""
  [ -r "$ALIASES" ] || { echo "cannot read resource registry $ALIASES" >&2; return 4; }
  # Parse the WHOLE file first: a malformed line or an unknown option anywhere makes the
  # registry unevaluable, whichever name is being looked up.
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line%$'\r'}
    case "$line" in *[![:space:]]*) ;; *) continue;; esac
    if [ "${line#*:}" = "$line" ]; then
      echo "malformed registry line (no colon): $line" >&2; return 4
    fi
    canon=${line%%:*}; rest=${line#*:}
    canon=${canon//[[:space:]]/}
    [ -n "$canon" ] || { echo "malformed registry line (empty name): $line" >&2; return 4; }
    # A `!` in the NAME field anywhere but the leading ban `!` is a misplaced option, never a
    # name: `fab-chrome!session: chrome` (or `fab-chrome !session:`, spaces stripped) used to
    # define a resource nobody could type, so `acquire fab-chrome x --new` registered a SECOND,
    # session-free fab-chrome (review 2026-10-06). Same verdict as an alias-field typo.
    case "${canon#!}" in *'!'*)
      echo "unknown registry option in the name field '$canon' on line: $line" >&2
      echo "  options go AFTER the colon, space-separated: <name>: <aliases> !session" >&2
      return 4 ;;
    esac
    if [ "${canon#!}" != "$canon" ]; then           # !name: reason  -> never resolves
      [ "$want" = "${canon#!}" ] && { is_banned=yes
        ban=$(printf '%s' "$rest" | sed 's/^[[:space:]]*//'); }
      continue
    fi
    for a in $rest; do
      case "$a" in
        '!session') ;;
        '!lease='*)
          lease_ok "${a#!lease=}" || {
            echo "bad registry option '$a' on line: $line" >&2
            echo "  need !lease=<whole seconds, $LEASE_MIN..86400>" >&2
            return 4; } ;;
        '!maxhold='*)
          lease_ok "${a#!maxhold=}" || {
            echo "bad registry option '$a' on line: $line" >&2
            echo "  need !maxhold=<whole seconds, $LEASE_MIN..86400>" >&2
            return 4; } ;;
        *'!'*)
          echo "unknown registry option '$a' on line: $line" >&2
          echo "  a token containing '!' must be exactly one of:$KNOWN_MARKERS(space-separated)" >&2
          return 4 ;;
      esac
    done
    r_canon[n]=$canon; r_rest[n]=$rest; n=$((n+1))
  done < "$ALIASES"
  # Pass 1: which canonical does $want name? Every line is consulted, so a duplicate
  # definition is DETECTED rather than silently decided by line order.
  i=0
  while [ "$i" -lt "$n" ]; do
    canon=${r_canon[i]}
    if [ "$want" = "$canon" ]; then
      [ -n "$hit" ] && [ "$hit" != "$canon" ] && {
        echo "registry is ambiguous: '$want' resolves to both '$hit' and '$canon'" >&2; return 4; }
      hit=$canon
    else
      for a in ${r_rest[i]}; do
        case "$a" in *'!'*) continue ;; esac
        if [ "$want" = "$a" ]; then
          [ -n "$hit" ] && [ "$hit" != "$canon" ] && {
            echo "registry is ambiguous: '$want' resolves to both '$hit' and '$canon'" >&2; return 4; }
          hit=$canon
        fi
      done
    fi
    i=$((i+1))
  done
  # A ban beats a match wherever it appears in the file, so an alias line above the ban
  # cannot defeat it.
  [ "$is_banned" = yes ] && { banned_reason=${ban:-"banned in the registry, no reason given"}; return 3; }
  [ -n "$hit" ] || return 1
  # A canonical name becomes a filesystem path, so it gets the same check as user input:
  # a registry entry like `../../tmp/x: scope` would otherwise point rm -rf outside the store.
  [[ "$hit" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "registry defines an unusable canonical name: $hit" >&2; return 4; }
  # Pass 2: everything the registry says about $hit, from EVERY line that defines it --
  # its options (so a marker on another line still applies) and all of its names.
  names=" $hit "
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${r_canon[i]}" = "$hit" ]; then
      for a in ${r_rest[i]}; do
        case "$a" in
          '!session') needs=yes ;;
          '!lease='*)
            [ -n "$lease" ] && [ "$lease" != "${a#!lease=}" ] && {
              echo "registry gives '$hit' two different leases ($lease, ${a#!lease=})" >&2; return 4; }
            lease=${a#!lease=} ;;
          '!maxhold='*)
            [ -n "$maxhold" ] && [ "$maxhold" != "${a#!maxhold=}" ] && {
              echo "registry gives '$hit' two different max holds ($maxhold, ${a#!maxhold=})" >&2; return 4; }
            maxhold=${a#!maxhold=} ;;
          *'!'*) ;;
          *) names="$names$a " ;;
        esac
      done
    fi
    i=$((i+1))
  done
  # ...and none of those names may mean something else. `browser: fab-chrome` beside
  # `fab-chrome: !session` used to hand out a session-less `browser` lock for what the
  # registry also calls fab-chrome: one name, two resources, and the requirement lost.
  i=0
  while [ "$i" -lt "$n" ]; do
    canon=${r_canon[i]}
    if [ "$canon" != "$hit" ]; then
      case "$names" in *" $canon "*)
        echo "registry is ambiguous: '$canon' is both its own resource and a name of '$hit'" >&2
        return 4 ;;
      esac
      for a in ${r_rest[i]}; do
        case "$a" in *'!'*) continue ;; esac
        case "$names" in *" $a "*)
          echo "registry is ambiguous: '$a' names both '$hit' and '$canon'" >&2; return 4 ;;
        esac
      done
    fi
    i=$((i+1))
  done
  [ -n "$maxhold" ] && [ -z "$lease" ] && {
    echo "registry gives '$hit' !maxhold without !lease (the cap works through the lease)" >&2; return 4; }
  NEEDS_SESSION=$needs; LEASE_S=$lease; MAXHOLD_S=$maxhold
  CANON=$hit; return 0
}

register() { # append a genuinely-new canonical resource to the registry
  printf '%s:\n' "$1" >> "$ALIASES" || { echo "cannot write registry $ALIASES" >&2; exit 2; }
  echo "REGISTERED $1 in $ALIASES" >&2
}

unknown_die() { # $1 = the name as typed, $2 = resolve()'s status; never falls through
  case "$2" in
    3) echo "REFUSED '$1': $banned_reason" >&2 ;;
    4) echo "REFUSED '$1': the resource registry could not be evaluated (see above)." >&2 ;;
    *) echo "REFUSED '$1': not a registered resource." >&2
       echo "  If it is a typo, fix it. If it is genuinely new, register it once:" >&2
       echo "    lock.sh acquire $1 \"note\" --new     (or edit $ALIASES)" >&2 ;;
  esac
  exit 2
}

# Every alias of a canonical, so acquire can refuse when a LEGACY lock exists under one of
# them. Without this the alias map itself reproduces the incident during rollout: an old
# session holding mxo4.lock is invisible to a new session that resolves mxo4 -> scope, and
# both would hold "the MXO44".
aliases_of() { # echo every name that resolves to canonical $1, including $1
  local line canon rest
  [ -r "$ALIASES" ] || return 1
  set -f
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}; line=${line%$'\r'}
    case "$line" in *[![:space:]]*) ;; *) continue;; esac
    [ "${line#*:}" = "$line" ] && continue
    canon=${line%%:*}; rest=${line#*:}; canon=${canon//[[:space:]]/}
    [ "$canon" = "$1" ] || continue
    echo "$canon"; for a in $rest; do case "$a" in *'!'*) ;; *) echo "$a" ;; esac; done
  done < "$ALIASES"
  set +f
}

split_lock_die() { # $1 = canonical, $2 = the legacy name found holding a lock
  echo "REFUSED $1: a lock also exists under the legacy name '$2'." >&2
  echo "  Both names mean one resource, so acquiring now could hand two sessions the same" >&2
  echo "  hardware — exactly the failure the alias map exists to prevent." >&2
  echo "  Resolve it first:  lock.sh status $2   then   lock.sh release $2 [--force]" >&2
  exit 2
}

canon_or_literal() { # inspect/repair path: sets CANON. A lock that exists on disk can
  # always be named, so neither a registry edit nor an unreadable registry can strand one.
  local rc
  # LITERAL FIRST: an object sitting at this exact name is the thing the caller can see and
  # wants to clear, even when the name also resolves elsewhere. This is the migration path
  # out of a legacy alias-named lock, so it must not be shadowed by the alias map.
  if [ -e "$(lockpath "$1")" ] || [ -L "$(lockpath "$1")" ] || [ -e "$(flagpath "$1")" ]; then
    resolve "$1" >/dev/null 2>&1
    [ "$CANON" != "$1" ] && [ -n "$CANON" ] && \
      echo "warning: '$1' normally means '$CANON', but an object exists under '$1' itself;" \
           "acting on the literal one" >&2
    CANON=$1; return 0
  fi
  resolve "$1"; rc=$?
  [ "$rc" = 0 ] && return 0
  unknown_die "$1" "$rc"
}

# --- ownership ---------------------------------------------------------------------
owner_pid() { # walk ancestry to the long-lived agent process; "unknown" if none
  # A DETACHED daemon has no agent ancestor -- nohup reparents it to launchd/init -- so the
  # walk below returns "unknown" and every ownership test fails closed. That is right for a
  # stray process and wrong for a long-running holder, which is exactly who needs `mine`:
  # on 2026-09-15 two 9-hour soaks each stopped ~60 s in, reporting "lost the lock to another
  # session" about locks they held, and then spun forever unable to re-acquire.
  # A daemon that IS the long-lived process names itself:
  #     export AGENT_LOCK_OWNER_PID=$$
  # Its own pid is stable for its lifetime and dies with it, so the lock still reads stale
  # the moment it exits -- the property the ancestry walk was protecting.
  if [ -n "${AGENT_LOCK_OWNER_PID:-}" ]; then
    if ps -p "$AGENT_LOCK_OWNER_PID" -o pid= >/dev/null 2>&1; then echo "$AGENT_LOCK_OWNER_PID"; return
    else echo unknown; return; fi     # a dead pid must never read as ours
  fi
  local pid=$$ comm
  while :; do
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] || break
    comm=$(basename "$(ps -o comm= -p "$pid" 2>/dev/null)")
    case "$comm" in claude|node|bun|codex|opencode|pi) echo "$pid"; return;; esac
  done
  echo unknown  # fail closed: never auto-stolen, --force only
}

owner_agent() { # identify agent binary/name from owner pid
  local pid=${1:-unknown}
  [ "$pid" = unknown ] || [ -z "$pid" ] && { echo "${AI_AGENT:-unknown}"; return; }
  local comm
  comm=$(basename "$(ps -o comm= -p "$pid" 2>/dev/null)")
  case "$comm" in
    claude) echo "claude" ;;
    codex|codex-*) echo "codex" ;;
    pi) echo "pi" ;;
    opencode) echo "opencode" ;;
    node|bun)
      local args
      args=$(ps -p "$pid" -o args= 2>/dev/null)
      case "$args" in
        *claude*) echo "claude" ;;
        *codex*) echo "codex" ;;
        *pi*) echo "pi" ;;
        *) echo "${comm:-unknown}" ;;
      esac
      ;;
    *) echo "${AI_AGENT:-${comm:-unknown}}" ;;
  esac
}

owner_session() { # $1 = explicit session, $2 = owner pid
  if [ -n "${1:-}" ]; then echo "$1"; return; fi
  if [ -n "${AGENT_SESSION_NAME:-}" ]; then echo "$AGENT_SESSION_NAME"; return; fi
  if [ -n "${SESSION_NAME:-}" ]; then echo "$SESSION_NAME"; return; fi
  if [ -n "${PI_SESSION_ID:-}" ]; then echo "${PI_SESSION_ID:0:8}"; return; fi
  if [ -n "${CODEX_SESSION_ID:-}" ]; then echo "${CODEX_SESSION_ID:0:8}"; return; fi
  if [ -n "${PASEO_AGENT_ID:-}" ]; then echo "${PASEO_AGENT_ID:0:8}"; return; fi
  local pid=${2:-unknown}
  if [ "$pid" != unknown ] && [ -n "$pid" ]; then
    local args
    args=$(ps -p "$pid" -o args= 2>/dev/null)
    local s
    s=$(echo "$args" | sed -n 's/.*--resume[= ]\([a-zA-Z0-9_-]\{8\}\).*/\1/p' | head -1)
    [ -n "$s" ] && { echo "$s"; return; }
    s=$(echo "$args" | sed -n 's/.*--session-id[= ]\([a-zA-Z0-9_-]\{8\}\).*/\1/p' | head -1)
    [ -n "$s" ] && { echo "$s"; return; }
  fi
  echo ""
}

holder_pid() { sed -n 's/^pid=//p' "$1/info" 2>/dev/null; }

holder_dead() { # true ONLY if the holder pid is provably dead (anything else => alive)
  local pid out; pid=$(holder_pid "$1")
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  # ps, not kill -0: kill -0 fails with EPERM on other users' live processes (fail-open).
  #
  # But `! ps -p "$pid"` alone read EVERY nonzero ps result as proof of death -- a broken
  # PATH, a fork that could not be taken, ps missing, a sandbox refusing it. The verdict this
  # returns DELETES A LOCK, so a ps that cannot answer used to hand two sessions the same
  # instrument, which is the failure this whole script exists to prevent.
  #
  # So: prove ps works before believing it about someone else, using OUR OWN pid as the
  # control. If ps cannot see a process we know is alive, its silence about the holder means
  # nothing. A guard that cannot run must not return "fine".
  # The control checks the OUTPUT, not the exit status. A ps that exits 0 and prints nothing
  # passes a status-only check and then "proves" every pid dead -- caught by test 20, which
  # is the same shape as the bug being fixed one level down.
  local self; self=$(ps -p $$ -o pid= 2>/dev/null | tr -d '[:space:]')
  [ "$self" = "$$" ] || {
    echo "cannot verify holder liveness (ps did not name our own pid) -- assuming ALIVE" >&2
    return 1
  }
  out=$(ps -p "$pid" -o pid= 2>/dev/null)
  [ -n "$out" ] && return 1        # ps named it: alive
  return 0                         # ps works, and does not know this pid: dead
}

# --- idleness: the OTHER kind of stale ------------------------------------------------
# holder_dead() only catches a holder whose pid is GONE. On 2026-09-06 a peer session held
# fugu-rig for three hours after stopping at bring-up: pid alive, so never "stale", yet the
# lock was abandoned in every sense that mattered and cost a blocking question. The info
# file's mtime is a free activity signal -- acquire writes it, `note` rewrites it -- so an
# untouched lock reports how long it has been quiet. This is INFORMATION, not a licence:
# nothing here auto-steals on idleness, because idle is not dead and a long settle is a
# legitimate reason to hold a rig silently.
info_mtime() { stat -c %Y "$1/info" 2>/dev/null || stat -f %m "$1/info" 2>/dev/null; }  # GNU first: on Linux `stat -f %m F` prints filesystem info for F (exit 1)

age_str() { # $1 = seconds -> compact human duration
  local s=${1:-0}
  if   [ "$s" -lt 90 ];   then echo "${s}s"
  elif [ "$s" -lt 5400 ]; then echo "$((s/60))m"
  else echo "$((s/3600))h$(((s%3600)/60))m"; fi
}

idle_note() { # $1 = lockdir; echoes " [idle X]" past IDLE_MIN_S, else nothing
  local m d; m=$(info_mtime "$1"); [ -n "$m" ] || return 0
  d=$(( $(date +%s) - m ))
  [ "$d" -ge "${IDLE_MIN_S:-600}" ] && printf ' [idle %s]' "$(age_str "$d")"
  return 0
}

# --- parked: the third kind of stale -------------------------------------------------
# holder_dead() catches a holder whose pid is GONE. idle_note() reports one that has gone
# quiet but may legitimately be mid-settle, and deliberately does not steal. Neither
# catches the case that actually blocks people: a LIVE holder that has finished with the
# resource and is waiting on a human. Measured 2026-09-14 -- esp32s3-9a70 held for hours
# by a live session whose own note read "awaiting Fab": it knew it was done, and had no
# way to say "you may take this".
#
# `park` is the holder saying exactly that. It is a declaration, not a timeout: only the
# holder can park, so nothing is ever taken from a session that still believes it is
# using the rig. A parked lock is stealable by acquire, which prints the park reason --
# the physical state of the hardware (mid-experiment, parked in ROM download mode, half
# flashed) lives in that reason and the next holder must read it.
parkpath() { echo "$1/parked"; }
is_parked() { [ -f "$(parkpath "$1")" ]; }
park_reason() { sed -n '2,$p' "$(parkpath "$1")" 2>/dev/null; }
park_since() { sed -n '1p' "$(parkpath "$1")" 2>/dev/null; }
park_note() { # $1 = lockdir; echoes " [PARKED x, reason]" or nothing
  local m d r; is_parked "$1" || return 0
  m=$(park_since "$1"); r=$(park_reason "$1")
  d=$(( $(date +%s) - ${m:-0} ))
  printf ' [PARKED %s: %s]' "$(age_str "$d")" "${r:-no reason given}"
  return 0
}

# --- flag rendering ------------------------------------------------------------------
# A flag reason is a paragraph, and it printed IN FULL on every acquire, release and
# status -- eight times in one session on 2026-09-06, several hundred words each. --brief
# renders the header plus a truncated reason and the path to the whole thing. The REFUSAL
# path never uses it: a stop that summarises the reason it is stopping you is not a stop.
show_flag() { # $1 = flag file
  if [ "${BRIEF:-no}" = yes ] && [ -r "$1" ]; then
    printf '  flagged=%s by=%s\n' \
      "$(sed -n 's/^flagged=//p' "$1" | head -1)" "$(sed -n 's/^by=//p' "$1" | head -1)"
    printf '  reason: %s...\n  (full text: %s)\n' \
      "$(sed -n 's/^reason=//p' "$1" | head -1 | cut -c1-110)" "$1"
  else
    sed 's/^/  /' "$1"
  fi
}

steal_gate() { # serialize stealers: only the gate holder may rm a stale lock
  local g="$1.steal" m now
  mkdir "$g" 2>/dev/null && return 0
  # break a gate leaked by a crashed stealer (held normally for milliseconds)
  m=$(stat -c %Y "$g" 2>/dev/null || stat -f %m "$g" 2>/dev/null) || return 1  # GNU first (see info_mtime)
  now=$(date +%s)
  [ $((now - m)) -gt 60 ] && rmdir "$g" 2>/dev/null && mkdir "$g" 2>/dev/null
}

show() { cat "$1/info" 2>/dev/null || echo "(info unreadable)"; }

read_note() { sed -n 's/^note=//p' "$1/info" 2>/dev/null; }

set_note() { # rewrite only the note= line, atomically within the lock dir
  local lp=$1 new=$2 tmp="$1/info.tmp.$$" keep
  # The existing info MUST be readable. Discarding a failed read used to look like an empty
  # file, and the rewrite then replaced valid metadata with note= alone — dropping pid=,
  # which makes the lock unreleasable and unstealable without --force.
  [ -r "$lp/info" ] || { echo "cannot read $lp/info — refusing to rewrite it" >&2; return 1; }
  keep=$(grep -v '^note=' "$lp/info") || [ -z "$keep" ] || return 1
  { printf '%s\n' "$keep"; printf 'note=%s\n' "$new"; } > "$tmp" || { rm -f "$tmp"; return 1; }
  grep -q '^pid=' "$tmp" || { rm -f "$tmp"; echo "refusing a rewrite that would drop pid=" >&2; return 1; }
  mv -f "$tmp" "$lp/info"
}

clean_note() { printf '%s' "${1:-}" | tr -d '\000-\037\177'; }  # info is one line per key

# --- leases: the FOURTH kind of stale -------------------------------------------------
# holder_dead() frees a lock whose agent process died. A SUB-AGENT's lock is owned by its
# PARENT's pid, so a sub-agent that is killed, errors out or forgets to release leaves a lock
# whose pid stays alive for as long as the parent session does. Measured 2026-10-06: a session
# limit killed every sub-agent at ~18:05; FARTCOIN's fab-chrome (session fartcoin-83f7d999bd,
# pid 39342 = the live parent) stayed held 66+ minutes with CRV queued behind it.
# A resource marked `!lease=N` therefore gives a SESSION-owned lock a deadline:
#   * the lock records lease_s=N and lease_until=<epoch>;
#   * acquire / wait / note / mine / run by the SAME session renew it;
#   * once now > lease_until, another session's acquire/wait may take it (loudly, through the
#     .steal gate), even though the pid is alive;
#   * the old holder's `mine` answers NO and its `release` exits 1 -- it lost the lock.
# A lock with no (numeric) lease_until never expires: pid-only locks, locks on resources
# without !lease, and locks taken before the resource gained one.
# Every write a LIVE holder makes to a leased lock (renew, note, re-acquire, release) goes
# through the same .steal gate as the taker, and re-checks ownership under it; otherwise a
# slow holder could rewrite or delete the lock a taker had just created.
lease_s_of()     { sed -n 's/^lease_s=//p' "$1/info" 2>/dev/null | head -1; }
lease_until_of() { sed -n 's/^lease_until=//p' "$1/info" 2>/dev/null | head -1; }
hold_until_of()  { sed -n 's/^hold_until=//p' "$1/info" 2>/dev/null | head -1; }
has_hold() { grep -q '^hold_until=' "$1/info" 2>/dev/null; }
hold_reached() { # $1 = lockdir; true if it carries a hold_until that has passed.
  # A hold_until= line that is present but not a plain epoch counts as REACHED: an unreadable
  # cap must not mean "no cap" (review 2026-10-14, finding 7). No line at all = not capped.
  local h; has_hold "$1" || return 1
  h=$(hold_until_of "$1")
  [[ "$h" =~ ^[1-9][0-9]{0,10}$ ]] || return 0
  [ "$(date +%s)" -ge "$h" ]
}
LEASE_LEFT=0
is_leased() { # $1 = lockdir; true if it carries a usable lease. Sets LEASE_LEFT (s, may be < 0)
  # Strictly a plain epoch: no leading zero (bash reads `0999` as octal and errors, which used
  # to read as a LOSS) and at most 11 digits (a 2^64-ish value wrapped NEGATIVE in $((...))
  # and read as long expired -> instant takeover). Anything else is unreadable: never expires.
  snap_read "$1" && snap_leased
}
lease_expired() { is_leased "$1" && [ "$LEASE_LEFT" -lt 0 ]; }
lease_note() { # $1 = lockdir; " [lease 12m left]" / " [lease EXPIRED 3m ago -- takeable]" / ""
  is_leased "$1" || return 0
  if [ "$LEASE_LEFT" -lt 0 ]; then printf ' [lease EXPIRED %s ago -- takeable]' "$(age_str $(( -LEASE_LEFT )))"
  else printf ' [lease %s left]' "$(age_str "$LEASE_LEFT")"; fi
}
set_info_kv() { # $1 = lockdir, $2 = key, $3 = value: rewrite one key=, atomically, keeping pid=
  local lp=$1 tmp="$1/info.tmp.$$" keep
  [ -r "$lp/info" ] || return 1
  keep=$(grep -v "^$2=" "$lp/info") || [ -z "$keep" ] || return 1
  { printf '%s\n' "$keep"; printf '%s=%s\n' "$2" "$3"; } > "$tmp" || { rm -f "$tmp"; return 1; }
  grep -q '^pid=' "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$lp/info"
}
renew_lease() { # $1 = lockdir. CALLER HOLDS THE GATE and has re-checked ownership under it.
  local ls; ls=$(lease_s_of "$1")
  [[ "$ls" =~ ^[1-9][0-9]{0,5}$ ]] || return 0
  local until h; until=$(( $(date +%s) + ls )); h=$(hold_until_of "$1")
  # !maxhold: never renew past the end of the hold (see the registry notes). A malformed
  # hold_until ends the lease now (fail closed).
  if has_hold "$1"; then
    [[ "$h" =~ ^[1-9][0-9]{0,10}$ ]] || h=$(date +%s)
    [ "$h" -lt "$until" ] && until=$h
  fi
  set_info_kv "$1" lease_until "$until"
}
# While the gate is held, SIGPIPE is IGNORED: `acquire ... | head -1` used to die (rc 141) in
# the middle of a takeover, leaving the .steal gate AND the old lock behind, so every other
# taker read BUSY for 60 s (review 2026-10-06, b5). Output is also kept out of gated sections.
gate_hold()    { trap '' PIPE; }
gate_release() { trap - PIPE; }
with_gate() { # $1 = lockdir; take the .steal gate, retrying ~2 s. 1 = could not.
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    steal_gate "$1" && { gate_hold; return 0; }; sleep 0.1
  done
  return 1
}
drop_gate() { rmdir "$1.steal" 2>/dev/null; gate_release; }
busy_or_lost() { # $1 = verb, $2 = canonical, $3 = lockdir. owner_gate said 2: never returns.
  # A busy gate is "retry" (exit 3, like mine), not "you lost it" -- unless one snapshot shows
  # the lock is no longer ours or its lease has already run out (exit 1).
  if ! snap_read "$3" || ! snap_owned; then
    echo "$1: $2 is no longer yours (released or taken over)" >&2; exit 1; fi
  if snap_leased && [ "$LEASE_LEFT" -lt 0 ]; then lost_lease_msg "$2" "$3" >&2; exit 1; fi
  echo "$1: the steal gate on $2 is busy right now (a takeover check may be in progress);" \
       "nothing was changed -- retry in a moment (exit 3)" >&2
  exit 3; }
owner_gate() { # $1 = lockdir; for a HOLDER about to write to / remove its own lock.
  # 0 = gate taken: re-check ownership under it, act, drop_gate.
  # 1 = gate busy, but neither the lock nor the registry has a lease: act ungated, exactly as
  #     before leases existed (a crashed stealer's gate must not make release leak a lock).
  # 2 = gate busy on a leased resource: it may be mid-takeover -- do NOT write.
  # Always gating matters: `owned_by_me` and `is_leased` read info separately, and a taker
  # removing the lock in between made a leased lock look lease-less, so a holder's park/note/
  # release went ungated into the TAKER's fresh lock (review 2026-10-06, a5 I: 1 in 60).
  with_gate "$1" && return 0
  if [ -n "${LEASE_S:-}" ] || is_leased "$1"; then return 2; fi
  return 1
}
lost_lease_msg() { # $1 = canonical, $2 = lockdir (ours, expired)
  if hold_reached "$2"; then
    echo "your hold on $1 reached its max hold (!maxhold) $(age_str $(( -LEASE_LEFT ))) ago: you LOST it." \
         "Stop touching the resource; release, then wait again to continue."
    return
  fi
  echo "your lease on $1 EXPIRED $(age_str $(( -LEASE_LEFT ))) ago (lease $(lease_s_of "$2")s," \
       "not renewed in time): you LOST it. Stop touching the resource; re-acquire to continue."
}

# --- holder identity: (pid, session) -------------------------------------------------
# owner_pid() alone cannot tell sub-agents apart: every sub-agent a Claude Code session
# starts runs inside the SAME claude process, so siblings walk up to the same pid. On
# 2026-10-06 a FIL research sub-agent's `wait fab-chrome` returned "already held by this
# session" -- the lock belonged to its AIN sibling -- overwrote the sibling's note, and both
# drove Fab's real Chrome at once. The identity is therefore (pid, session id):
#   * the session id comes from --session S, else $AGENT_LOCK_SESSION, else none;
#   * it is stored as sid= in the lock (session= stays the display label for lock-top);
#   * a lock is ours only if pid AND sid both match. An empty sid matches only an empty sid,
#     so a session-less caller behaves exactly as before against session-less locks, and a
#     mismatch where EITHER side has a session is someone else's lock.
# An explicitly EMPTY session is an error, not "no session": `--session "$S"` with S unset
# would otherwise silently fall back to pid-only identity -- the very collision this fixes.
MYSID=""; MYSID_SET=no
# First character a letter or digit, as for newsession labels: zsh's `--session=$S:h` (a
# history modifier eating the value) produced the id `.`, and `.`/`_` ids are never minted.
SID_RE='^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$'
EXAMPLE_SID=fil-3f9a0c71d2
norm_sid() { # $1 = raw id, $2 = where it came from; sets NSID or exits 2
  # Trim surrounding whitespace, then demand a plain token. No silent repair: stripping an
  # embedded newline turned 'fil\n-1' into 'fil-1', i.e. into SOMEONE ELSE'S identity.
  local v=$1
  v=${v#"${v%%[![:space:]]*}"}; v=${v%"${v##*[![:space:]]}"}
  [ -n "$v" ] || { echo "$2 is empty (get an id: lock.sh newsession <label>)" >&2; exit 2; }
  [[ "$v" =~ $SID_RE ]] || {
    echo "$2 '$v' is not a session id: need 1-64 of [A-Za-z0-9._-], starting with a letter or digit" >&2
    exit 2; }
  # The sample id from SKILL.md. Copied verbatim by two sub-agents it is ONE shared identity,
  # which is the very collision sessions exist to prevent.
  [ "$v" = "$EXAMPLE_SID" ] && {
    echo "$2 '$v' is the EXAMPLE id from the docs, not yours: mint one with lock.sh newsession <label>" >&2
    exit 2; }
  NSID=$v
}
take_session() { # $1 = raw value given to --session
  norm_sid "${1:-}" "--session value"
  # Given twice with different values: which identity did the caller mean? Refuse.
  if [ "$MYSID_SET" = yes ] && [ "$NSID" != "$MYSID" ]; then
    echo "--session given twice with different values ($MYSID vs $NSID)" >&2; exit 2
  fi
  MYSID=$NSID; MYSID_SET=yes
}
finalize_session() { # after option parsing: fall back to $AGENT_LOCK_SESSION
  [ "$MYSID_SET" = yes ] && return 0
  if [ -n "${AGENT_LOCK_SESSION+x}" ]; then
    norm_sid "$AGENT_LOCK_SESSION" "AGENT_LOCK_SESSION"; MYSID=$NSID
  fi
  MYSID_SET=yes
}
need_session_check() { # $1 = canonical; NEEDS_SESSION from resolve(). Call after finalize.
  [ "${NEEDS_SESSION:-no}" = yes ] && [ -z "$MYSID" ] || return 0
  echo "REFUSED $1: this resource REQUIRES a session id (registry marks it !session)." >&2
  echo "  Sub-agents share their parent's pid, so a pid-only lock here is shared by all of" >&2
  echo "  them. Get an id once:  lock.sh newsession <label>   then pass --session <id>." >&2
  echo "  Do NOT continue without a lock." >&2
  exit 2
}
note_not_option() { # $1 = verb, $2 = the positional note/reason ($3)
  # A flag in the note position used to be swallowed AS the note: `acquire fab-chrome
  # --session=fil-1` (or zsh's unquoted empty `--session $S`) stored the note "--session=fil-1"
  # and took the lock pid-only -- the 2026-10-06 incident again, by a different road.
  case "${2:-}" in --*)
    echo "$1: the note is the 3rd argument and got '$2'. Pass \"\" if you have none:" >&2
    echo "  lock.sh $1 <name> \"\" --session <id>" >&2; exit 2 ;;
  esac
}

OPT_FORCE=no; OPT_QUIET=no
parse_opts() { # parse_opts "<allowed flags>" args... ; --session is always accepted
  local allowed=" $1 " a; shift
  while [ "$#" -gt 0 ]; do
    a=$1
    case "$a" in
      --session=*) take_session "${a#*=}"; shift; continue ;;
      --session) [ "$#" -ge 2 ] || { echo "missing argument for --session" >&2; exit 2; }
                 take_session "$2"; shift 2; continue ;;
    esac
    # Unknown arguments are errors: a typo like `--sesion X` silently ignored would drop the
    # caller back to pid-only identity, which is the collision this code exists to stop.
    case "$allowed" in *" $a "*) ;; *) echo "unknown argument for $cmd: $a" >&2; exit 2 ;; esac
    case "$a" in --force) OPT_FORCE=yes ;; --quiet) OPT_QUIET=yes ;; --brief) BRIEF=yes ;; esac
    shift
  done
  finalize_session
}

holder_sid() { sed -n 's/^sid=//p' "$1/info" 2>/dev/null | head -1; }
holder_label() { sed -n 's/^session=//p' "$1/info" 2>/dev/null | head -1; }
who_str() { # $1 = pid, $2 = sid
  printf 'pid %s, session %s' "${1:-?}" "${2:-<none>}"; }

# ONE read of the info file, parsed for owner AND lease. info is only ever replaced by mv, so a
# single open sees one consistent version. Reading pid=, sid= and lease_until= in separate
# reads could mix the old holder's file with a taker's: siblings share a pid, so an old sid=
# next to a new pid= read as "ours" (review 2026-10-06, b1: the old holder's mine said 0 after
# a --force release and a takeover, 3/3).
SNAP_PID=""; SNAP_SID=""; SNAP_UNTIL=""; SNAP_LS=""
snap_read() { # $1 = lockdir; sets SNAP_*; 1 if info is unreadable
  local l np=0 ns=0
  SNAP_PID=""; SNAP_SID=""; SNAP_UNTIL=""; SNAP_LS=""
  { while IFS= read -r l || [ -n "$l" ]; do
      case "$l" in
        pid=*) np=$((np+1)); SNAP_PID=${l#pid=} ;;
        sid=*) [ "$ns" = 0 ] && SNAP_SID=${l#sid=}; ns=$((ns+1)) ;;
        lease_until=*) [ -n "$SNAP_UNTIL" ] || SNAP_UNTIL=${l#lease_until=} ;;
        lease_s=*) [ -n "$SNAP_LS" ] || SNAP_LS=${l#lease_s=} ;;
      esac
    done < "$1/info"; } 2>/dev/null || return 1
  [ "$np" = 1 ] || SNAP_PID=""          # zero or several pid= lines: nobody's
  return 0
}
snap_owned() { [ "$ME" != unknown ] && [ -n "$SNAP_PID" ] && [ "$SNAP_PID" = "$ME" ] && [ "$SNAP_SID" = "$MYSID" ]; }
snap_leased() { # from the snapshot; sets LEASE_LEFT. Same plain-epoch rule as is_leased.
  [[ "$SNAP_UNTIL" =~ ^[1-9][0-9]{0,10}$ ]] || return 1
  LEASE_LEFT=$(( SNAP_UNTIL - $(date +%s) ))
}
owned_by_me() { # $1 = lockdir; needs ME (owner_pid) and MYSID (finalized). One snapshot.
  snap_read "$1" && snap_owned
}

explain_sibling() { # $1 = lockdir; extra line when the pid matches but the session does not
  local hp hs; hp=$(holder_pid "$1"); hs=$(holder_sid "$1")
  [ "$ME" != unknown ] && [ "$hp" = "$ME" ] || return 0
  [ "$hs" != "$MYSID" ] || return 0
  echo "  Same agent process (pid $hp) but a DIFFERENT session: held by session" \
       "${hs:-<none>}, we are ${MYSID:-<none>}."
  echo "  That is a sibling sub-agent or the parent session -- NOT you. Treat it as busy."
}

# --- flags: a warning that outlives the lock ---------------------------------------
# Locks carry one bit and vanish on release. On 2026-08-13 the rig was released while it
# smelled of burnt insulation, and with the lock went the only cross-session record that
# it must not be energised. A flag persists until explicitly cleared.

check_flag() { # $1 = canonical; refuses unless the caller passed --ack
  local fp; fp=$(flagpath "$1")
  [ -e "$fp" ] || return 0
  if [ ! -r "$fp" ]; then
    echo "FLAG on $1 exists but is UNREADABLE ($fp) — refusing" >&2; exit 2
  fi
  if [ "$2" != ack ]; then
    echo "FLAGGED $1 — acquire refused. Raised:" >&2
    sed 's/^/  /' "$fp" >&2
    # Deliberately NOT advertising the override here. This message is read by the session
    # the flag exists to stop, and a refusal that hands out its own bypass is not a refusal.
    echo "  This is a hardware-safety hold. Resolve the underlying condition, then clear it." >&2
    exit 1
  fi
  echo "WARNING: acquiring $1 over an active flag (--ack):" >&2
  show_flag "$fp" >&2
}

case "$cmd" in
  acquire)
    sanitize "$name"
    # The note is STRICTLY positional ($3). Flags are recognised only from $4 on, because
    # scanning every argument made the note itself an option channel: `acquire rig "--ack"`
    # is a correctly-quoted call that used to silently override a burning-smell flag. And
    # a note that LOOKS like a flag is refused outright (note_not_option).
    note_not_option acquire "${3:-}"
    note=$(clean_note "${3:-}"); want_new=no; ack=no
    shift 3 2>/dev/null || shift $#
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --new) want_new=yes ;;
        --ack) ack=yes ;;
        --brief) BRIEF=yes ;;
        --session) [ "$#" -ge 2 ] || { echo "missing argument for --session" >&2; exit 2; }
                   shift; take_session "$1" ;;
        --session=*) take_session "${1#*=}" ;;
        *)     echo "unknown option: $1 (the note is the 3rd argument)" >&2; exit 2 ;;
      esac
      shift
    done
    finalize_session
    resolve "$name"; rrc=$?
    if [ "$rrc" = 0 ]; then canon=$CANON
    elif [ "$rrc" = 1 ] && [ "$want_new" = yes ]; then
      # Only a genuinely UNKNOWN name may be registered. A banned name (3) or an
      # unevaluable registry (4) must not be --new-able: an empty ban reason used to fall
      # through to this branch and grant the lock.
      register "$name"; canon=$name
    else
      unknown_die "$name" "$rrc"
    fi
    [ "$canon" != "$name" ] && echo "note: '$name' -> lock '$canon'" >&2
    need_session_check "$canon"
    # Rollout interlock: refuse while a lock exists under any other spelling of this
    # resource, rather than opening a second mutex beside it.
    while IFS= read -r a; do
      [ -n "$a" ] && [ "$a" != "$canon" ] && [ -d "$(lockpath "$a")" ] && split_lock_die "$canon" "$a"
    done < <(aliases_of "$canon")
    check_flag "$canon" "$([ "$ack" = yes ] && echo ack || echo noack)"
    lp=$(lockpath "$canon"); me=$(owner_pid); ME=$me
    agent=$(owner_agent "$me")
    sess=$(owner_session "$MYSID" "$me")
    # Without a session id the label is derived from the environment or the agent's argv,
    # which every sub-agent of one claude process shares (PASEO_AGENT_ID, --resume id). Mark
    # it, so nobody reads it as an identity.
    [ -z "$MYSID" ] && [ -n "$sess" ] && sess="$sess (pid-only)"
    # A lease is recorded only for a SESSION-owned lock: a pid-only lock already frees when
    # its process dies, and the lease exists for the case the pid cannot see (sub-agents).
    lease_lines=""
    if [ -n "$LEASE_S" ] && [ -n "$MYSID" ]; then
      lease_lines="lease_s=$LEASE_S"$'\n'"lease_until=$(( $(date +%s) + LEASE_S ))"$'\n'
      if [ -n "$MAXHOLD_S" ]; then
        now_s=$(date +%s)
        lease_lines="lease_s=$LEASE_S"$'\n'"lease_until=$(( now_s + (LEASE_S < MAXHOLD_S ? LEASE_S : MAXHOLD_S) ))"$'\n'
        lease_lines="${lease_lines}hold_until=$(( now_s + MAXHOLD_S ))"$'\n'
      fi
    fi
    # Takeover notices are collected under the gate and printed only once the lock is ours (or
    # we give up): nothing is written to a possibly-closed pipe while the gate is held.
    takeover_out=""; takeover_err=""
    flush_takeover() {
      [ -n "$takeover_err" ] && printf '%s' "$takeover_err" >&2
      [ -n "$takeover_out" ] && printf '%s' "$takeover_out"
      takeover_out=""; takeover_err=""; }
    for i in 1 2; do
      # Never CREATE a lock owned by pid=unknown: it is never stale, so nothing but --force
      # ever clears it. That is what an orphaned `wait` (its caller's shell gone, reparented
      # to launchd) used to leave behind.
      if [ "$me" != unknown ] && mkdir "$lp" 2>/dev/null; then
        # sid= is the IDENTITY (empty when the caller gave none); session= is only a label.
        if ! printf 'resource=%s\npid=%s\nsid=%s\nuser=%s\nagent=%s\nsession=%s\nsince=%s\nnote=%s\n%s' \
             "$canon" "$me" "$MYSID" "$USER" "$agent" "$sess" "$(date '+%Y-%m-%d %H:%M:%S')" "$note" \
             "$lease_lines" > "$lp/info"; then
          rm -rf "$lp"   # never leave an ownerless lock behind and report success
          flush_takeover; echo "cannot write lock info under $DIR" >&2; exit 2
        fi
        # Re-check the flag now the lock is OURS. check_flag ran before mkdir, so a flag
        # raised in between would otherwise be granted straight through the interlock.
        if [ "$ack" != yes ] && [ -e "$(flagpath "$canon")" ]; then
          rm -rf "$lp"
          flush_takeover
          echo "FLAGGED $canon — raised while we were acquiring; lock released again:" >&2
          sed 's/^/  /' "$(flagpath "$canon")" 2>/dev/null
          exit 1
        fi
        flush_takeover; echo "ACQUIRED $canon"; exit 0
      fi
      if [ ! -d "$lp" ] && [ "$me" = unknown ]; then
        echo "REFUSED $canon: no owning agent process found (pid=unknown) -- a lock created" >&2
        echo "  now could never be detected as stale. Run from inside the agent session, or" >&2
        echo "  from a long-lived holder: export AGENT_LOCK_OWNER_PID=\$\$" >&2
        exit 2
      fi
      # mkdir can also fail for disk-full/perms/RO-fs: that's an error, not "held"
      [ -d "$lp" ] || { echo "cannot create lock under $DIR" >&2; exit 2; }
      if owned_by_me "$lp" && is_leased "$lp"; then
        # Re-acquire of OUR leased lock: renew it, under the gate (a taker may be on it now).
        with_gate "$lp" || { echo "BUSY $canon (it is being taken over right now)"; exit 1; }
        if ! owned_by_me "$lp"; then
          drop_gate "$lp"; echo "BUSY $canon — taken over while we re-acquired; held by:"; show "$lp"; exit 1
        fi
        relapsed=""; noted=""
        if hold_reached "$lp"; then
          drop_gate "$lp"
          echo "HOLD LIMIT $canon: this acquisition reached its max hold; release it and wait again" >&2
          exit 1
        fi
        lease_expired "$lp" && relapsed=$(age_str $(( -LEASE_LEFT )))
        renew_lease "$lp" || { drop_gate "$lp"; echo "cannot renew the lease on $canon" >&2; exit 2; }
        if [ -n "$note" ] && [ "$note" != "$(read_note "$lp")" ]; then
          set_note "$lp" "$note" && noted=yes
        fi
        drop_gate "$lp"
        [ -n "$relapsed" ] && echo "warning: your lease on $canon had EXPIRED $relapsed ago; nobody took" \
             "it, so it is yours again from now -- but it was NOT protected in between" >&2
        [ -n "$noted" ] && echo "NOTE UPDATED $canon: $note"
        echo "ACQUIRED $canon (already held by this session: $(who_str "$me" "$MYSID"); lease renewed)"; exit 0
      fi
      if owned_by_me "$lp"; then
        # Idempotent re-acquire -- same pid AND same session. A DIFFERING note used to be
        # discarded in silence, which is how a lock went on advertising an abandoned run for
        # hours. Update it.
        if [ -n "$note" ] && [ "$note" != "$(read_note "$lp")" ]; then
          set_note "$lp" "$note" && echo "NOTE UPDATED $canon: $note"
        fi
        echo "ACQUIRED $canon (already held by this session: $(who_str "$me" "$MYSID"))"; exit 0
      fi
      if [ "$i" = 1 ] && { holder_dead "$lp" || is_parked "$lp" || lease_expired "$lp"; }; then
        if steal_gate "$lp"; then
          gate_hold
          # re-check under the gate: the lock may have been stolen and re-acquired
          # by a live session since our first look (check->rm must not be blind).
          # Notices are BUFFERED (flush_takeover): nothing is printed while the gate is held.
          nl=$'\n'
          if holder_dead "$lp"; then
            takeover_err="${takeover_err}stale lock (holder pid dead), stealing$nl"; rm -rf "$lp"
          elif is_parked "$lp"; then
            # The reason carries the state the hardware was left in. Print it in FULL and
            # to stdout, not stderr: it is the handover note, not a diagnostic.
            takeover_out="${takeover_out}taking over a PARKED lock, held $(age_str $(( $(date +%s) - $(park_since "$lp") ))) by pid $(holder_pid "$lp")$nl"
            takeover_out="${takeover_out}  parked because: $(park_reason "$lp")$nl"
            takeover_out="${takeover_out}  its last note:  $(read_note "$lp")$nl"
            rm -rf "$lp"
          elif lease_expired "$lp"; then
            # The holder's process is ALIVE (a sub-agent's pid is its parent's), so say loudly
            # whose lock this was: if it is still working, it is about to lose the resource.
            ago=$(age_str $(( -LEASE_LEFT ))); osid=$(holder_sid "$lp")
            takeover_out="${takeover_out}TAKING OVER AN EXPIRED LEASE on $canon: held by $(who_str "$(holder_pid "$lp")" "$osid"), lease $(lease_s_of "$lp")s, EXPIRED $ago ago (not renewed)$nl"
            takeover_out="${takeover_out}  its last note:  $(read_note "$lp")$nl"
            takeover_out="${takeover_out}  its pid is still alive; if that session is still working, its 'mine' now says it lost the lock.$nl"
            takeover_err="${takeover_err}WARNING: took over $canon from session $osid (lease expired $ago ago)$nl"
            rm -rf "$lp"
          fi
          rmdir "$lp.steal" 2>/dev/null; gate_release
          continue
        fi
        flush_takeover; echo "BUSY $canon (another session is reclaiming it)"; exit 1
      fi
      flush_takeover
      echo "BUSY $canon — held by:$(lease_note "$lp")$(idle_note "$lp")"; show "$lp"; explain_sibling "$lp"; exit 1
    done
    flush_takeover; echo "BUSY $canon (race)"; exit 1 ;;
  wait)
    # blocking acquire: retry every 2 s until acquired or timeout. From an agent's Bash tool
    # run it in the FOREGROUND with a bounded timeout and repeat it on TIMEOUT:
    #   lock.sh wait <name> "<what>" 540 --session <id>      (tool timeout 600000 ms)
    # Not run_in_background: a sub-agent is never woken by a background job's completion.
    # Not nohup/dtach: a detached wait has no agent ancestor and exits 2 at once, unless a
    # long-lived holder names itself with AGENT_LOCK_OWNER_PID (see owner_pid).
    sanitize "$name"
    # wait <name> [note] [timeout] [--timeout S] [--session S]. The note is strictly $3; the
    # timeout may follow it positionally. Options used to be read only from $5 on, so
    # `wait x "note" --session S` took "--session" as the TIMEOUT and silently dropped S.
    note_not_option wait "${3:-}"
    wait_note=${3:-}; timeout=3600; w_ack=no; w_brief=no
    shift 3 2>/dev/null || shift $#
    if [ "$#" -gt 0 ] && [[ "$1" =~ ^[0-9]+$ ]]; then timeout=$1; shift; fi
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --timeout) [ "$#" -ge 2 ] || { echo "missing argument for --timeout" >&2; exit 2; }
                   shift; timeout=$1 ;;
        --session) [ "$#" -ge 2 ] || { echo "missing argument for --session" >&2; exit 2; }
                   shift; take_session "$1" ;;
        --session=*) take_session "${1#*=}" ;;
        --ack)   w_ack=yes ;;      # passed through to acquire (fsw_sweep: wait rig n 5 --ack)
        --brief) w_brief=yes ;;
        *) echo "unknown argument for wait: $1" >&2; exit 2 ;;
      esac
      shift
    done
    finalize_session
    [[ "$timeout" =~ ^[0-9]+$ ]] || { echo "bad timeout: $timeout" >&2; exit 2; }
    if resolve "$name" 2>/dev/null; then need_session_check "$CANON"; fi
    deadline=$(( $(date +%s) + timeout ))
    acq_cmd=("$0" acquire "$name" "$wait_note")
    [ -n "$MYSID" ] && acq_cmd+=("--session" "$MYSID")
    [ "$w_ack" = yes ] && acq_cmd+=("--ack")
    [ "$w_brief" = yes ] && acq_cmd+=("--brief")
    # A wait must die with its caller. Orphaned (caller's shell gone, reparented to launchd)
    # it used to go on polling and later take the lock as pid=unknown -- never stale, so
    # held until someone --forced it. Checked every iteration, before each attempt.
    orig_ppid=$PPID
    # Already reparented to launchd/init before we even read $PPID (the caller exited first):
    # comparing against 1 forever would never notice. Measured in test 42.
    [ "$orig_ppid" -gt 1 ] 2>/dev/null || {
      echo "wait: caller is already gone (parent pid ${orig_ppid:-?}) -- NOT acquiring $name" >&2; exit 2; }
    # A signal must not strand a lock: bash runs the trap only after the in-flight acquire
    # returns, so record it and give back anything that acquire just took.
    stop=""; trap 'stop=143' TERM; trap 'stop=130' INT; trap 'stop=129' HUP
    while :; do
      [ -n "$stop" ] && exit "$stop"
      cur_ppid=$(ps -o ppid= -p $$ 2>/dev/null | tr -d '[:space:]')
      [ "$cur_ppid" = "$orig_ppid" ] || {
        echo "wait: caller (pid $orig_ppid) is gone -- giving up, NOT acquiring $name" >&2; exit 2; }
      [ "$(owner_pid)" != unknown ] || {
        echo "wait: no owning agent process any more -- giving up, NOT acquiring $name" >&2; exit 2; }
      out=$("${acq_cmd[@]}" 2>&1); rc=$?
      if [ "$rc" = 0 ]; then
        if [ -n "$stop" ]; then
          "$0" release "$name" ${MYSID:+--session "$MYSID"} >/dev/null 2>&1
          echo "wait: interrupted as the lock landed; released $name again" >&2; exit "$stop"
        fi
        echo "$out"; exit 0
      fi
      # 2 is an error (bad name, unreadable registry) and 1-with-a-flag will never clear
      # on its own — neither is worth retrying for an hour.
      [ "$rc" = 2 ] && { echo "error while waiting for $name:" >&2; printf '%s\n' "$out" >&2; exit 2; }
      # Our OWN hold ran out: it clears only when we release, so waiting would never succeed.
      case "$out" in *"HOLD LIMIT"*) printf '%s\n' "$out" >&2; exit 1 ;; esac
      resolve "$name" || CANON=$name
      if [ "$w_ack" != yes ] && [ -e "$(flagpath "$CANON")" ]; then
        echo "$name is FLAGGED; waiting would never succeed. Resolve the flag first." >&2; exit 1
      fi
      if [ "$(date +%s)" -ge "$deadline" ]; then
        echo "TIMEOUT waiting for $name after ${timeout}s -- still held by:"
        lp=$(lockpath "$CANON"); ME=$(owner_pid)
        show "$lp"; explain_sibling "$lp"; exit 1
      fi
      [ -n "$stop" ] && exit "$stop"
      sleep 2
    done ;;
  run)
    # acquire (blocking), run a command, release NO MATTER HOW WE LEAVE. This is the only
    # shape in which forgetting to release is impossible, and it is the one to reach for:
    #   lock.sh run rig "flashing" -- ./flash.sh 30
    #   lock.sh run rig "flashing" --timeout 1800 -- ./flash.sh 30
    # A lock this SAME (pid, session) already held before `run` started is taken over: wait
    # returns "already held", and run releases it on the way out like one it took itself.
    # Run inside an existing hold expecting to keep it afterwards, and you will not.
    # The exit status is the COMMAND's, never the launcher's. That matters because the
    # documented way to wait was "run `wait` in the background", and a backgrounded launch
    # returns 0 immediately -- so an agent reads 0, believes it holds the lock, and touches
    # the hardware anyway. Measured 2026-09-14.
    sanitize "$name"
    shift 2 || true
    runnote=""; runto=3600
    while [ "$#" -gt 0 ] && [ "${1:-}" != "--" ]; do
      case "$1" in
        --timeout) [ "$#" -ge 2 ] || { echo "missing argument for --timeout" >&2; exit 2; }
                   shift; runto=$1
                   # Checked HERE: passed on to wait, a bad value used to surface as the
                   # misleading "unknown argument for wait: abc".
                   [[ "$runto" =~ ^[0-9]+$ ]] || {
                     echo "run: bad --timeout '$runto' (whole seconds)" >&2; exit 2; } ;;
        --session) [ "$#" -ge 2 ] || { echo "missing argument for --session" >&2; exit 2; }
                   shift; take_session "$1" ;;
        --session=*) take_session "${1#*=}" ;;
        -*) echo "unknown option for run: $1" >&2; exit 2 ;;
        *)  [ -z "$runnote" ] && runnote=$(clean_note "$1") || { echo "unexpected argument: $1" >&2; exit 2; } ;;
      esac
      shift || true
    done
    [ "${1:-}" = "--" ] || { echo "usage: lock.sh run <name> \"note\" [--timeout S] [--session NAME] -- <command...>" >&2; exit 2; }
    shift
    [ "$#" -gt 0 ] || { echo "usage: lock.sh run <name> \"note\" [--timeout S] [--session NAME] -- <command...>" >&2; exit 2; }
    finalize_session
    # Resolve first so the trap releases the same name acquire took.
    resolve "$name" || CANON=$name
    runcanon=$CANON
    need_session_check "$runcanon"
    # The SAME identity must reach both wait and release: a release without the session
    # would be refused as "another session's lock" and leak the lock on every exit path.
    sess_args=(); [ -n "$MYSID" ] && sess_args=(--session "$MYSID")
    # The lock must come back on every path: normal exit, a failing command, or a signal.
    # The traps go in BEFORE the wait: installed after it, a TERM/INT that arrived while
    # still waiting killed run and left the wait child to take the lock later for nobody.
    # The wait runs in the background so `wait $!` is interruptible and the trap can stop it;
    # `release` checks identity itself, so releasing on every path is safe.
    released=no; waitpid=""; renewpid=""
    stop_renewer() { [ -n "$renewpid" ] || return 0
      kill -TERM "$renewpid" 2>/dev/null; wait "$renewpid" 2>/dev/null; renewpid=""; }
    # The renewer goes BEFORE the release: left running, its next `mine` would report a lost
    # lock that was simply given back.
    # release exits 3 when the steal gate is merely busy: retry -- bounded by ELAPSED time
    # (~20 s; each try itself waits ~2 s on the gate, so a try count ran 100-120 s) -- and
    # report the real outcome. It used to print RELEASED and exit 0 while the lock was still
    # HELD (review 2026-10-06, c5).
    REL_RC=0; REL_OUT=""
    release_once() { [ "$released" = yes ] && return "$REL_RC"; released=yes; stop_renewer
      local deadline=$(( $(date +%s) + 20 ))
      while :; do
        REL_OUT=$("$0" release "$runcanon" ${sess_args[@]+"${sess_args[@]}"} 2>&1); REL_RC=$?
        [ "$REL_RC" = 3 ] && [ "$(date +%s)" -lt "$deadline" ] || break
        sleep 0.5
      done
      return "$REL_RC"; }
    not_released() { # $1 = what the command did. Exit 76 (normal end) is documented.
      local left="" rlp2; rlp2=$(lockpath "$runcanon")
      snap_read "$rlp2" && snap_leased && [ "$LEASE_LEFT" -ge 0 ] && left="lease ends in ${LEASE_LEFT} s; "
      echo "NOT RELEASED: $runcanon (${left}retry 'lock.sh release $runcanon${MYSID:+ --session $MYSID}');" \
           "$1; release said: $(printf '%s' "$REL_OUT" | head -1)" >&2; }
    # The leased path runs the command as its OWN process group (pgid = cmdpgid), so stopping
    # it reaches grandchildren too: killing only the direct child left e.g. `sleep 41` running
    # after the lock was given back (review 2026-10-06, b3). A process that leaves the group
    # (setsid, daemonising) is beyond reach -- documented.
    cmdpgid=""; lost=no; GROUP_SURVIVED=no
    group_alive() { # any NON-zombie process still in the command's group?
      [ -n "$cmdpgid" ] || return 1
      [ -n "$(ps -A -o pgid=,stat= 2>/dev/null | awk -v g="$cmdpgid" '$1==g && $2 !~ /^Z/ {print; exit}')" ]; }
    stop_group() { # $1 = first signal (TERM/INT/HUP); KILL after 10 s; returns once it is gone
      [ -n "$cmdpgid" ] || return 0
      kill -"$1" -- "-$cmdpgid" 2>/dev/null
      local k=0
      while group_alive && [ "$k" -lt 100 ]; do sleep 0.1; k=$((k+1)); done
      if group_alive; then
        kill -KILL -- "-$cmdpgid" 2>/dev/null; k=0
        while group_alive && [ "$k" -lt 50 ]; do sleep 0.1; k=$((k+1)); done
      fi
      group_alive && GROUP_SURVIVED=yes
      wait "$cmdpgid" 2>/dev/null; cmdpgid=""; }
    on_sig() { # $1 = exit status, $2 = the signal, forwarded as-is to the command's group
      if [ -n "$waitpid" ]; then
        kill -TERM "$waitpid" 2>/dev/null; wait "$waitpid" 2>/dev/null; waitpid=""
      fi
      # The command is stopped BEFORE the lock goes back: releasing first would leave it
      # running unprotected. (Only the leased path backgrounds it, see below.)
      stop_group "$2"
      release_once || not_released "the command was stopped by SIG$2"
      exit "$1"; }
    trap 'on_sig 130 INT' INT
    trap 'on_sig 143 TERM' TERM
    trap 'on_sig 129 HUP' HUP
    trap 'release_once' EXIT
    "$0" wait "$runcanon" "$runnote" "$runto" ${sess_args[@]+"${sess_args[@]}"} &
    waitpid=$!
    wait "$waitpid"; wrc=$?; waitpid=""
    if [ "$wrc" != 0 ]; then
      released=yes   # nothing acquired; never release a lock we did not take here
      echo "run: never acquired $runcanon, command NOT started" >&2; exit 2
    fi
    # A LEASED lock must outlive a command longer than its lease, so a renewer calls `mine`
    # (which renews) every lease/3 s while the command runs.
    #   * mine 0     -> fine.
    #   * mine 3/2   -> cannot tell right now (gate busy): retry every 0.5 s. It is a loss
    #                   only once the lease has really expired.
    #   * mine 1     -> LOST (lease expired, taken over, or --force released): the renewer
    #                   signals run, which TERMs the command (KILL after 10 s) and exits 75.
    # The renewer used to give up on ONE failed mine and let the command run on, and run then
    # returned the command's rc=0 (review 2026-10-06, repros C and D). To be stoppable, the
    # command runs in the background (stdin passed through) under a trap-interruptible wait.
    # A lock WITHOUT a lease keeps the old foreground path exactly.
    rlp=$(lockpath "$runcanon")
    if is_leased "$rlp"; then
      rls=$(lease_s_of "$rlp"); riv=$(( ${rls:-3} / 3 )); [ "$riv" -ge 1 ] || riv=1
      run_pid=$$; ME=$(owner_pid)
      trap 'lost=yes' USR1
      (
        rsp=""; nap=$riv
        trap '[ -n "$rsp" ] && kill "$rsp" 2>/dev/null; exit 0' TERM
        while :; do
          # !maxhold: wake just after the hold ends, not up to lease/3 s later (review 2026-10-14).
          rh=$(hold_until_of "$rlp"); rnow=$(date +%s)
          if [[ "$rh" =~ ^[1-9][0-9]{0,10}$ ]] && [ "$nap" != 0.5 ] && [ $(( rh + 1 - rnow )) -lt "$nap" ]; then
            nap=$(( rh + 1 - rnow )); [ "$nap" -ge 1 ] || nap=1
          fi
          sleep "$nap" & rsp=$!; wait "$rsp"; rsp=""
          kill -0 "$run_pid" 2>/dev/null || exit 0
          "$0" mine "$runcanon" ${sess_args[@]+"${sess_args[@]}"} --quiet; mrc=$?
          if [ "$mrc" = 0 ]; then nap=$riv; continue; fi
          # "Cannot tell" (3) is retried -- but only while one snapshot still shows the lock
          # as OURS with an unexpired lease. Once it is gone, retrying would only hide a loss.
          if [ "$mrc" != 1 ] && snap_read "$rlp" && snap_owned && snap_leased && [ "$LEASE_LEFT" -ge 0 ]; then
            nap=0.5; continue
          fi
          echo "run: LOST the lock on $runcanon while the command was running (mine rc=$mrc:" \
               "lease expired, taken over or force-released) -- stopping the command" >&2
          kill -USR1 "$run_pid" 2>/dev/null; exit 1
        done
      ) &
      renewpid=$!
      # Own process group (set -m), which also gives the command DEFAULT SIGINT/SIGQUIT: a
      # plain `cmd &` in a script starts with them IGNORED, so Ctrl-C/KeyboardInterrupt never
      # fired (review 2026-10-06). A background group cannot read the terminal (SIGTTIN
      # would stop it while the lease kept renewing), so a tty stdin becomes /dev/null.
      if [ -t 0 ]; then
        echo "run: on a leased lock the command runs as its own process group and cannot read" \
             "the terminal; its stdin is /dev/null" >&2
        set -m; "$@" </dev/null & cmdpgid=$!; set +m
      else
        set -m; "$@" <&0 & cmdpgid=$!; set +m
      fi
      while :; do
        [ "$lost" = yes ] && break      # a loss signalled before we reached `wait`
        wait "$cmdpgid"; runrc=$?
        [ "$lost" = yes ] && break
        kill -0 "$cmdpgid" 2>/dev/null || break
      done
      if [ "$lost" = yes ]; then
        stop_group TERM; release_once
        trap - INT TERM HUP EXIT USR1
        # Exit 75 is ambiguous on its own (a command may exit 75 too), so the loss is ALSO
        # announced by this distinctive line; branch on it, not on the code alone.
        if [ "$GROUP_SURVIVED" = yes ]; then
          echo "LOCK LOST: lock.sh run lost $runcanon mid-command; the command's process group did NOT" \
               "all die after TERM+KILL. Exit 75 is lock.sh's, not the command's." >&2
        else
          echo "LOCK LOST: lock.sh run lost $runcanon mid-command; the command's whole process group" \
               "was stopped (TERM, KILL after 10 s). Exit 75 is lock.sh's, not the command's; its work" \
               "since the loss was NOT protected by the lock." >&2
        fi
        exit 75
      fi
      # The command itself finished: anything it left running in its group is still using the
      # resource, so it is stopped before the lock goes back.
      if group_alive; then
        echo "run: the command left processes running in its group; stopping them before releasing $runcanon" >&2
        stop_group TERM
      fi
      cmdpgid=""
      if ! release_once; then
        trap - INT TERM HUP EXIT USR1
        not_released "the command exited $runrc"; exit 76
      fi
      trap - INT TERM HUP EXIT USR1
      if [ "$GROUP_SURVIVED" = yes ]; then
        echo "RELEASED $runcanon (lock.sh run; command exit $runrc) -- WARNING: processes of the" \
             "command's group survived TERM+KILL and may still use the resource" >&2
      else
        echo "RELEASED $runcanon (lock.sh run; command exit $runrc)" >&2
      fi
      exit $runrc
    fi
    "$@"; runrc=$?
    if ! release_once; then
      trap - INT TERM HUP EXIT
      not_released "the command exited $runrc"; exit 76
    fi
    trap - INT TERM HUP EXIT
    echo "RELEASED $runcanon (lock.sh run; command exit $runrc)" >&2
    exit $runrc ;;
  note)
    sanitize "$name"; canon_or_literal "$name"; canon=$CANON; lp=$(lockpath "$canon")
    note_not_option note "${3:-}"
    new=$(clean_note "${3:-}")
    shift 3 2>/dev/null || shift $#
    parse_opts "--force" "$@"
    [ -n "$new" ] || { echo "usage: lock.sh note <name> \"text\" [--session S] [--force]" >&2; exit 2; }
    [ -d "$lp" ] || { echo "not locked: $canon (a note needs a lock; see 'flag' for a" \
                           "warning that outlives one)" >&2; exit 2; }
    ME=$(owner_pid); hp=$(holder_pid "$lp")
    if ! owned_by_me "$lp" && [ "$OPT_FORCE" != yes ]; then
      echo "held by another session ($(who_str "$hp" "$(holder_sid "$lp")"); we are" \
           "$(who_str "$ME" "$MYSID")); use --force to amend anyway:" >&2
      show "$lp" >&2; explain_sibling "$lp" >&2; exit 1
    fi
    if owned_by_me "$lp"; then
      # Our own lock: amend under the gate (see owner_gate). On a leased lock, refuse if the
      # lease already ran out, else amend AND renew. --force may still amend the TEXT of our
      # expired lock, but never renews it: that would revive a lock we lost.
      if is_leased "$lp" && [ "$LEASE_LEFT" -lt 0 ] && [ "$OPT_FORCE" != yes ]; then
        lost_lease_msg "$canon" "$lp" >&2; exit 1; fi
      owner_gate "$lp"; g=$?
      [ "$g" = 2 ] && { busy_or_lost note "$canon" "$lp"; }
      if [ "$g" = 0 ]; then
        if ! owned_by_me "$lp"; then drop_gate "$lp"; echo "note: $canon was taken over -- not yours" >&2; exit 1; fi
        if lease_expired "$lp"; then
          if [ "$OPT_FORCE" != yes ]; then drop_gate "$lp"; lost_lease_msg "$canon" "$lp" >&2; exit 1; fi
          set_note "$lp" "$new" || { drop_gate "$lp"; exit 2; }; drop_gate "$lp"
          echo "NOTE UPDATED $canon: $new (--force: the lease stays EXPIRED and was NOT renewed; you do not hold it)"
          exit 0
        fi
        set_note "$lp" "$new" || { drop_gate "$lp"; exit 2; }
        if is_leased "$lp"; then renew_lease "$lp"; drop_gate "$lp"
          echo "NOTE UPDATED $canon: $new (lease renewed)"; exit 0; fi
        drop_gate "$lp"; echo "NOTE UPDATED $canon: $new"; exit 0
      fi
    fi
    set_note "$lp" "$new" || exit 2
    echo "NOTE UPDATED $canon: $new" ;;
  park)
    # the holder declares it is done with the resource but cannot release yet (waiting on
    # a human, keeping the board powered for a follow-up). Others may then take it.
    sanitize "$name"; canon_or_literal "$name"; canon=$CANON; lp=$(lockpath "$canon")
    note_not_option park "${3:-}"
    reason=$(clean_note "${3:-}")
    shift 3 2>/dev/null || shift $#
    parse_opts "" "$@"
    [ -n "$reason" ] || { echo "usage: lock.sh park <name> \"why you are parked / what state the hardware is in\"" >&2; exit 2; }
    [ -d "$lp" ] || { echo "not locked: $canon (nothing to park)" >&2; exit 2; }
    ME=$(owner_pid); hp=$(holder_pid "$lp")
    # Only the holder may park. Parking someone else's lock would be stealing it by proxy,
    # which is the exact thing the steal rules exist to prevent.
    owned_by_me "$lp" || {
      echo "refusing: $canon is held by $(who_str "$hp" "$(holder_sid "$lp")"), not by this" \
           "session ($(who_str "$ME" "$MYSID"))." >&2
      explain_sibling "$lp" >&2
      echo "Only the holder may park a lock; it is a handover, not a seizure." >&2; exit 1; }
    # Gated (see owner_gate): ungated, a park racing a takeover could land in the TAKER's
    # fresh lock and hand it to a third session. An expired lease is refused: not ours.
    if is_leased "$lp" && [ "$LEASE_LEFT" -lt 0 ]; then lost_lease_msg "$canon" "$lp" >&2; exit 1; fi
    owner_gate "$lp"; g=$?
    [ "$g" = 2 ] && { busy_or_lost park "$canon" "$lp"; }
    if [ "$g" = 0 ]; then
      if ! owned_by_me "$lp" || lease_expired "$lp"; then
        drop_gate "$lp"; echo "park: $canon is no longer yours (lease expired or taken over)" >&2; exit 1
      fi
      printf '%s\n%s\n' "$(date +%s)" "$reason" > "$(parkpath "$lp")" || { drop_gate "$lp"; exit 2; }
      drop_gate "$lp"
    else
      printf '%s\n%s\n' "$(date +%s)" "$reason" > "$(parkpath "$lp")" || exit 2
    fi
    echo "PARKED $canon: $reason"
    echo "It stays yours until someone takes it; 'lock.sh unpark $canon' cancels, 'release' still works." ;;
  unpark)
    sanitize "$name"; canon_or_literal "$name"; canon=$CANON; lp=$(lockpath "$canon")
    shift 2 2>/dev/null || shift $#
    parse_opts "" "$@"
    [ -d "$lp" ] || { echo "not locked: $canon" >&2; exit 2; }
    ME=$(owner_pid); hp=$(holder_pid "$lp")
    owned_by_me "$lp" || {
      echo "refusing: $canon is held by $(who_str "$hp" "$(holder_sid "$lp")"), not this" \
           "session ($(who_str "$ME" "$MYSID"))" >&2
      explain_sibling "$lp" >&2; exit 1; }
    is_parked "$lp" || { echo "$canon is not parked"; exit 0; }
    # Unpark under the steal gate. A taker checks is_parked and removes the lock under that
    # gate; unparking outside it could print UNPARKED in the same instant the lock was taken,
    # and the old holder would go on believing it still held the resource.
    got=no
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      steal_gate "$lp" && { got=yes; gate_hold; break; }; sleep 0.1
    done
    [ "$got" = yes ] || { echo "unpark: $canon is being taken over right now; check 'mine'" >&2; exit 1; }
    if ! owned_by_me "$lp"; then
      drop_gate "$lp"
      echo "refusing: $canon was taken over while parked -- it is NOT yours any more" >&2; exit 1
    fi
    rm -f "$(parkpath "$lp")"; drop_gate "$lp"
    echo "UNPARKED $canon (it is a normal held lock again)" ;;
  flag)
    sanitize "$name"; canon_or_literal "$name"; canon=$CANON; fp=$(flagpath "$canon")
    reason=$(clean_note "${3:-}")
    [ -n "$reason" ] || { echo "usage: lock.sh flag <name> \"reason\"" >&2; exit 2; }
    # Write-then-rename, not truncate-in-place: two concurrent flag writers truncating the
    # same file can leave the tail of the longer warning under the head of the shorter one,
    # and a reader can catch the file mid-write.
    ftmp="$fp.tmp.$$"
    printf 'flagged=%s\nby=%s\nreason=%s\n' \
      "$(date '+%Y-%m-%d %H:%M:%S')" "$USER" "$reason" > "$ftmp" || { rm -f "$ftmp"; exit 2; }
    mv -f "$ftmp" "$fp" || { rm -f "$ftmp"; exit 2; }
    [ -e "$fp" ] || { echo "flag vanished immediately after writing (concurrent unflag?)" >&2; exit 2; }
    echo "FLAGGED $canon: $reason"
    echo "  This OUTLIVES the lock. acquire will refuse until: lock.sh unflag $canon" ;;
  unflag)
    sanitize "$name"; canon_or_literal "$name"; canon=$CANON; fp=$(flagpath "$canon")
    [ -e "$fp" ] || { echo "not flagged: $canon"; exit 0; }
    rm -f "$fp" && echo "UNFLAGGED $canon" || exit 2 ;;
  mine)
    # "Do I hold this?" as an EXIT STATUS. `status` says HELD, which is equally true when a
    # PEER holds it -- a daemon that branched on HELD flashed a board out from under another
    # session's measurement on 2026-09-15. Anything long-running must ask THIS instead, every
    # cycle, and stop touching the device the moment it answers no.
    #   0 = ours, 1 = not ours (free, someone else's, or OUR LEASE EXPIRED), 2 = bad name,
    #   3 = CANNOT TELL right now: our lease needs renewing but the .steal gate stayed busy
    #       for ~2 s. Treat it like "not ours" (stop touching the resource) and ask again;
    #       once the lease has really run out the answer becomes 1.
    # On a leased lock `mine` is also the RENEWAL: a holder that calls it at least every
    # lease/2 seconds keeps the lock. It stays cheap -- the gated rewrite happens only when
    # the last renewal is older than min(10 s, lease/10), so a tight poll loop does not
    # rewrite info on every call.
    sanitize "$name"; canon_or_literal "$name"; canon=$CANON; lp=$(lockpath "$canon")
    shift 2 2>/dev/null || shift $#
    # --min-left S: answer 0 only if, after renewing, at least S seconds of lease remain. With
    # !maxhold a plain 0 can mean "1 s left", so a step that may take S seconds asks for S.
    min_left=0; m_args=()
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --min-left) [ "$#" -ge 2 ] || { echo "missing argument for --min-left" >&2; exit 2; }
                    min_left=$2; shift 2 ;;
        --min-left=*) min_left=${1#*=}; shift ;;
        *) m_args+=("$1"); shift ;;
      esac
    done
    [[ "$min_left" =~ ^(0|[1-9][0-9]{0,5})$ ]] || { echo "bad --min-left: $min_left" >&2; exit 2; }
    parse_opts "--quiet" ${m_args[@]+"${m_args[@]}"}
    ME=$(owner_pid)
    # Every verdict below comes from ONE snapshot of info (owner and lease together).
    if [ -d "$lp" ] && snap_read "$lp" && snap_owned; then
      if ! snap_leased; then
        [ "$OPT_QUIET" = yes ] || echo "MINE $canon ($(who_str "$ME" "$MYSID"))"; exit 0
      fi
      if [ "$LEASE_LEFT" -lt 0 ]; then
        # A slow holder: the lock may still sit there under our name, but anyone may take it
        # now, so it is not ours to use. Fail closed.
        [ "$OPT_QUIET" = yes ] || { printf 'NOT MINE %s: ' "$canon"; lost_lease_msg "$canon" "$lp"; }
        exit 1
      fi
      # Skip the rewrite while the lease is fresh: renewed within min(10 s, lease/10).
      mls=$SNAP_LS; [[ "$mls" =~ ^[1-9][0-9]{0,5}$ ]] || mls=0
      mmargin=$(( mls / 10 )); [ "$mmargin" -le 10 ] || mmargin=10
      if [ "$LEASE_LEFT" -lt $(( mls - mmargin )) ]; then
        if ! with_gate "$lp"; then
          # A busy gate is not a loss -- but `release --force` needs no gate, so the lock may
          # have changed hands meanwhile. Re-read owner AND lease in one snapshot.
          if ! snap_read "$lp" || ! snap_owned; then
            [ "$OPT_QUIET" = yes ] || echo "NOT MINE $canon (released or taken over meanwhile)"; exit 1
          fi
          snap_leased || LEASE_LEFT=-1
          if [ "$LEASE_LEFT" -lt 0 ]; then
            [ "$OPT_QUIET" = yes ] || { printf 'NOT MINE %s: ' "$canon"; lost_lease_msg "$canon" "$lp"; }
            exit 1
          fi
          # With at least half the lease left nobody can take it without --force (a taker
          # needs it EXPIRED), so the answer is still yes; renewal waits for the next call.
          if [ "$LEASE_LEFT" -ge $(( mls / 2 )) ] && [ "$LEASE_LEFT" -ge "$min_left" ]; then
            [ "$OPT_QUIET" = yes ] || echo "MINE $canon ($(who_str "$ME" "$MYSID"); lease $(age_str "$LEASE_LEFT") left, renewal deferred: gate busy)"
            exit 0
          fi
          [ "$OPT_QUIET" = yes ] || echo "CANNOT TELL $canon right now (steal gate busy, lease $(age_str "$LEASE_LEFT") left): stop, then ask again"
          exit 3
        fi
        if ! snap_read "$lp" || ! snap_owned || ! snap_leased || [ "$LEASE_LEFT" -lt 0 ]; then
          drop_gate "$lp"; [ "$OPT_QUIET" = yes ] || echo "NOT MINE $canon (lost while renewing)"; exit 1
        fi
        renew_lease "$lp" || { drop_gate "$lp"; echo "cannot renew the lease on $canon (write failed)" >&2; exit 3; }
        drop_gate "$lp"; snap_read "$lp"; snap_leased
      fi
      if [ "$LEASE_LEFT" -lt "$min_left" ]; then
        [ "$OPT_QUIET" = yes ] || echo "NOT ENOUGH $canon: lease $(age_str "$LEASE_LEFT") left, need ${min_left}s" \
             "(max hold ending?) -- do not start the step; release and wait again"
        exit 1
      fi
      [ "$OPT_QUIET" = yes ] || echo "MINE $canon ($(who_str "$ME" "$MYSID"); lease $(age_str "$LEASE_LEFT") left)"
      exit 0
    fi
    hp=$(holder_pid "$lp" 2>/dev/null)
    [ "$OPT_QUIET" = yes ] || {
      if [ -d "$lp" ]; then
        echo "NOT MINE $canon (held by $(who_str "$hp" "$(holder_sid "$lp")"); we are $(who_str "$ME" "$MYSID"))"
        explain_sibling "$lp"
      else echo "NOT MINE $canon (not locked)"; fi; }
    exit 1 ;;
  want|unwant|wanted)
    # The missing primitive: a way to ASK for a board without taking it. `wait` is a polling
    # loop that registers nothing, so a holder running a long job has no way to learn that
    # anyone is queued behind it, and every cooperative holder ends up inventing its own
    # file convention. This is that convention, in the one place everybody already looks.
    #   want <name> [who]   register interest        (a holder in yield mode releases)
    #   wanted <name>       0 if somebody asked      (for the holder's poll loop)
    #   unwant <name>       withdraw / clear it
    #   The request records the requester's (pid, session). Sibling sub-agents share a pid, so
    #   the session is the only thing that says WHO asked; `wanted` ignores a request filed
    #   by the caller's own identity when that identity carries a session.
    sanitize "$name"; canon_or_literal "$name"; canon=$CANON; wp=$(wantpath "$canon")
    verb=$1
    case "$verb" in
      want) note_not_option want "${3:-}"
            wnote=$(clean_note "${3:-}"); shift 3 2>/dev/null || shift $#; parse_opts "" "$@" ;;
      wanted) shift 2 2>/dev/null || shift $#; parse_opts "--quiet" "$@" ;;
      unwant) shift 2 2>/dev/null || shift $#; parse_opts "--force" "$@" ;;
    esac
    ME=$(owner_pid)
    # Identity rules, applied whenever EITHER side carries a session (pid-only callers keep
    # the old behaviour): you cannot ask for a lock you hold, and only the requester (or
    # --force) withdraws a request -- a sibling clearing it would silently cancel the ask.
    req_who=$(sed -n 's/^who=//p' "$wp" 2>/dev/null | head -1)
    req_sid=$(sed -n 's/^session=//p' "$wp" 2>/dev/null | head -1)
    case "$verb" in
      want)   lpw=$(lockpath "$canon")
              if [ -n "$MYSID" ] && [ -d "$lpw" ] && owned_by_me "$lpw"; then
                echo "you already hold $canon ($(who_str "$ME" "$MYSID")); nothing to ask for" >&2; exit 1
              fi
              printf 'who=%s\nsession=%s\nsince=%s\nnote=%s\n' "$ME" "$MYSID" "$(date '+%F %T')" "$wnote" > "$wp" || exit 2
              echo "WANTED $canon — the holder releases it if it is running in yield mode; otherwise ask."
              [ -d "$(lockpath "$canon")" ] && show "$(lockpath "$canon")"
              exit 0 ;;
      wanted) [ -e "$wp" ] || exit 1
              if [ -n "$MYSID" ] && [ "$ME" != unknown ] \
                 && [ "$(sed -n 's/^who=//p' "$wp" | head -1)" = "$ME" ] \
                 && [ "$(sed -n 's/^session=//p' "$wp" | head -1)" = "$MYSID" ]; then
                [ "$OPT_QUIET" = yes ] || echo "only your own request is pending"; exit 1
              fi
              [ "$OPT_QUIET" = yes ] || sed 's/^/  /' "$wp"; exit 0 ;;
      unwant) [ -e "$wp" ] || { echo "no request pending for $canon"; exit 0; }
              if [ "$OPT_FORCE" != yes ] && { [ -n "$MYSID" ] || [ -n "$req_sid" ]; } \
                 && { [ "$ME" = unknown ] || [ "$req_who" != "$ME" ] || [ "$req_sid" != "$MYSID" ]; }; then
                echo "refusing: the request on $canon was filed by $(who_str "$req_who" "$req_sid")," \
                     "not by us ($(who_str "$ME" "$MYSID")); --force to clear it anyway" >&2; exit 1
              fi
              rm -f "$wp" || exit 2; echo "cleared any request for $canon"; exit 0 ;;
    esac ;;
  release)
    sanitize "$name"; canon_or_literal "$name"; canon=$CANON; lp=$(lockpath "$canon")
    shift 2 2>/dev/null || shift $#
    # Legacy callers write `release rig "done"`; the old script ignored the word. Warn and
    # drop ONE plain word rather than refuse -- refusing here would leak the lock.
    if [ "$#" -gt 0 ] && [ "${1#-}" = "$1" ]; then
      echo "warning: release takes no note; ignoring '$1'" >&2; shift
    fi
    parse_opts "--force" "$@"
    [ -d "$lp" ] || { echo "not locked: $canon"; exit 0; }
    ME=$(owner_pid); hp=$(holder_pid "$lp")
    if ! owned_by_me "$lp" && [ "$OPT_FORCE" != yes ]; then
      echo "held by another session ($(who_str "$hp" "$(holder_sid "$lp")"); we are" \
           "$(who_str "$ME" "$MYSID")); use --force to break:" >&2
      show "$lp" >&2; explain_sibling "$lp" >&2
      if [ -n "$MYSID" ] && is_leased "$lp"; then
        echo "  If this session held $canon earlier, its lease ran out and it was taken over:" \
             "you did NOT hold it since then." >&2
      fi
      exit 1
    fi
    g=1; [ "$OPT_FORCE" != yes ] && { owner_gate "$lp"; g=$?; }
    [ "$g" = 2 ] && { busy_or_lost release "$canon" "$lp"; }
    if [ "$g" = 0 ]; then
      # Our own lock: remove it only under the gate, after re-checking it is still ours --
      # an expired lease may be mid-takeover, and rm -rf would delete the TAKER's lock.
      if ! owned_by_me "$lp"; then
        drop_gate "$lp"; echo "release: $canon was taken over -- you no longer held it" >&2; exit 1
      fi
      if lease_expired "$lp"; then
        rm -rf "$lp"; rm -f "$(wantpath "$canon")"; drop_gate "$lp"
        echo "NOT HELD: your lease on $canon had EXPIRED $(age_str $(( -LEASE_LEFT ))) ago, so you no" \
             "longer held it; anything done since then was UNPROTECTED. (Nobody had taken it; the" \
             "stale lock is now cleared.)" >&2
        exit 1
      fi
      rm -rf "$lp" || { drop_gate "$lp"; exit 2; }
      drop_gate "$lp"
    elif [ "$OPT_FORCE" = yes ]; then
      # --force takes the gate too (with with_gate's ~2 s timeout), so it cannot interleave
      # with a renewal, note or takeover in progress. A gate that stays busy does not block
      # the override (a stale one is broken after 60 s anyway): it forces, and says so.
      if with_gate "$lp"; then
        rm -rf "$lp" || { drop_gate "$lp"; exit 2; }
        drop_gate "$lp"
      else
        echo "warning: the steal gate on $canon stayed busy; forcing the release without it" >&2
        rm -rf "$lp" || exit 2
      fi
    else
      rm -rf "$lp" || exit 2
    fi
    rm -f "$(wantpath "$canon")"      # the hand-over happened; the request is served
    if [ -e "$(flagpath "$canon")" ]; then
      echo "RELEASED $canon — NOTE: it is still FLAGGED:"
      sed 's/^/  /' "$(flagpath "$canon")" 2>/dev/null
    else
      echo "RELEASED $canon"
    fi ;;
  status)
    sanitize "$name"; canon_or_literal "$name"; canon=$CANON; lp=$(lockpath "$canon")
    shift 2 2>/dev/null || shift $#
    parse_opts "--brief" "$@"
    fp=$(flagpath "$canon"); flagged=no
    if [ -e "$fp" ]; then
      flagged=yes; echo "FLAGGED $canon:"
      [ -r "$fp" ] && show_flag "$fp" || {
        echo "  (flag exists but is UNREADABLE)"; echo "UNKNOWN $canon"; exit 2; }
    fi
    if [ -d "$lp" ]; then
      hwho=" by $(who_str "$(holder_pid "$lp")" "$(holder_sid "$lp")")"
      ME=$(owner_pid); owned_by_me "$lp" && hwho="$hwho (YOURS)"
      holder_dead "$lp" && echo "HELD $canon$hwho [stale — holder pid dead]" \
        || echo "HELD $canon$hwho$(park_note "$lp")$(lease_note "$lp")$(idle_note "$lp")"
      show "$lp"; exit 1
    fi
    # A non-directory at the lock path is not "free": something occupies the name and we
    # cannot say what. Reporting FREE here is the fail-open the whole script exists to avoid.
    [ -e "$lp" ] || [ -L "$lp" ] && { echo "UNKNOWN $canon — $lp exists but is not a lock" \
      "directory; refusing to call it free" >&2; exit 2; }
    [ "$flagged" = yes ] && { echo "FREE $canon (but FLAGGED — acquire will refuse)"; exit 1; }
    echo "FREE $canon"; exit 0 ;;
  list)
    [ -r "$DIR" ] && [ -x "$DIR" ] || { echo "cannot read $DIR" >&2; exit 2; }
    found=0
    for lp in "$DIR"/*.lock; do
      [ -d "$lp" ] || continue; found=1
      n=$(basename "$lp" .lock)
      holder_dead "$lp" && s=stale || { is_parked "$lp" && s=parked || { lease_expired "$lp" && s=expired || s=held; }; }
      if [ -r "$lp/info" ]; then
        echo "$n [$s]: $(tr '\n' ' ' < "$lp/info" 2>/dev/null)"
      else
        # No readable info: unknown owner, so it is never stale and never auto-stolen.
        echo "$n [$s]: (info missing or unreadable — owner unknown, needs --force)"
      fi
    done
    for fp in "$DIR"/*.flag; do
      [ -e "$fp" ] || continue; found=1
      echo "$(basename "$fp" .flag) [FLAGGED]: $(tr '\n' ' ' < "$fp" 2>/dev/null)"
    done
    [ "$found" = 0 ] && echo "no locks held"; exit 0 ;;
  top|monitor|watch)
    shift || true
    exec "$HERE/lock-top" "$@" ;;
  resolve)
    sanitize "$name"
    resolve "$name"; rrc=$?
    [ "$rrc" = 0 ] && { echo "$CANON"; exit 0; }
    unknown_die "$name" "$rrc" ;;
  newsession)
    # A fresh session id for a sub-agent, with no help from the harness. Sub-agents of one
    # Claude Code session share its pid, so without a distinct id they share every lock.
    #   S=$(lock.sh newsession fil)   ->  fil-3f9a0c71d2
    label=${name:-sa}
    [[ "$label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$ ]] || {
      echo "bad session label '$label': 1-32 of [A-Za-z0-9._-], starting with a letter or digit" >&2; exit 2; }
    for _ in 1 2 3; do   # never print the documented example id, which norm_sid refuses
      r=$(od -An -N5 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')
      [[ "$r" =~ ^[0-9a-f]{10}$ ]] || { echo "cannot read /dev/urandom for a session id" >&2; exit 2; }
      [ "$label-$r" != "$EXAMPLE_SID" ] && { echo "$label-$r"; exit 0; }
    done
    echo "cannot mint a session id" >&2; exit 2 ;;
  *)
    echo "usage: lock.sh acquire <name> [note] [--new] [--ack] [--brief] | release <name> [--force]" >&2
    echo "       lock.sh note <name> \"text\" [--force] | flag <name> \"reason\" | unflag <name>" >&2
    printf '%s\n' \
      "       lock.sh status <name> | list | top [filter] | resolve <name> | wait <name> [note] [timeout]" \
      "       lock.sh park <name> \"reason\" | unpark <name>" \
      "       lock.sh mine <name> [--quiet]                              # exit 0 only if WE hold it" \
      "       lock.sh want <name> [who] | wanted <name> | unwant <name>  # ask a holder to hand it over" \
      "       lock.sh run <name> \"note\" [--timeout S] -- <command...>   # acquire, run, ALWAYS release" \
      "                                    # exit = the command's; 75 = LOST a leased lock mid-command;" \
      "                                    # 76 = command done but the lock could NOT be released" \
      "       lock.sh newsession [label]                                 # print a fresh session id" \
      "  Registry option !lease=N: a SESSION lock on that resource expires N s after its last" \
      "  renewal. 'mine <name> --session S --quiet' is THE check-and-renew: run it before every" \
      "  use and at least every N/2 s; non-zero = stop (1 lost, 3 cannot tell yet: ask again)." \
      "  Every ownership verb (acquire wait run release mine note park unpark want wanted unwant" \
      "  status) takes --session S (or \$AGENT_LOCK_SESSION) AFTER its positional arguments; the" \
      "  note is always the 3rd argument (pass \"\" if none). Identity = (agent pid, session):" \
      "  SUB-AGENTS MUST pass --session, or they share their siblings' locks." >&2
    exit 2 ;;
esac
