#!/usr/bin/env bash
set -u
input=$(cat)
session=$(jq -r '.session_id // empty' <<<"$input")
source=$(jq -r '.source // "startup"' <<<"$input")
cwd=$(jq -r '.cwd // "."' <<<"$input")
[ -n "$session" ] || exit 0
cd "$cwd" 2>/dev/null || exit 0

# /clear gives the session a new session_id and the hook input does not name the
# previous one. The Claude Code process stays the same, so its PID links them.
pid=${CLAUDE_PID:-$(ps -o ppid= -p "$PPID" | tr -d ' ')}
branch=$(git branch --show-current 2>/dev/null)
top=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
repo=$(basename -s .git "$(git remote get-url origin 2>/dev/null || echo "$top")")
dir="${CLAUDE_THREAD_HOME:-$HOME/.claude/threads}/$repo"
mkdir -p "$dir/.live"
find "$dir/.live" -type f -mtime +30 -delete 2>/dev/null

thread=""
if [ "$source" = clear ] || [ "$source" = compact ]; then
  thread=$(cat "$dir/.live/$pid" 2>/dev/null)
fi
[ -n "$thread" ] || thread=$(awk -v s="$session" '$1 == s { t = $2 } END { print t }' "$dir/.sessions" 2>/dev/null)
[ -n "$thread" ] || thread=${session:0:8}
echo "$thread" >"$dir/.live/$pid"
grep -qs "^$session " "$dir/.sessions" || echo "$session $thread" >>"$dir/.sessions"

# A resumed session gets its whole context back, so only the link is refreshed.
[ "$source" = resume ] && exit 0

state="$dir/$thread.md"
cat <<EOF
# Thread $thread
This work uses /clear instead of compaction. Keep this thread up to date so the next session can resume from it.
- State file: $state
  Rewrite it in full after every finished step. At most 60 lines. Link to specs and plans, do not copy them. Layout:
  branch: ${branch:-none} | worktree: $top | ticket: <id or none> | updated: <date>
  ## Goal / ## State (done, doing, todo) / ## Dead ends / ## Next action
- Decision log: $dir/decisions.md
  Append one line per settled decision and never edit a line:
  <date> | $thread | ${branch:-none} | <ticket> | <domain> | <decision> | why: ... | rejected: ...
  A revised decision is a new line that quotes the date of the old one.
- Update both without being asked, at every settled decision and every finished step.
- For a question about past decisions, read decisions.md once. Do not search around.
EOF

if [ -f "$dir/decisions.md" ]; then
  filters=(-e "| $thread |")
  [ -n "$branch" ] && filters+=(-e "| $branch |")
  lines=$(grep -F "${filters[@]}" "$dir/decisions.md" | tail -n 20)
  [ -n "$lines" ] && printf '## Decisions so far\n%s\n' "$lines"
fi

if [ -f "$state" ]; then
  echo "## Current state: resume from here, do not ask again for what it already says"
  cat "$state"
elif [ -n "$branch" ]; then
  matches=$(grep -lsF "branch: $branch |" "$dir"/*.md)
  if [ -n "$matches" ]; then
    # shellcheck disable=SC2086
    previous=$(ls -t $matches | head -n 1)
    echo "## Earlier thread on this branch: $previous"
    echo "Read it if the user continues that work, then carry its state into the new state file."
  fi
fi
