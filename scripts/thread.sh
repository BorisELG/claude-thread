#!/usr/bin/env bash
set -u
# A hook that fails shows a "hook error" line in Claude Code. Keeping the thread must
# never show up in the console: whatever goes wrong, stay silent and let the work go on.
exec 2>/dev/null
trap 'exit 0' EXIT
input=$(cat)
event=$(jq -r '.hook_event_name // empty' <<<"$input")
session=$(jq -r '.session_id // empty' <<<"$input")
[ -n "$session" ] || exit 0

# /clear gives the session a new session_id and the hook input does not name the
# previous one. The Claude Code process stays the same, so its PID links them.
pid=${CLAUDE_PID:-$(ps -o ppid= -p "$PPID" | tr -d ' ')}
dir=${CLAUDE_THREAD_HOME:-$HOME/.claude/threads}
link="$dir/.live/pid-$pid"
ask="$dir/.live/ask-$session"
doc="$dir/$session.md"

# The handoff is a journal the hooks keep while you work: what you asked, what Claude
# answered at the end of each turn, the files it edited. The hook writes it, not the
# agent, so there is no model, no token and no tool call.
note() {
  if [ ! -f "$doc" ]; then
    mkdir -p "$dir" || exit 0
    local cwd branch
    cwd=$(jq -r '.cwd // empty' <<<"$input")
    branch=$(git -C "$cwd" branch --show-current)
    printf '# %s%s\n' "$cwd" "${branch:+ · $branch}" >"$doc"
  fi
  printf '%s\n' "$@" >>"$doc"
}

case $event in
SessionEnd)
  [ "$(jq -r '.reason // empty' <<<"$input")" = clear ] || exit 0
  # A session cleared before any prompt has nothing to continue: keep the older link.
  if [ -f "$ask" ]; then
    rm -f "$ask"
    exit 0
  fi
  mkdir -p "$dir/.live"
  find "$dir" -type f -mtime +30 -delete
  if [ ! -f "$doc" ]; then
    rm -f "$link"
    exit 0
  fi
  title=$(jq -r '.session_title // empty' <<<"$input")
  [ -n "$title" ] || title=$(grep '"type":"ai-title"' "$(jq -r '.transcript_path // empty' <<<"$input")" | tail -n 1 | jq -r '.aiTitle // empty')
  printf '%s\n%s\n' "$session" "$title" >"$link"
  ;;
SessionStart)
  [ "$(jq -r '.source // empty' <<<"$input")" = clear ] || exit 0
  [ -f "$link" ] || exit 0
  { read -r previous && read -r title; } <"$link"
  [ -f "$dir/$previous.md" ] || exit 0
  echo "$previous" >"$ask"
  question="Continue the previous work${title:+ (\"$title\")}? Reply \"yes\" to continue it, or just type a new request."
  jq -n --arg question "$question" '{
    systemMessage: $question, suppressOutput: true,
    hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: "The user just ran /clear and was shown this question: \($question)\nA hook reads the answer: on a yes, the handoff of the previous work comes with their prompt.\nAny other prompt is a new request. Do not mention the previous work."}}'
  ;;
UserPromptSubmit)
  prompt=$(jq -r '.prompt // empty' <<<"$input")
  if [ -f "$ask" ]; then
    previous=$(cat "$ask")
    rm -f "$ask"
    shopt -s nocasematch
    if [[ $prompt =~ ^[[:space:]]*(y|yes|yep|yeah|yup|sure|ok|okay|go|o|oui|ouais|continue|continuer|reprends|reprendre)([^[:alnum:]]|$) ]] && [ -f "$dir/$previous.md" ]; then
      # A thread is a chain of continued sessions. Its journal follows the live one.
      mv "$dir/$previous.md" "$doc"
      jq -n --rawfile handoff <(tail -c "${CLAUDE_THREAD_MAX:-60000}" "$doc") '{
        suppressOutput: true,
        hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: "The user chose to continue the previous work. Here is its handoff, a journal kept by a hook: what the user asked, the files you edited, and your final answer of each turn. Continue from where it stopped, do not ask again for what it already says. If nothing is left to do, say so in one sentence and wait.\n\n\($handoff)"}}'
      exit 0
    fi
  fi
  note "" "## User" "$prompt"
  ;;
Stop)
  answer=$(jq -r '.last_assistant_message // empty' <<<"$input")
  [ -z "$answer" ] || note "" "## Claude" "$answer"
  ;;
PostToolUse)
  file=$(jq -r '.tool_input | .file_path // .notebook_path // empty' <<<"$input")
  file=${file#"$(jq -r '.cwd // empty' <<<"$input")"/}
  [ -z "$file" ] || grep -qsxF -- "- edited: $file" "$doc" || note "- edited: $file"
  ;;
esac
