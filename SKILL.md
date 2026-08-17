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
"$L" list                      # all locks, [held] / [stale] / [FLAGGED]
"$L" note   <name> "text"      # correct the note on a lock you hold
"$L" flag   <name> "reason"    # raise a warning that OUTLIVES the lock
"$L" unflag <name>             # clear it
"$L" resolve <name>            # what canonical lock does this name mean?
```

Exit codes: `0` = ok/free, `1` = busy/held/flagged, `2` = error.

## Resource names are a closed set

Names resolve through `aliases.conf`, so **one instrument has one lock however you spell
it** — `scope`, `mxo`, `mxo4`, `mxo44` are the same mutex. Two sessions once held `scope`
and `mxo4` simultaneously and both believed they had the MXO44 to themselves.

**An unregistered name is refused, not granted.** A typo used to hand you your own private
mutex, which is exclusivity that protects nothing. If you meant a real new resource, register
it once:

```bash
"$L" acquire <name> "note" --new     # appends it to aliases.conf
```

Some names are refused *on purpose* because they are ambiguous — `dmm` names two instruments
on this bench, so it makes you say `dmm6500` or `hp3458a`. `lock.sh resolve <name>` tells you
what a name means without taking anything.

## Flags: the thing that outlives the lock

A lock says *busy*; it cannot say *broken*. When the rig faulted on 2026-08-13 — over-draw,
then a burning smell — releasing the locks erased the only cross-session record that it must
not be energised.

```bash
"$L" flag fugu-rig "over-draw then burning smell 2026-08-13 — do not energise"
```

`acquire` then **refuses** that resource, prints the reason, and stays refusing after any
release, until someone runs `unflag`. `--ack` overrides for a single acquire and says so
loudly. Raise a flag whenever you leave hardware in a state the next session must know about;
this is worth more than the lock itself.

## Rules for the agent

1. **Acquire before touching** a shared resource; pass a short note saying why.
2. **Release when done** with the resource — not at some later cleanup point.
3. **Exit code 2 (or any failure to evaluate) means BUSY**, never free.
4. If BUSY: report the holder info to the user. To queue for the resource
   instead, launch `wait` as a background task (Bash `run_in_background: true`)
   — you'll be woken when it acquires or times out. Never poll `status` in a
   foreground loop, and **never `--force` without explicitly asking the user
   first**.
5. Re-acquiring a lock this session already holds succeeds (idempotent), and a **differing
   note updates it**. Keep the note true: it is what a peer session reads to decide whether
   to wait, and a stale one is worse than none. Use `note` when you are not re-acquiring.
6. **Leave a `flag` behind** if you leave hardware faulted, mid-configuration, or otherwise
   unsafe for the next session — before you release.

## Crash recovery

The lock records the pid of the owning agent process (found by walking up the
process tree). If that session dies, the next `acquire` detects the dead pid and
steals the lock automatically — no daemon, no TTL. Concurrent stealers are
serialized through a `.steal` gate and re-verify before removing, so only one
can win. If the owner cannot be identified (`pid=unknown`), the lock is never
auto-stolen and needs `--force`.

### Trap: acquire from the session, release from a background job → `--force`

The pid comes from walking up the process tree, and **a background Bash job walks
up to a different pid than the interactive session does.** So a lock acquired in
the session and released from inside a background task fails:

```
held by another session (pid=33176, we are 83362); use --force to break
```

Both pids belong to the *same* Claude session. Nothing is wrong, nothing is
stale, and the holder is very much alive — so crash recovery will never clear it
either. The only exit is `--force`, which by rule 4 needs the user asked first.

**Release the lock from the same context you took it in.** If a session takes a
lock and then does its work through background tasks — which is normal for long
bench runs — it has silently converted a well-behaved hold into one only the user
can authorise clearing. Measured 2026-08-16: `scope` and `fugu-rig` held three
hours past the end of the work, with two peer sessions blocked on the same rig.

Before assuming a held lock belongs to someone else, check:
`ps -p <pid> -o command=` — if it is a `claude --resume <your-own-session-id>`,
it is yours.
