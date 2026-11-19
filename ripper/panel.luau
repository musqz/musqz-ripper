--!nonstrict
-- Ripper: video or folder of videos to AVIF frames.
local rip = require("./lib/rip.luau")

local function card(key)
  return { key = key, fill = "surface_variant", radius = 10, padding = 12, gap = 8, border = "primary", borderWidth = 1 }
end

local video, project, outBase = "", "", ""
local fps, skipStart, skipEnd, tol, quality = "2", "0", "0", "12", "80"
local filter = true
local order = "date"
local gen = 0
local running = false
local err, done, outDir, prog, phase, runStart
local render, readProgress

-- Matches the detached job: its sh -c command line starts with the script text.
local JOB = "^sh -c for c in ffmpeg"

local function dataFile(name)
  return noctalia.pluginDataDir() .. "/" .. name
end

local function progressDir()
  return noctalia.pluginDataDir() .. "/progress"
end

local function saveState()
  noctalia.mkdirAll(noctalia.pluginDataDir())
  noctalia.writeFile(dataFile("state"), string.format("video=%s\nproject=%s\nout=%s\nfps=%s\nss=%s\nse=%s\nfilter=%d\ntol=%s\nq=%s\norder=%s\n",
    video, project, outBase, fps, skipStart, skipEnd, filter and 1 or 0, tol, quality, order))
end

local function loadState()
  for line in string.gmatch(noctalia.readFile(dataFile("state")) or "", "[^\n]+") do
    local k, v = string.match(line, "^(%a+)=(.*)$")
    if k == "video" then video = v
    elseif k == "project" then project = v
    elseif k == "out" then outBase = v
    elseif k == "fps" then fps = v
    elseif k == "ss" then skipStart = v
    elseif k == "se" then skipEnd = v
    elseif k == "filter" then filter = v == "1"
    elseif k == "tol" then tol = v
    elseif k == "q" then quality = v
    elseif k == "order" then order = v == "name" and "name" or "date"
    end
  end
end

local function expand(t)
  t = noctalia.string.trim(t)
  return (string.gsub(t, "^~/", noctalia.getenv("HOME") .. "/"))
end

local function outRoot()
  local o = expand(outBase)
  return o ~= "" and o or noctalia.getenv("HOME") .. "/Pictures/ripper"
end

-- Runs detached so the dialog survives the panel closing; the pick goes to a file and the panel reopens.
local BROWSE = [[if [ "$3" != file ]; then
  p=$(yad --file --directory --center --width=1000 --height=650 --title="Ripper: folder" --filename="$1/") || p=
else
  p=$(yad --file --center --width=1000 --height=650 --title="Ripper: video" --filename="$1/" --file-filter="Video|*.mkv *.mp4 *.webm *.mov *.avi" --file-filter="All|*") || p=
fi
[ -n "$p" ] && readlink -f "$p" > "$2"
noctalia msg panel-close; noctalia msg panel-open musqz/ripper:main]]

-- kind: file (one video), videodir (folder of videos), dir (output folder).
local function browse(kind)
  noctalia.mkdirAll(noctalia.pluginDataDir())
  local start = noctalia.getenv("HOME") .. (kind == "dir" and "/Pictures" or "/Videos")
  noctalia.runAsync({ "setsid", "-f", "sh", "-c", BROWSE, "sh", start, dataFile(kind == "dir" and "pick-out" or "pick-video"), kind })
end

local function check()
  noctalia.runAsync({ "pgrep", "-f", JOB }, function(r)
    local now = r.exitCode == 0
    -- The detached job needs a moment to appear after Start.
    if not now and running and runStart and os.time() - runStart < 3 then
      return
    end
    if now ~= running then
      running = now
      if running then
        done = done or "Running. A season can take hours: close the panel if you like, a notification follows when it is done"
      else
        readProgress()
        done = outDir and "Finished" or "Failed, see the notification"
      end
      render()
    end
  end)
end

local function stop()
  noctalia.runAsync({ "sh", "-c", 'for p in $(pgrep -f "$1"); do pkill -s "$p"; done; true', "sh", JOB }, function()
    running = false
    done = "Stopped"
    render()
  end)
end

-- progress/dir holds the project folder the job picked (it never overwrites an existing one); the job removes it when it fails.
function readProgress()
  local pd = progressDir()
  local d = noctalia.string.trim(noctalia.readFile(pd .. "/dir") or "")
  outDir = d ~= "" and d or nil
  local ph = noctalia.string.trim(noctalia.readFile(pd .. "/phase") or "")
  local total = tonumber(noctalia.string.trim(noctalia.readFile(pd .. "/total") or ""))
  local start = tonumber(noctalia.string.trim(noctalia.readFile(pd .. "/start") or ""))
  local count = tonumber(noctalia.string.trim(noctalia.readFile(pd .. "/count") or "")) or 0
  local left = nil
  if ph == "convert" and start and total and count > 0 then
    left = math.floor((os.time() - start) / count * math.max(0, total - count))
  end
  local changed = not prog or prog.count ~= count or prog.left ~= left or prog.total ~= total or phase ~= ph
  prog = { count = count, total = total, left = left }
  phase = ph
  return changed
