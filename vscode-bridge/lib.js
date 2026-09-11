// lib.js - the Shepherd bridge's pure logic (no `vscode` import, so node tests run it).
// A Claude tab is a webview tab whose viewType names the Claude extension's panel. Its label
// is the only identity the tab API exposes, so close/select name a label and succeed only when
// exactly one Claude tab in this window carries it -- or name a UNIT: a tab this bridge itself
// saw open right after Shepherd said "expect" (a batch unit's tab, which never gets a name).
"use strict";

const CLAUDE_VIEW = "claudeVSCodePanel";   // VS Code reports "mainThreadWebview-claudeVSCodePanel"
const MAX_CMD_AGE_S = 30;                   // an older command is a leftover, never acted on
const ID_RE = /^[A-Za-z0-9._-]{1,64}$/;     // ids become file names in the outbox
const UNIT_RE = /^[A-Za-z0-9._:-]{1,80}$/;  // "<batch>:<slug>"
const OPS = ["close", "select", "expect"];

function isClaudeTab(tab) {
  const input = tab && tab.input;
  return !!(input && typeof input.viewType === "string" && input.viewType.includes(CLAUDE_VIEW));
}

// Every Claude tab across the window's groups, with what Shepherd needs to name it. `unitOf`
// (optional) returns the unit tag this bridge gave a tab, if any.
function claudeTabs(groups, unitOf) {
  const out = [];
  (groups || []).forEach((g, gi) => {
    ((g && g.tabs) || []).forEach((tab, ti) => {
      if (isClaudeTab(tab)) {
        const unit = typeof unitOf === "function" ? unitOf(tab) : undefined;
        out.push({ tab, label: String(tab.label || ""), group: g.viewColumn ?? null, active: !!tab.isActive, gi, ti, unit });
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
    tabs: (tabs || []).map((t) => {
      const r = { label: t.label, group: t.group, active: t.active };
      if (t.unit) r.unit = t.unit;
      return r;
    }),
    at: Math.floor(nowMs / 1000),
  };
}

// Three commands: close or select a Claude tab (by label, or by unit), and expect -- tag the
// next Claude tab that opens as a unit's.
function validateCommand(cmd, nowMs) {
  if (!cmd || typeof cmd !== "object") return { error: "not a command" };
  if (cmd.v !== 1) return { error: "unknown command version" };
  if (!OPS.includes(cmd.op)) return { error: "unknown op" };
  if (typeof cmd.id !== "string" || !ID_RE.test(cmd.id)) return { error: "bad id" };
  const hasUnit = cmd.unit !== undefined && cmd.unit !== null;
  if (hasUnit && (typeof cmd.unit !== "string" || !UNIT_RE.test(cmd.unit))) return { error: "bad unit" };
  if (cmd.op === "expect" && !hasUnit) return { error: "expect needs a unit" };
  if (cmd.op !== "expect" && !hasUnit
      && (typeof cmd.label !== "string" || cmd.label === "" || cmd.label.length > 200)) return { error: "bad label" };
  // 2026-09-11: close ANY empty chat -- only "Claude Code" tabs, with Shepherd's count of them
  const hasEmpty = cmd.empty !== undefined && cmd.empty !== null;
  if (hasEmpty && (cmd.op !== "close" || hasUnit || cmd.label !== EMPTY_LABEL
      || !Number.isInteger(cmd.empty) || cmd.empty < 1 || cmd.empty > 20)) return { error: "bad empty close" };
  const at = Number(cmd.at), now = nowMs / 1000;
  if (!Number.isFinite(at) || now - at > MAX_CMD_AGE_S || at - now > 5) return { error: "stale command" };
  return { ok: true, cmd: { id: cmd.id, op: cmd.op, label: hasUnit ? undefined : cmd.label, unit: hasUnit ? cmd.unit : undefined,
                            empty: hasEmpty ? cmd.empty : undefined } };
}

// A never-used chat's tab (2026-09-11). They all read "Claude Code" and are interchangeable, so
// one is picked -- only among untagged tabs of that name (a batch unit's tab is tagged and is
// never one), only while their number still equals the count Shepherd checked (its empty
// sessions in this window), preferring one that isn't in front.
const EMPTY_LABEL = "Claude Code";
function pickEmpty(tabs, count) {
  const hits = (tabs || []).filter((t) => t.label === EMPTY_LABEL && !t.unit);
  if (hits.length !== count) return { reason: `${hits.length} untagged "${EMPTY_LABEL}" tabs here, but Shepherd counted ${count} empty chats` };
  if (hits.length === 0) return { reason: `no "${EMPTY_LABEL}" tab here` };
  return { hit: hits.find((t) => !t.active) || hits[0] };
}

function pickExactlyOne(tabs, label) {
  const hits = (tabs || []).filter((t) => t.label === label);
  if (hits.length === 1) return { hit: hits[0] };
  if (hits.length === 0) return { reason: `no Claude tab named "${label}" in this window` };
  return { reason: `${hits.length} Claude tabs share the name "${label}"` };
}

function pickUnit(tabs, unit) {
  const hits = (tabs || []).filter((t) => t.unit === unit);
  if (hits.length === 1) return { hit: hits[0] };
  if (hits.length === 0) return { reason: `no Claude tab for unit ${unit} in this window` };
  return { reason: `${hits.length} Claude tabs claim unit ${unit}` };
}

module.exports = { CLAUDE_VIEW, ID_RE, UNIT_RE, isClaudeTab, claudeTabs, registryFor, validateCommand,
                   pickExactlyOne, pickUnit, pickEmpty, selectCommands };
