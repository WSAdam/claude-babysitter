# The worktree demo

A repeatable, ten-minute proof that Shepherd's parallel worktree flow does what it says:
**two separate pieces of work, in the same project, at the same time — both landing on main.**

## Run it

```bash
deno task demo        # from the Shepherd repo root (or: make demo)
```

It checks that everything it needs is there, creates a fresh little Deno app, and opens it in a new
VS Code window. In that window, open a Claude tab and type:

```
run the worktree demo
```

Then follow what it tells you: you approve the work once and click **Merge** twice.

## Read about it

- **[GUIDE.md](GUIDE.md)** — for anyone. What you'll see, what to click, and what it proves, in
  plain language.
- **[HOW-IT-WORKS.md](HOW-IT-WORKS.md)** — for engineers. The moving parts, the files they write,
  the sequence of events, why the merge conflict resolves, and how to recover when something
  goes wrong.

## What's in this folder

| File | What it is |
|---|---|
| `setup.ts` | `deno task demo`: checks, tidies old runs, creates and opens a fresh run |
| `check.ts` | `deno task check` inside a run: proves the result, line by line |
| `template/` | the starter app every run begins from, with its `CLAUDE.md`, permissions and the driver's playbook (`.claude/skills/worktree-demo/`) |
| `setup_test.ts` | the tests for all of the above (`deno task demo:test`) |
