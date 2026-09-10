-- capture-panel.lua: load the SHIPPED claude-dashboard.lua under a stubbed hs (the same
-- stubs as tests/smoke.test.lua) over a 3-session fixture, and write out the panel HTML
-- the webview is handed plus the first window.ccUpdate(...) call -- so a real browser
-- can replay the panel (tests/tile-press.browser.test.js). Side-effect-free: the
-- fixture lives in a temp CC_STATUS_DIR; run it with HOME pointed at a temp dir.
--   HOME=$(mktemp -d) lua tests/support/capture-panel.lua <repo-root> <out-dir>
local ROOT, OUT = arg[1], arg[2]
local function die(m) io.stderr:write("capture-panel: " .. m .. "\n"); os.exit(1) end
if not ROOT or not OUT then die("usage: capture-panel.lua <repo-root> <out-dir>") end

local FIXDIR
do local p = io.popen("mktemp -d 2>/dev/null"); FIXDIR = p and p:read("*l"); if p then p:close() end end
if not FIXDIR or FIXDIR == "" then die("could not mktemp a fixture dir") end
local now = os.time()
for _, r in ipairs({ { "k1", "alpha", "working" }, { "k2", "bravo", "working" }, { "k3", "charlie", "done" } }) do
  local f = io.open(FIXDIR .. "/" .. r[1] .. ".json", "w")
  if not f then die("could not write a fixture status file") end
  f:write(string.format('{"status":"%s","session_id":"%s","name":"%s","cwd":"%s/%s","since":%d,"updated":%d,"editor":"vscode"}',
    r[3], r[1], r[2], FIXDIR, r[2], now, now))
  f:close()
end
local realGetenv = os.getenv
os.getenv = function(k) if k == "CC_STATUS_DIR" then return FIXDIR end return realGetenv(k) end

local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local html, jsCalls = nil, {}
local function webviewHandle()
  return setmetatable({
    evaluateJavaScript = function(_, s) jsCalls[#jsCalls + 1] = tostring(s) end,
    html = function(self, s) html = s; return self end,
  }, { __index = function() return function() return webviewHandle() end end })
end
local json = dofile(ROOT .. "/tests/support/json.lua")
local settingsStore, frame = {}, { x = 0, y = 0, w = 1920, h = 1080 }
local hs = {
  json = json,
  fs = {
    dir = function(path)
      local files, p = {}, io.popen('ls -1 "' .. tostring(path) .. '" 2>/dev/null')
      if p then for line in p:lines() do files[#files + 1] = line end; p:close() end
      local i = 0; return function() i = i + 1; return files[i] end
    end,
    attributes = function() return nil end,
    mkdir = function() return true end,
  },
  settings = { get = function(k) return settingsStore[k] end, set = function(k, v) settingsStore[k] = v end },
  screen = { mainScreen = function() return { frame = function() return frame end, fullFrame = function() return frame end } end },
  execute = function() return "" end,
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
  doAfter = function() return mkstub() end,
  new = function() return mkstub() end,
  usleep = function() end,
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

-- the dashboard prints its load log; keep the capture's stdout to the one result line
local realPrint = print
print = function() end
local ok, err = pcall(dofile, ROOT .. "/claude-dashboard.lua")
print = realPrint
if not ok then die("claude-dashboard.lua failed to load: " .. tostring(err)) end
if not html then die("the webview was never handed its html") end
local upd
for _, s in ipairs(jsCalls) do if s:find("window.ccUpdate(", 1, true) then upd = s end end
if not upd then die("no window.ccUpdate(...) was pushed") end
local f = io.open(OUT .. "/panel.html", "w"); f:write(html); f:close()
f = io.open(OUT .. "/update.js", "w"); f:write(upd); f:close()
print("captured " .. #html .. " bytes of panel html")
