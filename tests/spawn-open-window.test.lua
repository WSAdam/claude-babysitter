-- spawn-open-window.test.lua : BEHAVIORAL fixture (2026-09-10) for spawning a session into
-- a project whose VS Code window already has a Claude tab.
-- 2026-09-10: the warm extension ladder pressed ⌘Esc -- claude-vscode.focus, which focuses the
-- Claude tab the extension last used -- then pasted the task and pressed Return, so a "new
-- session" in an open project was typed and SENT into the session already there.
-- Loads the real claude-dashboard.lua under a stubbed hs (a fake VS Code window per folder,
-- keystrokes recorded, hs.urlevent.openURL captured, `ps` answered from a fixture; timers fire
-- synchronously once the panel has loaded) and drives FX.spawnSession.
-- Side-effect-free: every file lives in a temp dir; HOME is pointed there too.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- spawn-open-window.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

-- ---- fixture: a project with a live Claude tab (pid 4242), and one with none ----------
local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local BUSY, IDLE = T .. "/busy", T .. "/quiet"
os.execute('mkdir -p "' .. T .. '/status" "' .. T .. '/.claude" "' .. BUSY .. '" "' .. IDLE .. '"')
local now = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
write(T .. "/status/b1.json", string.format(
  '{"status":"idle","session_id":"b1","name":"busy","cwd":"%s","since":%d,"updated":%d,"editor":"vscode","host_window":"900","session_pid":"4242"}',
  BUSY, now, now))
write(T .. "/.claude/cc-config.json", json.encode({ spawn = { live = true, editor = "vscode", vscodeFlavor = "extension" } }))
local ALIVE = { ["4242"] = true }

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json",
              CC_LABELS_FILE = T .. "/labels.json", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

-- ---- stubbed hs ----------------------------------------------------------------------
local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local keys, urls = {}, {}
local syncTimers = false
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function() end },
    { __index = function() return function() return webviewHandle() end end })
end
local vscodeApp = { bundleID = function() return "com.microsoft.VSCode" end }
local function window(title) return { title = function() return title end, focus = function() end, application = function() return vscodeApp end } end
local busyWin, quietWin = window("main.lua — busy"), window("notes.md — quiet")
local FRONT = busyWin
local fakeApp = { allWindows = function() return { busyWin, quietWin } end, activate = function() end }
local settingsStore, frame = {}, { x = 0, y = 0, w = 1920, h = 1080 }
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local files, p = {}, io.popen('ls -1 "' .. tostring(path) .. '" 2>/dev/null')
      if p then for line in p:lines() do files[#files + 1] = line end; p:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = function(path)
      return nil, "cannot obtain information from file '" .. tostring(path) .. "': No such file or directory"
    end,
    mkdir = function() return true end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function(cmd)
    cmd = tostring(cmd)
    if cmd:find("ps -o pid=", 1, true) then
      local out = {}
      for pid in cmd:gmatch("%d+") do if ALIVE[pid] then out[#out + 1] = pid end end
      return table.concat(out, "\n")
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
rawset(hs.eventtap, "keyStroke", function(_, key) keys[#keys + 1] = tostring(key) end)
rawset(hs.eventtap, "keyStrokes", function(s) keys[#keys + 1] = "typed:" .. tostring(s) end)
rawset(hs.urlevent, "openURL", function(u) urls[#urls + 1] = tostring(u) end)
rawset(hs.application, "applicationsForBundleID", function() return { fakeApp } end)
rawset(hs.application, "find", function() return fakeApp end)
rawset(hs.window, "focusedWindow", function() return FRONT end)
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
local function quiet(fn) print = function() end; local ok, err = pcall(fn); print = realPrint; if not ok then realPrint("       error: " .. tostring(err)) end; return ok end
local function pressed(k) for _, x in ipairs(keys) do if x == k then return true end end return false end
local function decode(u) return (u:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end)) end

check("the dashboard loads and runs its first refresh", quiet(function() dofile(ROOT .. "claude-dashboard.lua") end))
syncTimers = true
local fx = rawget(_G, "__ccDashboard").fx

-- a new session in the project whose window already has a live Claude tab
keys, urls, FRONT = {}, {}, busyWin
quiet(function() fx.spawnSession("vscode", BUSY, "fix the flaky login test") end)
check("spawning into a window that already has a Claude tab never presses ⌘Esc (it would focus that tab)",
      not pressed("escape"))
check("...types and sends nothing  (keys=" .. table.concat(keys, ",") .. ")", #keys == 0)
check("...and opens one new Claude tab with the task typed in", #urls == 1
      and decode(urls[1]:match("prompt=(.*)$") or ""):find("fix the flaky login test", 1, true) ~= nil)

-- the same project once its only session has died (its pid is gone): the old ladder runs
ALIVE["4242"] = nil
keys, urls = {}, {}
quiet(function() fx.spawnSession("vscode", BUSY, "retry after the crash") end)
check("a window whose Claude session is dead still gets the usual ⌘Esc ladder", pressed("escape") and #urls == 0)

-- a project with no session at all: the usual ladder, unchanged
keys, urls, FRONT = {}, {}, quietWin
quiet(function() fx.spawnSession("vscode", IDLE, "write the docs") end)
check("a window with no Claude session gets the usual ⌘Esc ladder", pressed("escape") and #urls == 0)
finish()
