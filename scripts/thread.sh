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
# previous one. The Claude Code process stays the same, so its PID links them. The link
# follows every journal write, so a /clear needs nothing from the end of the session.
pid=${CLAUDE_PID:-$(ps -o ppid= -p "$PPID" | tr -d ' ')}
dir=${CLAUDE_THREAD_HOME:-$HOME/.claude/threads}
link="$dir/.live/pid-$pid"
ask="$dir/.live/ask-$session"
doc="$dir/$session.md"
notes="$dir/$session.jev.json"
transcript=$(jq -r '.transcript_path // empty' <<<"$input")
# The transcripts of the sessions of a thread sit side by side.
previous_transcript() { printf '%s/%s.jsonl' "$(dirname "$transcript")" "$1"; }

# The name /resume shows for a transcript: the name the user gave, else the generated title.
name() {
  local found
  found=$(grep '"type":"custom-title"' "$1" | tail -n 1 | jq -r '.customTitle // empty')
  [ -n "$found" ] || found=$(grep '"type":"ai-title"' "$1" | tail -n 1 | jq -r '.aiTitle // empty')
  printf '%s' "$found"
}

# The link names the session whose journal a /clear of this process continues.
live() { mkdir -p "$dir/.live" && printf '%s\n' "$session" >"$link"; }

# The handoff is a journal the hooks keep while you work: what you asked and what Claude
# answered at the end of each turn. The edited files stay out: git diff shows them after
# the yes. The hook writes it, not the agent, so there is no model, no token and no tool call.
note() {
  if [ ! -f "$doc" ]; then
    mkdir -p "$dir" || exit 0
    local cwd branch
    cwd=$(jq -r '.cwd // empty' <<<"$input")
    branch=$(git -C "$cwd" branch --show-current)
    printf '# %s%s\n' "$cwd" "${branch:+ · $branch}" >"$doc"
  fi
  printf '%s\n' "$@" >>"$doc"
  live
}

# The journal as sections: the head line, then one entry per request or answer, in order.
# The ids are positions, stable because the journal is append-only.
sections() {
  awk '/^## (User|Claude)$/ { printf "\036%s\037", $2; next } { print }' "$doc" |
    jq -Rs 'split("\u001e") | .[0] as $head
      | [.[1:][] | split("\u001f") | {author: .[0], text: .[1]}] | to_entries
      | {head: $head, sections: map(.value + {id: .key})}'
}

# The scores Jev gave so far, kept next to the journal: {last, scores: {"s<id>": probability}}.
stored() {
  jq -c '{last: (.last // -1), scores: (.scores // {})}' "$notes" 2>/dev/null || echo '{"last": -1, "scores": {}}'
}

