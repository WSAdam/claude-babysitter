#!/usr/bin/env bash
# ask-hold.test.sh - ~/.claude/cc-ask.sh, the PreToolUse hook that holds a session's
# AskUserQuestion while Shepherd is running, so Adam answers it with a button on the card
# (2026-09-11). The answer comes back as <key>.answer bound to the nonce the hook wrote into
# the session's status file (the gate's claim-by-mv pattern) and goes to Claude as the tool's
# own answers (updatedInput.answers). A release, a timeout or a dead panel emits nothing,
# so the tab shows its own picker as before.
# Side-effect-free: status, ask and config under a temp dir.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
export CC_STATUS_DIR="$TMP/status" CC_ASK_DIR="$TMP/ask" CC_ASK_POLL=0.1 CC_CONFIG_FILE="$TMP/cc-config.json"
mkdir -p "$CC_STATUS_DIR"
H="$ROOT/cc-ask.sh"
SF="$CC_STATUS_DIR/s1.json"

Q1='[{"question":"Which colour?","header":"Colour","multiSelect":false,"options":[{"label":"Red","description":"warm"},{"label":"Blue"}]}]'
input() { # [tool] [questions-json] -> a PreToolUse event for session s1
  jq -nc --arg t "${1:-AskUserQuestion}" --argjson q "${2:-$Q1}" --arg cwd "$TMP/proj" \
    '{session_id:"s1", cwd:$cwd, hook_event_name:"PreToolUse", tool_name:$t, tool_input:{questions:$q}}'
}
alive() { date +%s > "$CC_STATUS_DIR/.panel-alive"; }
run() { # <name> [tool] [questions] [wait]: the hook in the background; stdout in $TMP/out.<name>, exit code in $TMP/rc.<name>
  local n="$1"
  (input "${2:-}" "${3:-}" | CC_ASK_WAIT="${4:-20}" bash "$H" > "$TMP/out.$n" 2> "$TMP/err.$n"; echo $? > "$TMP/rc.$n") &
}
wait_for() { local i; for i in $(seq 1 80); do [ -e "$1" ] && return 0; sleep 0.1; done; return 1; }
wait_nonce() { local i n; for i in $(seq 1 80); do n="$(jq -r '.ask_nonce // empty' "$SF" 2>/dev/null)"; [ -n "$n" ] && { printf '%s' "$n"; return 0; }; sleep 0.1; done; return 1; }
answer() { # <json body> : what Shepherd writes
  mkdir -p "$CC_ASK_DIR"; printf '%s' "$1" > "$CC_ASK_DIR/s1.answer.tmp" && mv "$CC_ASK_DIR/s1.answer.tmp" "$CC_ASK_DIR/s1.answer"
}
fresh() { rm -rf "$CC_ASK_DIR" "$SF" "$TMP"/out.* "$TMP"/rc.* "$TMP"/err.*; printf '{"name":"proj","status":"working"}' > "$SF"; }

# ---- out of the way: nothing on stdout, nothing held ----
fresh; alive
out="$(input Bash | CC_ASK_WAIT=20 bash "$H")"
assert_eq "another tool: the hook says nothing" "" "$out"
assert_eq "...and holds nothing" "" "$(jq -r '.ask_nonce // empty' "$SF")"

fresh; rm -f "$CC_STATUS_DIR/.panel-alive"
start=$(date +%s); out="$(input | CC_ASK_WAIT=20 bash "$H")"; took=$(( $(date +%s) - start ))
assert_eq "Shepherd not running: the question goes straight to the tab" "" "$out"
[ "$took" -le 2 ] && got=fast || got="slow (${took}s)"
assert_eq "...with no wait" "fast" "$got"
assert_eq "...and nothing held" "" "$(jq -r '.ask_nonce // empty' "$SF")"

fresh; echo 1 > "$CC_STATUS_DIR/.panel-alive"
out="$(input | CC_ASK_WAIT=20 bash "$H")"
assert_eq "a stale heartbeat counts as not running" "" "$out"

fresh; alive; printf '{"ask":{"enabled":false}}' > "$CC_CONFIG_FILE"
out="$(input | CC_ASK_WAIT=20 bash "$H")"
assert_eq "ask.enabled false: the tab's picker as before" "" "$out"
rm -f "$CC_CONFIG_FILE"

fresh; alive
out="$(input AskUserQuestion '[]' | CC_ASK_WAIT=20 bash "$H")"
assert_eq "no questions: nothing held" "" "$out"

