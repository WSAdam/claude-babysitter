// paste-target.test.js - BEHAVIORAL fixture for ⌘V in Shepherd's panel (2026-09-11).
// 2026-09-11 live: pasting into a held question's "Other…" box put the text in the nudge box at the
// bottom instead. Hammerspoon's ⌘V tap swallows the keystroke for the WHOLE panel (so images can be
// pasted) and always handed text to insertIntoNudge; only the worklist modal had an exception.
// Slices the REAL pasteTextTarget / ccPasteText / insertIntoNudge out of claude-dashboard.lua and
// runs them against fake fields, then pins that the tap routes text through ccPasteText.
//
// Usage: node tests/paste-target.test.js [path/to/claude-dashboard.lua]

const fs = require("fs");
const path = require("path");
const DASH = process.argv[2] || path.join(__dirname, "..", "claude-dashboard.lua");

let run = 0, failed = 0;
function check(name, cond) {
  run++;
  if (cond) console.log("ok   - " + name);
  else { failed++; console.log("FAIL - " + name); }
}
function eq(name, got, want) { check(name + "  (got=" + JSON.stringify(got) + " want=" + JSON.stringify(want) + ")", got === want); }

const src = fs.readFileSync(DASH, "utf8");
function slice(startNeedle, endNeedle) {
  const i = src.indexOf(startNeedle);
  if (i < 0) return null;
  const j = src.indexOf(endNeedle, i);
  return j < 0 ? null : src.slice(i, j + endNeedle.length);
}
const parts = {
  target: slice("    function pasteTextTarget(el){", "\n    }\n"),
  paste: slice("    window.ccPasteText = function(t){", "\n    };\n"),
  nudge: slice("    function insertIntoNudge(t){", "\n    }\n"),
};
for (const k of Object.keys(parts)) check("extracted " + k + " from the panel source", parts[k] !== null);
if (Object.values(parts).some((v) => v === null)) {
  console.log("-- paste-target.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}

// fake fields: just what the helpers touch
function field(tag, opts) {
  const f = Object.assign({ tagName: tag, type: tag === "INPUT" ? "text" : undefined, value: "", selectionStart: 0, selectionEnd: 0,
    disabled: false, readOnly: false, isContentEditable: false, events: [], focused: false }, opts || {});
  f.focus = () => { f.focused = true; };
  f.dispatchEvent = (e) => { f.events.push(e.type); return true; };
  return f;
}
const nudge = field("TEXTAREA", { id: "nudge", value: "draft", selectionStart: 5, selectionEnd: 5 });
const env = { document: { activeElement: null, getElementById: (id) => (id === "nudge" ? nudge : null) } };
const run1 = new Function("document", "window", "autoGrow", "Event",
  Object.values(parts).join("\n") + "\nreturn { pasteTextTarget: pasteTextTarget, ccPasteText: window.ccPasteText };");
const win = {};
class FakeEvent { constructor(type) { this.type = type; } }
const api = run1(env.document, win, () => {}, FakeEvent);

// the 2026-09-11 case: the "Other…" box of a held question has focus
const other = field("INPUT", { className: "ask-other", value: "extra ", selectionStart: 6, selectionEnd: 6 });
env.document.activeElement = other;
api.ccPasteText("large please");
eq("a paste lands in the focused Other box, at the caret", other.value, "extra large please");
eq("...with the caret after it", other.selectionStart, 18);
check("...and the box hears it (input event: the answer form enables Send)", other.events.indexOf("input") >= 0);
eq("...and the nudge box is untouched", nudge.value, "draft");

const mid = field("INPUT", { value: "ab", selectionStart: 1, selectionEnd: 2 });
env.document.activeElement = mid;
api.ccPasteText("XY");
eq("a paste replaces the selection in the focused field", mid.value, "aXY");

env.document.activeElement = field("BUTTON");
api.ccPasteText(" more");
eq("no text field focused (a button): the nudge box gets it, as before", nudge.value, "draft more");
env.document.activeElement = null;
api.ccPasteText("!");
eq("nothing focused: the nudge box", nudge.value, "draft more!");

check("a checkbox isn't a text target", api.pasteTextTarget(field("INPUT", { type: "checkbox" })) === null);
check("a disabled field isn't", api.pasteTextTarget(field("INPUT", { disabled: true })) === null);
check("a read-only field isn't", api.pasteTextTarget(field("TEXTAREA", { readOnly: true })) === null);
check("a search box is", api.pasteTextTarget(field("INPUT", { type: "search" })) !== null);

// the Lua ⌘V tap hands text to ccPasteText (never straight to insertIntoNudge)
const tap = slice("local function handlePanelPaste()", "\nend\n") || "";
check("the ⌘V tap routes text through ccPasteText", tap.indexOf('wv:evaluateJavaScript("ccPasteText(" .. jsString(txt) .. ")")') >= 0);
check("...and no longer force-feeds the nudge box", tap.indexOf('"insertIntoNudge(') < 0);

console.log("-- paste-target.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
