#!/usr/bin/env bash
#
# cc-ask.sh - PreToolUse hook (matcher AskUserQuestion): while Claude Shepherd is running,
# hold a session's question so Adam answers it with a button on its card instead of
# hunting for the tab (2026-09-11).
#
#   1. Publishes `ask_nonce` + `ask_until` at the top level of the session's status file
#      (cc-status.sh publishes the questions themselves as pending.ask, in parallel).
#   2. Waits for Shepherd's answer in $CC_ASK_DIR/<key>.answer, bound to that nonce and
#      claimed with mv (the gate's pattern, cc-approve.sh):
#        {"nonce":"…","answers":{"<question>":"<label>" | ["<label>",…] | "<free text>"}}
#        {"nonce":"…","release":true}     -- Adam chose to answer in the tab
#   3. Answered: allows the tool with the answers in updatedInput -- Claude Code then skips
#      its picker and hands Claude "The user answered: …" (spiked 2026-09-11, CLI + VS Code).
#
# Out of the way (no output: the tab shows its own picker, exactly as without the hook)
# when ask.enabled is false, the panel heartbeat is stale, there are no questions, Adam
# releases the question, or ask.waitSeconds (default 900, max 3600) runs out.
# Only the decision JSON is ever written to stdout; logs go to stderr.

set -u

# shellcheck source=cc-lib.sh
. "$(dirname "$0")/cc-lib.sh" 2>/dev/null || . "$HOME/.claude/cc-lib.sh"

HEARTBEAT_MAX_AGE="${CC_PANEL_MAX_AGE:-5}"
POLL="${CC_ASK_POLL:-0.25}"

INPUT="$(cat 2>/dev/null || true)"
cc_have_jq || exit 0
[ "$(cc_get "$INPUT" '.tool_name')" = "AskUserQuestion" ] || exit 0
[ "$(cc_config '.ask.enabled' 'true')" = "false" ] && exit 0

# Shepherd must be alive (fresh heartbeat), or we'd hold the question for nobody.
HB_FILE="$(cc_heartbeat_file)"
[ -f "$HB_FILE" ] || exit 0
HB="$(cat "$HB_FILE" 2>/dev/null || echo 0)"
case "$HB" in ''|*[!0-9]*) HB=0 ;; esac
[ $(( $(cc_now) - HB )) -le "$HEARTBEAT_MAX_AGE" ] || exit 0

TOOL_INPUT="$(printf '%s' "$INPUT" | jq -c '.tool_input // empty' 2>/dev/null)"
[ "$(printf '%s' "$TOOL_INPUT" | jq -r '(.questions // []) | length' 2>/dev/null)" -gt 0 ] 2>/dev/null || exit 0

SESSION_ID="$(cc_get "$INPUT" '.session_id')"
CWD="$(cc_get "$INPUT" '.cwd')"
[ -n "$CWD" ] || CWD="$PWD"
KEY="$(cc_key "$SESSION_ID" "$CWD")"

WAIT="${CC_ASK_WAIT:-$(cc_config '.ask.waitSeconds' '900')}"
case "$WAIT" in ''|*[!0-9]*) WAIT=900 ;; esac
[ "$WAIT" -ge 1 ] || WAIT=1
[ "$WAIT" -le 3600 ] || WAIT=3600   # the hook's settings.json timeout is 3630s

mkdir -p "$CC_ASK_DIR" 2>/dev/null || true
ANSWER_FILE="$CC_ASK_DIR/$KEY.answer"
CLAIM="$ANSWER_FILE.claim.$$"
NOW="$(cc_now)"
NONCE="$$.$NOW"
UNTIL=$(( NOW + WAIT ))
ARM="$(jq -nc --arg n "$NONCE" --argjson u "$UNTIL" '{ask_nonce:$n, ask_until:$u}')"

# Let go of the question on every way out (answered, released, timed out, Esc/SIGTERM) --
# only if it is still ours: a newer question on this session owns the fields then.
let_go() {
  if [ "$(cc_read_field "$KEY" '.ask_nonce')" = "$NONCE" ]; then
    cc_del_field "$KEY" "ask_nonce"
    cc_del_field "$KEY" "ask_until"
  fi
  rm -f "$CLAIM" 2>/dev/null || true
}
trap let_go EXIT
trap 'exit 0' TERM INT HUP

cc_merge "$KEY" "$ARM"
echo "[cc-ask] ⏳ holding the question for Shepherd ($KEY, up to ${WAIT}s)" >&2

ITERS="$(awk -v w="$WAIT" -v p="$POLL" 'BEGIN { printf "%d", w / p }')"
i=0
while [ "$i" -lt "$ITERS" ]; do
  if [ -f "$ANSWER_FILE" ] && mv "$ANSWER_FILE" "$CLAIM" 2>/dev/null; then
    BODY="$(cat "$CLAIM" 2>/dev/null)"
    rm -f "$CLAIM" 2>/dev/null || true
    if [ "$(cc_get "$BODY" '.nonce')" = "$NONCE" ]; then
      if [ "$(cc_get "$BODY" '.release')" = "true" ]; then
        echo "[cc-ask] ↩️ released to the tab's picker ($KEY)" >&2
        exit 0
      fi
      ANSWERS="$(printf '%s' "$BODY" | jq -c '.answers | select(type == "object" and length > 0)' 2>/dev/null)"
      if [ -n "$ANSWERS" ]; then
        echo "[cc-ask] ✅ answered from Shepherd ($KEY)" >&2
        jq -nc --argjson ti "$TOOL_INPUT" --argjson a "$ANSWERS" \
          '{hookSpecificOutput:{hookEventName:"PreToolUse", permissionDecision:"allow", updatedInput:($ti + {answers:$a})}}'
        exit 0
      fi
      echo "[cc-ask] ⚠️ an empty answer was ignored ($KEY)" >&2
    else
      echo "[cc-ask] ⚠️ an answer for another question was thrown away ($KEY)" >&2
    fi
  fi
  # cc-status.sh's read-modify-write can land a pre-arm snapshot over ours (#28): put the
  # nonce back (~1Hz) so the card keeps its buttons. A foreign nonce is a newer question.
  if [ $(( i % 4 )) -eq 0 ] && [ -z "$(cc_read_field "$KEY" '.ask_nonce')" ]; then
    cc_merge "$KEY" "$ARM"
  fi
  sleep "$POLL"
  i=$(( i + 1 ))
done

echo "[cc-ask] ⌛ no answer in ${WAIT}s -- the tab's picker takes over ($KEY)" >&2
exit 0
