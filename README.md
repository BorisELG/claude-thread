# claude-thread

Keep the thread of a long Claude Code session across `/clear`.

Large context windows are a bad idea. Push deep into the context window and the model starts forgetting what sits in the center. `/compact` doesn't help much, auto or not: Claude keeps a shorter, less accurate copy of the whole conversation, with the mistakes, bad ideas and things that didn't work still in it, and it costs a lot of tokens. With a clean handoff and a `/clear`, Claude starts fresh with only what it needs to continue, and uses far fewer tokens.

## Install

```
/plugin marketplace add BorisELG/claude-thread
/plugin install claude-thread@claude-thread
```

Then get a key at [typesafe.ai](https://typesafe.ai) and set `TYPESAFE_API_KEY` in the environment Claude Code starts from. It lets [Jev](#jev) pick what still holds; without it, the handoff is the whole journal, dead ends included, and Claude Code says so when it opens.

Requirements: `bash`, `jq`, `curl`. Linux and macOS.

## How it works

1. While you work, hooks keep a journal of the session: your requests, the files Claude edited and Claude's final answer of each turn. No model, no token, nothing in the console.
2. After `/clear`, Claude asks: `Continue the previous work ("<title>")?`
3. Reply `yes`: the handoff comes with your prompt and Claude continues where it stopped. `yes, and fix the conflict first` works too. Anything else is a new request, and the cleared conversation stays in `/resume`.

The handoff is a state, not the conversation: your requests, the edited files, the last answer, and the earlier answers that still hold. Rejected options and replaced plans stay out. Nothing is summarized or rewritten.

Journals live in `~/.claude/threads/`, outside your repository, one file per thread:

```
# /home/you/projects/app · feat/login

## User
fix the login bug
- edited: src/auth.ts
- edited: tests/auth.spec.ts

## Claude
Fixed: the token expired too early. Test added, the suite is green.
```

Opening Claude Code, `/resume` and compaction never ask anything.

## Jev

[Jev](https://typesafe.ai) is a decision model: it answers yes/no questions about a state with a probability, and writes no text. At the end of every turn, in the background, the hook asks it whether each earlier answer of Claude still holds. On a yes, the answers scored 0.3 or more come back verbatim, best first, while the handoff stays under 9000 bytes.

Without it, nothing is sorted: the whole journal comes back, cut to `CLAUDE_THREAD_MAX` from the end.

- About 1 second and $0.001 per turn, after the turn ends. No Claude token.
- Every turn sends the journal to TypeSafe, whatever the project. Do not set the key if your conversations must not leave your machine.
- Scores are kept next to the journal, in `<session>.jev.json`. An answer scored under 0.3 is frozen: it keeps its score and is never sent again.
- A call that fails or takes more than 3 seconds changes nothing: the next turn scores again. An answer Jev never scored comes back first.

## Status line (optional)

A plugin cannot set the status line, so add it yourself. Copy `scripts/statusline.sh` somewhere stable and reference it in `~/.claude/settings.json`:

```json
"statusLine": { "type": "command", "command": "~/.claude/statusline.sh" }
```

It shows `session name · 87k` and turns red with `⚠ /clear` past 100k tokens (`CLAUDE_THREAD_LIMIT`). The name is the one `/resume` shows: `--name`, `/rename`, or the generated title. After a `/clear`, the question stays on the status line until your first prompt.

## Settings

| Variable | Default | Purpose |
| --- | --- | --- |
| `TYPESAFE_API_KEY` | none | Lets Jev pick the earlier answers that still hold |
| `CLAUDE_THREAD_HOME` | `~/.claude/threads` | Where threads are stored |
| `CLAUDE_THREAD_LIMIT` | `100000` | Status line alert, in tokens |
| `CLAUDE_THREAD_MAX` | `60000` | Hard limit of what a yes injects, in bytes, counted from the end |
| `CLAUDE_THREAD_STATE` | `30000` | Ceiling of one request to Jev, in bytes |

## Limits

- Jev keeps or drops a whole answer. An answer half outdated comes back whole or not at all.
- Above 10000 bytes, Claude Code moves the handoff to a file and Claude reads it with a tool call, which shows in the console. The earlier answers never push it past 9000 bytes; many long requests, a very long last answer or a journal without scores can.
- Messages from subagents and background tasks are not requests, so they stay out of the journal. A turn you interrupt keeps only its request and its edited files.
- `/clear` keeps the Claude Code process, so the hooks link sessions by its PID, read from `CLAUDE_PID`, which Claude Code sets but does not document. Without it, the hook falls back to the parent of its own shell. Two sessions running in parallel never share a thread.
- Journals older than 30 days are deleted at the next `/clear`.

Tests: `tests/thread.test.sh` runs the hooks against fake inputs, without Claude Code and without the network.

## License

MIT
