-- worklist-worktrees.test.lua : BEHAVIORAL fixture for "one My List tab per project"
-- (2026-09-10). Loads the real claude-dashboard.lua under a stubbed hs whose `git`
-- answers for a throwaway repo -- a main checkout plus one linked worktree, each with its
-- own TODO.md -- lets the load-time refresh() run, and reads the My List push auto-sync
-- makes. Exercises the FX wiring end to end: stack identity -> the repo's ONE tab ->
-- every worktree root read -> the union import -> the pushed payload.
-- Side-effect-free: every file lives in a temp dir; HOME is pointed there too.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- worklist-worktrees.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

-- ---- fixture: a repo (main + one linked worktree), each with a TODO.md ----------
local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local MAIN, WT, UI = T .. "/repo", T .. "/repo-fix", T .. "/repo-ui"
os.execute('mkdir -p "' .. T .. '/status" "' .. T .. '/.claude" "' .. MAIN .. '/.git/worktrees/repo-fix" "'
  .. MAIN .. '/.git/worktrees/repo-ui" "' .. WT .. '" "' .. UI .. '"')
local now = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
write(MAIN .. "/.git/HEAD", "ref: refs/heads/main\n")
write(MAIN .. "/.git/worktrees/repo-fix/HEAD", "ref: refs/heads/fix/y\n")
write(MAIN .. "/.git/worktrees/repo-ui/HEAD", "ref: refs/heads/ui/z\n")
-- the repo COMMITS TODO.md, so the worktree's copy repeats main's line
write(MAIN .. "/TODO.md", "- [ ] shared item\n")
write(WT .. "/TODO.md", "- [ ] shared item\n- [x] fix-only item\n")
-- 2026-09-10: repo-ui has a live session but NO TODO.md. hs.fs.attributes(missing,
-- "modification") returns nil PLUS an error message, and tonumber(nil, "<msg>") throws
-- ("bad argument #2 to 'tonumber'") -- which crashed the repo import, and would have
-- crashed the auto-sync tick every second once the root was recorded.
for _, s in ipairs({ { "w1", "repo", MAIN }, { "w2", "repo-fix", WT }, { "w3", "repo-ui", UI } }) do
  write(T .. "/status/" .. s[1] .. ".json", string.format(
    '{"status":"idle","session_id":"%s","name":"%s","cwd":"%s","since":%d,"updated":%d,"editor":"vscode"}',
    s[1], s[2], s[3], now, now))
end
-- the main checkout's tab is already enrolled (it imported TODO.md before worktrees)
write(T .. "/worklist.json", json.encode({ generic = {}, byProject = {},
  todoMeta = { K = { cwd = MAIN, mtime = 1, seen = {} } } }))

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json",
              CC_LABELS_FILE = T .. "/labels.json", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

-- ---- stubbed hs: git answers for the fixture repo; files exist where written ----
local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local jsCalls = {}
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function(_, s) jsCalls[#jsCalls + 1] = tostring(s) end },
    { __index = function() return function() return webviewHandle() end end })
