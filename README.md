# claude-thread

Keep the thread of a long Claude Code session across `/clear`.

Large context windows are a bad idea. Push deep into the context window and the model starts forgetting what sits in the center. `/compact` doesn't help much, auto or not: Claude keeps a shorter, less accurate copy of the whole conversation, with the mistakes, bad ideas and things that didn't work still in it, and it costs a lot of tokens. With a clean handoff and a `/clear`, Claude starts fresh with only what it needs to continue, and uses far fewer tokens.

## How it works

- While you work, the hooks keep a handoff journal of the session: what you asked, the files Claude edited, and Claude's final answer of each turn. The messages between two tool calls, the tool calls and their output stay out of it.
- The journal costs no token. The hooks write it, not the agent: no model, no tool call, nothing in the Claude Code console. If a hook fails, it fails silently and your work goes on.
- After a `/clear` of a session that has a journal, Claude asks one question: `Continue the previous work ("<title>")?`
  - Reply `yes` (or `ok`, `continue`): the handoff comes with your prompt, out of the transcript, and Claude continues from where it stopped. What you type after the yes is part of the request: `yes, and fix the conflict first`.
  - Type anything else: it is a new request in a fresh session. Nothing is injected.
- The handoff is a state, not the conversation. It always holds your requests, the edited files and Claude's last answer. The earlier answers are where the rejected options, the replaced plans and the revised verdicts live, so they stay out, unless [Jev](#jev-optional) says they still hold.
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

Requirements: `bash`, `jq`. `git` is optional: outside a repository the thread has no branch. `curl` is only needed for Jev. Linux and macOS.

Tests: `tests/thread.test.sh` runs the hooks against fake inputs, without Claude Code and without the network.

## Jev (optional)

[Jev](https://typesafe.ai) is a decision model: it answers yes/no questions about a state with a probability, and writes no text. On a yes, the hook sends it the journal and asks, for each earlier answer of Claude, whether it still holds at the end of the session. The answers come back best first, from a probability of 0.3, while the handoff stays under 9000 bytes. Everything that comes back is verbatim: nothing is summarized or rewritten.

- Set `TYPESAFE_API_KEY` in the environment Claude Code starts from. Without it, nothing is sent and the handoff holds your requests, the edited files and the last answer.
- One call per yes, about 1 second and $0.001 for a 50 KB journal. No Claude token.
- With the key set, every yes sends that journal to TypeSafe, whatever the project. Do not set it if your conversations must not leave your machine.
- No answer within 3 seconds, or any error: the handoff does without Jev, silently.

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
| `CLAUDE_THREAD_MAX` | `60000` | Hard limit of what a yes injects, in bytes, counted from the end |
| `TYPESAFE_API_KEY` | none | Lets Jev pick the earlier answers that still hold |

## Limits

- The journal is a log, not a summary: nothing rewrites it, and it stays whole on disk. Only the handoff is selective.
- Jev keeps or drops a whole answer. An answer that is half outdated comes back whole or not at all.
- Above 10000 bytes, Claude Code moves the handoff to a file and Claude reads it with a tool call, which shows in the console. The earlier answers never push the handoff past 9000 bytes, but many long requests or a very long last answer can.
- Messages from subagents and background tasks are not requests, so they stay out of the journal.
- A turn you interrupt has no final answer, so the journal keeps only its request and its edited files.
- The question is asked once, right after the `/clear`. If you type something else, the cleared conversation is still there through `/resume`, and its journal stays on disk.
- The PID comes from the `CLAUDE_PID` environment variable, which Claude Code sets but does not document. When it is missing, the hook falls back to the parent of its own shell.
- Journals older than 30 days are deleted at the next `/clear`.

## License

MIT
