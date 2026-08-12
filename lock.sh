#!/bin/bash
# lock.sh — system-wide named resource locks for agents (scope, rig, dmm, ...).
# Lock = directory /tmp/claude-locks/<name>.lock (mkdir is atomic).
# Exit codes: 0 = ok/free, 1 = busy/held, 2 = error/unknown (treat as BUSY).
set -u
DIR=/tmp/claude-locks
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

show() { cat "$1/info" 2>/dev/null || echo "(info unreadable)"; }

case "$cmd" in
  acquire)
    sanitize "$name"; lp=$(lockpath "$name"); me=$(owner_pid)
    for i in 1 2; do
      if mkdir "$lp" 2>/dev/null; then
        printf 'resource=%s\npid=%s\nuser=%s\nsince=%s\nnote=%s\n' \
          "$name" "$me" "$USER" "$(date '+%Y-%m-%d %H:%M:%S')" "${3:-}" > "$lp/info"
        echo "ACQUIRED $name"; exit 0
      fi
      if [ "$(holder_pid "$lp")" = "$me" ] && [ "$me" != unknown ]; then
        echo "ACQUIRED $name (already held by this session)"; exit 0
      fi
      if [ "$i" = 1 ] && holder_dead "$lp"; then
        echo "stale lock (holder pid dead), stealing" >&2; rm -rf "$lp"; continue
      fi
      echo "BUSY $name — held by:"; show "$lp"; exit 1
    done
    echo "BUSY $name (race)"; exit 1 ;;
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
