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
"$L" status scope                    # FREE or HELD (+ holder info)
"$L" list                            # all locks, [held] or [stale]
"$L" release scope                   # give it back
"$L" release scope --force           # break another session's lock (ask first)
```

Resource names are arbitrary (`[A-Za-z0-9._-]+`) — you decide what a "resource"
is. Exit codes: `0` free/ok, `1` busy/held, `2` error (**treat as busy**).

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
- **Idempotent per session**: re-acquiring a lock the same session already
  holds succeeds.

## Caveats

- Do not point tmp-cleaning tools at the lock store: an external sweeper that
  deletes a held `.lock` directory makes the resource look free. Stock modern
  macOS does not sweep `/tmp` periodically, but if you run a third-party
  cleaner, set `AGENT_LOCK_DIR` to a path it ignores (e.g.
  `~/.claude/locks` — note that makes locks per-user, not per-machine).
- Pid reuse: if a dead holder's pid is recycled by an unrelated process the
  lock reads HELD until released with `--force` — it fails toward busy, never
  toward free.

## License

MIT