end
local function exists(path) local f = io.open(path, "r"); if f then f:close(); return true end return false end
local settingsStore, frame = {}, { x = 0, y = 0, w = 1920, h = 1080 }
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local files, p = {}, io.popen('ls -1 "' .. tostring(path) .. '" 2>/dev/null')
      if p then for line in p:lines() do files[#files + 1] = line end; p:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    -- the REAL return shape: a missing path answers nil AND an error message
    attributes = function(path, attr)
      if type(path) == "string" and path:match("/TODO%.md$") and exists(path) then
        if attr == "modification" then return now - 10 end   -- changed 10s ago: past the 2s settle guard
        if attr == nil then return { mode = "file", modification = now - 10 } end
      end
      return nil, "cannot obtain information from file '" .. tostring(path) .. "': No such file or directory"
    end,
    mkdir = function() return true end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function(cmd)
    cmd = tostring(cmd)
    if cmd:find("rev-parse", 1, true) then
      if cmd:find("'" .. WT .. "'", 1, true) then
        return WT .. "\n" .. MAIN .. "/.git\n" .. MAIN .. "/.git/worktrees/repo-fix\n"
      elseif cmd:find("'" .. UI .. "'", 1, true) then
        return UI .. "\n" .. MAIN .. "/.git\n" .. MAIN .. "/.git/worktrees/repo-ui\n"
      elseif cmd:find("'" .. MAIN .. "'", 1, true) then
        return MAIN .. "\n" .. MAIN .. "/.git\n" .. MAIN .. "/.git\n"
      end
    elseif cmd:find("worktree list", 1, true) then
      return "worktree " .. MAIN .. "\nHEAD aaaaaaa\nbranch refs/heads/main\n\n"
          .. "worktree " .. WT .. "\nHEAD bbbbbbb\nbranch refs/heads/fix/y\n\n"
          .. "worktree " .. UI .. "\nHEAD ccccccc\nbranch refs/heads/ui/z\n"
    end
    return ""
  end,
  hotkey = { bind = function() return mkstub() end },
  pathwatcher = { new = function() return mkstub() end },
  menubar = { new = function() return mkstub() end },
  autoLaunch = function() return false end,
  alert = { show = function() end },
}
hs.timer = setmetatable({
  secondsSinceEpoch = function() return os.time() end,
  absoluteTime = function() return os.time() * 1e9 end,
  doEvery = function() return mkstub() end, doAfter = function() return mkstub() end,
  new = function() return mkstub() end, usleep = function() end,
}, { __index = function() return function() return mkstub() end end })
hs.webview = setmetatable({
  windowMasks  = setmetatable({}, { __index = function() return 0 end }),
  windowLevels = setmetatable({}, { __index = function() return 0 end }),
  new = function() return webviewHandle() end,
  usercontent = { new = function() return mkstub() end },
}, { __index = function() return function() return mkstub() end end })
hs.drawing = setmetatable({
  windowLevels    = setmetatable({}, { __index = function() return 0 end }),
  windowBehaviors = setmetatable({}, { __index = function() return 0 end }),
}, { __index = function() return function() return mkstub() end end })
for _, ns in ipairs({ "eventtap", "streamdeck", "urlevent", "mouse", "application", "window", "pasteboard",
  "keycodes", "canvas", "image", "sound", "notify", "osascript", "dialog", "http", "task", "base", "console" }) do
  hs[ns] = mkstub()
end
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
print = function() end
local ok, err = pcall(dofile, ROOT .. "claude-dashboard.lua")
print = realPrint
check("the dashboard loads and runs its first refresh", ok)
if not ok then print("       " .. tostring(err)); finish() end

-- ---- the My List push -------------------------------------------------------
local payload
for _, s in ipairs(jsCalls) do
  local body = s:match("^window%.ccWorklist%((.*)%)$")
  if body then payload = json.decode(body) end
end
check("auto-sync imported the repo's TODO.md files and pushed My List", payload ~= nil)
if not payload then finish() end
local tabs, repoTab = 0, nil
for _, p in ipairs(payload.projects or {}) do
  if p.key == "K" then repoTab = p end
  if p.key == "K" or p.key == MAIN or p.key == WT then tabs = tabs + 1 end
end
check("the main checkout and its worktree share ONE My List tab", tabs == 1 and repoTab ~= nil)
if not repoTab then finish() end
local byText = {}
for _, it in ipairs(repoTab.items or {}) do byText[it.text] = it end
check("a line in both TODO.md copies imports once", #(repoTab.items or {}) == 2 and byText["shared item"] ~= nil)
check("the worktree-only line is tagged with its branch",
      byText["fix-only item"] and type(byText["fix-only item"].srcBranches) == "table"
      and byText["fix-only item"].srcBranches[1] == "fix/y")
check("the shared line carries no branch tag", byText["shared item"] and byText["shared item"].srcBranches == nil)
check("HARD RULE: the worktree's [x] is the automation badge, never the user's checkmark",
      byText["fix-only item"] and byText["fix-only item"].fileDone == true and byText["fix-only item"].done == false)
local f = io.open(T .. "/worklist.json"); local stored = json.decode(f:read("*a")); f:close()
local roots = {}
for _, r in ipairs(((stored.todoMeta or {}).K or {}).roots or {}) do roots[#roots + 1] = r.root .. (r.isMain and "*" or "") end
check("the tab records every root, main first (so auto-sync watches the worktrees too)  (got="
      .. table.concat(roots, ",") .. ")", table.concat(roots, ",") == MAIN .. "*," .. WT .. "," .. UI)

-- the NEXT tick: auto-sync now stats every recorded root, including repo-ui's missing
-- TODO.md -- it must shrug, not throw (a throw here froze the refresh tick every second)
local dash = rawget(_G, "__ccDashboard")
local tickOk, tickErr = pcall(function() dash.fx.todoAutoSyncTick(dash.fx._shownItems or {}) end)
check("the auto-sync tick survives a watched worktree with no TODO.md", tickOk)
if not tickOk then print("       " .. tostring(tickErr)) end
finish()
