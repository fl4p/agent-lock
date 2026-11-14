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
"$L" newsession <label>                                   # print a fresh session id: <label>-<10 hex>
"$L" acquire <name> "note" [--session S] [--ack] [--new] [--brief]   # take the lock
"$L" wait    <name> "note" [timeout_s] [--session S] [--ack] [--brief] # blocking acquire (default 3600 s)
"$L" run     <name> "note" [--session S] [--timeout S] -- <cmd...>   # acquire, run, ALWAYS release
"$L" release <name> [--session S] [--force]   # give it back; --force breaks another session's lock
"$L" mine    <name> [--session S] [--quiet]   # exit 0 ONLY if WE hold it (status says HELD for a peer too); renews a lease
"$L" status  <name> [--session S] [--brief]   # FREE or HELD by pid N, session S [(YOURS)]
"$L" note    <name> "text" [--session S] [--force]   # correct the note on a lock you hold
"$L" park    <name> "reason" [--session S]    # done with it but can't release: others may take it
"$L" unpark  <name> [--session S]             # cancel that; it is a normal held lock again
"$L" want    <name> "note" [--session S]      # ask the holder to hand it over, without taking it
"$L" wanted  <name> [--session S] [--quiet]   # exit 0 if somebody (else) asked; for a holder's poll loop
"$L" unwant  <name> [--session S] [--force]   # withdraw YOUR request
"$L" flag    <name> "reason"    # raise a warning that OUTLIVES the lock
"$L" unflag  <name>             # clear it
"$L" resolve <name>             # what canonical lock does this name mean?
"$L" list                       # all locks, [held] / [stale] / [parked] / [FLAGGED]
"$L" top [filter] [-i S]        # live monitor (compact cards <80 cols, table >=80 cols; --once)
```

Exit codes: `0` = ok/free, `1` = busy/held/flagged, `2` = error (treat as BUSY; never proceed).
More precise codes: `mine` exits `3` for "cannot tell right now" (stop, then ask again);
`release`, `note` and `park` exit `3` when the steal gate is only busy (nothing changed: retry);
`run` exits `75` when it lost a leased lock mid-command. A command can exit 75 on its own, so
the loss is also announced on stderr by a line starting `LOCK LOST:`; check for that line.
`run` exits `76` when the command finished but the lock could **not** be released (the gate
stayed busy for the ~20 s retry window, or someone else holds it now). It then prints
`NOT RELEASED: <name> (lease ends in N s; retry 'lock.sh release <name> --session <id>');
the command exited <rc>`, so the command's own rc is still there. Run that retry.

**Argument order is fixed.** The note/text/reason is **always the 3rd argument** — pass `""` if
you have none — and options come **after** the positional arguments (for `wait`, after the
optional timeout; for `run`, before `--`). A 3rd argument that starts with `--` is refused
(exit 2): `acquire fab-chrome --session=fil-1` used to store "--session=fil-1" as the *note*
and take the lock with no session — the incident again. `release` ignores (with a warning) one
legacy plain word such as `release rig "done"`; every other unknown argument is exit 2.

## Sub-agents MUST use `--session`

The holder identity is **(agent pid, session id)**. The pid comes from walking up the process
tree to the agent process — and **every sub-agent a Claude Code session starts runs inside that
same claude process**, so siblings get the same pid. With the pid alone, a sibling's `acquire`
or `wait` answered "already held by this session" and overwrote the holder's note. Measured
2026-10-06: a FIL research sub-agent and an AIN sub-agent both "held" `fab-chrome` and drove
Fab's real Chrome at the same time.

Nothing in the environment tells siblings apart either — `CLAUDE_CODE_SESSION_ID` and
`PASEO_AGENT_ID` are inherited unchanged by every sub-agent — so the id cannot be derived; it
must be minted. A sub-agent (and, for `!session` resources, a top-level session too) gets its
own id once and passes it on **every** call:

```bash
L=~/.claude/skills/lock/lock.sh
"$L" newsession fil                   # once, at the start; prints e.g. fil-3f9a0c71d2 (an example only)
"$L" wait    bench-scope "FIL research: scope capture" 540 --session <id>
"$L" mine    bench-scope --session <id> --quiet   # before EVERY use and at least every 7 min; non-zero = STOP
"$L" release bench-scope --session <id>
```

Fab's real Chrome is **no longer** a lock resource (Fab, 2026-10-14: the `fab-chrome` lock was
removed). Use `~/dev/bin/fab-chrome-fetch`, which refuses (exit 4) if another extension client
is running. The `fab-chrome` registry line stays only until the running Mouser crawl
(`/tmp/mo-hold.sh`) ends; delete it then.

`<id>` is the value **your** `newsession` printed. Never copy an id from these docs: two
sub-agents that both paste the sample would be one identity, so `lock.sh` refuses the sample
id above outright (exit 2).

**Write the literal id into each command.** Each Bash tool call is a fresh shell, so a `$S` or
an `export` from an earlier call is gone by the next one — and an unset `$S` is exactly how a
session silently disappears. `AGENT_LOCK_SESSION=<id>` works as a per-command prefix or inside
one long script; `--session` beats it when both are given. The label is 1–32 of `[A-Za-z0-9._-]`
starting with a letter or digit; a session id is 1–64 of `[A-Za-z0-9._-]`, also starting with a
letter or digit (so zsh's `--session=$S:h`, which yields `.`, is refused), surrounding whitespace
trimmed. Every id `newsession` prints satisfies this.

**Waiting inside a Bash tool call:** `wait <name> "note" 540 --session <id>` in the
**foreground**, with the tool's `timeout` at 600000 ms; on `TIMEOUT` (exit 1) just run it again.
Exit 2 means stop — never go on without the lock. Do not background it: a sub-agent is never
woken by a background job finishing, and a detached `wait` (`nohup`, `dtach`) has no caller and
exits 2 at once unless `AGENT_LOCK_OWNER_PID` names a live long-lived holder.

The rules the script enforces:

- **Same pid, different session = someone else's lock.** `acquire` prints `BUSY <name> — held
  by:`, the holder's info, then *"Same agent process (pid N) but a DIFFERENT session: held by
  session X, we are Y. That is a sibling sub-agent or the parent session -- NOT you. Treat it as
  busy."* (exit 1); `wait` keeps waiting and on TIMEOUT prints the same; `release`, `note`,
  `park`, `unpark` refuse; `mine` answers no. This holds whenever **either** side has a session:
  a session-less parent cannot take its sub-agent's lock by accident, nor the reverse.
- **Same pid and same session** = yours: re-acquire is idempotent and updates the note;
  `status` marks it `(YOURS)`.
- **No session on either side** = exactly the old behaviour (pid alone) — except on resources
  marked `!session` (below). The lock's `session=` label then ends in `(pid-only)`, because the
  derived label (e.g. `PASEO_AGENT_ID`) is shared by every sibling and is not an identity.
- An **empty**, malformed, or conflicting (`--session a --session b`) session is exit 2, not "no
  session": `--session "$S"` with `S` unset would otherwise drop you back to sharing your
  siblings' locks. So is a misspelt option.
- `want` refuses a lock you hold; `wanted` ignores your own request; `unwant` withdraws only
  your own request (`--force` for anyone's) — whenever either side has a session.
- `sid=` in the lock file is the identity; `session=` is the display label `lock-top` shows.

### `!session` resources: no session, no lock

A resource whose registry line carries `!session` (`fab-chrome: !session`) **refuses**
`acquire`, `wait` and `run` without a session id (exit 2, "REQUIRES a session id"). For those,
pid-only use is never right, so the old fallback is closed rather than documented.

The registry fails closed on the typos that used to drop the requirement silently:

- `!word` tokens are options, never aliases. **Any token containing `!` that is not exactly
  `!session`** — `!sesion`, `!SESSION`, `! session`, or `chrome!session` with the space
  forgotten — makes the whole registry unevaluable: every name exits 2 until it is fixed.
- The marker belongs to the **resource**, not to the line: with `fab-chrome: chrome` on one line
  and `fab-chrome: !session` on another, `chrome` requires a session too.
- A name that means two resources is exit 2 for both: an alias listed under two canonicals, or
  an alias that is another resource's canonical (`browser: fab-chrome` beside `fab-chrome:`).

### `!lease=N` resources: a session lock expires unless its holder renews it

A sub-agent's lock is owned by its **parent's** pid, so a sub-agent that is killed, errors out
or forgets to release leaves a lock whose pid stays alive, and crash recovery never fires.
Measured 2026-10-06: a session limit killed every sub-agent at ~18:05; FARTCOIN's `fab-chrome`
(session `fartcoin-83f7d999bd`, pid = the live parent) stayed held 66+ minutes with CRV queued
behind it. A resource whose registry line carries `!lease=N` (`fab-chrome: !session
!lease=900`) gives every **session-owned** lock on it a deadline:

- The lock records `lease_s=N` and `lease_until`, both in **wall-clock** seconds: after the
  Mac sleeps for longer than the lease, every lease has expired when it wakes.
- **`mine <name> --session <id> --quiet` is the ONLY check-and-renew.** It renews the lease
  only while the lock is still yours (owner and lease are read from one snapshot of the
  lock file). So a chain of 0s, each within the lease, means "you held it the whole time",
  with one exception: someone else's `release --force` needs no gate and can take it between
  two of your calls. A 0 is always "yours right now". Run it
  **before every use of the resource and at least every N/2 seconds** (7 min for
  `fab-chrome`), and treat **any non-zero result as "stop"**: `1` = you LOST it (expired or
  taken), `3` = cannot tell right now (the steal gate is busy and your lease is due), so ask
  again before you continue. `mine` is cheap (~70 ms).
- Do **not** use `acquire`/`wait` as a renewal. They succeed whenever the lock is free, so
  if your lease lapsed and someone else took the lock, used it and released it, your next
  `wait` still prints plain `ACQUIRED` and hides the gap. (`note` by the holder also renews,
  but it does not tell you about a gap either.)
- Once the lease runs out, another session's `acquire`/`wait` **takes it although the pid is
  alive**. It prints `TAKING OVER AN EXPIRED LEASE`, plus who held it, their note and how long
  ago the lease expired. Takers go through the `.steal` gate, so exactly one wins.
- The old holder then learns it lost the lock: `mine` exits 1 ("you LOST it"), `note` is
  refused, and `release` exits 1 saying you no longer held it. It also exits 1 when nobody
  took the lock (the stale lock is cleared). Re-`acquire` by the same session gets the lock
  back if nobody took it, with a warning that it was unprotected in between.
- `run` renews its own lease through `mine` every N/3 s while the command runs. A busy gate
  (`mine` 3) is retried every 0.5 s, but only while the lock is still ours; that is not a
  loss. A `run` can still LOSE the lock: if renewal is impossible until the lease expires (a
  gate stuck that long, a Mac asleep longer than the lease) or someone runs `release
  --force`. Then `run` stops the command's **whole process group** (TERM, KILL after 10 s),
  prints `LOCK LOST: …` on stderr and exits **75**, never the command's 0. The renewer dies
  with `run`.
- On a leased lock the command runs as **its own process group**, with default signal
  handlers (Ctrl-C/KeyboardInterrupt work) and stdin passed through. TERM, INT and HUP to
  `run` are forwarded to the whole group, so grandchildren stop too. Anything the command
  leaves running in its group when it exits is stopped as well. The lock goes back only
  once the group is gone.
- **What escapes the group, and so outlives `run` and its lock:** any child the command puts
  in its OWN process group or session. That includes `setsid`, `setpgid`, a daemonising
  double fork, Node's `spawn(..., {detached: true})`, Python's
  `subprocess.Popen(..., start_new_session=True)` (or `preexec_fn=os.setsid`), and a browser
  launched by Playwright/Puppeteer, which start it detached. `run` cannot see those; stop
  them yourself before the command exits. If members of the command's own group survive
  TERM+KILL, `run` says so in its `RELEASED` line instead of a plain `RELEASED`.
- A background group cannot read the terminal, so a terminal stdin is replaced by
  `/dev/null` (with a warning).
- **`kill -9` of `run` itself** cannot be trapped. The command is orphaned and keeps running
  while the lease lapses (nothing renews it any more), so another session may take the lock
  under it. Stop `run` with TERM/INT, never KILL. (The harness's TaskStop kills the whole
  process tree, command included; the reviewer measured that on 2026-10-06.)
- `status`/`BUSY` show `[lease 12m left]` or `[lease EXPIRED 3m ago -- takeable]`; `list`
  shows `[expired]`.
- **Unchanged:** a parked lock is taken over as parked; a flag still refuses; a pid-dead
  holder is still stolen at once. A lock with no `lease_until` never expires. That covers a
  pid-only lock, a lock on a resource without `!lease`, and a lock taken before the resource
  gained one. `N` is whole seconds, 60–86400; anything else (`!lease=15m`, `!lease=10`) or two
  different leases for one resource makes the registry unevaluable (exit 2).

### `!maxhold=N`: a cap on one acquisition, renewals included

A lease stops a *dead* holder from blocking everyone, but not a live one that keeps renewing.
Measured 2026-10-13/14: a Mouser crawl held `fab-chrome` for 22+ h. It renewed every 4 min
while it sat behind a challenge doing nothing, and every other session starved. A resource
marked `!maxhold=N` (only next to a `!lease`, e.g. `fab-chrome: !session !lease=900
!maxhold=1200`) caps one acquisition:

- The lock records `hold_until` = acquire time + N. No renewal (`mine`, `note`, re-`acquire`,
  `run`) moves `lease_until` past it, so once it passes, the lease expires like any other.
  `mine` then exits 1 and another session's `acquire`/`wait` takes the lock.
- Re-`acquire` by the same session after the hold has run out is refused with `HOLD LIMIT`,
  and `wait` stops at once with it rather than spinning. Release, then `wait` again; a fresh
  acquire starts a fresh hold. That leaves a gap in which others can get in, though FIFO order
  is not guaranteed. Measured by review: a holder that re-acquires within 0.5 s won 2–3
  handoffs in a row.
- Near the end of a hold, `mine` 0 can mean "1 s left". Before a step that may take S
  seconds, ask `mine <name> --session <id> --quiet --min-left S`: it renews, then answers 1
  (`NOT ENOUGH`) if less than S seconds of lease remain.
- `run` wakes its renewer just after `hold_until`, so it stops the command (exit 75) within
  about a second of the hold ending.
- A `hold_until=` line that is present but malformed counts as reached (fail closed).
- A lock taken before the registry gained `!maxhold` carries no `hold_until` and is not capped.
- Same range and same "unevaluable" rules as `!lease`.

### `wait` dies with its caller; no lock is ever created ownerless

A `wait` whose caller has gone (its parent pid changed or was already launchd) or whose owning
agent process has died gives up with exit 2 instead of acquiring later as `pid=unknown` — such
a lock is never stale, so only `--force` would ever clear it. For the same reason `acquire`
refuses to *create* a lock when no owning agent process can be found; a long-lived holder
outside an agent session names itself with `export AGENT_LOCK_OWNER_PID=$$`. A `wait` killed by
TERM/INT/HUP finishes its in-flight attempt and gives back anything that attempt just took.

**Finishing.** Release before you return your result. If you must hand over hardware without
releasing, `park` it with your `--session`. A sub-agent that finished and forgot leaves a lock
whose pid (the parent) is still alive, so crash recovery will not clear it (on a `!lease`
resource the lease frees it after N s; elsewhere nothing does): the **parent**, once
that sub-agent's result has come back to it, may `release <name> --session <that sub-agent's
id>` (the id is in `status`). Nobody else may — a sibling doing this is the incident again.
**Delegating a lock:** only a parent that **itself holds the lock under a session id** can
delegate: it gives the sub-agent that same `--session` id. A session-less parent cannot share
its lock with a sub-agent (the sub-agent's own session would mismatch); let the sub-agent
acquire it itself instead.

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

0. **If you are a sub-agent, use `--session <id from newsession>` on every call** (section
   above). Without it you share every lock with your siblings and your parent.
1. **Acquire before touching** a shared resource; pass a short note saying why.
2. **Release when done** with the resource — not at some later cleanup point.
3. **Exit code 2 (or any failure to evaluate) means BUSY**, never free.
4. If BUSY: report the holder info to the user. To queue for the resource instead, run
   `wait <name> "<what>" 540 --session <id>` in a **foreground** Bash call with `timeout:
   600000`, and repeat that same call on `TIMEOUT` (exit 1). Do **not** use
   `run_in_background`: a sub-agent is never woken when a background job ends, so it would
   never learn it got the lock. Never poll `status` in a loop instead of `wait`, and
   **never `--force` without explicitly asking the user first**.
5. Re-acquiring a lock this session (same pid **and** same `--session`) already holds
   succeeds (idempotent), and a **differing note updates it**. Keep the note true: it is what a peer session reads to decide whether
   to wait, and a stale one is worse than none. Use `note` when you are not re-acquiring.
6. **Leave a `flag` behind** if you leave hardware faulted, mid-configuration, or otherwise
   unsafe for the next session — before you release.
7. **On a `!lease=N` resource, run `mine <name> --session <id> --quiet` before every action
   on the resource and at least every N/2 s (`fab-chrome`: before every browser action and at
   least every 7 min); non-zero = stop.** You lost the lock (or cannot tell yet), and someone
   else may already be using the resource.

## Crash recovery

The lock records the pid of the owning agent process (found by walking up the
process tree). If that session dies, the next `acquire` detects the dead pid and
steals the lock automatically — no daemon. Concurrent stealers are
serialized through a `.steal` gate and re-verify before removing, so only one
can win. If the owner cannot be identified (`pid=unknown`), the lock is never
auto-stolen and needs `--force`. A sub-agent's death does not kill its pid (the
parent's); for that case a resource opts in to a **lease** (`!lease=N`, above).

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

It blocks until the lock is free (`--timeout`, whole seconds, default 3600), runs the command, and
releases on **every** path out — normal exit, a failing command, Ctrl-C, SIGTERM. If the
lock never comes free it exits 2 and **does not run the command at all**; a wrapper that
ran the work anyway would be worse than none, because it would look like serialisation.

The exit status is the **command's**, never the wrapper's (the one exception: `75` when a
leased lock was lost mid-command, see the lease section). That is the point. The older
advice was to run `wait` in the background so the agent is woken when the lock lands — but
a backgrounded launch returns 0 *immediately*, and an agent that reads that 0 as "I hold
the lock" goes on to touch the hardware. Measured 2026-09-14: that is how a session
convinced itself it held a board it did not.

Don't background anything that waits for a lock. Run `run` (or `wait`) in the foreground, with
the Bash tool's `timeout` above `--timeout` plus the command's runtime (up to 600000 ms). For
longer work, take the lock with the foreground `wait … 540` loop, then run the long job. A
top-level session may use `run_in_background`, but it must read `run`'s own output for
`RELEASED … command exit N`, never the launcher's exit status. A sub-agent must never
background either.

**`run` releases a lock your session already held.** If the same (pid, session) holds the lock
when `run` starts, `run` treats it as its own and releases it when the command ends, so you
do *not* still hold it afterwards. Inside an existing hold, call the command directly, or
re-acquire after `run`.

Retrying around a busy board needs care too. `if cmd; then ...; fi` yields **0** when the
condition fails and there is no `else`, so `rc=$?` after it reads 0 rather than the
command's status — a retry loop written that way treats "BUSY, try again" as a fatal error
and gives up on the first attempt. Capture with `cmd; rc=$?` on its own line.

### Who owns a lock: the session, not the process; the pid says only "alive"

The pid in a lock is the agent process found by walking up the process tree. It is **not**
the identity: every sub-agent of one Claude Code session runs inside the same claude process,
and a `run_in_background` Bash job resolved to that same claude pid too — measured in Claude
Code 2.1.289 (one run, 2026-10-06). (An older version of this section said a background job
walks up to a *different* pid and so needed `--force` to release.) Before relying on this in
another harness or version, confirm it: from the background context, `status <name> --session
<id>` must show `(YOURS)` for a lock you took in the foreground.

The identity is **(pid, session id)**: a lock is yours only when both match, so pass the same
`--session` from every context that touches it, whether that is the foreground call, a
background job, or a script. The pid only answers *is the owner still alive*: a dead pid makes
the lock stale and stealable; a live one keeps it held however idle it is.

Before assuming a held lock belongs to someone else, compare its `sid=` (shown by `status`)
with your own id. If it matches, it is yours: release it with that `--session`. A
session-less lock (`sid=` empty) is matched by pid alone; then `ps -p <pid> -o command=`
showing your own `claude --resume <your-session-id>` means it is yours.

**Release the lock from the context you took it in, or at least with the same `--session`.**
Measured 2026-08-16: `scope` and `fugu-rig` were held three hours past the end of the work,
with two peer sessions blocked on the same rig. A forgotten release is never cleared by crash
recovery while the agent process lives.


### `status` says HELD for a peer's lock too — long-running jobs must ask `mine`

`status` answers *is this locked*, not *is it mine*. A loop that branches on `HELD` keeps
running when a peer takes the board, which is the worst possible reading: it is exactly the
case where you must stop. On 2026-09-15 a yield-mode daemon did this — it also checked
`acquire`'s **output** instead of its exit status, and on refusal `acquire` prints the current
holder's note, which reads like success — and it flashed `esp32s3-1588` out from under
another session's BLE measurement, destroying their image and ~2.5 minutes of their data.

```bash
while :; do
  "$L" mine "$LOCK" --quiet || { stop_touching_the_device; break; }   # every cycle
  "$L" wanted "$LOCK" >/dev/null && { hand_it_over; break; }
  ...
done
```

Two rules fall out, and they cost one line each:

- **Branch on `mine`, never on `status`,** in anything that outlives a single command.
- **Branch on an exit status, never on output.** A refusal that prints the holder's note is
  indistinguishable from success if you only read the text.

### Yield mode: `want` / `wanted`, because `wait` registers nothing

`wait` is a polling loop. It leaves no trace, so a holder part-way through a long run has no
way to learn that anybody is queued behind it, and every cooperative holder ends up inventing
its own file convention. `want` records the request where everyone already looks:

```bash
"$L" want esp32s3-1588 "need the bench for a BLE run"   # asks; does NOT take the lock
```

A holder running in yield mode polls `wanted` and releases. `release` clears the request, so
one hand-over is not served twice. Say so in your note, so a peer knows asking will work:

    YIELD MODE — yours on request: `lock.sh want <name>` and I release within ~10 s.
