#!/bin/bash
# lock.sh — system-wide named resource locks for agents (scope, rig, dmm, ...).
# Lock = directory $DIR/<name>.lock (mkdir is the atomic primitive).
# Exit codes: 0 = ok/free, 1 = busy/held, 2 = error/unknown (treat as BUSY).
set -u
DIR=${AGENT_LOCK_DIR:-/tmp/claude-locks}
mkdir -p "$DIR" || exit 2
cmd=${1:-}; name=${2:-}

sanitize() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad resource name: $1" >&2; exit 2; }; }
lockpath() { echo "$DIR/$1.lock"; }

owner_pid() { # walk ancestry to the long-lived agent process; "unknown" if none
  local pid=$$ comm
  while :; do
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 1 ] || break
    comm=$(basename "$(ps -o comm= -p "$pid" 2>/dev/null)")
    case "$comm" in claude|node|bun|codex|opencode|pi) echo "$pid"; return;; esac
  done
  echo unknown  # fail closed: never auto-stolen, --force only
}

holder_pid() { sed -n 's/^pid=//p' "$1/info" 2>/dev/null; }

holder_dead() { # true only if holder pid PROVABLY dead (unparseable => alive)
  local pid; pid=$(holder_pid "$1")
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  # ps, not kill -0: kill -0 fails with EPERM on other users' live processes (fail-open)
  ! ps -p "$pid" > /dev/null 2>&1
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

case "$cmd" in
  acquire)
    sanitize "$name"; lp=$(lockpath "$name"); me=$(owner_pid)
    note=$(printf '%s' "${3:-}" | tr -d '\000-\037\177')  # keep info file one-line-per-key
    for i in 1 2; do
      if mkdir "$lp" 2>/dev/null; then
        printf 'resource=%s\npid=%s\nuser=%s\nsince=%s\nnote=%s\n' \
          "$name" "$me" "$USER" "$(date '+%Y-%m-%d %H:%M:%S')" "$note" > "$lp/info"
        echo "ACQUIRED $name"; exit 0
      fi
      # mkdir can also fail for disk-full/perms/RO-fs: that's an error, not "held"
      [ -d "$lp" ] || { echo "cannot create lock under $DIR" >&2; exit 2; }
      if [ "$(holder_pid "$lp")" = "$me" ] && [ "$me" != unknown ]; then
        echo "ACQUIRED $name (already held by this session)"; exit 0
      fi
      if [ "$i" = 1 ] && holder_dead "$lp"; then
        if steal_gate "$lp"; then
          # re-check under the gate: the lock may have been stolen and re-acquired
          # by a live session since our first look (check->rm must not be blind)
          holder_dead "$lp" && { echo "stale lock (holder pid dead), stealing" >&2; rm -rf "$lp"; }
          rmdir "$lp.steal" 2>/dev/null
          continue
        fi
        echo "BUSY $name (another session is reclaiming it)"; exit 1
      fi
      echo "BUSY $name — held by:"; show "$lp"; exit 1
    done
    echo "BUSY $name (race)"; exit 1 ;;
  wait)
    # blocking acquire: retry until acquired or timeout. Run it in the background
    # (run_in_background / dtach) so the agent is woken when the lock lands.
    sanitize "$name"
    timeout=${4:-3600}; deadline=$(( $(date +%s) + timeout ))
    while :; do
      out=$("$0" acquire "$name" "${3:-}" 2>/dev/null); rc=$?
      [ "$rc" = 0 ] && { echo "$out"; exit 0; }
      [ "$rc" = 2 ] && { echo "error while waiting for $name" >&2; exit 2; }
      [ "$(date +%s)" -ge "$deadline" ] && { echo "TIMEOUT waiting for $name after ${timeout}s"; exit 1; }
      sleep 2
    done ;;
  release)
    sanitize "$name"; lp=$(lockpath "$name")
    [ -d "$lp" ] || { echo "not locked: $name"; exit 0; }
    me=$(owner_pid); hp=$(holder_pid "$lp")
    if { [ "$hp" != "$me" ] || [ "$me" = unknown ]; } && [ "${3:-}" != "--force" ]; then
      echo "held by another session (pid=$hp, we are $me); use --force to break:" >&2
      show "$lp" >&2; exit 1
    fi
    rm -rf "$lp" && echo "RELEASED $name" || exit 2 ;;
  status)
    sanitize "$name"; lp=$(lockpath "$name")
    if [ -d "$lp" ]; then
      holder_dead "$lp" && echo "HELD $name [stale — holder pid dead]" || echo "HELD $name"
      show "$lp"; exit 1
    fi
    echo "FREE $name"; exit 0 ;;
  list)
    [ -r "$DIR" ] && [ -x "$DIR" ] || { echo "cannot read $DIR" >&2; exit 2; }
    found=0
    for lp in "$DIR"/*.lock; do
      [ -d "$lp" ] || continue; found=1
      n=$(basename "$lp" .lock)
      holder_dead "$lp" && s=stale || s=held
      echo "$n [$s]: $(tr '\n' ' ' < "$lp/info" 2>/dev/null)"
    done
    [ "$found" = 0 ] && echo "no locks held"; exit 0 ;;
  *)
    echo "usage: lock.sh acquire <name> [note] | release <name> [--force] | status <name> | list" >&2
    exit 2 ;;
esac
