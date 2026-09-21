#!/usr/bin/env bash
# Runs the hook and status line scripts against fake inputs. No Claude Code needed.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
export CLAUDE_THREAD_HOME="$work/threads"
threads=$CLAUDE_THREAD_HOME
repo="$work/repo"
git init -q -b feat/login "$repo"

A=aaaaaaaa-0000 B=bbbbbbbb-0000 C=cccccccc-0000 D=dddddddd-0000 E=eeeeeeee-0000 F=ffffffff-0000 G=99999999-0000

hook() { # event session pid [extra json]
  jq -n --arg e "$1" --arg s "$2" --arg d "$repo" --argjson x "${4:-{\}}" '{hook_event_name: $e, session_id: $s, cwd: $d} + $x' |
    CLAUDE_PID="$3" "$root/scripts/thread.sh"
}
title() { jq -nc --arg t "$2" '{type: "ai-title", aiTitle: $t}' >"$work/$1.jsonl"; } # session title
clear_from() { hook SessionEnd "$1" "$2" "{\"reason\":\"clear\",\"transcript_path\":\"$work/$1.jsonl\"}"; }
clear_to() { hook SessionStart "$1" "$2" '{"source":"clear"}'; }
prompt() { hook UserPromptSubmit "$1" 111 "$(jq -n --arg p "$2" '{prompt: $p}')"; }
stop() { hook Stop "$1" 111 "$(jq -n --arg m "$2" '{last_assistant_message: $m}')"; }
edit() { hook PostToolUse "$1" 111 "$(jq -n --arg f "$2" '{tool_name: "Edit", tool_input: {file_path: $f}}')"; }
statusline() { # session [name]
  jq -n --arg s "$1" --arg n "${2:-}" '{session_id: $s, context_window: {total_input_tokens: 12345}}
    + if $n == "" then {} else {session_name: $n} end' | "$root/scripts/statusline.sh"
}
check() { # label condition...
  local label=$1
  shift
  if "$@"; then echo "ok   $label"; else
    echo "FAIL $label"
    failed=1
  fi
}
# shellcheck disable=SC2329
empty() { [ -z "$1" ]; }
# shellcheck disable=SC2329
has() { grep -qF -- "$2" <<<"$1"; }
# shellcheck disable=SC2329
lacks() { ! grep -qF -- "$2" <<<"$1"; }
injected() { jq -r '.hookSpecificOutput.additionalContext' <<<"$1"; }
journals() {
  set -- "$threads"/*.md
  echo $#
}

out=$(hook SessionStart "$A" 111 '{"source":"startup"}')
check "opening Claude Code prints nothing" empty "$out"
check "opening Claude Code creates nothing" [ ! -e "$threads" ]
out=$(clear_to "$B" 111)
check "/clear without a previous session prints nothing" empty "$out"

out=$(prompt "$A" "ship the thing" 2>&1)
code=$?
check "a prompt is journaled without a word" empty "$out"
check "a prompt is journaled without an error" [ "$code" = 0 ]
out=$(
  edit "$A" "$repo/src/deploy.sh" 2>&1
  edit "$A" "$repo/src/deploy.sh" 2>&1
)
check "an edit is journaled without a word" empty "$out"
out=$(stop "$A" "Shipped, the deploy is green." 2>&1)
check "an answer is journaled without a word" empty "$out"
journal=$(cat "$threads/$A.md")
check "the journal starts with the directory and the branch" has "$(head -n 1 <<<"$journal")" "$repo · feat/login"
check "the journal holds the request" has "$journal" "ship the thing"
check "the journal holds the final answer" has "$journal" "Shipped, the deploy is green."
check "an edited file is listed once, from the directory" [ "$(grep -c -- '^- edited: src/deploy.sh$' <<<"$journal")" = 1 ]
out=$(CLAUDE_THREAD_HOME=/proc/nope prompt "$A" "hello" 2>&1)
code=$?
check "a journal that cannot be written says nothing" empty "$out"
check "a journal that cannot be written is not an error" [ "$code" = 0 ]

title "$A" "Ship the thing"
touch -d '40 days ago' "$threads/old.md"
clear_from "$A" 111
check "/clear drops the journals older than 30 days" [ ! -e "$threads/old.md" ]
out=$(clear_to "$B" 111)
check "/clear asks to continue, not to resume" has "$(jq -r .systemMessage <<<"$out")" 'Continue the previous work ("Ship the thing")?'
check "/clear hides the hook output from the transcript" [ "$(jq -r .suppressOutput <<<"$out")" = true ]
check "the status line shows the question" has "$(statusline "$B")" "continue the previous work? reply yes"
out=$(clear_to "$F" 222)
check "another process is not asked" empty "$out"

out=$(prompt "$B" "fix the login bug
continue the download where it stopped")
check "a new request gets nothing" empty "$out"
check "a new request leaves the older journal alone" has "$(cat "$threads/$A.md")" "Shipped, the deploy is green."
check "a new request starts its own journal" has "$(cat "$threads/$B.md")" "fix the login bug"
check "the status line drops the question after the first prompt" lacks "$(statusline "$B")" "continue"
out=$(prompt "$B" "yes")
check "the question is asked once" empty "$out"

stop "$B" "Fixed, the token was expired."
clear_from "$B" 111
out=$(clear_to "$C" 111)
check "without a title the question still reads" has "$(jq -r .systemMessage <<<"$out")" "Continue the previous work? Reply"
clear_from "$C" 111
clear_to "$D" 111 >/dev/null
check "a session cleared before any prompt keeps the older link" has "$(cat "$threads/.live/ask-$D")" "$B"

out=$(prompt "$D" "Oui, on continue")
check "yes injects the final answer" has "$(injected "$out")" "Fixed, the token was expired."
check "yes injects the request" has "$(injected "$out")" "fix the login bug"
check "the injection is hidden from the transcript" [ "$(jq -r .suppressOutput <<<"$out")" = true ]
check "the journal follows the live session" [ -f "$threads/$D.md" ]
check "the journal leaves the cleared session" [ ! -e "$threads/$B.md" ]
check "the yes is not journaled" lacks "$(cat "$threads/$D.md")" "Oui, on continue"

prompt "$D" "now add a test"
stop "$D" "Test added."
clear_from "$D" 111
clear_to "$E" 111 >/dev/null
out=$(prompt "$E" "yes")
check "the thread carries the earlier sessions" has "$(injected "$out")" "Fixed, the token was expired."
check "the thread carries the last session" has "$(injected "$out")" "Test added."
check "a thread is one file" [ "$(journals)" = 2 ]

clear_from "$G" 111
out=$(clear_to "$F" 111)
check "a session with no journal asks nothing" empty "$out"

check "the status line shows the session name, not the branch" [ "$(statusline "$A" "Ship the thing")" = "Ship the thing · 12k" ]
check "the status line works without a name" [ "$(statusline "$A")" = "12k" ]

exit $failed
