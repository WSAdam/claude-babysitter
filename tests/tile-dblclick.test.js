// tile-dblclick.test.js - BEHAVIORAL fixture for the tile press decision. Slices the REAL
// tileDblStep + onGridMouseDown out of claude-dashboard.lua and runs them against fake
// presses, so there is no copy of the rule to drift. (tests/tile-press.browser.test.js
// proves the same fix in a real browser; this one is the fast, always-on half.)
//
// 2026-09-10: a grid rebuild between a press's mousedown and mouseup detached the tile,
// so its inline onclick/ondblclick never fired -- the jump and the select were dropped.
// Presses are now decided at mousedown (the node is live then), from the OS click count.
//
// Usage: node tests/tile-dblclick.test.js [path/to/claude-dashboard.lua]

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
  return j < 0 ? null : src.slice(i, j);
}
const code = slice("    var tileDblState = null;", "    function tileActivate(");
check("extracted the tile press logic from the panel source", code !== null);
if (!code) {
  console.log("-- tile-dblclick.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}

// A fresh panel per scenario: its own press state, clock, and select/jump recorders.
function panel() {
  const p = { now: 100000, selected: [], jumped: [] };
  const fakeDate = { now: () => p.now };
  p.cards = [];
  const api = new Function("selectTile", "tileActivate", "Date",
    code + "\nreturn { down: onGridMouseDown, step: tileDblStep };")(
    (k) => p.selected.push(k), (k, stack) => { p.jumped.push(k); p.cards.push(stack || null); }, fakeDate);
  p.down = api.down; p.step = api.step;
  // a press on a tile (a NEW node object each time -- grid rebuilds replace them);
  // opts.stack = the card's data-stack (project stacks)
  p.press = (key, detail, opts) => {
    opts = opts || {};
    const tile = { getAttribute: (n) => (n === "data-key" ? key : n === "data-stack" ? (opts.stack || null) : null) };
    const badge = { closest: (s) => (s === ".tile" ? tile : s === "[data-nodbl]" ? badge : null) };
    const plain = { closest: (s) => (s === ".tile" ? tile : null) };
    p.down({ button: opts.button === undefined ? 0 : opts.button, detail: detail,
             target: opts.onBadge ? badge : plain });
  };
  p.wait = (ms) => { p.now += ms; };
  return p;
}

let p = panel();
p.press("k1", 1); p.wait(150); p.press("k1", 2);
eq("a double-click jumps once", p.jumped.join(","), "k1");
eq("its first press selects the tile", p.selected.join(","), "k1");

p = panel();
p.press("k1", 1); p.wait(150); p.press("k1", 2);   // press() builds a fresh node: a rebuild between presses
eq("a rebuild between the presses (new node, same key) still jumps once", p.jumped.length, 1);

p = panel();
p.press("k1", 1); p.wait(150); p.press("k2", 2);
eq("a double press that spans two different tiles never jumps", p.jumped.length, 0);

p = panel();
p.press("k1", 1); p.wait(800); p.press("k1", 1);
eq("two slow clicks are two selects, not a jump", p.jumped.length, 0);
eq("...and both presses select", p.selected.length, 2);

p = panel();
p.press("k1", 1); p.wait(120); p.press("k1", 2); p.wait(120); p.press("k1", 3);
eq("a triple-click jumps once", p.jumped.length, 1);

p = panel();
p.press("k1", 1, { onBadge: true }); p.wait(150); p.press("k1", 2);
eq("a press on a badge inside the tile never arms a jump", p.jumped.length, 0);
eq("...and never selects the tile", p.selected.length, 0);

p = panel();
p.press("k1", 1, { button: 2 }); p.wait(100); p.press("k1", 2, { button: 2 });
eq("right-button presses neither select nor jump", p.selected.length + p.jumped.length, 0);

p = panel();
p.press("k1", 0); p.wait(200); p.press("k1", 0);
eq("presses without a click count (detail 0) jump on a same-tile pair within 400ms", p.jumped.length, 1);
p.wait(100); p.press("k1", 0);
eq("...once, not again on a third", p.jumped.length, 1);
p = panel();
p.press("k1", 0); p.wait(500); p.press("k1", 0);
eq("...and not when the pair is slower than 400ms", p.jumped.length, 0);

p = panel();
p.press("k1", 2);
eq("a double-click whose first press was swallowed (panel activation) still jumps", p.jumped.join(","), "k1");

p = panel();
p.press("k2", 1); p.wait(5000); p.press("k1", 2);
eq("a stale press on another tile seconds ago doesn't veto a real double-click", p.jumped.join(","), "k1");

// 2026-09-10 project stacks: a card pairs on its STACK -- between the two presses the card
// may start drawing a different instance (a new lead), and that is still one double-click
p = panel();
p.press("k1", 1, { stack: "repo:/r/.git" }); p.wait(150); p.press("k2", 2, { stack: "repo:/r/.git" });
eq("a lead change between the presses (same card) still jumps once", p.jumped.length, 1);
eq("...and the jump carries the card's stack (focus-group)", p.cards.join(","), "repo:/r/.git");
p = panel();
p.press("k1", 1, { stack: "repo:/a/.git" }); p.wait(150); p.press("k2", 2, { stack: "repo:/b/.git" });
eq("a press pair spanning two different cards never jumps", p.jumped.length, 0);

console.log("-- tile-dblclick.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed ? 1 : 0);