end

local function eta(sec)
  if sec < 60 then
    return sec .. " s"
  end
  return math.floor(sec / 60) .. " min " .. sec % 60 .. " s"
end

local function num(t, default)
  local n = tonumber(noctalia.string.trim(t))
  if n == nil or n < 0 then return default end
  return n
end

local function run()
  if running then
    stop()
    return
  end
  local path = expand(video)
  local name = noctalia.string.trim(project)
  if path == "" then
    err = "Pick a video or a folder first"
  elseif name == "" or string.find(name, "/", 1, true) then
    err = "Give the project a name (no slash)"
  elseif string.find(name, "%", 1, true) then
    err = "The project name cannot contain %"
  elseif num(fps, 0) < 1 or num(fps, 0) > 3 then
    err = "Frames per second: 1 to 3"
  elseif tonumber(skipStart) == nil or tonumber(skipStart) < 0 or tonumber(skipEnd) == nil or tonumber(skipEnd) < 0 then
    err = "Skip start and end: a number of seconds, 0 or more"
  elseif tonumber(tol) == nil or tonumber(tol) < 0 or tonumber(tol) > 40 then
    err = "Tolerance: 0 to 40"
  elseif tonumber(quality) == nil or tonumber(quality) < 0 or tonumber(quality) > 100 then
    err = "AVIF quality: 0 to 100"
  else
    err = nil
  end
  if err then
    render()
    return
  end
  done = nil
  saveState()
  local t = math.min(40, math.floor(num(tol, 12)))
  local q = math.min(100, math.floor(num(quality, 80)))
  noctalia.mkdirAll(outRoot())
  noctalia.runAsync({ "setsid", "-f", "sh", "-c", rip, "ripper-job", path, outRoot(), name,
    tostring(num(fps, 2)), tostring(num(skipStart, 0)), tostring(num(skipEnd, 0)),
    filter and "1" or "0", tostring(t), tostring(q), progressDir(), order })
  outDir = nil
  prog = nil
  phase = nil
  runStart = os.time()
  running = true
  done = "Running. A season can take hours: close the panel if you like, a notification follows when it is done"
  render()
end

-- While a job runs only Stop works.
local function idle(fn)
  return function(...)
    if not running then
      fn(...)
    end
  end
end

local function field(key, value, onSet, width)
  return ui.input({ key = key .. gen, value = value, frameVisible = true, controlSize = "sm", width = width, flexGrow = width == nil and 1 or nil,
    onChange = idle(function(t) onSet(t); saveState() end) })
end

local function folderBtn(key, kind)
  return ui.button({ key = key, glyph = "folder-open", variant = "outline", controlSize = "sm", enabled = not running, onClick = idle(function() browse(kind) end) })
end

