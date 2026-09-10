// tile-press.browser.test.js - BEHAVIORAL fixture: replays the SHIPPED panel HTML in a
// real (headless Chromium) browser and presses a tile while the grid re-renders.
//
// 2026-09-10: "double-click on a tile isn't always reliable" (README, CD comment). Cause,
// reproduced here: renderGrid rebuilds grid.innerHTML whenever a tile's data changes --
// several times a second while a session works -- and when that rebuild lands between
// the mousedown and the mouseup of a press, the pressed node is detached, so neither
// click nor dblclick reaches the tile's inline handlers. The jump (2nd press) and the
// select (1st press) were silently dropped. A rebuild BETWEEN presses was harmless.
//
// Needs Playwright (the isolate runner's copy, or CC_PLAYWRIGHT=<module path>); without
// it this prints an explicit skip, like `make lint` does for a missing luacheck.
// Usage: node tests/tile-press.browser.test.js

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const ROOT = path.join(__dirname, "..");
let run = 0, failed = 0;
function check(name, cond) {
  run++;
  if (cond) console.log("ok   - " + name);
  else { failed++; console.log("FAIL - " + name); }
}
function eq(name, got, want) { check(name + "  (got=" + got + " want=" + want + ")", got === want); }
function finish() {
  console.log("-- tile-press.browser.test.js: " + run + " run, " + failed + " failed --");
  process.exit(failed ? 1 : 0);
}

function loadPlaywright() {
  const tries = [process.env.CC_PLAYWRIGHT,
    path.join(os.homedir(), ".isolate-runner", "node_modules", "playwright"), "playwright"].filter(Boolean);
  for (const t of tries) { try { return require(t); } catch (e) { /* next */ } }
  return null;
}
const pw = loadPlaywright();
if (!pw) {
  console.log("skip - real-browser tile-press check: Playwright not installed (set CC_PLAYWRIGHT or install the isolate runner)");
  process.exit(0);
}

// ---- capture the real panel (stubbed-hs load of claude-dashboard.lua) --------
const out = fs.mkdtempSync(path.join(os.tmpdir(), "cc-panel-"));
const home = fs.mkdtempSync(path.join(os.tmpdir(), "cc-home-"));
try {
  execFileSync("lua", [path.join(ROOT, "tests/support/capture-panel.lua"), ROOT, out],
    { env: Object.assign({}, process.env, { HOME: home }), stdio: ["ignore", "pipe", "inherit"] });
} catch (e) {
  check("captured the shipped panel html under a stubbed hs", false);
  finish();
}
const update = fs.readFileSync(path.join(out, "update.js"), "utf8");

(async () => {
  let browser;
  try { browser = await pw.chromium.launch({ headless: true }); }
  catch (e) {
    console.log("skip - real-browser tile-press check: Chromium could not launch (" + String(e.message).split("\n")[0] + ")");
    process.exit(0);
  }
  const page = await browser.newPage({ viewport: { width: 580, height: 320 } });
  await page.addInitScript(() => {
    window.__sent = [];
    window.webkit = { messageHandlers: { cc: { postMessage: (m) => window.__sent.push(String(m)) } } };
  });
  await page.goto("file://" + path.join(out, "panel.html"));
  await page.evaluate((code) => {
    const orig = window.ccUpdate;
    window.__orig = orig;
    window.ccUpdate = function (a, b, c) { window.__args = [a, b, c]; return orig.apply(this, arguments); };
    (0, eval)(code);
    // a rebuild exactly like a status write mid-work: every tile's data changes
    window.__rebuild = () => {
      const [a, b, c] = window.__args;
      const items = JSON.parse(JSON.stringify(a));
      items.forEach((i) => { i.updated = (i.updated || 0) + 1 + Math.random(); });
      window.__args = [items, b, c];
      window.__orig.call(window, items, b, c);
    };
  }, update);

  check("the fixture's tiles rendered", (await page.locator(".tile").count()) === 3);
  async function at(key) {
    const box = await page.locator('.tile[data-key="' + key + '"]').boundingBox();
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  }
  async function sent(a, v) {
    return page.evaluate(([a, v]) => window.__sent.filter((s) => {
      try { const m = JSON.parse(s); return m.a === a && m.v === v; } catch (e) { return false; }
    }).length, [a, v]);
  }
  // A jump on a tile: "focus" for a stackless tile, or (project stacks, 2026-09-10)
  // "focus-group" for the card's stack -- Lua resolves the instance from fresh state.
  async function jumps(key) {
    const stack = await page.evaluate((k) => {
      const el = document.querySelector('.tile[data-key="' + k + '"]');
      return el ? el.getAttribute("data-stack") : null;
    }, key);
    return (await sent("focus", key)) + (stack ? await sent("focus-group", stack) : 0);
  }
  async function reset() {
    await page.evaluate(() => { window.__sent = []; selectedKey = null; });
    await page.waitForTimeout(700);                // past the OS double-click interval
  }
  const rebuild = () => page.evaluate(() => window.__rebuild());
  async function press(n, mid) {
    await page.mouse.down({ clickCount: n });
    if (mid) await rebuild();
    await page.mouse.up({ clickCount: n });
  }

  await reset(); await at("k1");
  await press(1); await press(2);
  eq("a plain double-click jumps exactly once", await jumps("k1"), 1);

  await reset(); await at("k1");
  await press(1); await rebuild(); await press(2);
  eq("a double-click still jumps when the grid re-renders between the presses", await jumps("k1"), 1);

  await reset(); await at("k1");
  await press(1); await press(2, true);
  eq("a double-click jumps even when the grid re-renders during the second press", await jumps("k1"), 1);

  await reset(); await at("k2");
  await press(1, true);
  eq("a single click selects even when the grid re-renders during the press",
     await page.evaluate(() => selectedKey), "k2");
  eq("a single click never jumps", await jumps("k2"), 0);

  await reset(); await at("k3");
  await press(1); await press(2); await press(3);
  eq("a triple-click jumps once, not twice", await jumps("k3"), 1);

  await browser.close();
  finish();
})().catch((e) => { console.log("FAIL - browser run crashed: " + e.message); process.exit(1); });