# How many earlier answers have no score yet, from the journal on stdin: a call failed, is
# still running, or left them beyond the ceiling.
unscored() {
  jq --argjson scores "$(stored | jq .scores)" '
    ([.sections[] | select(.author == "Claude") | .id] | max // -1) as $last
    | [.sections[] | select(.author == "Claude" and .id < $last and $scores["s\(.id)"] == null)] | length'
}
behind() { [ "$(sections | unscored)" -gt 0 ]; }

# Jev (typesafe.ai) is a decision model: it reads a state and tells, for each earlier answer,
# how likely it still holds. It writes no text, so what comes back stays verbatim.
# Every turn sends the requests, the earlier answers still alive and the last answer, and
# asks about each alive answer. An answer scored under 0.3 is frozen: it keeps its score and
# is never sent again. A request stays under CLAUDE_THREAD_STATE bytes: the lowest scored
# answers are left out first and keep their score, and an unscored answer left out gets
# another round, up to the rounds given. Without a key, without anything to ask or on any
# failure, nothing is written.
score() { # [rounds]
  local rounds=${1:-5} journal request answers last merged before
  journal=$(cat)
  [ -n "${TYPESAFE_API_KEY:-}" ] || return 0
  while [ "$rounds" -gt 0 ]; do
    rounds=$((rounds - 1))
    before=$(unscored <<<"$journal")
    round || return 0
    # Another round only while an unscored answer was left out and this one scored a new one.
    [ "$(unscored <<<"$journal")" -gt 0 ] && [ "$(unscored <<<"$journal")" -lt "$before" ] || return 0
  done
}
round() {
  request=$(jq --argjson scores "$(stored | jq .scores)" --argjson max "${CLAUDE_THREAD_STATE:-30000}" '
    def size: {id, author, text} | tojson | utf8bytelength;
    ([.sections[] | select(.author == "Claude") | .id] | max // -1) as $last
    | [.sections[] | select(.author == "User" or .id >= $last)] as $fixed
    | ([.sections[] | select(.author == "Claude" and .id < $last)
        | . + {score: ($scores["s\(.id)"] // 1)} | select(.score >= 0.3)] | sort_by(-.score, -.id)) as $alive
    | ($fixed | map(size) | add // 0) as $base
    | select($alive != [] and $base <= $max)
    | (reduce $alive[] as $s ({bytes: $base, ids: [], full: false};
        if .full or .bytes + ($s | size) > $max then .full = true
        else {bytes: (.bytes + ($s | size)), ids: (.ids + [$s.id]), full: false} end) | .ids) as $in
    | select($in != [])
    | {model: "jev-latest",
       state: (($fixed + [$alive[] | select(.id | IN($in[]))]) | sort_by(.id) | map({id, author, text})),
       questions: ([$in[] | {key: "s\(.)", value: {type: "noul",
         instructions: "Section \(.) is an answer written by the assistant earlier in this work session. At this point of the session, is section \(.) still in force and still useful to continue the work?",
         criteria: {
           "true": "Its content still holds now: nothing later replaces it, and the user did not abandon, reject or correct it afterwards.",
           "false": "It is outdated: a later section replaces or revises it, or the user later abandoned, rejected or corrected what it proposes."}}}] | from_entries)}' <<<"$journal") || return 0
  [ -n "$request" ] || return 0
  # The key goes through a config file descriptor, so it never shows up in ps.
  answers=$(curl -sS -m 3 https://api.typesafe.ai/v1/systemone -H 'Content-Type: application/json' --data @- \
    -K <(printf 'header = "Authorization: Bearer %s"\n' "$TYPESAFE_API_KEY") <<<"$request" |
    jq -ec '.answers | map_values(.noul) | select(all(.[]; type == "number"))') || return 0
  last=$(jq '.state | map(select(.author == "Claude") | .id) | max' <<<"$request")
  # A slow call from an earlier turn must not overwrite newer scores.
  merged=$(jq -nc --argjson old "$(stored)" --argjson new "$answers" --argjson last "$last" \
    'select($old.last <= $last) | {last: $last, scores: ($old.scores + $new)}') || return 0
  [ -n "$merged" ] || return 0
  printf '%s\n' "$merged" >"$notes.$$" && mv -f "$notes.$$" "$notes"
}

# A yes brings back a state, not the whole conversation: the requests and the last answer,
# always. The earlier answers hold the options, plans and verdicts that
# were replaced since: only the ones Jev scored 0.3 or more come back, best first, while the
# handoff stays under 9000 bytes. An answer Jev never scored comes back first: nothing judged
# it. Above 10000, Claude Code moves a hook's context to a file and Claude has to read it
# with a tool call, which shows in the console. Without any score, the hook does not sort:
# the whole journal comes back.
handoff() {
  if [ ! -f "$notes" ]; then
    sections | jq -r '.head + (.sections | map("## \(.author)\n\(.text)") | join(""))'
    return
  fi
  sections | jq -r --argjson scores "$(stored | jq .scores)" 'def size: "## \(.author)\n\(.text)" | utf8bytelength;
    ([.sections[] | select(.author == "Claude") | .id] | max // -1) as $last
    | (.sections | map(. + {keep: (.author == "User" or .id >= $last)})) as $sections
    | ($sections | map(select(.keep | not) | . + {score: ($scores["s\(.id)"] // 1)} | select(.score >= 0.3)) | sort_by(-.score, -.id)) as $ranked
    | (reduce $ranked[] as $answer
        ({bytes: ((.head | utf8bytelength) + ($sections | map(select(.keep) | size) | add // 0)), ids: []};
          if .bytes + ($answer | size) <= 9000 then {bytes: (.bytes + ($answer | size)), ids: (.ids + [$answer.id])} else . end)
      | .ids) as $back
    | .head + ($sections | map(select(.keep or (.id | IN($back[]))) | "## \(.author)\n\(.text)") | join(""))'
}

case $event in
SessionStart)
  source=$(jq -r '.source // empty' <<<"$input")
  # The key comes from the environment Claude Code starts from, so a missing one is
  # said once, when it opens. Without Jev, a yes brings back the whole journal.
  if [ "$source" = startup ] || [ "$source" = resume ]; then
    [ -z "${TYPESAFE_API_KEY:-}" ] || exit 0
    jq -n '{systemMessage: "claude-thread: TYPESAFE_API_KEY is not set. Without Jev, a yes after /clear brings back the whole journal, dead ends included. Get a key at https://typesafe.ai", suppressOutput: true}'
    exit 0
  fi
  [ "$source" = clear ] || exit 0
  find "$dir" -type f -mtime +30 -delete
  [ -f "$link" ] || exit 0
  previous=$(head -n 1 "$link")
  [ -f "$dir/$previous.md" ] || exit 0
  title=$(name "$(previous_transcript "$previous")")
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
      [ ! -f "$dir/$previous.jev.json" ] || mv -f "$dir/$previous.jev.json" "$notes"
      live
      # A thread keeps one name in /resume, the name of the session it continues. Claude Code
      # carries a name given with /rename by itself, but gives each session after a /clear a
      # new generated title. The new session takes the name as its own, so the next yes
      # carries it again.
      title=$(name "$(previous_transcript "$previous")")
      if [ -n "$title" ] && [ -n "$transcript" ] && ! grep -q '"type":"custom-title"' "$transcript"; then
        mkdir -p "$(dirname "$transcript")" &&
          jq -nc --arg title "$title" --arg session "$session" \
            '{type: "custom-title", customTitle: $title, sessionId: $session}' >>"$transcript"
      fi
      # A short catch-up when the last turn's scoring failed; the yes then uses whatever is stored.
      ! behind || sections | score 2
      jq -n --rawfile handoff <(handoff | tail -c "${CLAUDE_THREAD_MAX:-60000}") '{
        suppressOutput: true,
        hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: "The user chose to continue the previous work. Here is its handoff, kept by a hook: what the user asked, your last answer and the earlier ones that still hold. The answers that were replaced or abandoned since are left out on purpose. Continue from where it stopped, do not ask again for what it already says. If the yes came with a question or a request, answer it first. If nothing is left to do, say so in one sentence and wait.\n\n\($handoff)"}}'
      # "yes, and fix the conflict first" is a request too. A bare yes is not.
      [[ ! ${prompt:${#BASH_REMATCH[0]}} =~ [[:alnum:]] ]] || note "" "## User" "$prompt"
      exit 0
    fi
  fi
  note "" "## User" "$prompt"
  ;;
Stop)
  answer=$(jq -r '.last_assistant_message // empty' <<<"$input")
  [ -n "$answer" ] || exit 0
  note "" "## Claude" "$answer"
  # Scoring runs detached, with every descriptor closed, so the turn ends at once: Claude
  # Code waits for the hook's output pipe, and a background list would keep it open.
  if [ -n "${TYPESAFE_API_KEY:-}" ]; then
    (sections | score) >/dev/null 2>&1 </dev/null &
  fi
  ;;
esac
