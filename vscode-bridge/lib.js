// lib.js - the Shepherd bridge's pure logic (no `vscode` import, so node tests run it).
// A Claude tab is a webview tab whose viewType names the Claude extension's panel; its
// label is the only live identity the tab API exposes, so a close names a label and
// succeeds only when exactly one Claude tab in this window carries it.
"use strict";

const CLAUDE_VIEW = "claudeVSCodePanel";   // VS Code reports "mainThreadWebview-claudeVSCodePanel"
const MAX_CMD_AGE_S = 30;                   // an older command is a leftover, never acted on
const ID_RE = /^[A-Za-z0-9._-]{1,64}$/;     // ids become file names in the outbox

function isClaudeTab(tab) {
  const input = tab && tab.input;
  return !!(input && typeof input.viewType === "string" && input.viewType.includes(CLAUDE_VIEW));
}

// Every Claude tab across the window's groups, with what Shepherd needs to name it.
function claudeTabs(groups) {
  const out = [];
  (groups || []).forEach((g, gi) => {
    ((g && g.tabs) || []).forEach((tab, ti) => {
      if (isClaudeTab(tab)) {
        out.push({ tab, label: String(tab.label || ""), group: g.viewColumn ?? null, active: !!tab.isActive, gi, ti });
      }
    });
  });
  return out;
}

// select: VS Code has no "reveal this tab" API for another extension's webview, but these two
// commands do it -- focus the tab's editor group, then open the editor at its index in the
// active group. Groups past the eighth have no focus command -> null (refused).
const GROUP_FOCUS = ["First", "Second", "Third", "Fourth", "Fifth", "Sixth", "Seventh", "Eighth"]
  .map((n) => "workbench.action.focus" + n + "EditorGroup");
function selectCommands(gi, ti) {
  if (!Number.isInteger(gi) || !Number.isInteger(ti) || gi < 0 || ti < 0 || gi >= GROUP_FOCUS.length) return null;
  return [{ id: GROUP_FOCUS[gi], args: [] }, { id: "workbench.action.openEditorAtIndex", args: [ti] }];
}

// The registry file Shepherd reads: which Claude tabs this window has, stamped so a
// crashed window's leftover file goes stale instead of being trusted forever.
function registryFor(pid, tabs, folders, version, nowMs) {
  return {
    v: 1, pid, version, folders: folders || [],
    tabs: (tabs || []).map((t) => ({ label: t.label, group: t.group, active: t.active })),
    at: Math.floor(nowMs / 1000),
  };
}

// Two commands exist, both by label: close a Claude tab, or bring it to the front (select).
function validateCommand(cmd, nowMs) {
  if (!cmd || typeof cmd !== "object") return { error: "not a command" };
  if (cmd.v !== 1) return { error: "unknown command version" };
  if (cmd.op !== "close" && cmd.op !== "select") return { error: "unknown op" };
  if (typeof cmd.id !== "string" || !ID_RE.test(cmd.id)) return { error: "bad id" };
  if (typeof cmd.label !== "string" || cmd.label === "" || cmd.label.length > 200) return { error: "bad label" };
  const at = Number(cmd.at), now = nowMs / 1000;
  if (!Number.isFinite(at) || now - at > MAX_CMD_AGE_S || at - now > 5) return { error: "stale command" };
  return { ok: true, cmd: { id: cmd.id, op: cmd.op, label: cmd.label } };
}

function pickExactlyOne(tabs, label) {
  const hits = (tabs || []).filter((t) => t.label === label);
  if (hits.length === 1) return { hit: hits[0] };
  if (hits.length === 0) return { reason: `no Claude tab named "${label}" in this window` };
  return { reason: `${hits.length} Claude tabs share the name "${label}"` };
}

module.exports = { CLAUDE_VIEW, ID_RE, isClaudeTab, claudeTabs, registryFor, validateCommand, pickExactlyOne, selectCommands };
