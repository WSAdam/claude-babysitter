-- new-worktree-tab.test.lua : BEHAVIORAL fixture for "New worktree tab" (2026-09-10).
-- Loads the real claude-dashboard.lua under a stubbed hs -- a fake VS Code with the repo's
-- window, a controllable front window, captured hs.urlevent.openURL calls and counted
-- keystrokes; timers fire synchronously once the panel has loaded -- then drives the
-- bridge: a valid request opens exactly one Claude tab URI in the repo's window with the
-- EnterWorktree prompt typed in (no keystroke), bad or taken names open nothing, a lost
-- window opens nothing, and Open on an idle .claude/worktrees/ worktree resumes it in a tab.
-- Side-effect-free: every file lives in a temp dir; HOME is pointed there too.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- new-worktree-tab.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

-- ---- fixture: a repo with one session in its main checkout ------------------------
local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local MAIN = T .. "/repo"
local OLD = MAIN .. "/.claude/worktrees/old"     -- an idle worktree a tab left behind
local SIB = T .. "/repo-sib"                     -- an idle sibling worktree
os.execute('mkdir -p "' .. T .. '/status" "' .. T .. '/.claude" "' .. MAIN .. '/.git" "' .. OLD .. '" "' .. SIB .. '"')
local now = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
write(MAIN .. "/.git/HEAD", "ref: refs/heads/main\n")
write(T .. "/status/m1.json", string.format(
  '{"status":"idle","session_id":"m1","name":"repo","cwd":"%s","since":%d,"updated":%d,"editor":"vscode"}', MAIN, now, now))

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json",
              CC_LABELS_FILE = T .. "/labels.json", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

-- ---- stubbed hs --------------------------------------------------------------------
local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local urls, alerts, tasks, logs = {}, {}, {}, {}
local taps = 0
local syncTimers = false          -- timers fire at once, but only after the panel has loaded
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function() end },
    { __index = function() return function() return webviewHandle() end end })
end
local function exists(p) return os.execute('test -e "' .. p .. '"') and true or false end
local vscodeApp = { bundleID = function() return "com.microsoft.VSCode" end }
local function window(title, app)
  return { title = function() return title end, focus = function() end, application = function() return app end }
