// new-tab-form.test.js - BEHAVIORAL fixture for the Instances view's "New worktree tab"
// form (2026-09-10). Slices the REAL ntSlug / ntSlugOk / ntMessage out of
// claude-dashboard.lua and runs them, then checks the form sits outside #inst-body (the
// live re-render rewrites that div's innerHTML, which would wipe half-typed input).
//
// Usage: node tests/new-tab-form.test.js [path/to/claude-dashboard.lua]

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
  slug: slice("    function ntSlug(raw){", "\n    }\n"),
  ok: slice("    function ntSlugOk(s){", "\n    }\n"),
  msg: slice("    function ntMessage(stackKey, type, rawSlug, task){", "\n    }\n"),
};
for (const k of Object.keys(parts)) check("extracted " + k + " from the panel source", parts[k] !== null);
if (Object.values(parts).some((v) => v === null)) {
  console.log("-- new-tab-form.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}
const api = new Function(Object.values(parts).join("\n") + "\nreturn { ntSlug: ntSlug, ntSlugOk: ntSlugOk, ntMessage: ntMessage };")();

eq("slug: trimmed, lowercased, spaces become dashes", api.ntSlug("  Login Redirect "), "login-redirect");
check("slug rule: a plain name is fine", api.ntSlugOk("login-redirect"));
check("slug rule: dots and underscores are fine", api.ntSlugOk("v2.1_fix"));
for (const bad of ["", "-x", ".x", "a/b", "a..b", "a.", "a.lock", "a b", "x".repeat(41), "../escape"]) {
  check("slug rule: refuses " + JSON.stringify(bad), !api.ntSlugOk(bad));
}

const m = api.ntMessage("repo:/r/.git", "fix", " Login Redirect ", 'say "hi"\nthen </script><b>x</b>');
check("message: a valid form yields one JSON message", !m.error && typeof m.text === "string");
const body = JSON.parse(m.text || "{}");
eq("message: type", body.type, "fix");
eq("message: the normalized slug", body.slug, "login-redirect");
eq("message: the task travels as JSON, byte for byte (never interpolated)", body.task, 'say "hi"\nthen </script><b>x</b>');
check("message: an unknown type is refused before sending", !!api.ntMessage("repo:/r/.git", "chore", "x", "").error);
check("message: a bad name is refused before sending", !!api.ntMessage("repo:/r/.git", "fix", "a/b", "").error);
check("message: no card, no message", !!api.ntMessage("", "fix", "x", "").error);
check("message: a runaway task is capped", JSON.parse(api.ntMessage("k", "ui", "x", "y".repeat(9000)).text).task.length === 4000);

// the form lives OUTSIDE #inst-body (renderInstances rewrites that div's innerHTML)
const iBody = src.indexOf('<div class="ov-body" id="inst-body"></div>');
const iForm = src.indexOf('<div id="inst-new"');
const iFoot = src.indexOf('<div class="ov-foot"><span id="inst-foot"></span></div>');
check("the form is a sibling after #inst-body, not inside it", iBody > 0 && iForm > iBody && iFoot > iForm);
const render = slice("    function renderInstances(force){", "\n    }\n") || "";
check("renderInstances never rewrites the form",
      render.length > 0 && render.indexOf('"inst-new"') < 0 && render.indexOf("nt-slug") < 0 && render.indexOf("nt-task") < 0);

console.log("-- new-tab-form.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
