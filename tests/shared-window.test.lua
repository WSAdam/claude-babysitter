-- shared-window.test.lua : BEHAVIORAL fixture for the shared-window keystroke guard
-- (2026-09-10). Several Claude tabs in one VS Code window share its extension host
-- (host_window), and Shepherd types into the WINDOW -- the keys land in whichever tab is
-- in front. Loads the real claude-dashboard.lua under a stubbed hs (a fake VS Code window
-- per folder; hs.eventtap and window focus counted), with two sessions on one host and one
-- alone, then drives the real effects: the pair must get no focus and no keystroke, the
-- lone session must still be typed into.
-- Side-effect-free: every file lives in a temp dir; HOME is pointed there too.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- shared-window.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

-- ---- fixture: two tabs in one window (host 500), one session alone (host 600) ----
local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local MAIN, OTHER = T .. "/repo", T .. "/other"
os.execute('mkdir -p "' .. T .. '/status" "' .. T .. '/.claude" "' .. MAIN .. '" "' .. OTHER .. '"')
local now = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
for _, s in ipairs({ { "a1", MAIN, "500", "501" }, { "a2", MAIN, "500", "502" }, { "b1", OTHER, "600", "601" } }) do
  write(T .. "/status/" .. s[1] .. ".json", string.format(
    '{"status":"done","session_id":"%s","name":"%s","cwd":"%s","since":%d,"updated":%d,"editor":"vscode","host_window":"%s","session_pid":"%s"}',
    s[1], s[2]:match("([^/]+)$"), s[2], now, now, s[3], s[4]))
end

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json",
              CC_LABELS_FILE = T .. "/labels.json", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

-- ---- stubbed hs: a VS Code window per folder; keystrokes + focus counted ----
local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local taps, focusCalls, alerts = 0, 0, {}
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function() end },
    { __index = function() return function() return webviewHandle() end end })
end
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
  execute = function() return "" end,
  hotkey = { bind = function() return mkstub() end },
  pathwatcher = { new = function() return mkstub() end },
  menubar = { new = function() return mkstub() end },
  autoLaunch = function() return false end,
  alert = { show = function(s) alerts[#alerts + 1] = tostring(s) end },
}
hs.timer = setmetatable({
  secondsSinceEpoch = function() return os.time() end,
  absoluteTime = function() return os.time() * 1e9 end,
  doEvery = function() return mkstub() end, doAfter = function() return mkstub() end,   -- beats never fire
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
-- a window for EACH folder, so without the guard the pair's window would really be focused
local function fakeWindow(title) return { title = function() return title end, focus = function() focusCalls = focusCalls + 1 end } end
local fakeApp = { allWindows = function() return { fakeWindow("main.lua — repo"), fakeWindow("notes.md — other") } end,
                  activate = function() end }
rawset(hs.application, "applicationsForBundleID", function() return { fakeApp } end)
rawset(hs.application, "find", function() return fakeApp end)
hs.reload = function() end
setmetatable(hs, { __index = function() return mkstub() end })
_G.hs = hs

local realPrint = print
local logs = {}
print = function(...) local parts = {} for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end; logs[#logs + 1] = table.concat(parts, " ") end
local ok, err = pcall(dofile, ROOT .. "claude-dashboard.lua")
print = realPrint
check("the dashboard loads and runs its first refresh", ok)
if not ok then print("       " .. tostring(err)); finish() end
local dash = rawget(_G, "__ccDashboard")
local core, fx = dash.core, dash.fx

local byK = {}
for _, it in ipairs(fx._shownItems or {}) do byK[it.key] = it end
local a1, a2, b1 = byK.a1, byK.a2, byK.b1
check("all three sessions are on the panel", a1 and a2 and b1)
if not (a1 and a2 and b1) then finish() end
check("the two tabs in one window are flagged as sharing it  (got=" .. tostring(a1.sharedWindow) .. ")",
      a1.sharedWindow == 2 and a2.sharedWindow == 2)
check("the session alone in its window isn't", b1.sharedWindow == nil)

local function quiet(fn) logs = {}; print = function(...) local parts = {} for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end; logs[#logs + 1] = table.concat(parts, " ") end; local r = { pcall(fn) }; print = realPrint; return table.unpack(r) end
local function logged(needle) for _, l in ipairs(logs) do if l:find(needle, 1, true) then return true end end return false end
local function refusalAlerts() local n = 0 for _, a in ipairs(alerts) do if a:find("Claude tabs", 1, true) then n = n + 1 end end return n end

-- a nudge (every hotkey / deck / rule / detail-panel action takes this path)
local _, acted = quiet(function() return core.handleAction(fx, a1, "nudge", "hello") end)
check("a nudge to a shared-window session is refused", acted == nil)
check("...before any focus or keystroke  (focus=" .. focusCalls .. " taps=" .. taps .. ")", focusCalls == 0 and taps == 0)
check("...and an alert says why", refusalAlerts() == 1)

-- the direct paths (queue feed, /clear, image paste, Improve...) hit the effect layer itself
local _, pasted = quiet(function() return fx.pasteIntoWindow(fx.targetFor(a1), { text = "x" }) end)
check("a direct paste into a shared window reports not delivered (a queued task stays queued)", pasted == false)
check("...logs the refusal", logged("NOT sent") and logged("hosts 2 Claude sessions"))
check("...still with no focus or keystroke", focusCalls == 0 and taps == 0)
check("the alert shows at most once a minute per session", refusalAlerts() == 1)
local _, keyed = quiet(function() return fx.sendKeys(fx.targetFor(a2), { { mods = {}, key = "return" } }) end)
check("a key chain into a shared window reports not delivered", keyed == false and focusCalls == 0 and taps == 0)

-- close would be ⌘⇧W on the whole window: every session in it
local _, closed = quiet(function() return core.handleAction(fx, a2, "close") end)
local f = io.open(T .. "/status/a2.json", "r"); local stillThere = f ~= nil; if f then f:close() end
check("close on a shared-window session is refused and its card stays", closed == nil and stillThere and focusCalls == 0 and taps == 0)

-- the lone session is untouched by the guard
local _, lone = quiet(function() return fx.pasteIntoWindow(fx.targetFor(b1), { text = "x" }) end)
check("a session alone in its window is still typed into (its window focused, the paste scheduled)",
      lone == true and focusCalls == 1 and not logged("NOT sent to"))
check("the router never picks a shared-window session", not core.sessionFree(a1) and core.sessionFree(b1))
finish()