end
local repoWin = window("main.lua — repo", vscodeApp)
local chromeWin = window("Reddit - Google Chrome", { bundleID = function() return "com.google.Chrome" end })
local WINDOWS, FRONT = { repoWin }, repoWin
local fakeApp = { allWindows = function() return WINDOWS end, activate = function() end }
local settingsStore, frame = {}, { x = 0, y = 0, w = 1920, h = 1080 }
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local files, p = {}, io.popen('ls -1 "' .. tostring(path) .. '" 2>/dev/null')
      if p then for line in p:lines() do files[#files + 1] = line end; p:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = function(path, attr)
      if type(path) == "string" and exists(path) then
        local t = { mode = os.execute('test -d "' .. path .. '"') and "directory" or "file", modification = now - 10 }
        if attr then return t[attr] end
        return t
      end
      return nil, "cannot obtain information from file '" .. tostring(path) .. "': No such file or directory"
    end,
    mkdir = function() return true end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function(cmd)
    cmd = tostring(cmd)
    if cmd:find("rev-parse", 1, true) and cmd:find("'" .. MAIN .. "'", 1, true) then
      return MAIN .. "\n" .. MAIN .. "/.git\n" .. MAIN .. "/.git\n"
    elseif cmd:find("worktree list", 1, true) then
      return "worktree " .. MAIN .. "\nHEAD aaaaaaa\nbranch refs/heads/main\n\n"
          .. "worktree " .. OLD .. "\nHEAD bbbbbbb\nbranch refs/heads/fix/old\n\n"
          .. "worktree " .. SIB .. "\nHEAD ccccccc\nbranch refs/heads/ui/sib\n"
    elseif cmd:find("for-each-ref", 1, true) then
      return "main\nfix/taken\nfix/old\nui/sib\n"
    end
    return ""
  end,
  hotkey = { bind = function() return mkstub() end },
  pathwatcher = { new = function() return mkstub() end },
  menubar = { new = function() return mkstub() end },
  autoLaunch = function() return false end,
  alert = { show = function(s) alerts[#alerts + 1] = tostring(s) end },
}
hs.timer = setmetatable({
  secondsSinceEpoch = function() return os.time() end,
  absoluteTime = function() return os.time() * 1e9 end,
  doEvery = function() return mkstub() end,
  doAfter = function(_, fn) if syncTimers then fn() end; return mkstub() end,
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
rawset(hs.eventtap, "keyStroke", function() taps = taps + 1 end)
rawset(hs.eventtap, "keyStrokes", function() taps = taps + 1 end)
rawset(hs.urlevent, "openURL", function(u) urls[#urls + 1] = tostring(u) end)
rawset(hs.application, "applicationsForBundleID", function() return { fakeApp } end)
rawset(hs.application, "find", function() return fakeApp end)
rawset(hs.window, "focusedWindow", function() return FRONT end)
rawset(hs.task, "new", function(bin, _, args) tasks[#tasks + 1] = { bin = bin, args = args }; return mkstub() end)
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
local function capture(fn)
  logs = {}
  print = function(...) local parts = {} for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end; logs[#logs + 1] = table.concat(parts, " ") end
  local ok, err = pcall(fn)
  print = realPrint
  if not ok then realPrint("       error: " .. tostring(err)) end
  return ok
end
local function logged(needle) for _, l in ipairs(logs) do if l:find(needle, 1, true) then return true end end return false end
local function alerted(needle) for _, a in ipairs(alerts) do if a:find(needle, 1, true) then return true end end return false end
local function decode(u) return (u:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end

local loaded = capture(function() dofile(ROOT .. "claude-dashboard.lua") end)
check("the dashboard loads and runs its first refresh", loaded)
if not loaded then finish() end
syncTimers = true
local dash = rawget(_G, "__ccDashboard")
local fx = dash.fx
local m1
for _, it in ipairs(fx._shownItems or {}) do if it.key == "m1" then m1 = it end end
check("the repo's session is on a repo card", m1 ~= nil and m1.stackKey == "repo:" .. MAIN .. "/.git")
if not m1 then finish() end
local SK = m1.stackKey

-- ---- a valid request ----------------------------------------------------------------
urls, alerts, taps = {}, {}, 0
capture(function() fx.newWorktreeTab(SK, json.encode({ type = "fix", slug = "login-redirect", task = 'make the "login" redirect work' })) end)
check("a valid request opens exactly one Claude tab URI  (got " .. #urls .. ")", #urls == 1)
local u = urls[1] or ""
check("...through the extension's open handler, in VS Code", u:find("^vscode://anthropic%.claude%-code/open%?prompt=") ~= nil)
local prompt = decode(u:match("prompt=(.*)$") or "")
check("...with the EnterWorktree prompt typed in", prompt:find('EnterWorktree with name "login-redirect"', 1, true) ~= nil
      and prompt:find("git branch -m fix/login-redirect", 1, true) ~= nil)
check("...carrying the task intact", prompt:find('make the "login" redirect work', 1, true) ~= nil)
check("...and never a keystroke (the prompt waits for Return)", taps == 0)
check("...and says to check it and press Return", alerted("press Return"))

-- ---- refusals: nothing opens ----------------------------------------------------------
urls, alerts = {}, {}
capture(function() fx.newWorktreeTab(SK, json.encode({ type = "fix", slug = "taken" })) end)
check("a branch that already exists opens nothing and says so", #urls == 0 and alerted("already exists"))
urls, alerts = {}, {}
capture(function() fx.newWorktreeTab(SK, json.encode({ type = "fix", slug = "../escape" })) end)
check("a bad name opens nothing", #urls == 0 and #alerts >= 1)
urls, alerts = {}, {}
capture(function() fx.newWorktreeTab(SK, json.encode({ type = "fix", slug = "old" })) end)
check("a name a worktree already has opens nothing", #urls == 0)
urls, alerts = {}, {}
capture(function() fx.newWorktreeTab("repo:/nowhere/.git", json.encode({ type = "fix", slug = "x" })) end)
check("a card with no repo behind it opens nothing", #urls == 0)

-- the repo's window is focused, but something else is in front when the URI would go out
urls, alerts, FRONT = {}, {}, chromeWin
capture(function() fx.newWorktreeTab(SK, json.encode({ type = "fix", slug = "lost-focus" })) end)
check("if the repo's window isn't in front when the tab would open, nothing opens", #urls == 0 and alerted("wasn't in front"))
FRONT = repoWin

-- no window for the repo at all: open the folder, wait for its window, give up cleanly
urls, alerts, tasks, WINDOWS = {}, {}, {}, {}
capture(function() fx.newWorktreeTab(SK, json.encode({ type = "fix", slug = "cold" })) end)
local opened = false
for _, t in ipairs(tasks) do
  for _, a in ipairs(t.args or {}) do if a == MAIN then opened = true end end
end
check("with no window for the repo, its folder is opened first", opened)
check("...and when its window never appears, no tab opens", #urls == 0 and alerted("never appeared"))
WINDOWS = { repoWin }

-- ---- Open on idle worktrees --------------------------------------------------------------
urls, alerts, tasks = {}, {}, {}
capture(function() fx.openWorktree(SK, OLD) end)
check("Open on an idle .claude/worktrees/ worktree resumes it in a new tab", #urls == 1
      and decode(urls[1]:match("prompt=(.*)$") or ""):find('EnterWorktree with path "' .. OLD .. '"', 1, true) ~= nil)
urls, alerts = {}, {}
capture(function() fx.openWorktree(SK, SIB) end)
check("Open on a sibling worktree still spawns its own window (no tab)", #urls == 0 and logged("open-worktree: " .. SIB))
finish()