# ---- held, then answered from Shepherd ----
fresh; alive
run a
N="$(wait_nonce)" || N=""
[ -n "$N" ] && got=yes || got=no
assert_eq "a held question publishes its nonce on the session" "yes" "$got"
until_at="$(jq -r '.ask_until // 0' "$SF")"; now=$(date +%s)
[ "$until_at" -ge $(( now + 15 )) ] && [ "$until_at" -le $(( now + 21 )) ] && got=yes || got="no ($until_at vs $now)"
assert_eq "...and when it falls back to the tab (ask_until)" "yes" "$got"
answer "$(jq -nc --arg n "$N" '{nonce:$n, answers:{"Which colour?":"Blue"}}')"
wait_for "$TMP/rc.a"
assert_eq "an answer with the right nonce: exit 0" "0" "$(cat "$TMP/rc.a")"
assert_json "...allows the tool" "$TMP/out.a" '.hookSpecificOutput.permissionDecision' "allow"
assert_json "...as a PreToolUse decision" "$TMP/out.a" '.hookSpecificOutput.hookEventName' "PreToolUse"
assert_json "...carrying Adam's answer as the tool's own answers" "$TMP/out.a" '.hookSpecificOutput.updatedInput.answers["Which colour?"]' "Blue"
assert_json "...with the questions untouched" "$TMP/out.a" '.hookSpecificOutput.updatedInput.questions[0].options[0].description' "warm"
assert_eq "stdout is one JSON document and nothing else" "1" "$(jq -c . "$TMP/out.a" | wc -l | tr -d ' ')"
assert_eq "the nonce is spent once answered" "" "$(jq -r '.ask_nonce // empty' "$SF")"
assert_eq "...and so is the until" "" "$(jq -r '.ask_until // empty' "$SF")"
assert_absent "the answer is claimed (single use)" "$CC_ASK_DIR/s1.answer"

# ---- several parts, multi-select, free text ----
Q2='[{"question":"Which toppings?","multiSelect":true,"options":[{"label":"Cheese"},{"label":"Ham"}]},{"question":"Which size?","multiSelect":false,"options":[{"label":"Small"},{"label":"Large"}]}]'
fresh; alive
run b "" "$Q2"
N="$(wait_nonce)" || N=""
answer "$(jq -nc --arg n "$N" '{nonce:$n, answers:{"Which toppings?":["Cheese","Ham"], "Which size?":"extra large please"}}')"
wait_for "$TMP/rc.b"
assert_json "a multi-select answer stays a list" "$TMP/out.b" '.hookSpecificOutput.updatedInput.answers["Which toppings?"] | join(",")' "Cheese,Ham"
assert_json "free text goes through as the answer" "$TMP/out.b" '.hookSpecificOutput.updatedInput.answers["Which size?"]' "extra large please"

# ---- not answered from Shepherd: the tab's picker ----
fresh; alive
run c
N="$(wait_nonce)" || N=""
answer '{"nonce":"12.34","answers":{"Which colour?":"Red"}}'
sleep 0.5
[ -e "$TMP/rc.c" ] && got=ended || got=waiting
assert_eq "an answer with another nonce is ignored (still waiting)" "waiting" "$got"
assert_absent "...and thrown away" "$CC_ASK_DIR/s1.answer"
answer "$(jq -nc --arg n "$N" '{nonce:$n, release:true}')"
wait_for "$TMP/rc.c"
assert_eq "Answer in the tab instead: the hook says nothing" "" "$(cat "$TMP/out.c")"
assert_eq "...and lets go" "" "$(jq -r '.ask_nonce // empty' "$SF")"

fresh; alive
run d
N="$(wait_nonce)" || N=""
answer "$(jq -nc --arg n "$N" '{nonce:$n, answers:{}}')"
sleep 0.5
[ -e "$TMP/rc.d" ] && got=ended || got=waiting
assert_eq "an empty answer is ignored (still waiting)" "waiting" "$got"
answer "$(jq -nc --arg n "$N" '{nonce:$n, release:true}')"
wait_for "$TMP/rc.d"

fresh; alive
run e "" "" 1
wait_for "$TMP/rc.e"; sleep 0.1
assert_eq "no answer before the wait runs out: the hook says nothing" "" "$(cat "$TMP/out.e")"
assert_eq "...and lets go of the question" "" "$(jq -r '.ask_nonce // empty' "$SF")"

# ---- the nonce survives a sibling hook clobbering the status file ----
fresh; alive
run f
N="$(wait_nonce)" || N=""
printf '{"name":"proj","status":"approval"}' > "$SF"
N2="$(wait_nonce)" || N2=""
assert_eq "a clobbered nonce is written back, unchanged" "$N" "$N2"
answer "$(jq -nc --arg n "$N" '{nonce:$n, release:true}')"
wait_for "$TMP/rc.f"

# ---- SessionEnd leaves no answer behind ----
mkdir -p "$CC_ASK_DIR"; : > "$CC_ASK_DIR/s1.answer"; : > "$CC_ASK_DIR/s1.answer.claim.99"
( . "$ROOT/cc-lib.sh"; cc_remove s1 )
assert_absent "cc_remove drops the answer file" "$CC_ASK_DIR/s1.answer"
assert_absent "...and any claim" "$CC_ASK_DIR/s1.answer.claim.99"

finish
