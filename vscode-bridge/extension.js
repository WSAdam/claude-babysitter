// extension.js - the Shepherd bridge: runs inside this VS Code window's extension host
// (the same process as the window's Claude tabs, so process.pid == Shepherd's
// host_window) and lets Shepherd close ONE Claude tab by name, or bring it to the front
// (select), with no keystrokes.
//
//   <dir>/<pid>.json        registry: this window's Claude tabs (on change + every 15s)
//   <dir>/<pid>.in/<id>.json   commands from Shepherd ("close" or "select", both by name)
//   <dir>/<pid>.out/<id>.json  results for Shepherd
//
// <dir> is ~/.claude/cc-bridge (CC_BRIDGE_DIR overrides it for tests).
"use strict";

const vscode = require("vscode");
const fs = require("fs");
const os = require("os");
const path = require("path");
const lib = require("./lib");

const DIR = process.env.CC_BRIDGE_DIR || path.join(os.homedir(), ".claude", "cc-bridge");
const PID = process.pid;
const REGISTRY = path.join(DIR, PID + ".json");
const INBOX = path.join(DIR, PID + ".in");
const OUTBOX = path.join(DIR, PID + ".out");
const HEARTBEAT_MS = 15000;
const POLL_MS = 2000;

let version = "0";
let out = null;
let writeTimer = null, heartbeat = null, poller = null, watcher = null;
let busy = false;

function log(msg) { if (out) out.appendLine(new Date().toISOString() + " " + msg); }

function writeAtomic(file, text) {
  const tmp = file + ".tmp." + PID;
  fs.writeFileSync(tmp, text, { mode: 0o600 });
  fs.renameSync(tmp, file);
}

function snapshot() { return lib.claudeTabs(vscode.window.tabGroups.all); }

function writeRegistry() {
  try {
    const folders = (vscode.workspace.workspaceFolders || []).map((f) => f.uri.fsPath);
    writeAtomic(REGISTRY, JSON.stringify(lib.registryFor(PID, snapshot(), folders, version, Date.now())));
  } catch (e) {
    log("❌ registry write failed: " + e.message);
  }
}

function scheduleWrite() {
  clearTimeout(writeTimer);
  writeTimer = setTimeout(writeRegistry, 300);
}

function answer(id, result) {
  if (!id) return;
  try {
    writeAtomic(path.join(OUTBOX, id + ".json"),
      JSON.stringify(Object.assign({ v: 1, id, at: Math.floor(Date.now() / 1000) }, result)));
  } catch (e) {
    log("❌ couldn't write the result for " + id + ": " + e.message);
  }
}

// Claim each command by unlinking it (so a retry never runs twice), validate, re-check
// the tabs at execution time, close, answer.
async function processInbox() {
  if (busy) return;
  busy = true;
  try {
    let names = [];
    try { names = fs.readdirSync(INBOX).filter((n) => n.endsWith(".json")); } catch (e) { return; }
    for (const name of names) {
      const file = path.join(INBOX, name);
      let raw;
      try { raw = fs.readFileSync(file, "utf8"); fs.unlinkSync(file); } catch (e) { continue; }
      let cmd = null;
      try { cmd = JSON.parse(raw); } catch (e) { cmd = null; }
      const id = cmd && typeof cmd.id === "string" && lib.ID_RE.test(cmd.id) ? cmd.id : null;
      const v = lib.validateCommand(cmd, Date.now());
      if (!v.ok) {
        log("⚠️ refused a command (" + v.error + ")");
        answer(id, { ok: false, reason: v.error });
        continue;
      }
      const pick = lib.pickExactlyOne(snapshot(), v.cmd.label);
      if (!pick.hit) {
        log("⚠️ didn't close \"" + v.cmd.label + "\": " + pick.reason);
        answer(id, { ok: false, reason: pick.reason });
        continue;
      }
      if (v.cmd.op === "select") {
        const cmds = lib.selectCommands(pick.hit.gi, pick.hit.ti);
        if (!cmds) { answer(id, { ok: false, reason: "the tab is in an editor group past the eighth" }); continue; }
        try {
          for (const c of cmds) await vscode.commands.executeCommand(c.id, ...c.args);
          const g = vscode.window.tabGroups.activeTabGroup;
          const front = !!(g && g.activeTab && g.activeTab.label === v.cmd.label);
          log((front ? "✅ brought forward" : "⚠️ couldn't bring forward") + " the Claude tab \"" + v.cmd.label + "\"");
          answer(id, front ? { ok: true } : { ok: false, reason: "VS Code didn't bring the tab to the front" });
        } catch (e) {
          answer(id, { ok: false, reason: "select failed: " + e.message });
        }
        continue;
      }
      try {
        const closed = await vscode.window.tabGroups.close(pick.hit.tab);
        log((closed ? "✅ closed" : "⚠️ VS Code kept") + " the Claude tab \"" + v.cmd.label + "\"");
        answer(id, closed ? { ok: true } : { ok: false, reason: "VS Code kept the tab open" });
      } catch (e) {
        log("❌ close failed for \"" + v.cmd.label + "\": " + e.message);
        answer(id, { ok: false, reason: "close failed: " + e.message });
      }
    }
  } finally {
    busy = false;
  }
}

function stop() {
  clearTimeout(writeTimer);
  clearInterval(heartbeat);
  clearInterval(poller);
  if (watcher) { try { watcher.close(); } catch (e) { /* already closed */ } }
  writeTimer = heartbeat = poller = watcher = null;
  try { fs.unlinkSync(REGISTRY); } catch (e) { /* never written */ }
}

function activate(context) {
  version = (context.extension && context.extension.packageJSON && context.extension.packageJSON.version) || "0";
  out = vscode.window.createOutputChannel("Shepherd Bridge");
  context.subscriptions.push(out);
  try {
    for (const d of [DIR, INBOX, OUTBOX]) {
      fs.mkdirSync(d, { recursive: true, mode: 0o700 });
      fs.chmodSync(d, 0o700);
    }
  } catch (e) {
    log("❌ can't create " + DIR + ": " + e.message);
    return;
  }
  log("🚀 Shepherd bridge " + version + " up in extension host " + PID);
  writeRegistry();
  context.subscriptions.push(
    vscode.window.tabGroups.onDidChangeTabs(scheduleWrite),
    vscode.window.tabGroups.onDidChangeTabGroups(scheduleWrite),
    vscode.workspace.onDidChangeWorkspaceFolders(scheduleWrite),
    { dispose: stop },
  );
  heartbeat = setInterval(writeRegistry, HEARTBEAT_MS);
  poller = setInterval(processInbox, POLL_MS);
  try { watcher = fs.watch(INBOX, () => { processInbox(); }); } catch (e) { log("⚠️ no file watch, polling only: " + e.message); }
  processInbox();
}

function deactivate() { stop(); }

module.exports = { activate, deactivate, _test: { processInbox, writeRegistry, stop } };
