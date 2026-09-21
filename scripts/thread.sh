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

# Jev (typesafe.ai) is a decision model: it reads the journal and tells, for each earlier
# answer, how likely it still holds. It writes no text, so what comes back stays verbatim.
# Prints {"s<id>": probability}. Without a key, without an earlier answer or on any failure
# it prints nothing, and the handoff does without it.
jev() {
  local request
  [ -n "${TYPESAFE_API_KEY:-}" ] || return 0
  request=$(jq '{model: "jev-latest", state: [.sections[] | {id, author, text}],
    questions: (.sections | map(select(.keep | not) | {key: "s\(.id)", value: {type: "noul",
      instructions: "Section \(.id) is an answer written by the assistant earlier in this work session. At the end of the session, is section \(.id) still in force and still useful to continue the work?",
      criteria: {
        "true": "Its content still holds at the end: nothing later replaces it, and the user did not abandon, reject or correct it afterwards.",
        "false": "It is outdated: a later section replaces or revises it, or the user later abandoned, rejected or corrected what it proposes."}}}) | from_entries)}
    | select(.questions != {})')
  [ -n "$request" ] || return 0
  # The key goes through a config file descriptor, so it never shows up in ps.
  curl -sS -m 3 https://api.typesafe.ai/v1/systemone -H 'Content-Type: application/json' --data @- \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$TYPESAFE_API_KEY") <<<"$request" |
    jq -e '.answers | map_values(.noul)'
}

# A yes brings back a state, not the whole conversation: the requests, the edited files and
# the last answer, always. The earlier answers hold the options, plans and verdicts that
# were replaced since: only the ones Jev still believes in come back, best first, while the
# handoff stays under 9000 bytes. Above 10000, Claude Code moves a hook's context to a file
# and Claude has to read it with a tool call, which shows in the console. On real journals
# the answers that were replaced score under 0.25.
handoff() {
  local journal scores
  journal=$(awk '/^## (User|Claude)$/ { printf "\036%s\037", $2; next } { print }' "$doc" |
    jq -Rs 'split("\u001e") | .[0] as $head
      | [.[1:][] | split("\u001f") | {author: .[0], text: .[1]}] | to_entries | map(.value + {id: .key}) as $sections
      | ([$sections[] | select(.author == "Claude") | .id] | max // -1) as $last
      | {head: $head, sections: [$sections[] | . + {keep: (.author == "User" or .id >= $last)}]}')
  scores=$(jev <<<"$journal") || scores=
  jq -r --argjson scores "${scores:-{\}}" 'def size: "## \(.author)\n\(.text)" | utf8bytelength;
    (reduce (.sections | map(select(.keep | not) | . + {score: ($scores["s\(.id)"] // 0)} | select(.score >= 0.3)) | sort_by(-.score))[] as $answer
      ({bytes: ((.head | utf8bytelength) + (.sections | map(select(.keep) | size) | add // 0)), ids: []};
        if .bytes + ($answer | size) <= 9000 then {bytes: (.bytes + ($answer | size)), ids: (.ids + [$answer.id])} else . end)
      | .ids) as $back
    | .head + (.sections | map(select(.keep or (.id | IN($back[]))) | "## \(.author)\n\(.text)") | join(""))' <<<"$journal"
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
  # Subagents and background tasks report through this event too. They are not requests.
  [[ $prompt != '<agent-message'* && $prompt != '<task-notification'* ]] || exit 0
  if [ -f "$ask" ]; then
    previous=$(cat "$ask")
    rm -f "$ask"
    shopt -s nocasematch
    if [[ $prompt =~ ^[[:space:]]*(y|yes|yep|yeah|yup|sure|ok|okay|go|o|oui|ouais|continue|continuer|reprends|reprendre)([^[:alnum:]]|$) ]] && [ -f "$dir/$previous.md" ]; then
      # A thread is a chain of continued sessions. Its journal follows the live one.
      mv "$dir/$previous.md" "$doc"
      jq -n --rawfile handoff <(handoff | tail -c "${CLAUDE_THREAD_MAX:-60000}") '{
        suppressOutput: true,
        hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: "The user chose to continue the previous work. Here is its handoff, kept by a hook: what the user asked, the files you edited, your last answer and the earlier ones that still hold. The answers that were replaced or abandoned since are left out on purpose. Continue from where it stopped, do not ask again for what it already says. If nothing is left to do, say so in one sentence and wait.\n\n\($handoff)"}}'
      # "yes, and fix the conflict first" is a request too. A bare yes is not.
      [[ ! ${prompt:${#BASH_REMATCH[0]}} =~ [[:alnum:]] ]] || note "" "## User" "$prompt"
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
