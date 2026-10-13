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
echo >>"$fake/calls"
[ ! -f "$fake/sleep" ] || sleep "$(cat "$fake/sleep")"
# AUTO answers 0.5 to whatever was asked, so a test can count the rounds of a scoring.
if [ "$(cat "$fake/response")" = AUTO ]; then
  jq '{answers: (.questions | map_values({type: "noul", noul: 0.5}))}' "$fake/request.json"
else
  cat "$fake/response"
fi
exit "$(cat "$fake/exit")"
EOF
chmod +x "$work/bin/curl"
PATH="$work/bin:$PATH"
jev() { # response [exit code]
  rm -f "$fake/args" "$fake/config" "$fake/request.json" "$fake/sleep" "$fake/calls"
  echo "$1" >"$fake/response"
  echo "${2:-0}" >"$fake/exit"
}
calls() { wc -l <"$fake/calls" 2>/dev/null || echo 0; }
notes() { echo "$threads/$1.jev.json"; }
settle() { # session last: waits for the background scorer to store that turn
  local tries=50
  until [ "$(jq .last "$(notes "$1")" 2>/dev/null)" = "$2" ]; do
    [ $((tries -= 1)) -gt 0 ] || return 1
    sleep 0.1
  done
}
ms() { echo $((${EPOCHREALTIME//[.,]/} / 1000)); }

A=aaaaaaaa-0000 B=bbbbbbbb-0000 C=cccccccc-0000 D=dddddddd-0000 E=eeeeeeee-0000 F=ffffffff-0000 G=99999999-0000
H=11111111-0000 I=22222222-0000 J=33333333-0000 K=44444444-0000 L=55555555-0000 M=66666666-0000
N=77777777-0000 O=88888888-0000 P=12121212-0000 Q=34343434-0000 R=56565656-0000 S=78787878-0000
T=90909090-0000 U=13131313-0000 V=24242424-0000 W=35353535-0000 X=46464646-0000 Y=57575757-0000 Z=68686868-0000

hook() { # event session pid [extra json]
  jq -n --arg e "$1" --arg s "$2" --arg d "$repo" --argjson x "${4:-{\}}" '{hook_event_name: $e, session_id: $s, cwd: $d} + $x' |
    CLAUDE_PID="$3" "$root/scripts/thread.sh"
}
title() { jq -nc --arg t "$2" '{type: "ai-title", aiTitle: $t}' >"$work/$1.jsonl"; } # session title
clear_to() { hook SessionStart "$1" "$2" "{\"source\":\"clear\",\"transcript_path\":\"$work/$1.jsonl\"}"; }
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
check "opening Claude Code without a key warns" has "$(jq -r .systemMessage <<<"$out")" "TYPESAFE_API_KEY is not set"
check "the warning is hidden from the transcript" [ "$(jq -r .suppressOutput <<<"$out")" = true ]
check "opening Claude Code creates nothing" [ ! -e "$threads" ]
out=$(TYPESAFE_API_KEY=secret hook SessionStart "$A" 111 '{"source":"startup"}')
check "opening Claude Code with a key prints nothing" empty "$out"
out=$(hook SessionStart "$A" 111 '{"source":"compact"}')
check "compaction prints nothing" empty "$out"
out=$(clear_to "$B" 111)
check "/clear drops the journals older than 30 days" [ ! -e "$threads/old.md" ]
check "/clear without a previous session prints nothing" empty "$out"

out=$(prompt "$A" "ship the thing" 2>&1)
code=$?
check "a prompt is journaled without a word" empty "$out"
check "a prompt is journaled without an error" [ "$code" = 0 ]
out=$(
  edit "$A" "$repo/src/deploy.sh" 2>&1
  edit "$A" "$repo/src/deploy.sh" 2>&1
)
check "an edit prints nothing" empty "$out"
out=$(stop "$A" "Shipped, the deploy is green." 2>&1)
check "an answer is journaled without a word" empty "$out"
journal=$(cat "$threads/$A.md")
check "the journal starts with the directory and the branch" has "$(head -n 1 <<<"$journal")" "$repo · feat/login"
check "the journal holds the request" has "$journal" "ship the thing"
check "the journal holds the final answer" has "$journal" "Shipped, the deploy is green."
check "an edited file stays out of the journal: git diff shows it" lacks "$journal" "src/deploy.sh"
out=$(CLAUDE_THREAD_HOME=/proc/nope prompt "$A" "hello" 2>&1)
code=$?
check "a journal that cannot be written says nothing" empty "$out"
check "a journal that cannot be written is not an error" [ "$code" = 0 ]

title "$A" "Ship the thing"
touch -d '40 days ago' "$threads/old.md"
out=$(hook SessionStart "$B" 111 '{"source":"compact"}')
check "compaction with a previous session prints nothing" empty "$out"
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
out=$(clear_to "$C" 111)
check "without a title the question still reads" has "$(jq -r .systemMessage <<<"$out")" "Continue the previous work? Reply"
clear_to "$D" 111 >/dev/null
check "a session cleared before any prompt keeps the older link" has "$(cat "$threads/.live/ask-$D")" "$B"

out=$(prompt "$D" "Yep, and check the logout too")
check "yes injects the final answer" has "$(injected "$out")" "Fixed, the token was expired."
check "yes injects the request" has "$(injected "$out")" "fix the login bug"
check "the injection is hidden from the transcript" [ "$(jq -r .suppressOutput <<<"$out")" = true ]
check "the journal follows the live session" [ -f "$threads/$D.md" ]
check "the journal leaves the cleared session" [ ! -e "$threads/$B.md" ]
check "what follows the yes is not injected twice" lacks "$(injected "$out")" "check the logout too"
check "what follows the yes is journaled" has "$(cat "$threads/$D.md")" "Yep, and check the logout too"

prompt "$D" "now add a test"
edit "$D" "$repo/src/auth.ts"
stop "$D" "Test added."
clear_to "$E" 111 >/dev/null
out=$(prompt "$E" "Ok.")
check "the handoff keeps the directory and the branch" has "$(injected "$out")" "$repo · feat/login"
check "the handoff keeps the requests of the earlier sessions" has "$(injected "$out")" "fix the login bug"
check "the handoff lists no edited file" lacks "$(injected "$out")" "src/auth.ts"
check "the handoff keeps the last answer" has "$(injected "$out")" "Test added."
check "without Jev the whole journal comes back" has "$(injected "$out")" "Fixed, the token was expired."
check "the journal on disk stays whole" has "$(cat "$threads/$E.md")" "Fixed, the token was expired."
check "a thread is one file" [ "$(journals)" = 2 ]
check "a bare yes is not journaled" [ "$(grep -cx Ok. "$threads/$E.md")" = 0 ]

out=$(clear_to "$G" 111)
check "after a bare yes the link follows the journal" has "$(jq -r .systemMessage <<<"$out")" "Continue the previous work"
out=$(clear_to "$F" 999)
check "a process without a journal asks nothing" empty "$out"

prompt "$H" "review the PR"
prompt "$H" '<agent-message from="a1">the reviewer found nothing</agent-message>'
prompt "$H" '<task-notification>task 3 is done</task-notification>'
journal=$(cat "$threads/$H.md")
check "a message from a subagent is not a request" lacks "$journal" "the reviewer found nothing"
check "a task notification is not a request" lacks "$journal" "task 3 is done"

export TYPESAFE_API_KEY=secret
jev '{"answers": {"s1": {"type": "noul", "noul": 0.2}}}'
prompt "$R" "plan the cache"
stop "$R" "Use Redis for the cache."
echo 3 >"$fake/sleep"
started=$(ms)
prompt "$R" "no Redis, keep it in memory"
out=$(stop "$R" "Plan: an in-memory map.")
check "a turn closes its output before Jev answers" [ $(($(ms) - started)) -lt 1500 ]
check "a turn prints nothing" empty "$out"
check "a turn scores the earlier answers in the background" settle "$R" 3
check "a turn asks about each earlier answer, not the last one" [ "$(jq -c '.questions | keys' "$fake/request.json")" = '["s1"]' ]
check "a turn sends the requests, the alive answers and the last answer" [ "$(jq -c '[.state[].id]' "$fake/request.json")" = '[0,1,2,3]' ]
check "the key stays out of the command line" lacks "$(cat "$fake/args")" "secret"
check "a turn stores the scores next to the journal" [ "$(jq .scores.s1 "$(notes "$R")")" = 0.2 ]
jev '{"answers": {"s3": {"type": "noul", "noul": 0.8}}}'
prompt "$R" "go"
stop "$R" "Done, the cache is an in-memory map."
settle "$R" 5
check "an answer scored under 0.3 is frozen and not sent again" [ "$(jq -c '.questions | keys' "$fake/request.json")" = '["s3"]' ]
check "a frozen answer leaves the state" [ "$(jq -c '[.state[].id]' "$fake/request.json")" = '[0,2,3,4,5]' ]
check "a frozen answer keeps its score" [ "$(jq .scores.s1 "$(notes "$R")")" = 0.2 ]
check "a new score is stored" [ "$(jq .scores.s3 "$(notes "$R")")" = 0.8 ]
jev '' 28
prompt "$R" "thanks"
stop "$R" "Nothing else."
sleep 0.5
check "a failed turn leaves the scores untouched" [ "$(jq .last "$(notes "$R")")" = 5 ]
jev '<html>502</html>'
prompt "$R" "and?"
stop "$R" "Still nothing."
sleep 0.5
check "a garbled answer leaves the scores untouched" [ "$(jq .last "$(notes "$R")")" = 5 ]
jev '{"answers": {"s3": {"type": "noul", "noul": 0.7}, "s5": {"type": "noul", "noul": 0.6}, "s7": {"type": "noul", "noul": 0.5}}}'
echo 3 >"$fake/sleep"
started=$(ms)
out=$(stop "$R" "Late.")
check "a slow Jev does not hold the turn" [ $(($(ms) - started)) -lt 1500 ]
check "a slow Jev still stores its scores" settle "$R" 10
check "a turn asks again about every alive and unscored answer" [ "$(jq -c '.questions | keys' "$fake/request.json")" = '["s3","s5","s7","s9"]' ]

export CLAUDE_THREAD_STATE=880
jev '{"answers": {"s1": {"type": "noul", "noul": 0.9}}}'
prompt "$S" "audit the repo"
stop "$S" "Audit: $(printf 'x%.0s' {1..600})"
prompt "$S" "and the tests?"
stop "$S" "The tests cover the parser."
settle "$S" 3
jev '{"answers": {"s3": {"type": "noul", "noul": 0.4}}}'
prompt "$S" "thanks, and write down what you checked"
stop "$S" "Nothing else to report, the parser is the only tested module."
settle "$S" 5
check "the ceiling leaves the lowest scored answers out of the state" [ "$(jq -c '[.state[].id]' "$fake/request.json")" = '[0,2,3,4,5]' ]
check "the ceiling leaves their questions out" [ "$(jq -c '.questions | keys' "$fake/request.json")" = '["s3"]' ]
check "an answer left out keeps its score" [ "$(jq .scores.s1 "$(notes "$S")")" = 0.9 ]
check "a scored answer left out ends the scoring" [ "$(calls)" = 1 ]
unset TYPESAFE_API_KEY
prompt "$X" "one"
stop "$X" "First: $(printf 'x%.0s' {1..300})"
prompt "$X" "two"
stop "$X" "Second: $(printf 'x%.0s' {1..300})"
prompt "$X" "three"
stop "$X" "Third: $(printf 'x%.0s' {1..300})"
prompt "$X" "four"
export TYPESAFE_API_KEY=secret
export CLAUDE_THREAD_STATE=600
jev AUTO
stop "$X" "Fourth."
settle "$X" 7
sleep 0.3
check "unscored answers beyond the ceiling get their own rounds" [ "$(calls)" = 3 ]
check "every unscored answer ends up scored" [ "$(jq -c '.scores | keys' "$(notes "$X")")" = '["s1","s3","s5"]' ]
unset CLAUDE_THREAD_STATE
unset TYPESAFE_API_KEY
rm -f "$fake/request.json"
prompt "$T" "say hello"
stop "$T" "Hello."
prompt "$T" "again"
stop "$T" "Hello again."
sleep 0.5
check "without a key a turn asks nothing" [ ! -e "$fake/request.json" ]
check "without a key a turn stores nothing" [ ! -e "$(notes "$T")" ]

export TYPESAFE_API_KEY=secret
jev '{"answers": {"s1": {"type": "noul", "noul": 0.2}}}'
prompt "$U" "plan the cache"
stop "$U" "Use Redis for the cache."
prompt "$U" "no Redis, keep it in memory"
stop "$U" "Plan: an in-memory map."
settle "$U" 3
jev '{"answers": {"s3": {"type": "noul", "noul": 0.8}}}'
prompt "$U" "go"
stop "$U" "Done, the cache is an in-memory map."
settle "$U" 5
clear_to "$V" 111 >/dev/null
rm -f "$fake/request.json"
out=$(prompt "$V" "yes")
check "with the scores up to date the yes asks nothing" [ ! -e "$fake/request.json" ]
check "the notes follow the journal" [ -f "$(notes "$V")" ]
check "the notes leave the cleared session" [ ! -e "$(notes "$U")" ]
check "a stored score under 0.3 keeps an answer out" lacks "$(injected "$out")" "Use Redis for the cache."
check "a stored score above brings an answer back" has "$(injected "$out")" "Plan: an in-memory map."
check "the last answer is still there" has "$(injected "$out")" "Done, the cache is an in-memory map."
prompt "$V" "one more"
jev '' 28
stop "$V" "Never scored."
sleep 0.5
prompt "$V" "and another"
stop "$V" "Neither."
sleep 0.5
clear_to "$W" 111 >/dev/null
jev '' 28
out=$(prompt "$W" "yes")
check "behind, the yes tries to catch up" [ -e "$fake/request.json" ]
check "the catch-up asks about the alive and the unscored answers, not the frozen one" [ "$(jq -c '.questions | keys' "$fake/request.json")" = '["s3","s5","s7"]' ]
check "an answer never scored comes back" has "$(injected "$out")" "Never scored."
unset TYPESAFE_API_KEY

prompt "$Y" "one"
stop "$Y" "First: $(printf 'x%.0s' {1..300})"
prompt "$Y" "two"
stop "$Y" "Second: $(printf 'x%.0s' {1..300})"
prompt "$Y" "three"
stop "$Y" "Third: $(printf 'x%.0s' {1..300})"
prompt "$Y" "four"
stop "$Y" "Fourth."
clear_to "$Z" 111 >/dev/null
jev AUTO
export CLAUDE_THREAD_STATE=600
out=$(TYPESAFE_API_KEY=secret prompt "$Z" "yes")
check "the catch-up at the yes stops after two rounds" [ "$(calls)" = 2 ]
check "what the catch-up could not score comes back" has "$(injected "$out")" "First: xxx"
unset CLAUDE_THREAD_STATE

prompt "$I" "plan the cache"
stop "$I" "Use Redis for the cache."
prompt "$I" "no Redis, keep it in memory"
stop "$I" "Plan: an in-memory map."
prompt "$I" "go"
stop "$I" "Done, the cache is an in-memory map."
clear_to "$J" 111 >/dev/null
jev '{"answers": {"s1": {"type": "noul", "noul": 0.29}, "s3": {"type": "noul", "noul": 0.8}}}'
out=$(TYPESAFE_API_KEY=secret prompt "$J" "yes")
check "Jev is asked about each earlier answer" [ "$(jq -c '.questions | keys' "$fake/request.json")" = '["s1","s3"]' ]
check "the catch-up reads the whole journal" [ "$(jq '.state | length' "$fake/request.json")" = 6 ]
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
clear_to "$L" 111 >/dev/null
jev '{"answers": {"s1": {"type": "noul", "noul": 0.9}, "s3": {"type": "noul", "noul": 0.5}}}'
out=$(TYPESAFE_API_KEY=secret prompt "$L" "yes")
check "an answer that does not fit in 9000 bytes stays out" lacks "$(injected "$out")" "Audit: xxx"
check "a smaller answer comes back in its place" has "$(injected "$out")" "The tests cover the parser."

prompt "$M" "plan the cache"
stop "$M" "Use Redis for the cache."
prompt "$M" "go"
stop "$M" "Done, without Redis."
clear_to "$N" 111 >/dev/null
jev '' 28
out=$(TYPESAFE_API_KEY=secret prompt "$N" "yes" 2>&1)
code=$?
check "when Jev fails the yes still brings the last answer" has "$(injected "$out")" "Done, without Redis."
check "when Jev fails and nothing was scored the whole journal comes back" has "$(injected "$out")" "Use Redis for the cache."
check "when Jev fails it is not an error" [ "$code" = 0 ]
prompt "$N" "one more thing"
stop "$N" "Noted."
clear_to "$O" 111 >/dev/null
jev '<html>502 Bad Gateway</html>'
out=$(TYPESAFE_API_KEY=secret prompt "$O" "yes" 2>&1)
check "an answer Jev garbles is ignored" has "$(injected "$out")" "Noted."

prompt "$P" "say hello"
stop "$P" "Hello."
clear_to "$Q" 111 >/dev/null
jev '{"answers": {}}'
out=$(TYPESAFE_API_KEY=secret prompt "$Q" "yes")
check "a journal with a single answer does not call Jev" [ ! -e "$fake/request.json" ]
check "a journal with a single answer brings it back" has "$(injected "$out")" "Hello."

N5=a5a5a5a5-0000 N6=a6a6a6a6-0000
prompt "$N5" "rename the module"
out=$(clear_to "$N6" 111)
check "a turn interrupted after its request can still be continued" has "$(jq -r .systemMessage <<<"$out")" "Continue the previous work"

check "the status line shows the session name, not the branch" [ "$(statusline "$A" "Ship the thing")" = "Ship the thing · 12k" ]
check "the status line works without a name" [ "$(statusline "$A")" = "12k" ]

exit $failed
