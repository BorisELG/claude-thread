# claude-thread

Keep the thread of a long Claude Code session across `/clear`.

`/compact` replaces your context with a summary you did not write. `/clear` gives you a clean context, but the agent forgets where the task stands and what was decided. `claude-thread` makes the agent keep two small files up to date and re-injects them at every session start, so a `/clear` costs nothing.

## How it works

- A **thread** is a chain of sessions linked by `/clear`. `/clear` starts a new `session_id` inside the same Claude Code process, so the hook uses the process PID to link the new session to the thread of the previous one. Two sessions running in parallel, even on the same branch, never share a thread.
- Files live outside your repository, in `~/.claude/threads/<repo>/`:
  - `<thread>.md`: the current state (goal, done / doing / todo, dead ends, next action). The agent rewrites it after every finished step. Its first line records the branch and the worktree.
  - `decisions.md`: one line per settled decision, append-only: `date | thread | branch | ticket | domain | decision | why | rejected`.
- The `SessionStart` hook prints the writing rules, the decisions of the thread and of the branch (20 at most), then the state file. On a fresh start it points to the latest thread of the current branch instead. A resumed session gets nothing: its context is already back.
- The filtering runs in the shell. Only the result enters the context.

## Install

```
/plugin marketplace add BorisELG/claude-thread
/plugin install claude-thread@claude-thread
```

Requirements: `bash`, `jq`. `git` is optional: outside a repository the thread has no branch. Linux and macOS.

## Status line (optional)

A plugin cannot set the status line, so add it yourself. Copy `scripts/statusline.sh` somewhere stable and reference it in `~/.claude/settings.json`:

```json
"statusLine": { "type": "command", "command": "~/.claude/statusline.sh" }
```

It shows `branch · 87k` and turns red with `⚠ /clear` once the context passes 100k tokens. Set `CLAUDE_THREAD_LIMIT` to change the limit.

## Settings

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLAUDE_THREAD_HOME` | `~/.claude/threads` | Where threads are stored |
| `CLAUDE_THREAD_LIMIT` | `100000` | Status line alert, in tokens |

## Limits

- No hook can run before `/clear`. If the state file is stale, tell the agent "update the thread" first. The cleared conversation stays available through `/resume`.
- The PID comes from the `CLAUDE_PID` environment variable, which Claude Code sets but does not document. When it is missing, the hook falls back to the parent of its own shell.
- Nothing is deleted. Old threads stay readable, and `decisions.md` is the history.

## License

MIT
