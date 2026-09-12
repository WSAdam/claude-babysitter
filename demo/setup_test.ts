// setup_test.ts - the worktree demo's setup and check (2026-09-12).
// `deno task demo` creates a FRESH demo repo per run (a new path, so VS Code has no old Claude tabs
// to restore -- the 2026-09-11 runs tripped on exactly that), and `deno task check` in a run proves
// the result: both features on main, tests green, no worktrees or unit branches left.
//
// Run: deno task demo:test   (from the Shepherd repo root)

import { createRun, findOldRuns, openFolders, preflight, runName } from "./setup.ts";
import { checkRun } from "./check.ts";

const HERE = new URL(".", import.meta.url).pathname;
const dec = new TextDecoder();

function assert(cond: unknown, msg: string): void {
  if (!cond) throw new Error(msg);
}

async function sh(cmd: string, args: string[], cwd?: string): Promise<{ code: number; out: string }> {
  const r = await new Deno.Command(cmd, { args, cwd, stdout: "piped", stderr: "piped" }).output();
  return { code: r.code, out: (dec.decode(r.stdout) + dec.decode(r.stderr)).trim() };
}

async function exists(p: string): Promise<boolean> {
  try {
    await Deno.stat(p);
    return true;
  } catch {
    return false;
  }
}

async function newRun(stamp = "20260912-1030") {
  const runsDir = await Deno.makeTempDir({ prefix: "wt-demo-runs-" });
  const run = await createRun({
    template: HERE + "template",
    checkScript: HERE + "check.ts",
    runsDir,
    stamp,
    home: "/Users/test",
    runTests: true,
  });
  return { runsDir, ...run };
}

// what the two units do, written straight onto main (a merged run, for the check's pass case)
async function mergeBothFeatures(dir: string): Promise<void> {
  await Deno.writeTextFile(
    dir + "/src/greet.ts",
    "\nexport function shout(name: string): string {\n  return `HELLO, ${name.toUpperCase()}!`;\n}\n" +
      "\nexport function whisper(name: string): string {\n  return `(hello, ${name.toLowerCase()}…)`;\n}\n",
    { append: true },
  );
  await Deno.writeTextFile(
    dir + "/src/greet_test.ts",
    '\nimport { shout, whisper } from "./greet.ts";\n' +
      'Deno.test("shout greets loudly", () => {\n  if (shout("Adam") !== "HELLO, ADAM!") throw new Error(shout("Adam"));\n});\n' +
      'Deno.test("whisper greets quietly", () => {\n  if (whisper("Adam") !== "(hello, adam…)") throw new Error(whisper("Adam"));\n});\n',
    { append: true },
  );
  await sh("git", ["-C", dir, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-qam", "Add shout and whisper"]);
}

Deno.test("a run is a fresh repo: one clean commit, green tests, the driver's skill and the check script", async () => {
  const { dir, testsPassed } = await newRun();
  assert(dir.endsWith("/" + runName("20260912-1030")), `run folder named after the stamp: ${dir}`);
  const log = await sh("git", ["-C", dir, "log", "--format=%s"]);
  assert(log.out === "Starter app", `exactly one commit, "Starter app": got ${JSON.stringify(log.out)}`);
  assert((await sh("git", ["-C", dir, "status", "--porcelain"])).out === "", "the tree is clean");
  assert((await sh("git", ["-C", dir, "branch", "--show-current"])).out === "main", "on main");
  for (const f of [".claude/skills/worktree-demo/SKILL.md", "scripts/check.ts", "CLAUDE.md", ".gitignore", "src/greet_test.ts"]) {
    assert(await exists(dir + "/" + f), `the run carries ${f}`);
  }
  const settings = await Deno.readTextFile(dir + "/.claude/settings.json");
  assert(settings.includes("/Users/test/.claude/cc-merge.sh"), "the allow list names this machine's cc-merge.sh");
  assert(!settings.includes("__HOME__"), "no placeholder left in the settings");
  assert(testsPassed === true, "the starter app's tests pass");
});

Deno.test("check fails on a fresh run: the two features aren't there yet", async () => {
  const { dir } = await newRun();
  const r = await checkRun(dir);
  assert(r.ok === false, "a fresh run doesn't pass the check");
  assert(r.lines.some((l) => !l.ok && l.text.includes("shout")), "it names the missing shout");
  assert(r.lines.some((l) => !l.ok && l.text.includes("whisper")), "it names the missing whisper");
});

Deno.test("check passes once both features are on main, and fails with a worktree or unit branch left", async () => {
  const { dir } = await newRun();
  await mergeBothFeatures(dir);
  const good = await checkRun(dir);
  assert(good.ok === true, "both features merged, tests green, nothing left over: " + JSON.stringify(good.lines));
  await sh("git", ["-C", dir, "worktree", "add", "-q", dir + "/.claude/worktrees/extra", "-b", "feat/extra"]);
  const bad = await checkRun(dir);
  assert(bad.ok === false, "a leftover worktree fails the check");
  assert(bad.lines.some((l) => !l.ok && l.text.includes("worktree")), "it says a worktree is left");
  assert(bad.lines.some((l) => !l.ok && l.text.includes("feat/extra")), "it names the leftover unit branch");
});

Deno.test("old runs whose window is closed are for the Trash; open runs and other folders stay", async () => {
  const runsDir = await Deno.makeTempDir({ prefix: "wt-demo-old-" });
  const a = runsDir + "/" + runName("20260101-0900");
  const b = runsDir + "/" + runName("20260102-0900");
  for (const d of [a, b, runsDir + "/notes"]) await Deno.mkdir(d);
  const r = await findOldRuns(runsDir, [b]);
  assert(JSON.stringify(r.trash) === JSON.stringify([a]), "the closed run goes: " + JSON.stringify(r.trash));
  assert(JSON.stringify(r.keep) === JSON.stringify([b]), "the open run stays: " + JSON.stringify(r.keep));
});

Deno.test("open folders come from fresh tab-bridge registries only", async () => {
  const dir = await Deno.makeTempDir({ prefix: "wt-demo-bridge-" });
  const now = Math.floor(Date.now() / 1000);
  await Deno.writeTextFile(dir + "/101.json", JSON.stringify({ v: 1, pid: 101, folders: ["/r/open"], tabs: [], at: now }));
  await Deno.writeTextFile(dir + "/102.json", JSON.stringify({ v: 1, pid: 102, folders: ["/r/crashed"], tabs: [], at: now - 600 }));
  await Deno.writeTextFile(dir + "/.installed", "0.4.0");
  const f = await openFolders(dir, now);
  assert(JSON.stringify(f) === JSON.stringify(["/r/open"]), "only the live window's folder: " + JSON.stringify(f));
});

Deno.test("preflight names each missing piece, with a fix", async () => {
  const home = await Deno.makeTempDir({ prefix: "wt-demo-home-" });
  const problems = await preflight({ home, now: Math.floor(Date.now() / 1000), codeCli: null });
  const all = problems.join("\n");
  assert(all.includes("Shepherd isn't running"), "Shepherd's heartbeat is missing: " + all);
  assert(all.includes("cc-fleet.sh"), "the batch script is missing");
  assert(all.includes("tab bridge"), "the tab bridge isn't installed");
  assert(all.includes("VS Code"), "VS Code's command-line tool wasn't found");
});
