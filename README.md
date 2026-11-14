# agent-lock

System-wide named locks for exclusive-access shared resources — a scope, a test
rig, a multimeter, a serial port, a build directory — coordinating multiple AI
coding agent sessions (Claude Code, Codex, OpenCode, ...) on one machine.

A [Claude Code skill](https://docs.anthropic.com/en/docs/claude-code): drop the
directory into `~/.claude/skills/lock/` and the agent acquires a lock before
touching a shared resource and releases it when done. The script is plain bash
with zero dependencies, so any harness (or human) can call it directly.

## Install

```bash
git clone https://github.com/fl4p/agent-lock ~/.claude/skills/lock
```

## Usage

```bash
L=~/.claude/skills/lock/lock.sh
"$L" acquire scope "ringing sweep"   # take the lock, say why
"$L" wait scope "queued" 600         # blocking acquire: retry every 2s, give up after 600s
"$L" status scope                    # FREE or HELD (+ holder info)
"$L" list                            # all locks, [held] or [stale]
"$L" release scope                   # give it back
"$L" release scope --force           # break another session's lock (ask first)
"$L" note scope "what changed"       # correct the note on a lock you hold
"$L" flag scope "probe off the node" # a warning that OUTLIVES the lock
"$L" unflag scope                    # clear it
"$L" resolve mxo4                    # -> scope
```

Resource names live in `aliases.conf` (`[A-Za-z0-9._-]+`). Exit codes: `0`
free/ok, `1` busy/held/flagged, `2` error (**treat as busy**).

## Design

- **Atomic, dependency-free**: a lock is a directory under `/tmp/claude-locks/`
  (override with `AGENT_LOCK_DIR`); `mkdir` is the atomic primitive (macOS has
  no `flock(1)`).
- **Crash recovery, no daemon/TTL**: the lock records the pid of the owning
  *agent process* (found by walking up the process tree past the throwaway tool
  shell). If that session dies, the next `acquire` sees a provably-dead holder
  and steals the lock automatically.
- **Race-free steal**: would-be stealers serialize through a `.steal` gate
  directory and re-verify the holder is still dead *under the gate* before
  removing anything, so a check→remove window can never delete a lock that a
  faster session already stole and re-acquired. A gate leaked by a crashed
  stealer blocks stealing (fail closed) and is broken after 60 s.
- **Fails closed**: anything the script cannot evaluate — unreadable info file,
  unparseable pid, a live process it may not signal, an unidentifiable owner —
  reads as **BUSY**, never as free. Absence of evidence is not absence of a
  holder.
- **One resource, one lock**: names resolve through `aliases.conf`, so `scope`,
  `mxo` and `mxo4` are the same mutex rather than three private ones. An
  *unregistered* name is refused rather than granted — a typo that opens its own
  mutex is exclusivity that protects nothing. `--new` registers a genuinely new
  resource, once. A name that is ambiguous between two real instruments can be
  banned outright (`!dmm:`) so the caller has to say which.
- **Flags outlive locks**: a lock says *busy*, never *broken*. `flag` records a
  reason that survives release; `acquire` refuses until `unflag`, and `--ack`
  overrides one acquire loudly. This is for "the rig faulted, do not energise it"
  — the state that used to vanish the moment the lock was given back.
- **Holder identity is (agent pid, session id)**: sub-agents of one Claude Code
  session run inside the same agent process and share its pid, so the pid alone
  cannot tell them apart. `--session S` (or `$AGENT_LOCK_SESSION`; a fresh id
  from `lock.sh newsession`) is stored as `sid=` and must match too. With no
  session on either side, identity is the pid alone, as before — except on a
  resource marked `!session` in `aliases.conf` (e.g. `fab-chrome`), where
  `acquire`/`wait`/`run` refuse without a session. Session ids start with a letter
  or digit. The marker applies to the resource whichever of its lines carries it,
  and any `!` token that is not exactly `!session` (`!sesion`, `chrome!session`)
  makes the registry unevaluable (exit 2 for every name), so a typo cannot drop
  the requirement silently.
- **Leases for session locks** (`!lease=N` in `aliases.conf`, e.g.
  `fab-chrome: !session !lease=900`): a sub-agent's lock is owned by its parent's
  pid, so a killed or forgetful sub-agent never goes stale. On a leased resource a
  session-owned lock expires N s (wall clock) after its last renewal. `mine <name>
  --session <id> --quiet` is the ONLY check-and-renew: holders call it before every use
  and at least every N/2 s, and stop on non-zero (1 = lost, 3 = cannot tell yet).
  `acquire`/`wait` are not renewals, since they can hide that someone else used it in
  between. Another session's `acquire`/`wait` takes an expired lease, loudly and through
  the steal gate, and the old holder's `mine` and `release` exit 1. `run` renews in the
  background and runs a leased command as its own process group. If it still loses the
  lock, it stops the whole group, prints `LOCK LOST:` and exits 75. If the command finished
  but the lock could not be released, it prints `NOT RELEASED: …` (with the command's rc)
  and exits 76. A busy gate gives exit 3 ("retry") for `mine`, `release`, `note` and
  `park`. Children that put themselves in their own process group (`setsid`, detached
  spawns, Playwright browsers) escape `run`.
  Locks without `lease_until` never expire; parked, flagged and pid-dead semantics are
  unchanged.
- **Idempotent per identity**: re-acquiring a lock the same (pid, session)
  already holds succeeds, and a differing note updates it rather than being
  silently discarded (a stale note is worse than no note: peers act on it).
- **Waiting**: `wait` is a blocking acquire (atomic retry loop, no
  check-then-take race). Agents run it in the **foreground** with a bounded
  timeout (`wait <name> "note" 540 --session <id>` in a tool call allowed 600 s)
  and repeat it on `TIMEOUT`. A background job never wakes a sub-agent, and a
  detached `wait` (nohup/dtach) has no caller and exits 2 unless
  `AGENT_LOCK_OWNER_PID` names a live holder.
- **`run` always releases**, including a lock the same session already held
  before `run` started.

## Caveats

- Do not point tmp-cleaning tools at the lock store: an external sweeper that
  deletes a held `.lock` directory makes the resource look free. Stock modern
  macOS does not sweep `/tmp` periodically, but if you run a third-party
  cleaner, set `AGENT_LOCK_DIR` to a path it ignores (e.g.
  `~/.claude/locks` — note that makes locks per-user, not per-machine).
- Pid reuse: if a dead holder's pid is recycled by an unrelated process the
  lock reads HELD until released with `--force` — it fails toward busy, never
  toward free.
- The registry is a **closed world**, which is a deliberate behaviour change: a
  name you have not registered will not acquire. `release`, `status`, `note` and
  `flag` still accept the literal name of an object that exists on disk, so
  editing `aliases.conf` can never strand a lock somebody is holding.

## Tests

`./test-lock.sh` — every case is a known-bad that must be seen to fail, including
the two incidents this design comes from (two names on one instrument; a note
that could not be corrected). Runs against a throwaway store and registry.

## License

MIT
