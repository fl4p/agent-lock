---
name: lock
description: System-wide named locks for exclusive-access shared resources (a scope, a rig, a multimeter, a serial port, a build dir...). Use whenever the user asks to lock/reserve/claim/release a resource, asks "is X free/in use", or before this agent touches bench hardware or any resource another agent session might be using concurrently.
---

# lock — named resource locks for agents

One lock per user-chosen resource name, visible to every agent session on this
machine. Backed by `~/.claude/skills/lock/lock.sh` (atomic `mkdir` under
`/tmp/claude-locks/`, no dependencies; override the store with `AGENT_LOCK_DIR`
— all sessions must use the same one).

## Commands

```bash
L=~/.claude/skills/lock/lock.sh
"$L" acquire <name> ["note"]   # take the lock; note = what you're doing
"$L" wait <name> ["note"] [timeout_s]  # blocking acquire, retries every 2s (default timeout 3600)
"$L" release <name> [--force]  # give it back; --force breaks another session's lock
"$L" status  <name>            # FREE or HELD (+ holder info)
"$L" list                      # all locks, [held] or [stale]
```

Resource names: `[A-Za-z0-9._-]+`, chosen by the user (e.g. `scope`, `fugu-rig`,
`dmm`). Exit codes: `0` = ok/free, `1` = busy/held, `2` = error.

## Rules for the agent

1. **Acquire before touching** a shared resource; pass a short note saying why.
2. **Release when done** with the resource — not at some later cleanup point.
3. **Exit code 2 (or any failure to evaluate) means BUSY**, never free.
4. If BUSY: report the holder info to the user. To queue for the resource
   instead, launch `wait` as a background task (Bash `run_in_background: true`)
   — you'll be woken when it acquires or times out. Never poll `status` in a
   foreground loop, and **never `--force` without explicitly asking the user
   first**.
5. Re-acquiring a lock this session already holds succeeds (idempotent).

## Crash recovery

The lock records the pid of the owning agent process (found by walking up the
process tree). If that session dies, the next `acquire` detects the dead pid and
steals the lock automatically — no daemon, no TTL. Concurrent stealers are
serialized through a `.steal` gate and re-verify before removing, so only one
can win. If the owner cannot be identified (`pid=unknown`), the lock is never
auto-stolen and needs `--force`.