function render()
  -- Chips set the value; the input takes any other number.
  local function chipRow(key, values, current, set)
    local cells = {}
    for _, v in ipairs(values) do
      local on = noctalia.string.trim(current) == v
      table.insert(cells, ui.button({ key = "chip" .. key .. v, text = v, variant = on and "primary" or "outline", controlSize = "sm", enabled = not running,
        onClick = idle(function() set(v); saveState(); gen = gen + 1; render() end) }))
    end
    return ui.row({ key = "chips" .. key, gap = 6 }, cells)
  end

  local status = nil
  if running and prog then
    if phase == "convert" and prog.total then
      status = ui.column({ key = "prog", gap = 4 }, {
        ui.progress({ progress = math.min(1, prog.count / math.max(prog.total, 1)), fill = "primary", track = "surface_variant", height = 8, radius = 4 }),
        ui.label({ text = prog.count .. " of " .. prog.total .. " frames" .. (prog.left and ("  -  about " .. eta(prog.left) .. " left") or ""), color = "on_surface_variant", fontSize = 11 }),
      })
    else
      status = ui.label({ key = "prog", text = "Reading the videos, the first numbers follow in a moment", color = "on_surface_variant", fontSize = 11 })
    end
  end

  panel.render(ui.column({ gap = 10, padding = 12 }, {
    ui.row({ gap = 8, align = "center" }, {
      ui.glyph({ name = "movie", size = 20, color = "primary" }),
      ui.label({ text = "Ripper", flexGrow = 1 }),
      ui.button({ glyph = "x", variant = "ghost", controlSize = "sm", tooltip = "Close", onClick = function() panel.close() end }),
    }),
    ui.column(card("video"), {
      ui.label({ text = "Video", fontWeight = "bold" }),
      ui.row({ gap = 6, align = "center" }, {
        field("video", video, function(t) video = t end),
        ui.button({ key = "pickfile", glyph = "movie", variant = "outline", controlSize = "sm", tooltip = "One video", enabled = not running, onClick = idle(function() browse("file") end) }),
        folderBtn("pickvideodir", "videodir"),
      }),
      ui.row({ gap = 6, align = "center" }, {
        ui.label({ text = "Folder order", color = "on_surface_variant", fontSize = 11 }),
        ui.button({ key = "ord-date", text = "Created", variant = order == "date" and "primary" or "outline", controlSize = "sm", enabled = not running, onClick = idle(function() order = "date"; saveState(); render() end) }),
        ui.button({ key = "ord-name", text = "Name", variant = order == "name" and "primary" or "outline", controlSize = "sm", enabled = not running, onClick = idle(function() order = "name"; saveState(); render() end) }),
      }),
    }),
    ui.column(card("proj"), {
      ui.label({ text = "Project name", fontWeight = "bold" }),
      field("project", project, function(t) project = t end),
      ui.label({ text = "Output folder", fontWeight = "bold" }),
      ui.row({ gap = 6, align = "center" }, {
        field("out", outBase, function(t) outBase = t end),
        folderBtn("pickout", "dir"),
      }),
    }),
    ui.column(card("time"), {
      ui.label({ text = "Frames per second (max 3)", fontWeight = "bold" }),
      chipRow("fps", { "1", "2", "3" }, fps, function(v) fps = v end),
      ui.row({ gap = 12, align = "start" }, {
        ui.column({ key = "skip-s", gap = 8, flexGrow = 1 }, {
          ui.label({ text = "Skip start (s)", fontWeight = "bold" }),
          ui.row({ gap = 6, align = "center" }, {
            chipRow("ss", { "0", "10", "30", "50" }, skipStart, function(v) skipStart = v end),
            field("ss", skipStart, function(t) skipStart = t end, 56),
          }),
        }),
        ui.column({ key = "skip-e", gap = 8, flexGrow = 1 }, {
          ui.label({ text = "Skip end (s)", fontWeight = "bold" }),
          ui.row({ gap = 6, align = "center" }, {
            chipRow("se", { "0", "10", "30", "50" }, skipEnd, function(v) skipEnd = v end),
            field("se", skipEnd, function(t) skipEnd = t end, 56),
          }),
        }),
      }),
    }),
    ui.column(card("filter"), {
      ui.row({ gap = 8, align = "center" }, {
        ui.toggle({ key = "filter", checked = filter, enabled = not running, onChange = idle(function(v) filter = v == true or v == "true"; saveState(); render() end) }),
        ui.label({ text = "Remove white and black frames", flexGrow = 1 }),
        ui.label({ text = "Tolerance" }),
        field("tol", tol, function(t) tol = t end, 60),
      }),
      ui.row({ gap = 8, align = "center" }, {
        ui.label({ text = "AVIF quality (0-100)", flexGrow = 1 }),
        field("q", quality, function(t) quality = t end, 60),
      }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.button({ key = "run", glyph = running and "player-stop" or "player-play", text = running and "Stop" or "Start", variant = running and "destructive" or "primary", onClick = run }),
      done and not running and outDir and ui.button({ key = "open", glyph = "folder-open", text = "Open folder", variant = "outline", onClick = function()
        noctalia.runAsync({ "xdg-open", outDir })
        panel.close()
      end }) or ui.box({ height = 0 }),
    }),
    status or ui.box({ height = 0 }),
    err and ui.label({ text = err, color = "error" }) or done and ui.label({ text = done .. (outDir and (" in " .. outDir) or ""), color = "primary", maxLines = 3 }) or ui.box({ height = 0 }),
  }))
end

function onOpen()
  err = nil
  done = nil
  loadState()
  check()
  for name, set in pairs({ ["pick-video"] = function(v) video = v end, ["pick-out"] = function(v) outBase = v end }) do
    local picked = noctalia.readFile(dataFile(name))
    if picked and picked ~= "" then
      set(noctalia.string.trim(picked))
      if name == "pick-video" then
        project = (string.match((string.gsub(video, "/+$", "")), "([^/]+)$") or ""):gsub("%.[^.]*$", "")
      end
      gen = gen + 1
      noctalia.writeFile(dataFile(name), "")
    end
  end
  saveState()
  render()
  panel.setWantsSecondTicks(true)
end

function update()
  if running then
    check()
    if readProgress() then
      render()
    end
  end
end
