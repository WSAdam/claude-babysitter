// stack-fold.test.js - BEHAVIORAL fixture for project cards (2026-09-10). Slices the REAL
// foldCards, tileMatches and the card-extras helpers (branch chip, "also" line, corner
// button) out of claude-dashboard.lua and runs them, so there's no copy of the rules to drift.
//
// A repo's main checkout and its worktrees (or two sessions in one folder) share ONE card.
// Filters run on sessions first -- the bulk bar keeps acting on exactly what matched --
// then each stack draws its best-ranked MATCHING member.
//
// Usage: node tests/stack-fold.test.js [path/to/claude-dashboard.lua]

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
  esc: slice("    function esc(s){", "\n    }\n"),
  fold: slice("    function foldCards(matched){", "\n    }\n"),
  matches: slice("    function tileMatches(it, toks){", "\n    }\n"),
  chip: slice("    function stackBranchChip(it){", "\n    }\n"),
  words: slice("    var STACK_WORDS = ", "};\n"),
  also: slice("    function stackAlsoHtml(it){", "\n    }\n"),
  icon: slice("    var STACK_ICON = ", "</svg>';\n"),
  btn: slice("    function stackBtnHtml(it){", "\n    }\n"),
};
for (const k of Object.keys(parts)) check("extracted " + k + " from the panel source", parts[k] !== null);
if (Object.values(parts).some((v) => v === null)) {
  console.log("-- stack-fold.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const api = new Function(Object.values(parts).join("\n") +
  "\nreturn { foldCards: foldCards, tileMatches: tileMatches, chip: stackBranchChip, also: stackAlsoHtml, btn: stackBtnHtml };")();

// ---- the fixture: Lua's pushed list, already sorted neediest-first -----------
const R = "repo:/p/shepherd/.git";
const items = [
  { key: "fix", name: "shepherd-fix", stackKey: R, stackRank: 1, branch: "fix/tile-flash", status: "approval", stackSize: 3 },
  { key: "sp",  name: "Scratch-pad", stackKey: "-p-shepherd-Scratch-pad", stackRank: 1, status: "working", stackSize: 1 },
  { key: "ui",  name: "shepherd-ui", stackKey: R, stackRank: 2, branch: "ui/rework", status: "working", sessTitle: "Rework the grid", stackSize: 3 },
  { key: "main", name: "shepherd", stackKey: R, stackRank: 3, branch: "main", status: "idle", isMainWt: true, stackSize: 3 },
  { key: "solo", name: "no-stack", status: "idle" },                       // stacks.enabled off / unknown
  { key: R, name: "evil", status: "idle" },                                 // a session key spelled like a stack key
];
const draw = (cards) => cards.map((c) => c.drawn.key).join(",");

let cards = api.foldCards(items);
eq("a repo's main checkout and its worktrees draw ONE card", cards.filter((c) => c.stack === R).length, 1);
eq("a nested non-repo folder (Scratch-pad) is its own card", cards.some((c) => c.stack === "-p-shepherd-Scratch-pad"), true);
eq("the card draws its best-ranked instance", cards[0].drawn.key, "fix");
eq("cards keep Lua's neediest-first order", draw(cards), "fix,sp,solo," + R);
eq("a card remembers all its visible instances (the double-click chooses among them)", cards[0].keys.join(","), "fix,ui,main");
eq("a session without a stack is its own card", cards.filter((c) => c.drawn.key === "solo").length, 1);
eq("a stack key never collides with a session key", cards.length, 4);

// search runs on SESSIONS, then folds: the card draws its best MATCHING instance
function matched(q) {
  const toks = q.toLowerCase().split(/\s+/).filter(Boolean);
  return items.filter((it) => api.tileMatches(it, toks));
}
cards = api.foldCards(matched("ui/rework"));
eq("searching a worktree's branch finds its project card", cards.length, 1);
eq("...and the card draws the matching instance, not the card's lead", cards[0].drawn.key, "ui");
eq("...so bulk actions reach only the matched session", matched("ui/rework").map((i) => i.key).join(","), "ui");
eq("searching a non-lead's chat title finds the card", api.foldCards(matched("rework the grid"))[0].drawn.key, "ui");
check("search text includes the stack name", api.tileMatches({ name: "x", stackName: "Shepherd" }, ["shepherd"]));

// ---- the card extras --------------------------------------------------------
eq("branch chip: shown on a multi-instance card", api.chip({ branch: "fix/y", stackSize: 2 }).includes("fix/y"), true);
eq("branch chip: shown for a lone linked worktree", api.chip({ branch: "fix/y", stackSize: 1, isMainWt: false }).includes("fix/y"), true);
eq("branch chip: a solo main-checkout card looks as before", api.chip({ branch: "main", stackSize: 1, isMainWt: true }), "");
check("branch chip: the branch name is escaped", api.chip({ branch: "<b>x", stackSize: 2 }).includes("&lt;b&gt;x"));
eq("also: summarises the other instances",
   api.also({ stackAlso: [{ b: "working", n: 1 }, { b: "idle", n: 2 }] }).replace(/<[^>]+>/g, ""), "also: 1 working · 2 idle");
eq("also: nothing for a lone instance", api.also({ stackAlso: [] }), "");
eq("also: an empty list encoded as {} renders nothing", api.also({ stackAlso: {} }), "");

const multi = api.btn({ stackKey: R, stackSize: 3, stackNeeds: 1 });
check("button: every local card gets the corner button", api.btn({ stackKey: "-p-x", stackSize: 1 }).includes('class="stk-btn'));
check("button: shows the instance count when there's more than one", multi.includes('<span class="stk-n">3</span>'));
check("button: a pulsing dot when another instance needs you", multi.includes('class="stk-dot"'));
check("button: no count and no dot for a lone, calm instance",
      !api.btn({ stackKey: "-p-x", stackSize: 1, stackNeeds: 0 }).includes("stk-n") && !api.btn({ stackKey: "-p-x", stackSize: 1 }).includes("stk-dot"));
check("button: presses never select the card or pair into a double-click (data-nodbl)", multi.includes("data-nodbl"));
check("button: never interpolates a key into its handler", multi.includes('onclick="openInstances(event)"') && !multi.includes(R));
eq("button: a remote bridge tile gets none (no instances to open)", api.btn({ stackKey: "remote:box|-p", stackSize: 1 }), "");
eq("button: a stackless tile gets none", api.btn({ stackSize: 1 }), "");

console.log("-- stack-fold.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed ? 1 : 0);
