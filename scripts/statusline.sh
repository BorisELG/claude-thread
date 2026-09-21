#!/usr/bin/env bash
limit=${CLAUDE_THREAD_LIMIT:-100000}
input=$(cat)
tokens=$(jq -r '.context_window.total_input_tokens // 0' <<<"$input")
name=$(jq -r '.session_name // empty' <<<"$input")
label="${name:+${name:0:40} · }$((tokens / 1000))k"
# After a /clear, the question of the hook stays here until the first prompt.
if [ -f "${CLAUDE_THREAD_HOME:-$HOME/.claude/threads}/.live/ask-$(jq -r '.session_id // empty' <<<"$input")" ]; then
  label="$label · continue the previous work? reply yes"
fi
if [ "$tokens" -ge "$limit" ]; then
  printf '\033[1;31m%s ⚠ /clear\033[0m' "$label"
else
  printf '%s' "$label"
fi
