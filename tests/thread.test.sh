#!/usr/bin/env bash
# Runs the hook and status line scripts against fake inputs. No Claude Code needed.
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
unset TYPESAFE_API_KEY
export CLAUDE_THREAD_HOME="$work/threads"
threads=$CLAUDE_THREAD_HOME
repo="$work/repo"
git init -q -b feat/login "$repo"

# No test reaches the network: this curl stands for the Jev API. It records the call and
# answers what the test prepared with jev.
export fake="$work/jev"
mkdir -p "$fake" "$work/bin"
cat >"$work/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$fake/args"
while [ $# -gt 0 ]; do
  [ "$1" != -K ] || cat "$2" >"$fake/config"
  shift
done
cat >"$fake/request.json"
cat "$fake/response"
exit "$(cat "$fake/exit")"
EOF
chmod +x "$work/bin/curl"
PATH="$work/bin:$PATH"
jev() { # response [exit code]
  rm -f "$fake/args" "$fake/config" "$fake/request.json"
  echo "$1" >"$fake/response"
  echo "${2:-0}" >"$fake/exit"
}

A=aaaaaaaa-0000 B=bbbbbbbb-0000 C=cccccccc-0000 D=dddddddd-0000 E=eeeeeeee-0000 F=ffffffff-0000 G=99999999-0000
H=11111111-0000 I=22222222-0000 J=33333333-0000 K=44444444-0000 L=55555555-0000 M=66666666-0000
N=77777777-0000 O=88888888-0000 P=12121212-0000 Q=34343434-0000

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

out=$(prompt "$D" "Oui, et regarde aussi le logout")
check "yes injects the final answer" has "$(injected "$out")" "Fixed, the token was expired."
check "yes injects the request" has "$(injected "$out")" "fix the login bug"
check "the injection is hidden from the transcript" [ "$(jq -r .suppressOutput <<<"$out")" = true ]
check "the journal follows the live session" [ -f "$threads/$D.md" ]
check "the journal leaves the cleared session" [ ! -e "$threads/$B.md" ]
check "what follows the yes is not injected twice" lacks "$(injected "$out")" "regarde aussi le logout"
check "what follows the yes is journaled" has "$(cat "$threads/$D.md")" "Oui, et regarde aussi le logout"

prompt "$D" "now add a test"
edit "$D" "$repo/src/auth.ts"
stop "$D" "Test added."
clear_from "$D" 111
clear_to "$E" 111 >/dev/null
out=$(prompt "$E" "Ok.")
check "the handoff keeps the directory and the branch" has "$(injected "$out")" "$repo · feat/login"
check "the handoff keeps the requests of the earlier sessions" has "$(injected "$out")" "fix the login bug"
check "the handoff keeps the edited files" has "$(injected "$out")" "- edited: src/auth.ts"
check "the handoff keeps the last answer" has "$(injected "$out")" "Test added."
check "without Jev the earlier answers stay out" lacks "$(injected "$out")" "Fixed, the token was expired."
check "the journal on disk stays whole" has "$(cat "$threads/$E.md")" "Fixed, the token was expired."
check "a thread is one file" [ "$(journals)" = 2 ]
check "a bare yes is not journaled" [ "$(grep -cx Ok. "$threads/$E.md")" = 0 ]

clear_from "$G" 111
out=$(clear_to "$F" 111)
check "a session with no journal asks nothing" empty "$out"

prompt "$H" "review the PR"
prompt "$H" '<agent-message from="a1">the reviewer found nothing</agent-message>'
prompt "$H" '<task-notification>task 3 is done</task-notification>'
journal=$(cat "$threads/$H.md")
check "a message from a subagent is not a request" lacks "$journal" "the reviewer found nothing"
check "a task notification is not a request" lacks "$journal" "task 3 is done"

prompt "$I" "plan the cache"
stop "$I" "Use Redis for the cache."
prompt "$I" "no Redis, keep it in memory"
stop "$I" "Plan: an in-memory map."
prompt "$I" "go"
stop "$I" "Done, the cache is an in-memory map."
clear_from "$I" 333
clear_to "$J" 333 >/dev/null
jev '{"answers": {"s1": {"type": "noul", "noul": 0.29}, "s3": {"type": "noul", "noul": 0.8}}}'
out=$(TYPESAFE_API_KEY=secret prompt "$J" "yes")
check "Jev is asked about each earlier answer" [ "$(jq -c '.questions | keys' "$fake/request.json")" = '["s1","s3"]' ]
check "Jev reads the whole journal" [ "$(jq '.state | length' "$fake/request.json")" = 6 ]
check "Jev gets the key" has "$(cat "$fake/config")" "Authorization: Bearer secret"
check "the key stays out of the command line" lacks "$(cat "$fake/args")" "secret"
check "an answer Jev scores under 0.3 stays out" lacks "$(injected "$out")" "Use Redis for the cache."
check "an answer Jev scores above comes back" has "$(injected "$out")" "Plan: an in-memory map."
check "with Jev the last answer is still there" has "$(injected "$out")" "Done, the cache is an in-memory map."
check "the answers that come back stay in order" [ "$(injected "$out" | grep -o -e '^Plan' -e '^Done' | tr -d '\n')" = PlanDone ]

prompt "$K" "audit the repo"
stop "$K" "Audit: $(printf 'x%.0s' {1..9000})"
prompt "$K" "and the tests?"
stop "$K" "The tests cover the parser."
prompt "$K" "thanks"
stop "$K" "Nothing else to report."
clear_from "$K" 444
clear_to "$L" 444 >/dev/null
jev '{"answers": {"s1": {"type": "noul", "noul": 0.9}, "s3": {"type": "noul", "noul": 0.5}}}'
out=$(TYPESAFE_API_KEY=secret prompt "$L" "yes")
check "an answer that does not fit in 9000 bytes stays out" lacks "$(injected "$out")" "Audit: xxx"
check "a smaller answer comes back in its place" has "$(injected "$out")" "The tests cover the parser."

prompt "$M" "plan the cache"
stop "$M" "Use Redis for the cache."
prompt "$M" "go"
stop "$M" "Done, without Redis."
clear_from "$M" 555
clear_to "$N" 555 >/dev/null
jev '' 28
out=$(TYPESAFE_API_KEY=secret prompt "$N" "yes" 2>&1)
code=$?
check "when Jev fails the yes still brings the last answer" has "$(injected "$out")" "Done, without Redis."
check "when Jev fails the earlier answers stay out" lacks "$(injected "$out")" "Use Redis for the cache."
check "when Jev fails it is not an error" [ "$code" = 0 ]
prompt "$N" "one more thing"
stop "$N" "Noted."
clear_from "$N" 555
clear_to "$O" 555 >/dev/null
jev '<html>502 Bad Gateway</html>'
out=$(TYPESAFE_API_KEY=secret prompt "$O" "yes" 2>&1)
check "an answer Jev garbles is ignored" has "$(injected "$out")" "Noted."

prompt "$P" "say hello"
stop "$P" "Hello."
clear_from "$P" 666
clear_to "$Q" 666 >/dev/null
jev '{"answers": {}}'
out=$(TYPESAFE_API_KEY=secret prompt "$Q" "yes")
check "a journal with a single answer does not call Jev" [ ! -e "$fake/request.json" ]
check "a journal with a single answer brings it back" has "$(injected "$out")" "Hello."

check "the status line shows the session name, not the branch" [ "$(statusline "$A" "Ship the thing")" = "Ship the thing · 12k" ]
check "the status line works without a name" [ "$(statusline "$A")" = "12k" ]

exit $failed
