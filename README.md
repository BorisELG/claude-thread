# claude-thread

Keep the thread of a long Claude Code session across `/clear`.

Large context windows are a bad idea. Push deep into the context window and the model starts forgetting what sits in the center. `/compact` doesn't help much, auto or not: Claude keeps a shorter, less accurate copy of the whole conversation, with the mistakes, bad ideas and things that didn't work still in it, and it costs a lot of tokens. With a clean handoff and a `/clear`, Claude starts fresh with only what it needs to continue, and uses far fewer tokens.

## How it works

- While you work, the hooks keep a handoff journal of the session: what you asked, the files Claude edited, and Claude's final answer of each turn. The messages between two tool calls, the tool calls and their output stay out of it.
- The journal costs no token. The hooks write it, not the agent: no model, no tool call, nothing in the Claude Code console. If a hook fails, it fails silently and your work goes on.
- After a `/clear` of a session that has a journal, Claude asks one question: `Continue the previous work ("<title>")?`
  - Reply `yes` (or `ok`, `continue`): the journal comes with your prompt, out of the transcript, and Claude continues from where it stopped.
  - Type anything else: it is a new request in a fresh session. Nothing is injected.
- Opening Claude Code, `/resume` and compaction never ask anything.
- A **thread** is a chain of sessions linked by `/clear` and a yes. `/clear` starts a new `session_id` inside the same Claude Code process, so the hooks use the process PID to link the new session to the one that just ended. Two sessions running in parallel, even on the same branch, never share a thread.
- Journals live outside your repository, in `~/.claude/threads/<session_id>.md`. The first line records the directory and the branch. On a yes, the journal is renamed to the new session and keeps growing, so a thread is one file:

```
# /home/you/projects/app · feat/login

## User
fix the login bug
- edited: src/auth.ts
- edited: tests/auth.spec.ts

## Claude
Fixed: the token expired too early. Test added, the suite is green.
```

## Install

```
/plugin marketplace add BorisELG/claude-thread
/plugin install claude-thread@claude-thread
```

Requirements: `bash`, `jq`. `git` is optional: outside a repository the thread has no branch. Linux and macOS.

Tests: `tests/thread.test.sh` runs the hooks against fake inputs, without Claude Code.

## Status line (optional)

A plugin cannot set the status line, so add it yourself. Copy `scripts/statusline.sh` somewhere stable and reference it in `~/.claude/settings.json`:

```json
"statusLine": { "type": "command", "command": "~/.claude/statusline.sh" }
```

It shows `session name · 87k` and turns red with `⚠ /clear` once the context passes 100k tokens. Set `CLAUDE_THREAD_LIMIT` to change the limit. The name is the one Claude Code shows in `/resume`: the one you set with `--name` or `/rename`, otherwise the generated title. Until a title exists, only the tokens show. After a `/clear`, the question stays on the status line until your first prompt.

## Settings

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLAUDE_THREAD_HOME` | `~/.claude/threads` | Where threads are stored |
| `CLAUDE_THREAD_LIMIT` | `100000` | Status line alert, in tokens |
| `CLAUDE_THREAD_MAX` | `60000` | How much of the journal a yes injects, in bytes, counted from its end |

## Limits

- The journal is a log, not a summary: nothing rewrites it. It holds what was asked and what was answered, not a list of dead ends.
- A turn you interrupt has no final answer, so the journal keeps only its request and its edited files.
- The question is asked once, right after the `/clear`. If you type something else, the cleared conversation is still there through `/resume`, and its journal stays on disk.
- The PID comes from the `CLAUDE_PID` environment variable, which Claude Code sets but does not document. When it is missing, the hook falls back to the parent of its own shell.
- Journals older than 30 days are deleted at the next `/clear`.

## License

MIT
