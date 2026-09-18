#!/usr/bin/env bash
limit=${CLAUDE_THREAD_LIMIT:-100000}
input=$(cat)
tokens=$(jq -r '.context_window.total_input_tokens // 0' <<<"$input")
dir=$(jq -r '.workspace.current_dir // "."' <<<"$input")
branch=$(git -C "$dir" branch --show-current 2>/dev/null)
label="${branch:+${branch:0:32} · }$((tokens / 1000))k"
if [ "$tokens" -ge "$limit" ]; then
  printf '\033[1;31m%s ⚠ /clear\033[0m' "$label"
else
  printf '%s' "$label"
fi
