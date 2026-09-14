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
"$L" run    <name> "note" [--timeout S] -- <cmd...>   # acquire, run, ALWAYS release
"$L" park   <name> "reason"    # done with it but can't release: others may take it
"$L" unpark <name>             # cancel that; it is a normal held lock again
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

### If you are done with the hardware but cannot release: PARK it

`release` is the only correct end to a lock, but sometimes the work is over and the lock
is not: you are waiting on the user to answer, or holding the board powered for a
follow-up they have to decide on. A lock in that state blocks every peer for hours while
its own note says the run finished. Measured 2026-09-14: `esp32s3-9a70` held by a live
session whose note read "awaiting Fab" — it knew it was done and had no way to say so.

```sh
"$L" park esp32s3-9a70 "test DONE. Board parked in ROM DOWNLOAD MODE — press reset before
                        expecting the app to boot. Held only for the antenna follow-up."
```

A parked lock is still yours — `release` and `unpark` both still work — but `acquire`
will now hand it to a peer, printing your reason and your note so the next session knows
what state the hardware is in. That is why the reason is mandatory and why it should
describe the HARDWARE, not your intentions.

Park is a declaration by the holder, never a timeout. Only the holder can park, and an
unparked lock held by a live process is never taken no matter how long it has been idle —
idle is not dead, and a long settle is a legitimate reason to hold a rig silently.

### Prefer `run`: the only shape where forgetting to release is impossible

```sh
"$L" run xiao-s3-jd9853 "flash HEAD, read 30 s" -- out/flash_exp.sh 30
```

It blocks until the lock is free (`--timeout`, default 3600 s), runs the command, and
releases on **every** path out — normal exit, a failing command, Ctrl-C, SIGTERM. If the
lock never comes free it exits 2 and **does not run the command at all**; a wrapper that
ran the work anyway would be worse than none, because it would look like serialisation.

The exit status is the **command's**, never the wrapper's. That is the point. The older
advice was to run `wait` in the background so the agent is woken when the lock lands — but
a backgrounded launch returns 0 *immediately*, and an agent that reads that 0 as "I hold
the lock" goes on to touch the hardware. Measured 2026-09-14: that is how a session
convinced itself it held a board it did not. If you must background, background `run`, and
read the status from its own output, never from the launcher.

Retrying around a busy board needs care too. `if cmd; then ...; fi` yields **0** when the
condition fails and there is no `else`, so `rc=$?` after it reads 0 rather than the
command's status — a retry loop written that way treats "BUSY, try again" as a fatal error
and gives up on the first attempt. Capture with `cmd; rc=$?` on its own line.

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
