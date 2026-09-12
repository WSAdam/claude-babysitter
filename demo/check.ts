// check.ts - does a worktree demo run show what it promised? (2026-09-12)
// Copied into every run as scripts/check.ts; `deno task check` runs it there. Each line is a
// plain ✅/❌ statement; the exit code is 0 only when every line holds.

export interface CheckLine {
  ok: boolean;
  text: string;
}

const dec = new TextDecoder();

async function sh(cmd: string, args: string[], cwd: string): Promise<{ code: number; out: string }> {
  try {
    const r = await new Deno.Command(cmd, { args, cwd, stdout: "piped", stderr: "piped" }).output();
    return { code: r.code, out: (dec.decode(r.stdout) + dec.decode(r.stderr)).trim() };
  } catch (e) {
    return { code: 127, out: String(e) };
  }
}

export async function checkRun(dir: string): Promise<{ ok: boolean; lines: CheckLine[] }> {
  const lines: CheckLine[] = [];
  const add = (ok: boolean, text: string) => lines.push({ ok, text });

  const branch = (await sh("git", ["branch", "--show-current"], dir)).out;
  add(branch === "main", branch === "main" ? "on main" : `not on main (on ${branch || "no branch"})`);

  let src = "";
  try {
    src = await Deno.readTextFile(dir + "/src/greet.ts");
  } catch { /* reported below */ }
  for (const fn of ["shout", "whisper"]) {
    const has = src.includes(`export function ${fn}(`);
    add(has, has ? `${fn} is on main` : `${fn} is not on main (src/greet.ts has no exported ${fn})`);
  }

  const tests = await sh("deno", ["task", "test"], dir);
  const passed = tests.out.match(/(\d+) passed/);
  add(tests.code === 0, tests.code === 0 ? `the tests pass (${passed ? passed[1] : "all"})` : "the tests fail: run deno task test");

  const wts = (await sh("git", ["worktree", "list", "--porcelain"], dir)).out
    .split("\n").filter((l) => l.startsWith("worktree ")).map((l) => l.slice(9));
  add(wts.length === 1, wts.length === 1 ? "no unit worktree is left" : `${wts.length - 1} worktree(s) left: ${wts.slice(1).join(", ")}`);

  const units = (await sh("git", ["branch", "--list", "feat/*", "fix/*", "ui/*", "docs/*", "--format=%(refname:short)"], dir)).out
    .split("\n").filter(Boolean);
  add(units.length === 0, units.length === 0 ? "no unit branch is left" : `unit branch(es) left: ${units.join(", ")}`);

  const dirty = (await sh("git", ["status", "--porcelain"], dir)).out;
  add(dirty === "", dirty === "" ? "main is clean" : "main has uncommitted changes");

  return { ok: lines.every((l) => l.ok), lines };
}

if (import.meta.main) {
  const r = await checkRun(Deno.cwd());
  console.log("🔍 Worktree demo check");
  for (const l of r.lines) console.log(`  ${l.ok ? "✅" : "❌"} ${l.text}`);
  console.log(r.ok ? "✅ The run did what it promised." : "❌ Not there yet: see the ❌ lines above.");
  Deno.exit(r.ok ? 0 : 1);
}
