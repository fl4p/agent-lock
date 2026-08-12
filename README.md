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

- **Atomic, dependency-free**: a lock is a directory under `/tmp/claude-locks/`;
  `mkdir` is the atomic primitive (macOS has no `flock(1)`).
- **Crash recovery, no daemon/TTL**: the lock records the pid of the owning
  *agent process* (found by walking up the process tree past the throwaway tool
  shell). If that session dies, the next `acquire` sees a provably-dead holder
  and steals the lock automatically.
- **Fails closed**: anything the script cannot evaluate — unreadable info file,
  unparseable pid, a live process it may not signal, an unidentifiable owner —
  reads as **BUSY**, never as free. Absence of evidence is not absence of a
  holder.
- **Idempotent per session**: re-acquiring a lock the same session already
  holds succeeds.

## License

MIT
