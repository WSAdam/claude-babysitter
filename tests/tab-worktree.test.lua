-- tab-worktree.test.lua : BEHAVIORAL fixture for sessions that work in ANOTHER worktree
-- (2026-09-10). A Claude tab starts in the main checkout and EnterWorktree's into
-- .claude/worktrees/<slug>; a driver session may also enter a sibling worktree folder.
-- Both keep their launch folder's projectKey, so identity used to come from the main
-- checkout: the tab's card said `main`, Instances listed its worktree as idle (Open would
-- start a second session in it), My List never read its TODO.md, and the sibling session
-- got a card of its own. Loads the real claude-dashboard.lua under a stubbed hs whose `git`
-- answers for a throwaway repo, lets the load-time refresh() run, then reads the annotated
-- items, the Instances payload, an Open attempt and the My List push.
-- Side-effect-free: every file lives in a temp dir; HOME is pointed there too.

local HERE = debug.getinfo(1, "S").source:sub(2):match("(.*/)") or "./"
local ROOT = HERE .. "../"
local json = dofile(HERE .. "support/json.lua")

local run, failed = 0, 0
local function check(name, cond)
  run = run + 1
  if cond then print("ok   - " .. name) else failed = failed + 1; print("FAIL - " .. name) end
end
local function finish() print("-- tab-worktree.test.lua: " .. run .. " run, " .. failed .. " failed --"); os.exit(failed == 0 and 0 or 1) end

-- ---- fixture: a repo, a tab's worktree inside it, a sibling worktree beside it ----
local T
do local p = io.popen("mktemp -d 2>/dev/null"); T = p and p:read("*l"); if p then p:close() end end
if not T or T == "" then check("mktemp a fixture dir", false); finish() end
local MAIN = T .. "/repo"
local TAB = MAIN .. "/.claude/worktrees/t"
local SIB = T .. "/repo-sib"
local function encode(p) return (p:gsub("[^%w]", "-")) end   -- ASCII paths: Claude Code's encoding
local PROJ = T .. "/.claude/projects/" .. encode(MAIN)
os.execute('mkdir -p "' .. T .. '/status" "' .. PROJ .. '" "' .. MAIN .. '/.git/worktrees/t" "'
  .. MAIN .. '/.git/worktrees/sib" "' .. TAB .. '" "' .. SIB .. '"')
local now = os.time()
local function write(path, s) local f = io.open(path, "w"); f:write(s); f:close() end
write(MAIN .. "/.git/HEAD", "ref: refs/heads/main\n")
write(MAIN .. "/.git/worktrees/t/HEAD", "ref: refs/heads/fix/t\n")
write(MAIN .. "/.git/worktrees/sib/HEAD", "ref: refs/heads/fix/sib\n")
write(TAB .. "/.git", "gitdir: " .. MAIN .. "/.git/worktrees/t\n")        -- a linked worktree's .git is a FILE
write(SIB .. "/.git", "gitdir: " .. MAIN .. "/.git/worktrees/sib\n")
write(MAIN .. "/TODO.md", "- [ ] main item\n")
write(TAB .. "/TODO.md", "- [ ] tab-only item\n")
-- all three sessions STARTED in the main checkout: their transcripts live under its
-- project dir, and each transcript's first cwd is the main checkout (the origin folder)
for _, s in ipairs({ { "m1", MAIN }, { "t1", TAB }, { "s1", SIB } }) do
  local tp = PROJ .. "/" .. s[1] .. ".jsonl"
  write(tp, '{"type":"user","cwd":"' .. MAIN .. '","sessionId":"' .. s[1] .. '"}\n')
  write(T .. "/status/" .. s[1] .. ".json", string.format(
    '{"status":"idle","session_id":"%s","name":"%s","cwd":"%s","transcript_path":"%s","since":%d,"updated":%d,"editor":"vscode"}',
    s[1], s[2]:match("([^/]+)$"), s[2], tp, now, now))
end
-- the main checkout's My List tab is already enrolled (it imported TODO.md before)
write(T .. "/worklist.json", json.encode({ generic = {}, byProject = {},
  todoMeta = { K = { cwd = MAIN, mtime = 1, seen = {} } } }))

local realGetenv = os.getenv
local ENV = { CC_STATUS_DIR = T .. "/status", CC_WORKLIST_FILE = T .. "/worklist.json",
              CC_LABELS_FILE = T .. "/labels.json", HOME = T }
os.getenv = function(k) if ENV[k] then return ENV[k] end return realGetenv(k) end

-- ---- stubbed hs: git answers for the fixture repo; the file system is the real one ----
local function mkstub()
  return setmetatable({}, { __index = function() return mkstub() end, __call = function() return mkstub() end })
