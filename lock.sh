#!/bin/bash
# lock.sh — system-wide named resource locks for agents (scope, rig, dmm, ...).
# Lock = directory $DIR/<canonical>.lock (mkdir is the atomic primitive).
# Exit codes: 0 = ok/free, 1 = busy/held/flagged, 2 = error/unknown (treat as BUSY).
set -u
DIR=${AGENT_LOCK_DIR:-/tmp/claude-locks}
HERE=$(cd "$(dirname "$0")" && pwd)
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

resolve() { # set CANON for $1; return 0 ok / 1 unknown / 3 explicitly banned
  local want=$1 line canon rest a hit="" ban="" is_banned=no
  banned_reason=""; CANON=""
  [ -r "$ALIASES" ] || { echo "cannot read resource registry $ALIASES" >&2; return 4; }
  # Globbing OFF for the whole parse: `for a in $rest` would otherwise pathname-expand, so a
  # stray `*` in an alias field resolves differently depending on the caller's cwd.
  set -f
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=${line%$'\r'}
    case "$line" in *[![:space:]]*) ;; *) continue;; esac
    if [ "${line#*:}" = "$line" ]; then
      set +f; echo "malformed registry line (no colon): $line" >&2; return 4
    fi
    canon=${line%%:*}; rest=${line#*:}
    canon=${canon//[[:space:]]/}
    [ -n "$canon" ] || { set +f; echo "malformed registry line (empty name): $line" >&2; return 4; }
    if [ "${canon#!}" != "$canon" ]; then           # !name: reason  -> never resolves
      [ "$want" = "${canon#!}" ] && { is_banned=yes
        ban=$(printf '%s' "$rest" | sed 's/^[[:space:]]*//'); }
      continue
    fi
    # No early return: the whole file is scanned so a duplicate definition is DETECTED
    # rather than silently decided by line order, and a later ban still wins.
    if [ "$want" = "$canon" ]; then
      [ -n "$hit" ] && [ "$hit" != "$canon" ] && { set +f
        echo "registry is ambiguous: '$want' resolves to both '$hit' and '$canon'" >&2; return 4; }
      hit=$canon; continue
    fi
    for a in $rest; do
      if [ "$want" = "$a" ]; then
        [ -n "$hit" ] && [ "$hit" != "$canon" ] && { set +f
          echo "registry is ambiguous: '$want' resolves to both '$hit' and '$canon'" >&2; return 4; }
        hit=$canon
      fi
    done
  done < "$ALIASES"
  set +f
  # A ban beats a match wherever it appears in the file, so an alias line above the ban
  # cannot defeat it.
  [ "$is_banned" = yes ] && { banned_reason=${ban:-"banned in the registry, no reason given"}; return 3; }
  [ -n "$hit" ] || return 1
  # A canonical name becomes a filesystem path, so it gets the same check as user input:
  # a registry entry like `../../tmp/x: scope` would otherwise point rm -rf outside the store.
  [[ "$hit" =~ ^[A-Za-z0-9._-]+$ ]] || {
    echo "registry defines an unusable canonical name: $hit" >&2; return 4; }
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
    echo "$canon"; for a in $rest; do echo "$a"; done
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
info_mtime() { stat -f %m "$1/info" 2>/dev/null; }

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
  m=$(stat -f %m "$g" 2>/dev/null || stat -c %Y "$g" 2>/dev/null) || return 1
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
    # is a correctly-quoted call that used to silently override a burning-smell flag.
    note=$(clean_note "${3:-}"); want_new=no; ack=no; opt_session=""
    shift 3 2>/dev/null || shift $#
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --new) want_new=yes ;;
        --ack) ack=yes ;;
        --brief) BRIEF=yes ;;
        --session) shift || { echo "missing argument for --session" >&2; exit 2; }
                   opt_session=$(clean_note "${1:-}") ;;
        --session=*) opt_session=$(clean_note "${1#*=}") ;;
        *)     echo "unknown option: $1 (the note is the 3rd argument)" >&2; exit 2 ;;
      esac
      shift
    done
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
    # Rollout interlock: refuse while a lock exists under any other spelling of this
    # resource, rather than opening a second mutex beside it.
    while IFS= read -r a; do
      [ -n "$a" ] && [ "$a" != "$canon" ] && [ -d "$(lockpath "$a")" ] && split_lock_die "$canon" "$a"
    done < <(aliases_of "$canon")
    check_flag "$canon" "$([ "$ack" = yes ] && echo ack || echo noack)"
    lp=$(lockpath "$canon"); me=$(owner_pid)
    agent=$(owner_agent "$me")
    sess=$(owner_session "$opt_session" "$me")
    for i in 1 2; do
      if mkdir "$lp" 2>/dev/null; then
        if ! printf 'resource=%s\npid=%s\nuser=%s\nagent=%s\nsession=%s\nsince=%s\nnote=%s\n' \
             "$canon" "$me" "$USER" "$agent" "$sess" "$(date '+%Y-%m-%d %H:%M:%S')" "$note" > "$lp/info"; then
          rm -rf "$lp"   # never leave an ownerless lock behind and report success
          echo "cannot write lock info under $DIR" >&2; exit 2
        fi
        # Re-check the flag now the lock is OURS. check_flag ran before mkdir, so a flag
        # raised in between would otherwise be granted straight through the interlock.
        if [ "$ack" != yes ] && [ -e "$(flagpath "$canon")" ]; then
          rm -rf "$lp"
          echo "FLAGGED $canon — raised while we were acquiring; lock released again:" >&2
          sed 's/^/  /' "$(flagpath "$canon")" 2>/dev/null
          exit 1
        fi
        echo "ACQUIRED $canon"; exit 0
      fi
      # mkdir can also fail for disk-full/perms/RO-fs: that's an error, not "held"
      [ -d "$lp" ] || { echo "cannot create lock under $DIR" >&2; exit 2; }
      if [ "$(holder_pid "$lp")" = "$me" ] && [ "$me" != unknown ]; then
        # Idempotent re-acquire. A DIFFERING note used to be discarded in silence, which
        # is how a lock went on advertising an abandoned run for hours. Update it.
        if [ -n "$note" ] && [ "$note" != "$(read_note "$lp")" ]; then
          set_note "$lp" "$note" && echo "NOTE UPDATED $canon: $note"
        fi
        echo "ACQUIRED $canon (already held by this session)"; exit 0
      fi
      if [ "$i" = 1 ] && { holder_dead "$lp" || is_parked "$lp"; }; then
        if steal_gate "$lp"; then
          # re-check under the gate: the lock may have been stolen and re-acquired
          # by a live session since our first look (check->rm must not be blind)
          if holder_dead "$lp"; then
            echo "stale lock (holder pid dead), stealing" >&2; rm -rf "$lp"
          elif is_parked "$lp"; then
            # The reason carries the state the hardware was left in. Print it in FULL and
            # to stdout, not stderr: it is the handover note, not a diagnostic.
            echo "taking over a PARKED lock, held $(age_str $(( $(date +%s) - $(park_since "$lp") ))) by pid $(holder_pid "$lp")"
            echo "  parked because: $(park_reason "$lp")"
            echo "  its last note:  $(read_note "$lp")"
            rm -rf "$lp"
          fi
          rmdir "$lp.steal" 2>/dev/null
          continue
        fi
        echo "BUSY $canon (another session is reclaiming it)"; exit 1
      fi
      echo "BUSY $canon — held by:$(idle_note "$lp")"; show "$lp"; exit 1
    done
    echo "BUSY $canon (race)"; exit 1 ;;
  wait)
    # blocking acquire: retry until acquired or timeout. Run it in the background
    # (run_in_background / dtach) so the agent is woken when the lock lands.
    sanitize "$name"
    wait_note=${3:-}; timeout=${4:-3600}; deadline=$(( $(date +%s) + timeout ))
    wait_session=""
    shift 4 2>/dev/null || shift $#
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --session) shift || true; wait_session=$(clean_note "${1:-}") ;;
        --session=*) wait_session=$(clean_note "${1#*=}") ;;
      esac
      shift || true
    done
    acq_cmd=("$0" acquire "$name" "$wait_note")
    [ -n "$wait_session" ] && acq_cmd+=("--session" "$wait_session")
    while :; do
      out=$("${acq_cmd[@]}" 2>/dev/null); rc=$?
      [ "$rc" = 0 ] && { echo "$out"; exit 0; }
      # 2 is an error (bad name, unreadable registry) and 1-with-a-flag will never clear
      # on its own — neither is worth retrying for an hour.
      [ "$rc" = 2 ] && { echo "error while waiting for $name" >&2; exit 2; }
      resolve "$name" || CANON=$name
      if [ -e "$(flagpath "$CANON")" ]; then
        echo "$name is FLAGGED; waiting would never succeed. Resolve the flag first." >&2; exit 1
      fi
      [ "$(date +%s)" -ge "$deadline" ] && { echo "TIMEOUT waiting for $name after ${timeout}s"; exit 1; }
      sleep 2
    done ;;
  run)
    # acquire (blocking), run a command, release NO MATTER HOW WE LEAVE. This is the only
    # shape in which forgetting to release is impossible, and it is the one to reach for:
    #   lock.sh run rig "flashing" -- ./flash.sh 30
    #   lock.sh run rig "flashing" --timeout 1800 -- ./flash.sh 30
    # The exit status is the COMMAND's, never the launcher's. That matters because the
    # documented way to wait was "run `wait` in the background", and a backgrounded launch
    # returns 0 immediately -- so an agent reads 0, believes it holds the lock, and touches
    # the hardware anyway. Measured 2026-09-14.
    sanitize "$name"
    shift 2 || true
    runnote=""; runto=3600; runsess=""
    while [ "$#" -gt 0 ] && [ "${1:-}" != "--" ]; do
      case "$1" in
        --timeout) shift || true; runto=${1:-3600} ;;
        --session) shift || true; runsess=$(clean_note "${1:-}") ;;
        --session=*) runsess=$(clean_note "${1#*=}") ;;
        -*) echo "unknown option for run: $1" >&2; exit 2 ;;
        *)  [ -z "$runnote" ] && runnote=$(clean_note "$1") || { echo "unexpected argument: $1" >&2; exit 2; } ;;
      esac
      shift || true
    done
    [ "${1:-}" = "--" ] || { echo "usage: lock.sh run <name> \"note\" [--timeout S] [--session NAME] -- <command...>" >&2; exit 2; }
    shift
    [ "$#" -gt 0 ] || { echo "usage: lock.sh run <name> \"note\" [--timeout S] [--session NAME] -- <command...>" >&2; exit 2; }
    # Resolve first so the trap releases the same name acquire took.
    resolve "$name" || CANON=$name
    runcanon=$CANON
    wait_cmd=("$0" wait "$runcanon" "$runnote" "$runto")
    [ -n "$runsess" ] && wait_cmd+=("--session" "$runsess")
    "${wait_cmd[@]}" || { echo "run: never acquired $runcanon, command NOT started" >&2; exit 2; }
    # From here the lock is ours and must come back on every path: normal exit, a failing
    # command, or a signal. Without the signal traps a Ctrl-C or a harness timeout leaks it,
    # which is the exact failure this subcommand exists to remove.
    released=no
    release_once() { [ "$released" = yes ] && return 0; released=yes; "$0" release "$runcanon" >/dev/null 2>&1; }
    trap 'release_once; exit 130' INT
    trap 'release_once; exit 143' TERM
    trap 'release_once' EXIT
    "$@"; runrc=$?
    release_once
    trap - INT TERM EXIT
    echo "RELEASED $runcanon (lock.sh run; command exit $runrc)" >&2
    exit $runrc ;;
  note)
    sanitize "$name"; canon_or_literal "$name"; canon=$CANON; lp=$(lockpath "$canon")
    new=$(clean_note "${3:-}")
    [ -n "$new" ] || { echo "usage: lock.sh note <name> \"text\"" >&2; exit 2; }
    [ -d "$lp" ] || { echo "not locked: $canon (a note needs a lock; see 'flag' for a" \
                           "warning that outlives one)" >&2; exit 2; }
    me=$(owner_pid); hp=$(holder_pid "$lp")
    if { [ "$hp" != "$me" ] || [ "$me" = unknown ]; } && [ "${4:-}" != "--force" ]; then
      echo "held by another session (pid=$hp, we are $me); use --force to amend anyway:" >&2
      show "$lp" >&2; exit 1
    fi
    set_note "$lp" "$new" || exit 2
    echo "NOTE UPDATED $canon: $new" ;;
  park)
    # the holder declares it is done with the resource but cannot release yet (waiting on
    # a human, keeping the board powered for a follow-up). Others may then take it.
    sanitize "$name"; canon_or_literal "$name"; canon=$CANON; lp=$(lockpath "$canon")
    reason=$(clean_note "${3:-}")
    [ -n "$reason" ] || { echo "usage: lock.sh park <name> \"why you are parked / what state the hardware is in\"" >&2; exit 2; }
    [ -d "$lp" ] || { echo "not locked: $canon (nothing to park)" >&2; exit 2; }
    me=$(owner_pid); hp=$(holder_pid "$lp")
    # Only the holder may park. Parking someone else's lock would be stealing it by proxy,
    # which is the exact thing the steal rules exist to prevent.
    [ "$hp" = "$me" ] && [ "$me" != unknown ] || {
      echo "refusing: $canon is held by pid ${hp:-?}, not by this session (pid $me)." >&2
      echo "Only the holder may park a lock; it is a handover, not a seizure." >&2; exit 1; }
    printf '%s\n%s\n' "$(date +%s)" "$reason" > "$(parkpath "$lp")" || exit 2
    echo "PARKED $canon: $reason"
    echo "It stays yours until someone takes it; 'lock.sh unpark $canon' cancels, 'release' still works." ;;
  unpark)
    sanitize "$name"; canon_or_literal "$name"; canon=$CANON; lp=$(lockpath "$canon")
    [ -d "$lp" ] || { echo "not locked: $canon" >&2; exit 2; }
    me=$(owner_pid); hp=$(holder_pid "$lp")
    [ "$hp" = "$me" ] && [ "$me" != unknown ] || {
      echo "refusing: $canon is held by pid ${hp:-?}, not this session (pid $me)" >&2; exit 1; }
    is_parked "$lp" || { echo "$canon is not parked"; exit 0; }
    rm -f "$(parkpath "$lp")"; echo "UNPARKED $canon (it is a normal held lock again)" ;;
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
    #   0 = ours, 1 = not ours (free, or someone else's), 2 = bad name
    sanitize "$name"; canon_or_literal "$name"; canon=$CANON; lp=$(lockpath "$canon")
    me=$(owner_pid); hp=$(holder_pid "$lp" 2>/dev/null)
    if [ -d "$lp" ] && [ -n "$hp" ] && [ "$hp" = "$me" ] && [ "$me" != unknown ]; then
      [ "${3:-}" = --quiet ] || echo "MINE $canon (pid $me)"; exit 0
    fi
    [ "${3:-}" = --quiet ] || {
      if [ -d "$lp" ]; then echo "NOT MINE $canon (held by pid ${hp:-?}, we are $me)"
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
    sanitize "$name"; canon_or_literal "$name"; canon=$CANON; wp=$(wantpath "$canon")
    case "$1" in
      want)   printf 'who=%s\nsince=%s\nnote=%s\n' "$(owner_pid)" "$(date '+%F %T')" "$(clean_note "${3:-}")" > "$wp" || exit 2
              echo "WANTED $canon — the holder releases it if it is running in yield mode; otherwise ask."
              [ -d "$(lockpath "$canon")" ] && show "$(lockpath "$canon")"
              exit 0 ;;
      wanted) [ -e "$wp" ] || exit 1; [ "${3:-}" = --quiet ] || sed 's/^/  /' "$wp"; exit 0 ;;
      unwant) rm -f "$wp" || exit 2; echo "cleared any request for $canon"; exit 0 ;;
    esac ;;
  release)
    sanitize "$name"; canon_or_literal "$name"; canon=$CANON; lp=$(lockpath "$canon")
    [ -d "$lp" ] || { echo "not locked: $canon"; exit 0; }
    me=$(owner_pid); hp=$(holder_pid "$lp")
    if { [ "$hp" != "$me" ] || [ "$me" = unknown ]; } && [ "${3:-}" != "--force" ]; then
      echo "held by another session (pid=$hp, we are $me); use --force to break:" >&2
      show "$lp" >&2; exit 1
    fi
    rm -rf "$lp" || exit 2
    rm -f "$(wantpath "$canon")"      # the hand-over happened; the request is served
    if [ -e "$(flagpath "$canon")" ]; then
      echo "RELEASED $canon — NOTE: it is still FLAGGED:"
      sed 's/^/  /' "$(flagpath "$canon")" 2>/dev/null
    else
      echo "RELEASED $canon"
    fi ;;
  status)
    sanitize "$name"; canon_or_literal "$name"; canon=$CANON; lp=$(lockpath "$canon")
    [ "${3:-}" = --brief ] && BRIEF=yes
    fp=$(flagpath "$canon"); flagged=no
    if [ -e "$fp" ]; then
      flagged=yes; echo "FLAGGED $canon:"
      [ -r "$fp" ] && show_flag "$fp" || {
        echo "  (flag exists but is UNREADABLE)"; echo "UNKNOWN $canon"; exit 2; }
    fi
    if [ -d "$lp" ]; then
      holder_dead "$lp" && echo "HELD $canon [stale — holder pid dead]" \
        || echo "HELD $canon$(park_note "$lp")$(idle_note "$lp")"
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
      holder_dead "$lp" && s=stale || { is_parked "$lp" && s=parked || s=held; }
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
  *)
    echo "usage: lock.sh acquire <name> [note] [--new] [--ack] [--brief] | release <name> [--force]" >&2
    echo "       lock.sh note <name> \"text\" [--force] | flag <name> \"reason\" | unflag <name>" >&2
    echo "       lock.sh status <name> | list | top [filter] | resolve <name> | wait <name> [note] [timeout]\n       lock.sh park <name> \"reason\" | unpark <name>\n       lock.sh mine <name> [--quiet]                              # exit 0 only if WE hold it\n       lock.sh want <name> [who] | wanted <name> | unwant <name>  # ask a holder to hand it over\n       lock.sh run <name> \"note\" [--timeout S] -- <command...>   # acquire, run, ALWAYS release" >&2
    exit 2 ;;
esac
