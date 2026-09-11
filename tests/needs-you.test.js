// needs-you.test.js - BEHAVIORAL fixture for how a card says it is waiting on Adam (2026-09-11).
// 2026-09-11 live: a driver's batch waited for Adam's approval, but its session had finished its
// turn, so the card read a green "Ready for you" with only a thin ring -- Adam had no idea it was
// waiting on him. Slices the REAL bgRunning / needsYouNow / effStatus / statusWords (and LABELS)
// out of claude-dashboard.lua and runs them, then pins the tile class and its pulse.
//
// Usage: node tests/needs-you.test.js [path/to/claude-dashboard.lua]

const fs = require("fs");
const path = require("path");
const DASH = process.argv[2] || path.join(__dirname, "..", "claude-dashboard.lua");

let run = 0, failed = 0;
function check(name, cond) {
  run++;
  if (cond) console.log("ok   - " + name);
  else { failed++; console.log("FAIL - " + name); }
}
function eq(name, got, want) { check(name + "  (got=" + got + " want=" + want + ")", got === want); }

const src = fs.readFileSync(DASH, "utf8");
function slice(startNeedle, endNeedle) {
  const i = src.indexOf(startNeedle);
  if (i < 0) return null;
  const j = src.indexOf(endNeedle, i);
  return j < 0 ? null : src.slice(i, j + endNeedle.length);
}
const parts = {
  labels: slice("    var LABELS = {", "};\n"),
  bg: slice("    function bgRunning(it){", "}\n"),
  needs: slice("    function needsYouNow(it){", "}\n"),
  eff: slice("    function effStatus(it){", "}\n"),
  words: slice("    function statusWords(it){", "\n    }\n"),
};
for (const k of Object.keys(parts)) check("extracted " + k + " from the panel source", parts[k] !== null);
if (Object.values(parts).some((v) => v === null)) {
  console.log("-- needs-you.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const api = new Function(Object.values(parts).join("\n") +
  "\nreturn { needsYouNow: needsYouNow, effStatus: effStatus, statusWords: statusWords };")();

// the live card: the driver finished its turn; its batch waits for Adam
const driver = { key: "drv", status: "done", fleet: { phase: "proposed", needsYou: true, line: "⇉ proposes 1 unit" } };
check("a batch waiting for approval: the card needs Adam", api.needsYouNow(driver));
eq("...its dot is the approval colour, not done's green", api.effStatus(driver), "approval");
eq("...and it reads Needs you, not Ready for you", api.statusWords(driver), "Needs you");
const merge = { key: "u", status: "done", merge: { phase: "requested", needsYou: true } };
eq("a merge waiting for Adam's click reads Needs you", api.statusWords(merge), "Needs you");
const ask = { key: "q", status: "approval", askHeld: true };
eq("a held question reads Needs you", api.statusWords(ask), "Needs you");
const busy = { key: "b", status: "done", bg_active: true, bg_count: 2, fleet: { needsYou: true } };
eq("waiting on Adam wins over background agents running", api.effStatus(busy), "approval");
const plain = { key: "p", status: "done" };
eq("a plain finished session still reads Ready for you", api.statusWords(plain), "Ready for you");
check("...and doesn't need Adam", !api.needsYouNow(plain));
const merging = { key: "m", status: "working", merge: { phase: "merging", needsYou: false } };
eq("a merge already running doesn't need Adam", api.effStatus(merging), "working");

const tile = slice("    function tileHtml(it){", "\n    }\n") || "";
check("the tile pulses whenever it needs Adam (class needs)", tile.indexOf('(needsYouNow(it) ? " needs" : "")') >= 0);
check("the pulse is styled", /\.tile\.needs \{ animation:askglow/.test(src));

console.log("-- needs-you.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