end
local jsCalls, alerts = {}, {}
local function webviewHandle()
  return setmetatable({ evaluateJavaScript = function(_, s) jsCalls[#jsCalls + 1] = tostring(s) end },
    { __index = function() return function() return webviewHandle() end end })
end
local dirCache = {}
local function isDir(p)
  if dirCache[p] == nil then dirCache[p] = os.execute('test -d "' .. p .. '"') and true or false end
  return dirCache[p]
end
local function isFile(p) local f = io.open(p, "r"); if f then f:close(); return not isDir(p) end return false end
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
      if type(path) == "string" and (isDir(path) or isFile(path)) then
        local t = { mode = isDir(path) and "directory" or "file", modification = now - 10 }
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
    if cmd:find("rev-parse", 1, true) then
      if cmd:find("'" .. TAB .. "'", 1, true) then
        return TAB .. "\n" .. MAIN .. "/.git\n" .. MAIN .. "/.git/worktrees/t\n"
      elseif cmd:find("'" .. SIB .. "'", 1, true) then
        return SIB .. "\n" .. MAIN .. "/.git\n" .. MAIN .. "/.git/worktrees/sib\n"
      elseif cmd:find("'" .. MAIN .. "'", 1, true) then
        return MAIN .. "\n" .. MAIN .. "/.git\n" .. MAIN .. "/.git\n"
      end
    elseif cmd:find("worktree list", 1, true) then
      return "worktree " .. MAIN .. "\nHEAD aaaaaaa\nbranch refs/heads/main\n\n"
          .. "worktree " .. TAB .. "\nHEAD bbbbbbb\nbranch refs/heads/fix/t\n\n"
          .. "worktree " .. SIB .. "\nHEAD ccccccc\nbranch refs/heads/fix/sib\n"
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
local dash = rawget(_G, "__ccDashboard")

-- ---- the annotated sessions ------------------------------------------------------
local byK = {}
for _, it in ipairs(dash.fx._shownItems or {}) do byK[it.key] = it end
local m, t, s = byK.m1, byK.t1, byK.s1
check("the main checkout's session, the tab and the sibling session are all on the panel", m and t and s)
if not (m and t and s) then finish() end
check("the tab stays on its repo's card", t.stackKey ~= nil and t.stackKey == m.stackKey)
check("the tab shows its worktree's branch, not main's  (got=" .. tostring(t.branch) .. ")", t.branch == "fix/t")
check("the tab's root is the worktree it works in  (got=" .. tostring(t.wtRoot) .. ")", t.wtRoot == TAB)
check("the tab isn't marked as the main checkout", t.isMainWt == false)
check("the main checkout's session still shows main", m.branch == "main" and m.isMainWt == true)
check("a session that entered a sibling worktree joins its repo's card  (got=" .. tostring(s.stackKey) .. ")",
      s.stackKey == m.stackKey)
check("...and shows the sibling's branch  (got=" .. tostring(s.branch) .. ")", s.branch == "fix/sib")

-- ---- the Instances view ----------------------------------------------------------
dash.fx._instancesView = { stackKey = m.stackKey }
dash.fx.pushInstances(true)
local inst
for _, js in ipairs(jsCalls) do
  local body = js:match("^window%.ccInstances%((.*)%)$")
  if body then inst = json.decode(body) end
end
check("Instances pushed a payload", inst ~= nil)
if inst then
  local idle = {}
  for _, w in ipairs(inst.worktrees or {}) do idle[w.path] = true end
  check("Instances never lists the tab's worktree as idle", not idle[TAB])
  check("Instances never lists the sibling session's worktree as idle", not idle[SIB])
end

-- ---- Open on the tab's worktree ----------------------------------------------------
alerts = {}
dash.fx.openWorktree(m.stackKey, TAB)
local refused = false
for _, a in ipairs(alerts) do if a:find("already has a session", 1, true) then refused = true end end
check("Open refuses the worktree a tab is already working in", refused)

-- ---- My List: the tab's TODO.md ------------------------------------------------------
local payload
for _, js in ipairs(jsCalls) do
  local body = js:match("^window%.ccWorklist%((.*)%)$")
  if body then payload = json.decode(body) end
end
local repoTab
for _, p in ipairs((payload or {}).projects or {}) do if p.key == "K" then repoTab = p end end
local tabItem
for _, it in ipairs((repoTab or {}).items or {}) do if it.text == "tab-only item" then tabItem = it end end
check("My List imported the tab's TODO.md line", tabItem ~= nil)
check("...tagged with the tab's branch",
      tabItem ~= nil and type(tabItem.srcBranches) == "table" and tabItem.srcBranches[1] == "fix/t")
finish()
