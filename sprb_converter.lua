-- ============================================================
-- SPRB MIDI → BABFT Converter (FIXED)
-- ============================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")

local lp = Players.LocalPlayer

-- cleanup старого GUI
if getgenv and getgenv()._SPRB_MusicConverterGui then
    pcall(function() getgenv()._SPRB_MusicConverterGui:Destroy() end)
end

local screenGui = Instance.new("ScreenGui")
screenGui.Name = "SPRB_MusicConverter"
screenGui.ResetOnSpawn = false
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
if not pcall(function() screenGui.Parent = CoreGui end) then
    screenGui.Parent = lp:WaitForChild("PlayerGui")
end
if getgenv then getgenv()._SPRB_MusicConverterGui = screenGui end

-- ============================================================
-- ПАЛИТРА / ХЕЛПЕРЫ
-- ============================================================
local C = {
    Bg = Color3.fromRGB(18, 20, 26),
    Card = Color3.fromRGB(25, 28, 38),
    Border = Color3.fromRGB(48, 54, 72),
    Accent = Color3.fromRGB(245, 130, 32),
    AccentDark = Color3.fromRGB(180, 85, 15),
    AccentSoft = Color3.fromRGB(40, 30, 24),
    Text = Color3.fromRGB(240, 240, 245),
    TextDim = Color3.fromRGB(160, 165, 180),
    Success = Color3.fromRGB(50, 205, 120),
    Error = Color3.fromRGB(245, 75, 75)
}
local FontMain = Enum.Font.Gotham
local FontBold = Enum.Font.GothamBold

local function makeCorner(p, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 6); c.Parent = p; return c
end

local function makeStroke(p, col, th, trans)
    local s = Instance.new("UIStroke")
    s.Color = col or C.Border; s.Thickness = th or 1.0
    s.Transparency = trans or 0.6; s.Parent = p; return s
end

local function fmtTime(sec)
    sec = math.max(0, math.floor((tonumber(sec) or 0) + 0.5))
    return string.format("%02d:%02d", math.floor(sec / 60), sec % 60)
end

-- ============================================================
-- MIDI: НОТЫ
-- ============================================================
local NOTE_NAMES = {
    [0]="F#",[1]="G",[2]="G#",[3]="A",[4]="A#",[5]="B",
    [6]="C",[7]="C#",[8]="D",[9]="D#",[10]="E",[11]="F",
    [12]="F#",[13]="G",[14]="G#",[15]="A",[16]="A#",[17]="B",
    [18]="C",[19]="C#",[20]="D",[21]="D#",[22]="E",[23]="F",[24]="F#"
}

local function midiToBabftPitch(midiNote, transpose)
    transpose = transpose or 0
    local raw = (midiNote + transpose) - 42
    local pitch = raw % 25
    if pitch < 0 then pitch = pitch + 25 end
    return pitch, NOTE_NAMES[pitch] or "F#"
end

-- ============================================================
-- MIDI: ПАРСЕР
-- ============================================================
local function parseMidiData(data)
    if type(data) ~= "string" or #data < 14 then
        return nil, "Invalid MIDI: too short"
    end
    local pos, len = 1, #data

    local function readBytes(n)
        if pos + n - 1 > len then return nil end
        local s = data:sub(pos, pos + n - 1); pos = pos + n; return s
    end
    local function readU16()
        if pos + 1 > len then return nil end
        local b1, b2 = string.byte(data, pos, pos + 1); pos = pos + 2
        return b1 * 256 + b2
    end
    local function readU32()
        if pos + 3 > len then return nil end
        local b1, b2, b3, b4 = string.byte(data, pos, pos + 3); pos = pos + 4
        return b1 * 16777216 + b2 * 65536 + b3 * 256 + b4
    end
    local function readVLQ()
        local v, c = 0, 0
        while pos <= len and c < 4 do
            local b = string.byte(data, pos); pos = pos + 1; c = c + 1
            v = v * 128 + (b % 128)
            if b < 128 then break end
        end
        return v
    end

    if readBytes(4) ~= "MThd" then return nil, "Not MIDI (MThd missing)" end
    local hlen = readU32()
    local fmt = readU16()
    local numTracks = readU16()
    local division = readU16() or 480
    if division <= 0 then division = 480 end
    if hlen and hlen > 6 then pos = pos + (hlen - 6) end

    local allEvents = {}
    for _ = 1, (numTracks or 1) do
        if pos > len then break end
        if readBytes(4) ~= "MTrk" then
            local nx = data:find("MTrk", pos, true)
            if not nx then break end
            pos = nx + 4
        end
        local trkLen = readU32(); if not trkLen then break end
        local trkEnd = pos + trkLen
        local running, absTicks = 0, 0
        while pos < trkEnd and pos <= len do
            absTicks = absTicks + (readVLQ() or 0)
            local b = string.byte(data, pos)
            local status
            if b and b >= 128 then status = b; pos = pos + 1
            else status = running end

            if status == 0xFF then
                local metaType = string.byte(data, pos) or 0; pos = pos + 1
                local mlen = readVLQ() or 0
                local mdata = readBytes(mlen) or ""
                allEvents[#allEvents+1] = {ticks=absTicks, kind="meta", metaType=metaType, data=mdata}
            elseif status == 0xF0 or status == 0xF7 then
                local slen = readVLQ() or 0; pos = pos + slen
            else
                running = status
                local cmd = math.floor(status / 16) * 16
                local ch = status % 16
                if cmd == 0xC0 or cmd == 0xD0 then
                    allEvents[#allEvents+1] = {ticks=absTicks, kind="midi", cmd=cmd, ch=ch,
                        p1=string.byte(data, pos) or 0, p2=0}
                    pos = pos + 1
                else
                    allEvents[#allEvents+1] = {ticks=absTicks, kind="midi", cmd=cmd, ch=ch,
                        p1=string.byte(data, pos) or 0, p2=string.byte(data, pos+1) or 0}
                    pos = pos + 2
                end
            end
        end
        pos = trkEnd
    end
    return {format=fmt, numTracks=numTracks, division=division, events=allEvents}, nil
end

-- ============================================================
-- MIDI: ДЛИТЕЛЬНОСТЬ
-- ============================================================
local function getMidiDuration(rawData, speed)
    speed = tonumber(speed) or 1.0; if speed <= 0 then speed = 1.0 end
    local parsed = parseMidiData(rawData)
    if not parsed then return 120 end
    local events = parsed.events
    table.sort(events, function(a, b)
        if a.ticks ~= b.ticks then return a.ticks < b.ticks end
        local aT = a.kind == "meta" and a.metaType == 0x51
        local bT = b.kind == "meta" and b.metaType == 0x51
        if aT and not bT then return true end
        if bT and not aT then return false end
        return false
    end)
    local division = parsed.division or 480
    local curTick, curTime, usPerBeat, maxNoteTime = 0, 0.0, 500000, 0.0
    for _, ev in ipairs(events) do
        local dT = ev.ticks - curTick
        if dT > 0 then
            curTime = curTime + dT * (usPerBeat / 1e6) / division
            curTick = ev.ticks
        end
        if ev.kind == "meta" and ev.metaType == 0x51 then
            if #ev.data >= 3 then
                local b1,b2,b3 = string.byte(ev.data,1,3)
                usPerBeat = b1*65536 + b2*256 + b3
            end
        elseif ev.kind == "midi" and ev.cmd == 0x90 and ev.p2 > 0 then
            local t = curTime / speed
            if t > maxNoteTime then maxNoteTime = t end
        end
    end
    return math.max(1, math.floor((maxNoteTime > 0 and maxNoteTime or curTime / speed) + 0.5))
end

-- ============================================================
-- MIDI → BUILD DATA
-- ============================================================
local function convertMidiToBuildData(rawData, opts)
    opts = opts or {}
    local speed = tonumber(opts.speed) or 1.0; if speed <= 0 then speed = 1.0 end
    local transpose = tonumber(opts.transpose) or 0
    local minStep = tonumber(opts.minStep) or 0.05
    local maxChord = tonumber(opts.maxChord) or 4
    local startSec = tonumber(opts.startSec) or 0
    local endSec = tonumber(opts.endSec) or 999999

    local parsed, err = parseMidiData(rawData)
    if not parsed then return nil, err or "MIDI parse error" end

    local events = parsed.events
    table.sort(events, function(a, b)
        if a.ticks ~= b.ticks then return a.ticks < b.ticks end
        local aT = a.kind == "meta" and a.metaType == 0x51
        local bT = b.kind == "meta" and b.metaType == 0x51
        if aT and not bT then return true end
        if bT and not aT then return false end
        return false
    end)

    local division = parsed.division or 480
    local curTick, curTime, usPerBeat = 0, 0.0, 500000
    local rawNotes = {}

    for _, ev in ipairs(events) do
        local dT = ev.ticks - curTick
        if dT > 0 then
            curTime = curTime + dT * (usPerBeat / 1e6) / division
            curTick = ev.ticks
        end
        if ev.kind == "meta" and ev.metaType == 0x51 then
            if #ev.data >= 3 then
                local b1,b2,b3 = string.byte(ev.data,1,3)
                usPerBeat = b1*65536 + b2*256 + b3
            end
        elseif ev.kind == "midi" and ev.cmd == 0x90 and ev.p2 > 0 then
            local t = curTime / speed
            if t >= startSec and t <= endSec then
                rawNotes[#rawNotes+1] = {time = t - startSec, note = ev.p1}
            end
        end
    end

    if #rawNotes == 0 then
        return nil, "No notes in selected time range"
    end

    local steps = {}
    for _, rn in ipairs(rawNotes) do
        local p = midiToBabftPitch(rn.note, transpose)
        local last = steps[#steps]
        if not last or (rn.time - last.time) > minStep then
            steps[#steps+1] = {time = rn.time, pitches = {p}}
        else
            if #last.pitches < maxChord then
                local dup = false
                for _, ep in ipairs(last.pitches) do
                    if ep == p then dup = true; break end
                end
                if not dup then last.pitches[#last.pitches+1] = p end
            end
        end
    end

    -- buildData ...
    local buildData = {Button = {}, Note = {}, Delay = {}}
    local pitchToId = {}
    for p = 0, 24 do
        local nid = p + 1
        pitchToId[p] = nid
        buildData.Note[#buildData.Note+1] = {
            Position = {-32, 1.5 + p * 2.0, -20},
            Rotation = {0,0,0}, Size = {2,2,2}, Color = {1,1,1},
            Anchored = true, CanCollide = true, ShowShadow = true,
            ID = nid,
            NumberValues = {Key = p, NotePitch = p},
            BoolValues = {}, BindTable = {},
            NotePitch = p, Note = NOTE_NAMES[p] or "F#",
            cf = {-32, 1.5 + p * 2.0, -20}, s = {2,2,2}, i = nid,
            np = p, nt = NOTE_NAMES[p] or "F#",
            nv = {Key = p, NotePitch = p}, bd = {}
        }
    end

    buildData.Button[1] = {
        Position = {0,1.5,-28}, Rotation = {0,0,0}, Size = {2,2,2},
        Color = {1,0,0}, Anchored = true, CanCollide = true, ShowShadow = true,
        ID = 26, BindTable = {}, NumberValues = {}, BoolValues = {},
        cf = {0,1.5,-28}, s = {2,2,2}, bd = {}, i = 26
    }

    local STEPS_PER_PILLAR, COLS_X, ROWS_Z = 25, 14, 10
    local PILLARS_PER_FLOOR = COLS_X * ROWS_Z
    local stepDelayIds = {}

    for i = 1, #steps - 1 do
        local st = steps[i]
        local gPillar = math.floor((i - 1) / STEPS_PER_PILLAR)
        local rowIn = (i - 1) % STEPS_PER_PILLAR
        local floor = math.floor(gPillar / PILLARS_PER_FLOOR)
        local onFloor = gPillar % PILLARS_PER_FLOOR
        local cx = -26 + (onFloor % COLS_X) * 4
        local cz = -18 + math.floor(onFloor / COLS_X) * 4
        local cy = 1.5 + floor * 54 + rowIn * 2.0
        local dId = 26 + i
        stepDelayIds[i] = dId

        local dt = math.clamp(steps[i+1].time - st.time, 0.05, 10.0)
        local rdt = math.floor(dt * 100 + 0.5) / 100
        buildData.Delay[#buildData.Delay+1] = {
            Position = {cx, cy, cz}, Rotation = {0,0,0}, Size = {2,2,2},
            Color = {0.85,0.85,0.85}, Anchored = true, CanCollide = true, ShowShadow = true,
            ID = dId,
            NumberValues = {WaitDuration = rdt, Delay = rdt, ["Delay time"] = rdt},
            BoolValues = {Legacy = true}, BindTable = {},
            cf = {cx, cy, cz}, s = {2,2,2},
            bv = {Legacy = true}, bd = {}, i = dId,
            nv = {WaitDuration = rdt, Delay = rdt, ["Delay time"] = rdt}
        }
    end

    -- связи
    for _, p in ipairs(steps[1] and steps[1].pitches or {}) do
        local nid = pitchToId[p]
        if nid then
            local e = {nid, "BindFire", -1}
            buildData.Button[1].bd[#buildData.Button[1].bd+1] = e
            buildData.Button[1].BindTable[#buildData.Button[1].BindTable+1] = e
        end
    end
    if stepDelayIds[1] then
        local e = {stepDelayIds[1], "BindFire", -1}
        buildData.Button[1].bd[#buildData.Button[1].bd+1] = e
        buildData.Button[1].BindTable[#buildData.Button[1].BindTable+1] = e
    end
    for i = 1, #steps - 1 do
        local d = buildData.Delay[i]
        if d then
            for _, p in ipairs(steps[i+1] and steps[i+1].pitches or {}) do
                local nid = pitchToId[p]
                if nid then
                    local e = {nid, "BindFire", -1}
                    d.bd[#d.bd+1] = e; d.BindTable[#d.BindTable+1] = e
                end
            end
            if stepDelayIds[i+1] then
                local e = {stepDelayIds[i+1], "BindFire", -1}
                d.bd[#d.bd+1] = e; d.BindTable[#d.BindTable+1] = e
            end
        end
    end

    buildData._parsedSteps = steps
    return buildData, nil, #steps
end

local function formatLuauPro(buildData, name)
    local total = #buildData.Button + #buildData.Note + #buildData.Delay
    local listObj = {
        Total = total, Need = total,
        Blocks = {
            Button = {Count = #buildData.Button, Need = #buildData.Button},
            Note = {Count = #buildData.Note, Need = #buildData.Note},
            Delay = {Count = #buildData.Delay, Need = #buildData.Delay}
        }
    }
    local lines = {
        "LP_META", "Name: " .. tostring(name or "MusicBuild"),
        "Author: SPRB Music Converter",
        "Creation Date: " .. os.date("%Y-%m-%d %H:%M:%S"),
        "Game: Build A Boat For Treasure",
        "Discord server: discord.gg/autobuild",
        "Format Version: 1", "Codec Version: 2.0", "",
        "LP_LIST", HttpService:JSONEncode(listObj), "",
        "LP_BUILD", HttpService:JSONEncode(buildData)
    }
    return table.concat(lines, "\n")
end

-- ============================================================
-- СКАНЕР ФАЙЛОВ (без хардкод-пути)
-- ============================================================
local function scanMidiFiles()
    local files, seen = {}, {}
    local function add(name, path)
        local low = name:lower()
        if (low:sub(-4) == ".mid" or low:sub(-5) == ".midi") and not seen[name] then
            seen[name] = true
            files[#files+1] = {name=name, path=path or name}
        end
    end
    if listfiles then
        for _, d in ipairs({"", "SOPERA_WORKSPACE", "Music"}) do
            pcall(function()
                for _, p in ipairs(listfiles(d) or {}) do
                    add(p:match("([^/\\]+)$") or p, p)
                end
            end)
        end
    end
    table.sort(files, function(a,b) return a.name:lower() < b.name:lower() end)
    return files
end

-- ============================================================
-- GUI
-- ============================================================
local mainFrame = Instance.new("Frame")
mainFrame.Size = UDim2.new(0, 420, 0, 580)
mainFrame.Position = UDim2.new(0.5, -200, 0.5, -260)
mainFrame.BackgroundColor3 = C.Bg
mainFrame.BorderSizePixel = 0
mainFrame.Active = true
mainFrame.ClipsDescendants = true
mainFrame.Parent = screenGui
makeCorner(mainFrame, 10); makeStroke(mainFrame, C.Accent, 1.2, 0.3)

local titleBar = Instance.new("Frame")
titleBar.Size = UDim2.new(1,0,0,38)
titleBar.BackgroundColor3 = C.Card
titleBar.BorderSizePixel = 0
titleBar.Parent = mainFrame
makeCorner(titleBar, 10)

local titleLbl = Instance.new("TextLabel")
titleLbl.Size = UDim2.new(1,-50,1,0); titleLbl.Position = UDim2.new(0,12,0,0)
titleLbl.BackgroundTransparency = 1
titleLbl.Text = "SPRB • MIDI to Build Converter"
titleLbl.TextColor3 = C.Accent; titleLbl.TextSize = 14; titleLbl.Font = FontBold
titleLbl.TextXAlignment = Enum.TextXAlignment.Left
titleLbl.Parent = titleBar

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.new(0,28,0,28); closeBtn.Position = UDim2.new(1,-34,0.5,-14)
closeBtn.BackgroundColor3 = Color3.fromRGB(35,38,48)
closeBtn.Text = "✕"; closeBtn.TextColor3 = C.TextDim
closeBtn.TextSize = 13; closeBtn.Font = FontBold; closeBtn.Parent = titleBar
makeCorner(closeBtn, 6)
closeBtn.MouseButton1Click:Connect(function() screenGui:Destroy() end)

-- drag
do
    local dragging, dragStart, startPos
    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true; dragStart = input.Position; startPos = mainFrame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then dragging = false end
            end)
        end
    end)
    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            local d = input.Position - dragStart
            mainFrame.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X,
                                            startPos.Y.Scale, startPos.Y.Offset + d.Y)
        end
    end)
end

local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.new(1,-20,1,-48); scroll.Position = UDim2.new(0,10,0,42)
scroll.BackgroundTransparency = 1; scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 4; scroll.ScrollBarImageColor3 = C.Accent
scroll.CanvasSize = UDim2.new(0,0,0,0)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.Parent = mainFrame

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0,8); layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = scroll

-- state
local selectedFile
local speedVal, transposeVal = 1.0, 0
local minStepVal, maxChordVal = 0.05, 4
local saveFormatVal = "LuauPro"
local midiRangeSlider, refreshMidiDurationLimits

-- === FILE CARD ===
local fileCard = Instance.new("Frame")
fileCard.Size = UDim2.new(1,0,0,130)
fileCard.BackgroundColor3 = C.Card; fileCard.BorderSizePixel = 0
fileCard.Parent = scroll
makeCorner(fileCard, 8); makeStroke(fileCard, C.Border, 1.0, 0.6)

local fileTitle = Instance.new("TextLabel")
fileTitle.Size = UDim2.new(1,-16,0,22); fileTitle.Position = UDim2.new(0,8,0,4)
fileTitle.BackgroundTransparency = 1
fileTitle.Text = "SELECT MIDI FILE"; fileTitle.TextColor3 = C.Accent
fileTitle.TextSize = 11; fileTitle.Font = FontBold
fileTitle.TextXAlignment = Enum.TextXAlignment.Left
fileTitle.Parent = fileCard

local fileListScroll = Instance.new("ScrollingFrame")
fileListScroll.Size = UDim2.new(1,-16,0,62); fileListScroll.Position = UDim2.new(0,8,0,26)
fileListScroll.BackgroundColor3 = Color3.fromRGB(20,22,28)
fileListScroll.BorderSizePixel = 0; fileListScroll.ScrollBarThickness = 3
fileListScroll.Parent = fileCard
makeCorner(fileListScroll, 6); makeStroke(fileListScroll, C.Border, 1.0, 0.8)

local fileListLayout = Instance.new("UIListLayout")
fileListLayout.Padding = UDim.new(0,2); fileListLayout.Parent = fileListScroll

local manualPathBox = Instance.new("TextBox")
manualPathBox.Size = UDim2.new(1,-90,0,28); manualPathBox.Position = UDim2.new(0,8,0,94)
manualPathBox.BackgroundColor3 = Color3.fromRGB(20,22,28)
manualPathBox.TextColor3 = C.Text; manualPathBox.PlaceholderText = "Or enter file name / path manually..."
manualPathBox.PlaceholderColor3 = C.TextDim; manualPathBox.TextSize = 11
manualPathBox.Font = FontMain; manualPathBox.ClearTextOnFocus = false
manualPathBox.TextXAlignment = Enum.TextXAlignment.Left
manualPathBox.Parent = fileCard
makeCorner(manualPathBox, 6); makeStroke(manualPathBox, C.Border, 1.0, 0.8)

local refreshBtn = Instance.new("TextButton")
refreshBtn.Size = UDim2.new(0,74,0,28); refreshBtn.Position = UDim2.new(1,-80,0,94)
refreshBtn.BackgroundColor3 = Color3.fromRGB(35,40,52)
refreshBtn.Text = "Refresh"; refreshBtn.TextColor3 = C.Text
refreshBtn.TextSize = 11; refreshBtn.Font = FontBold; refreshBtn.Parent = fileCard
makeCorner(refreshBtn, 6); makeStroke(refreshBtn, C.Border, 1.0, 0.6)

local function populateFileList()
    for _, c in ipairs(fileListScroll:GetChildren()) do
        if c:IsA("TextButton") or c:IsA("TextLabel") then c:Destroy() end
    end
    local files = scanMidiFiles()
    fileListScroll.CanvasSize = UDim2.new(0,0,0,#files*24)
    if #files == 0 then
        local l = Instance.new("TextLabel")
        l.Size = UDim2.new(1,0,1,0); l.BackgroundTransparency = 1
        l.Text = "No .mid files found in workspace or Music folder"
        l.TextColor3 = C.TextDim; l.TextSize = 10; l.Font = FontMain
        l.Parent = fileListScroll
        return
    end
    for _, f in ipairs(files) do
        local b = Instance.new("TextButton")
        local sel = selectedFile and selectedFile.path == f.path
        b.Size = UDim2.new(1,-6,0,22)
        b.BackgroundColor3 = sel and C.AccentSoft or Color3.fromRGB(25,28,36)
        b.Text = "  ♪ " .. f.name
        b.TextColor3 = sel and C.Accent or C.Text
        b.TextSize = 11; b.Font = FontMain
        b.TextXAlignment = Enum.TextXAlignment.Left
        b.Parent = fileListScroll
        makeCorner(b, 4)
        b.MouseButton1Click:Connect(function()
            selectedFile = f
            manualPathBox.Text = f.path
            populateFileList()
            if refreshMidiDurationLimits then task.spawn(refreshMidiDurationLimits) end
        end)
    end
end

refreshBtn.MouseButton1Click:Connect(populateFileList)
manualPathBox.FocusLost:Connect(function()
    local t = manualPathBox.Text
    if t and #t > 0 then
        selectedFile = {name = t:match("([^/\\]+)$") or t, path = t}
        if refreshMidiDurationLimits then task.spawn(refreshMidiDurationLimits) end
    end
end)
populateFileList()

-- === RANGE SLIDER ===
local function makeRangeSlider(titleText, minV, maxV, parent, onChange)
    local card = Instance.new("Frame")
    card.Size = UDim2.new(1,0,0,56)
    card.BackgroundColor3 = C.Card; card.BorderSizePixel = 0
    card.Parent = parent
    makeCorner(card, 8); makeStroke(card, C.Border, 1.0, 0.6)

    local curMin = math.max(0, minV or 0)
    local curMax = math.max(curMin + 1, maxV or 120)
    local curStart, curEnd = curMin, curMax

    local topRow = Instance.new("Frame")
    topRow.Size = UDim2.new(1,-16,0,20); topRow.Position = UDim2.new(0,8,0,4)
    topRow.BackgroundTransparency = 1; topRow.Parent = card

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(0.45,0,1,0); title.BackgroundTransparency = 1
    title.Text = titleText or "TIME RANGE (CROP)"; title.TextColor3 = C.Accent
    title.TextSize = 11; title.Font = FontBold
    title.TextXAlignment = Enum.TextXAlignment.Left; title.Parent = topRow

    local rangeLbl = Instance.new("TextLabel")
    rangeLbl.Size = UDim2.new(0.55,0,1,0); rangeLbl.Position = UDim2.new(0.45,0,0,0)
    rangeLbl.BackgroundTransparency = 1; rangeLbl.TextColor3 = C.Text
    rangeLbl.TextSize = 11; rangeLbl.Font = FontBold
    rangeLbl.TextXAlignment = Enum.TextXAlignment.Right; rangeLbl.Parent = topRow

    local trackContainer = Instance.new("Frame")
    trackContainer.Size = UDim2.new(1,-16,0,24); trackContainer.Position = UDim2.new(0,8,0,26)
    trackContainer.BackgroundTransparency = 1; trackContainer.Parent = card

    local minLbl = Instance.new("TextLabel")
    minLbl.Size = UDim2.new(0,36,1,0); minLbl.BackgroundTransparency = 1
    minLbl.TextColor3 = C.TextDim; minLbl.TextSize = 10; minLbl.Font = FontMain
    minLbl.TextXAlignment = Enum.TextXAlignment.Left; minLbl.Parent = trackContainer

    local maxLbl = Instance.new("TextLabel")
    maxLbl.Size = UDim2.new(0,36,1,0); maxLbl.Position = UDim2.new(1,-36,0,0)
    maxLbl.BackgroundTransparency = 1; maxLbl.TextColor3 = C.TextDim
    maxLbl.TextSize = 10; maxLbl.Font = FontMain
    maxLbl.TextXAlignment = Enum.TextXAlignment.Right; maxLbl.Parent = trackContainer

    local trackBar = Instance.new("ImageButton")
    trackBar.Size = UDim2.new(1,-84,0,6); trackBar.Position = UDim2.new(0,42,0.5,-3)
    trackBar.BackgroundColor3 = Color3.fromRGB(35,40,52)
    trackBar.AutoButtonColor = false; trackBar.BorderSizePixel = 0
    trackBar.Parent = trackContainer
    makeCorner(trackBar, 3)

    local active = Instance.new("Frame")
    active.BackgroundColor3 = C.Accent; active.BorderSizePixel = 0; active.Parent = trackBar
    makeCorner(active, 3)

    local hStart = Instance.new("ImageButton")
    hStart.Size = UDim2.new(0,14,0,14); hStart.AnchorPoint = Vector2.new(0.5,0.5)
    hStart.BackgroundColor3 = Color3.fromRGB(245,245,250)
    hStart.AutoButtonColor = false; hStart.BorderSizePixel = 0; hStart.ZIndex = 5
    hStart.Parent = trackBar
    makeCorner(hStart, 7); makeStroke(hStart, C.Accent, 2.0, 0.1)

    local hEnd = Instance.new("ImageButton")
    hEnd.Size = UDim2.new(0,14,0,14); hEnd.AnchorPoint = Vector2.new(0.5,0.5)
    hEnd.BackgroundColor3 = Color3.fromRGB(245,245,250)
    hEnd.AutoButtonColor = false; hEnd.BorderSizePixel = 0; hEnd.ZIndex = 5
    hEnd.Parent = trackBar
    makeCorner(hEnd, 7); makeStroke(hEnd, C.Accent, 2.0, 0.1)

    local function update()
        local span = math.max(1, curMax - curMin)
        local fs = math.clamp((curStart - curMin) / span, 0, 1)
        local fe = math.clamp((curEnd - curMin) / span, 0, 1)
        if fe < fs then fe = fs end
        hStart.Position = UDim2.new(fs,0,0.5,0)
        hEnd.Position = UDim2.new(fe,0,0.5,0)
        active.Position = UDim2.new(fs,0,0,0)
        active.Size = UDim2.new(math.max(0, fe - fs), 0, 1, 0)
        minLbl.Text = fmtTime(curMin)
        maxLbl.Text = fmtTime(curMax)
        rangeLbl.Text = fmtTime(curStart) .. " - " .. fmtTime(curEnd) .. " / " .. fmtTime(curMax)
    end

    local draggingStart, draggingEnd = false, false

    hStart.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            draggingStart = true
            TweenService:Create(hStart, TweenInfo.new(0.08), {Size = UDim2.new(0,18,0,18)}):Play()
        end
    end)
    hEnd.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            draggingEnd = true
            TweenService:Create(hEnd, TweenInfo.new(0.08), {Size = UDim2.new(0,18,0,18)}):Play()
        end
    end)

    -- ✅ ВАЖНО: соединения хранятся и отключаются при уничтожении
    local conn1 = trackBar.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            local w = math.max(1, trackBar.AbsoluteSize.X)
            local rel = math.clamp((i.Position.X - trackBar.AbsolutePosition.X) / w, 0, 1)
            local span = math.max(1, curMax - curMin)
            local tgt = curMin + rel * span
            if math.abs(tgt - curStart) < math.abs(tgt - curEnd) then
                curStart = math.clamp(tgt, curMin, curEnd); draggingStart = true
            else
                curEnd = math.clamp(tgt, curStart, curMax); draggingEnd = true
            end
            update()
            if onChange then onChange(curStart, curEnd) end
        end
    end)

    local conn2 = UserInputService.InputChanged:Connect(function(i)
        if not (draggingStart or draggingEnd) then return end
        if i.UserInputType ~= Enum.UserInputType.MouseMovement and i.UserInputType ~= Enum.UserInputType.Touch then return end
        local w = math.max(1, trackBar.AbsoluteSize.X)
        local rel = math.clamp((i.Position.X - trackBar.AbsolutePosition.X) / w, 0, 1)
        local span = math.max(1, curMax - curMin)
        local tgt = curMin + rel * span
        if draggingStart then
            curStart = math.clamp(tgt, curMin, curEnd)
        else
            curEnd = math.clamp(tgt, curStart, curMax)
        end
        update()
        if onChange then onChange(curStart, curEnd) end
    end)

    local conn3 = UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType ~= Enum.UserInputType.MouseButton1 and i.UserInputType ~= Enum.UserInputType.Touch then return end
        if draggingStart then
            draggingStart = false
            TweenService:Create(hStart, TweenInfo.new(0.08), {Size = UDim2.new(0,14,0,14)}):Play()
        end
        if draggingEnd then
            draggingEnd = false
            TweenService:Create(hEnd, TweenInfo.new(0.08), {Size = UDim2.new(0,14,0,14)}):Play()
        end
    end)

    -- ✅ отключаем соединения при удалении
    card.Destroying:Connect(function()
        conn1:Disconnect(); conn2:Disconnect(); conn3:Disconnect()
    end)

    update()
    return {
        card = card,
        getRange = function() return curStart, curEnd end,
        setLimits = function(nMin, nMax)
            nMin = math.max(0, nMin or 0)
            nMax = math.max(nMin + 1, nMax or 120)
            local wasFull = (curStart <= curMin + 0.5) and (curEnd >= curMax - 0.5)
            curMin, curMax = nMin, nMax
            if wasFull then curStart, curEnd = nMin, nMax
            else
                curStart = math.clamp(curStart, curMin, curMax)
                curEnd = math.clamp(curEnd, curStart, curMax)
            end
            update()
        end
    }
end

midiRangeSlider = makeRangeSlider("TIME RANGE (START & END CROP)", 0, 120, scroll, function() end)

refreshMidiDurationLimits = function()
    if not (selectedFile and selectedFile.path and midiRangeSlider) then return end
    if not readfile then return end
    local ok, raw = pcall(readfile, selectedFile.path)
    if not (ok and raw) then return end
    local dur = getMidiDuration(raw, speedVal)
    if dur and dur > 0 then midiRangeSlider.setLimits(0, dur) end
end

-- === SLIDER ===
local function makeSlider(titleText, minVal, maxVal, defaultVal, isFloat, unit, onChange)
    local curVal = defaultVal
    local frame = Instance.new("Frame")
    frame.Size = UDim2.new(1,0,0,48)
    frame.BackgroundColor3 = C.Card; frame.BorderSizePixel = 0
    frame.Parent = scroll
    makeCorner(frame, 8); makeStroke(frame, C.Border, 1.0, 0.6)

    local lbl = Instance.new("TextLabel")
    lbl.Size = UDim2.new(0.65,0,0,20); lbl.Position = UDim2.new(0,10,0,4)
    lbl.BackgroundTransparency = 1
    lbl.Text = titleText; lbl.TextColor3 = C.Text
    lbl.TextSize = 12; lbl.Font = FontMain
    lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.Parent = frame

    local valLbl = Instance.new("TextLabel")
    valLbl.Size = UDim2.new(0.30,0,0,20); valLbl.Position = UDim2.new(0.70,-10,0,4)
    valLbl.BackgroundTransparency = 1
    valLbl.Text = (isFloat and string.format("%.2f", curVal) or tostring(curVal)) .. (unit or "")
    valLbl.TextColor3 = C.Accent; valLbl.TextSize = 12; valLbl.Font = FontBold
    valLbl.TextXAlignment = Enum.TextXAlignment.Right; valLbl.Parent = frame

    local track = Instance.new("Frame")
    track.Size = UDim2.new(1,-20,0,6); track.Position = UDim2.new(0,10,0,30)
    track.BackgroundColor3 = Color3.fromRGB(35,40,52); track.BorderSizePixel = 0
    track.Parent = frame
    makeCorner(track, 3)

    local fill = Instance.new("Frame")
    fill.Size = UDim2.new(math.clamp((curVal - minVal)/(maxVal - minVal),0,1), 0, 1, 0)
    fill.BackgroundColor3 = C.Accent; fill.BorderSizePixel = 0; fill.Parent = track
    makeCorner(fill, 3)

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1,0,1,0); btn.BackgroundTransparency = 1
    btn.Text = ""; btn.Parent = track

    local dragging = false
    local function updateFrom(x)
        local rel = math.clamp((x - track.AbsolutePosition.X) / math.max(1, track.AbsoluteSize.X), 0, 1)
        local raw = minVal + rel * (maxVal - minVal)
        curVal = isFloat and (math.floor(raw*100 + 0.5)/100) or math.floor(raw + 0.5)
        fill.Size = UDim2.new(math.clamp((curVal - minVal)/(maxVal - minVal),0,1), 0, 1, 0)
        valLbl.Text = (isFloat and string.format("%.2f", curVal) or tostring(curVal)) .. (unit or "")
        if onChange then onChange(curVal) end
    end

    local c1 = btn.InputBegan:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = true; updateFrom(i.Position.X)
        end
    end)
    local c2 = UserInputService.InputEnded:Connect(function(i)
        if i.UserInputType == Enum.UserInputType.MouseButton1 or i.UserInputType == Enum.UserInputType.Touch then
            dragging = false
        end
    end)
    local c3 = UserInputService.InputChanged:Connect(function(i)
        if dragging and (i.UserInputType == Enum.UserInputType.MouseMovement or i.UserInputType == Enum.UserInputType.Touch) then
            updateFrom(i.Position.X)
        end
    end)
    frame.Destroying:Connect(function()
        c1:Disconnect(); c2:Disconnect(); c3:Disconnect()
    end)
    return frame
end

makeSlider("Tempo / Speed Multiplier", 0.25, 3.0, 1.0, true, "x", function(v)
    speedVal = v
    if refreshMidiDurationLimits then task.spawn(refreshMidiDurationLimits) end
end)
makeSlider("Pitch Transpose", -12, 12, 0, false, " semitones", function(v) transposeVal = v end)
makeSlider("Gap / Chord Tolerance", 0.02, 0.20, 0.05, true, "s", function(v) minStepVal = v end)
makeSlider("Max Simultaneous Notes (Chord)", 1, 6, 4, false, " notes", function(v) maxChordVal = v end)

-- === FORMAT TOGGLES ===
local optRow = Instance.new("Frame")
optRow.Size = UDim2.new(1,0,0,36)
optRow.BackgroundColor3 = C.Card; optRow.BorderSizePixel = 0
optRow.Parent = scroll
makeCorner(optRow, 8); makeStroke(optRow, C.Border, 1.0, 0.6)

local optL = Instance.new("UIListLayout")
optL.FillDirection = Enum.FillDirection.Horizontal
optL.Padding = UDim.new(0,8)
optL.VerticalAlignment = Enum.VerticalAlignment.Center
optL.HorizontalAlignment = Enum.HorizontalAlignment.Center
optL.Parent = optRow

local function makeToggleBtn(text, active, onClick)
    local b = Instance.new("TextButton")
    b.Size = UDim2.new(0,165,0,26)
    b.BackgroundColor3 = active and C.AccentDark or Color3.fromRGB(30,34,46)
    b.Text = text
    b.TextColor3 = active and Color3.fromRGB(255,255,255) or C.TextDim
    b.TextSize = 11; b.Font = FontBold; b.Parent = optRow
    makeCorner(b, 6); makeStroke(b, active and C.Accent or C.Border, 1.0, active and 0.2 or 0.7)
    b.MouseButton1Click:Connect(function() if onClick then onClick() end end)
    return b
end

local btnLuau, btnBabft
local function updateToggles()
    local a = saveFormatVal == "LuauPro"
    btnLuau.BackgroundColor3 = a and C.AccentDark or Color3.fromRGB(30,34,46)
    btnLuau.TextColor3 = a and Color3.fromRGB(255,255,255) or C.TextDim
    local b = saveFormatVal == "BABFT"
    btnBabft.BackgroundColor3 = b and C.AccentDark or Color3.fromRGB(30,34,46)
    btnBabft.TextColor3 = b and Color3.fromRGB(255,255,255) or C.TextDim
end
btnLuau = makeToggleBtn("Format: LuauPro (.Build)", true, function() saveFormatVal = "LuauPro"; updateToggles() end)
btnBabft = makeToggleBtn("Format: BABFT (.build)", false, function() saveFormatVal = "BABFT"; updateToggles() end)
updateToggles()

-- === GAME HELPERS ===
local function getPlayerZone(player)
    player = player or lp
    if not player then return nil end
    local myTeamColor = player.TeamColor
    for _, zone in pairs(workspace:GetChildren()) do
        local tc = zone:FindFirstChild("TeamColor")
        if tc and tc:IsA("ValueBase") and tc.Value == myTeamColor then
            return zone
        end
    end
    if player.Team then
        local tName = player.Team.Name:lower()
        for _, zone in pairs(workspace:GetChildren()) do
            if zone.Name:lower():find(tName) then return zone end
        end
    end
    return nil
end

local function getBlockID(blockName)
    local data = lp:FindFirstChild("Data")
    if not data then return nil end
    local c = data:FindFirstChild(blockName)
    if c and c.Value ~= nil then
        return tonumber(c.Value) or c.Value
    end
    for _, ch in ipairs(data:GetChildren()) do
        if ch.Name:lower() == blockName:lower() then
            return tonumber(ch.Value) or ch.Value
        end
    end
    return nil
end

local function getRealBlockCount(blockName)
    local count = 0
    pcall(function()
        local data = lp:FindFirstChild("Data")
        if data then
            local item = data:FindFirstChild(blockName)
            if item and item.Value ~= nil then
                local used = item:FindFirstChild("Used")
                local usedVal = (used and tonumber(used.Value)) or 0
                count = math.max(0, math.floor((tonumber(item.Value) or 0) - usedVal))
                return
            end
        end
        local pg = lp:FindFirstChild("PlayerGui")
        local bg = pg and pg:FindFirstChild("BuildGui")
        if not bg then return end
        local inv = bg:FindFirstChild("InventoryFrame") or bg:FindFirstChild("Inventory")
        local sf = inv and (inv:FindFirstChild("ScrollingFrame") or inv)
        local bf = sf and (sf:FindFirstChild("BlocksFrame") or sf)
        if bf then
            for _, ch in ipairs(bf:GetChildren()) do
                if ch.Name:lower() == blockName:lower() then
                    local at = ch:FindFirstChild("AmountText") or ch:FindFirstChild("Amount")
                    if at and at:IsA("TextLabel") and at.Text then
                        local digits = at.Text:gsub("[^%d]", "")
                        count = digits ~= "" and tonumber(digits) or 1
                    else
                        count = 1
                    end
                    return
                end
            end
        end
    end)
    return count
end

local function equipAllBuildTools()
    local ch = lp.Character
    local bp = lp:FindFirstChild("Backpack")
    if not ch or not bp then return end
    local names = {BuildingTool = true, PropertiesTool = true, BindTool = true}
    for _, tool in ipairs(bp:GetChildren()) do
        if tool:IsA("Tool") and names[tool.Name] then
            pcall(function() tool.Parent = ch end)
        end
    end
    task.wait(0.15) -- ✅ больше времени
    for _, tool in ipairs(ch:GetChildren()) do
        if tool:IsA("Tool") and names[tool.Name] then
            pcall(function() tool:Activate() end)
        end
    end
end

-- === ACTION CARD ===
local actionCard = Instance.new("Frame")
actionCard.Size = UDim2.new(1,0,0,95)
actionCard.BackgroundColor3 = C.Card; actionCard.BorderSizePixel = 0
actionCard.Parent = scroll
makeCorner(actionCard, 8); makeStroke(actionCard, C.Border, 1.0, 0.6)

local convertBtn = Instance.new("TextButton")
convertBtn.Size = UDim2.new(1,-20,0,38); convertBtn.Position = UDim2.new(0,10,0,8)
convertBtn.BackgroundColor3 = C.Accent
convertBtn.Text = "CONVERT & SAVE"; convertBtn.TextColor3 = Color3.fromRGB(20,20,25)
convertBtn.TextSize = 13; convertBtn.Font = FontBold; convertBtn.Parent = actionCard
makeCorner(convertBtn, 6)

local statusLbl = Instance.new("TextLabel")
statusLbl.Size = UDim2.new(1,-20,0,40); statusLbl.Position = UDim2.new(0,10,0,50)
statusLbl.BackgroundTransparency = 1
statusLbl.Text = "Ready. Select a MIDI file, adjust range if needed, and click Convert."
statusLbl.TextColor3 = C.TextDim; statusLbl.TextSize = 11; statusLbl.Font = FontMain
statusLbl.TextWrapped = true; statusLbl.Parent = actionCard

local lastConvertedBuildData, lastConvertedSteps

convertBtn.MouseButton1Click:Connect(function()
    if not selectedFile or not selectedFile.path or #selectedFile.path == 0 then
        statusLbl.TextColor3 = C.Error
        statusLbl.Text = "Please select or type a MIDI file path first."
        return
    end
    if not (readfile and writefile) then
        statusLbl.TextColor3 = C.Error
        statusLbl.Text = "This executor does not support readfile/writefile."
        return
    end
    statusLbl.TextColor3 = C.Accent
    statusLbl.Text = "Reading & parsing MIDI..."
    task.wait(0.05)

    local ok, raw = pcall(readfile, selectedFile.path)
    if not (ok and raw) then
        statusLbl.TextColor3 = C.Error
        statusLbl.Text = "Error: Could not read '" .. tostring(selectedFile.path) .. "'"
        return
    end

    local startSec, endSec = 0, 999999
    if midiRangeSlider then startSec, endSec = midiRangeSlider.getRange() end

    local buildData, err = convertMidiToBuildData(raw, {
        speed = speedVal, transpose = transposeVal,
        minStep = minStepVal, maxChord = maxChordVal,
        startSec = startSec, endSec = endSec
    })

    if not buildData then
        statusLbl.TextColor3 = C.Error
        statusLbl.Text = "Conversion failed: " .. tostring(err)
        return
    end

    local baseName = selectedFile.name:gsub("%.midi?$", "")
    local saved = {}

    if saveFormatVal == "LuauPro" or saveFormatVal == "Both" then
        local s = formatLuauPro(buildData, baseName)
        for _, p in ipairs({"SOPERA_WORKSPACE/" .. baseName .. ".Build", baseName .. ".Build"}) do
            local wOk = pcall(writefile, p, s)
            if wOk then saved[#saved+1] = p end
        end
    end

    if saveFormatVal == "BABFT" or saveFormatVal == "Both" then
        local s = HttpService:JSONEncode(buildData)
        for _, p in ipairs({"SOPERA_WORKSPACE/" .. baseName .. ".build", baseName .. ".build"}) do
            local wOk = pcall(writefile, p, s)
            if wOk then saved[#saved+1] = p end
        end
    end

    if #saved == 0 then
        statusLbl.TextColor3 = C.Error
        statusLbl.Text = "Conversion done but writefile failed."
        return
    end

    local total = #buildData.Button + #buildData.Note + #buildData.Delay
    lastConvertedBuildData = buildData
    lastConvertedSteps = buildData._parsedSteps
    statusLbl.TextColor3 = C.Success
    statusLbl.Text = string.format("Success! %d blocks saved to %s", total, table.concat(saved, ", "))
    if updateInventoryDisplay then updateInventoryDisplay() end
end)

-- === INVENTORY CARD ===
local invCard = Instance.new("Frame")
invCard.Size = UDim2.new(1,0,0,140)
invCard.BackgroundColor3 = C.Card; invCard.BorderSizePixel = 0
invCard.Parent = scroll
makeCorner(invCard, 8); makeStroke(invCard, C.Border, 1.0, 0.6)

local invTitle = Instance.new("TextLabel")
invTitle.Size = UDim2.new(1,-20,0,24); invTitle.Position = UDim2.new(0,10,0,6)
invTitle.BackgroundTransparency = 1
invTitle.Text = "INVENTORY & REQUIREMENTS"; invTitle.TextColor3 = C.Accent
invTitle.TextSize = 12; invTitle.Font = FontBold
invTitle.TextXAlignment = Enum.TextXAlignment.Left; invTitle.Parent = invCard

local function makeInvRow(icon, name, posY)
    local row = Instance.new("Frame")
    row.Size = UDim2.new(1,-20,0,22); row.Position = UDim2.new(0,10,0,posY)
    row.BackgroundTransparency = 1; row.Parent = invCard

    local n = Instance.new("TextLabel")
    n.Size = UDim2.new(0.45,0,1,0); n.BackgroundTransparency = 1
    n.Text = icon .. " " .. name .. ":"; n.TextColor3 = C.Text
    n.TextSize = 12; n.Font = FontBold
    n.TextXAlignment = Enum.TextXAlignment.Left; n.Parent = row

    local c = Instance.new("TextLabel")
    c.Size = UDim2.new(0.55,0,1,0); c.Position = UDim2.new(0.45,0,0,0)
    c.BackgroundTransparency = 1
    c.Text = "Owned: --  / Need: --"; c.TextColor3 = C.TextDim
    c.TextSize = 11; c.Font = FontMain
    c.TextXAlignment = Enum.TextXAlignment.Right; c.Parent = row
    return c
end

local btnCountLbl = makeInvRow("🔘", "Button", 32)
local noteCountLbl = makeInvRow("🎵", "Note", 56)
local delayCountLbl = makeInvRow("⏱️", "Delay", 80)

local refreshInvBtn = Instance.new("TextButton")
refreshInvBtn.Size = UDim2.new(1,-20,0,24); refreshInvBtn.Position = UDim2.new(0,10,0,108)
refreshInvBtn.BackgroundColor3 = Color3.fromRGB(35,38,48)
refreshInvBtn.Text = "⟳ Refresh Inventory Counts"
refreshInvBtn.TextColor3 = C.TextDim; refreshInvBtn.TextSize = 11
refreshInvBtn.Font = FontMain; refreshInvBtn.Parent = invCard
makeCorner(refreshInvBtn, 5)

function updateInventoryDisplay()
    local bo, no, dof = getRealBlockCount("Button"), getRealBlockCount("Note"), getRealBlockCount("Delay")
    local bn, nn = 1, 25
    local dn = (lastConvertedBuildData and lastConvertedBuildData.Delay and #lastConvertedBuildData.Delay) or 0
    local function fmt(o, n)
        local ok = o >= n
        return string.format("Owned: %d / Need: %d%s", o, n,
            ok and "  ✓ OK" or string.format("  (NEED %d MORE)", n - o)), ok
    end
    local bt, bok = fmt(bo, bn); btnCountLbl.Text = bt; btnCountLbl.TextColor3 = bok and C.Success or C.Error
    local nt, nok = fmt(no, nn); noteCountLbl.Text = nt; noteCountLbl.TextColor3 = nok and C.Success or C.Error
    local dt, dok = fmt(dof, dn); delayCountLbl.Text = dt
    delayCountLbl.TextColor3 = (dn == 0 or dok) and C.Success or C.Error
end

refreshInvBtn.MouseButton1Click:Connect(updateInventoryDisplay)
updateInventoryDisplay()

-- === BUILD CARD ===
local buildCard = Instance.new("Frame")
buildCard.Size = UDim2.new(1,0,0,140)
buildCard.BackgroundColor3 = C.Card; buildCard.BorderSizePixel = 0
buildCard.Parent = scroll
makeCorner(buildCard, 8); makeStroke(buildCard, C.Border, 1.0, 0.6)

local buildTitle = Instance.new("TextLabel")
buildTitle.Size = UDim2.new(1,-20,0,24); buildTitle.Position = UDim2.new(0,10,0,6)
buildTitle.BackgroundTransparency = 1
buildTitle.Text = "BUILD IN GAME"; buildTitle.TextColor3 = C.Accent
buildTitle.TextSize = 12; buildTitle.Font = FontBold
buildTitle.TextXAlignment = Enum.TextXAlignment.Left; buildTitle.Parent = buildCard

local btnRow = Instance.new("Frame")
btnRow.Size = UDim2.new(1,-20,0,34); btnRow.Position = UDim2.new(0,10,0,30)
btnRow.BackgroundTransparency = 1; btnRow.Parent = buildCard

local startBuildBtn = Instance.new("TextButton")
startBuildBtn.Size = UDim2.new(0.68,-4,1,0)
startBuildBtn.BackgroundColor3 = Color3.fromRGB(38,140,80)
startBuildBtn.Text = "▶ BUILD IN GAME"
startBuildBtn.TextColor3 = Color3.fromRGB(240,255,240)
startBuildBtn.TextSize = 12; startBuildBtn.Font = FontBold; startBuildBtn.Parent = btnRow
makeCorner(startBuildBtn, 6)

local stopBuildBtn = Instance.new("TextButton")
stopBuildBtn.Size = UDim2.new(0.32,-4,1,0); stopBuildBtn.Position = UDim2.new(0.68,4,0,0)
stopBuildBtn.BackgroundColor3 = Color3.fromRGB(150,40,40)
stopBuildBtn.Text = "■ STOP"; stopBuildBtn.TextColor3 = Color3.fromRGB(255,230,230)
stopBuildBtn.TextSize = 12; stopBuildBtn.Font = FontBold; stopBuildBtn.Parent = btnRow
makeCorner(stopBuildBtn, 6)

local buildProgressBg = Instance.new("Frame")
buildProgressBg.Size = UDim2.new(1,-20,0,6); buildProgressBg.Position = UDim2.new(0,10,0,72)
buildProgressBg.BackgroundColor3 = Color3.fromRGB(30,33,42)
buildProgressBg.BorderSizePixel = 0; buildProgressBg.Parent = buildCard
makeCorner(buildProgressBg, 3)

local buildProgressFill = Instance.new("Frame")
buildProgressFill.Size = UDim2.new(0,0,1,0)
buildProgressFill.BackgroundColor3 = C.Accent; buildProgressFill.BorderSizePixel = 0
buildProgressFill.Parent = buildProgressBg
makeCorner(buildProgressFill, 3)

local buildStatusLbl = Instance.new("TextLabel")
buildStatusLbl.Size = UDim2.new(1,-20,0,46); buildStatusLbl.Position = UDim2.new(0,10,0,84)
buildStatusLbl.BackgroundTransparency = 1
buildStatusLbl.Text = "Ready. Convert a song, then click 'BUILD IN GAME'."
buildStatusLbl.TextColor3 = C.TextDim; buildStatusLbl.TextSize = 11; buildStatusLbl.Font = FontMain
buildStatusLbl.TextWrapped = true; buildStatusLbl.Parent = buildCard

local isBuilding, stopBuildRequested = false, false

stopBuildBtn.MouseButton1Click:Connect(function()
    if isBuilding then
        stopBuildRequested = true
        buildStatusLbl.TextColor3 = C.Error
        buildStatusLbl.Text = "Stopping build..."
    end
end)

-- === BUILD IN GAME ===
local function buildMusicInGame(buildData, steps)
    if isBuilding then return end
    isBuilding, stopBuildRequested = true, false

    local function setProg(msg, pct, isErr)
        buildStatusLbl.TextColor3 = isErr and C.Error or (pct >= 100 and C.Success or C.Accent)
        buildStatusLbl.Text = tostring(msg)
        local safe = math.clamp(pct or 0, 0, 100)
        TweenService:Create(buildProgressFill, TweenInfo.new(0.12), {Size = UDim2.new(safe/100, 0, 1, 0)}):Play()
    end

    local myZone = getPlayerZone(lp)
    if not myZone then setProg("Error: could not locate your team plot.", 0, true); isBuilding = false; return end

    setProg("Equipping building tools...", 5)
    equipAllBuildTools()
    task.wait(0.1)

    local ch = lp.Character
    local placeTool = (ch and ch:FindFirstChild("BuildingTool")) or lp.Backpack:FindFirstChild("BuildingTool")
    local placeRF = placeTool and placeTool:FindFirstChild("RF")
    if not placeRF then setProg("Error: BuildingTool RF missing.", 0, true); isBuilding = false; return end

    local propTool = (ch and ch:FindFirstChild("PropertiesTool")) or lp.Backpack:FindFirstChild("PropertiesTool")
    local propRF = propTool and propTool:FindFirstChild("SetPropertieRF")
    local bindTool = (ch and ch:FindFirstChild("BindTool")) or lp.Backpack:FindFirstChild("BindTool")
    local bindRF = bindTool and bindTool:FindFirstChild("RF")

    local blockID = getBlockID("Button")
    if not blockID then setProg("Error: 'Button' block ID not found.", 0, true); isBuilding = false; return end
    local noteBlockID = getBlockID("Note")
    if not noteBlockID then setProg("Error: 'Note' block ID not found.", 0, true); isBuilding = false; return end
    local delayBlockID = getBlockID("Delay")
    if not delayBlockID then setProg("Error: 'Delay' block ID not found.", 0, true); isBuilding = false; return end

    local blocksFolder = workspace:FindFirstChild("Blocks")
    local myBlocks = blocksFolder and blocksFolder:FindFirstChild(lp.Name)
    if not myBlocks then setProg("Error: workspace.Blocks[" .. lp.Name .. "] missing.", 0, true); isBuilding = false; return end

    local preExisting, initialCount = {}, 0
    for _, b in ipairs(myBlocks:GetChildren()) do preExisting[b] = true; initialCount = initialCount + 1 end

    local totalDelayCount = #buildData.Delay
    local totalBlocks = 1 + #buildData.Note + totalDelayCount
    setProg("Placing blocks (1 Button, 25 Notes, " .. totalDelayCount .. " Delays)...", 10)

    -- ✅ ограничиваем burst: батчи по 30 с ожиданием
    local function invokePlace(name, id, cframe)
        task.spawn(function()
            pcall(function() placeRF:InvokeServer(name, id, myZone, cframe, true, true) end)
        end)
    end

    invokePlace("Button", blockID, CFrame.new(0, 1.5, -28))
    for p = 0, 24 do
        invokePlace("Note", noteBlockID, CFrame.new(-32, 1.5 + p * 2.0, -20))
        if p % 6 == 5 then RunService.Heartbeat:Wait() end
    end

    local BATCH = 25
    for i = 1, totalDelayCount do
        if stopBuildRequested then break end
        local it = buildData.Delay[i]
        invokePlace("Delay", delayBlockID, CFrame.new(it.cf[1], it.cf[2], it.cf[3]))
        if i % BATCH == 0 then
            RunService.Heartbeat:Wait()
            setProg(string.format("Placing delays: %d / %d...", i, totalDelayCount),
                10 + math.floor((i / math.max(1, totalDelayCount)) * 48))
        end
    end

    if stopBuildRequested then setProg("Build stopped.", 0, true); isBuilding = false; return end

    setProg("Waiting for replication...", 58)
    local targetCount = initialCount + totalBlocks
    local t0 = os.clock()
    local maxWait = math.max(5, math.min(30, totalBlocks * 0.015))
    while (os.clock() - t0 < maxWait) and not stopBuildRequested do
        RunService.Heartbeat:Wait()
        if #myBlocks:GetChildren() >= targetCount then break end
    end
    task.wait(0.2)

    setProg("Mapping placed blocks...", 62)
    local myZoneCF = myZone.CFrame
    local newButtons, newNotes, newDelays = {}, {}, {}
    for _, b in ipairs(myBlocks:GetChildren()) do
        if not preExisting[b] and b:FindFirstChild("PPart") then
            if b.Name == "Button" then newButtons[#newButtons+1] = b
            elseif b.Name == "Note" then newNotes[#newNotes+1] = b
            elseif b.Name == "Delay" then newDelays[#newDelays+1] = b end
        end
    end

    local buttonInst = newButtons[1]

    -- ✅ маппинг нот по ЦЕЛЕВОМУ CFrame, а не по Y
    local noteInstances = {}
    local usedNotes = {}
    for p = 0, 24 do
        local targetPos = myZoneCF:PointToWorldSpace(Vector3.new(-32, 1.5 + p * 2.0, -20))
        local best, bestD = nil, math.huge
        for _, nb in ipairs(newNotes) do
            if not usedNotes[nb] and nb:FindFirstChild("PPart") then
                local d = (nb.PPart.Position - targetPos).Magnitude
                if d < bestD then bestD = d; best = nb end
            end
        end
        if best then usedNotes[best] = true; noteInstances[p] = best end
    end

    local delayInstances, usedDelays = {}, {}
    for i = 1, totalDelayCount do
        local it = buildData.Delay[i]
        local targetPos = myZoneCF:PointToWorldSpace(Vector3.new(it.cf[1], it.cf[2], it.cf[3]))
        local best, bestD = nil, math.huge
        for _, db in ipairs(newDelays) do
            if not usedDelays[db] and db:FindFirstChild("PPart") then
                local d = (db.PPart.Position - targetPos).Magnitude
                if d < bestD then bestD = d; best = db end
            end
        end
        if best then usedDelays[best] = true; delayInstances[i] = best end
    end

    if propRF then
        setProg("Applying pitches & timings...", 65)
        local pt = ch and ch:FindFirstChild("PropertiesTool") or lp.Backpack:FindFirstChild("PropertiesTool")
        if pt and pt.Parent ~= ch then pcall(function() pt.Parent = ch end); task.wait(0.04) end

        for click = 1, 24 do
            if stopBuildRequested then break end
            local targets = {}
            for p = click, 24 do if noteInstances[p] then targets[#targets+1] = noteInstances[p] end end
            if #targets > 0 then pcall(function() propRF:InvokeServer("Key", targets) end); task.wait(0.04) end
            setProg(string.format("Tuning notes: %d / 24...", click), 65 + math.floor((click/24)*10))
        end

        local groups, valid = {}, {}
        for i = 1, totalDelayCount do
            local db = delayInstances[i]
            if db then
                valid[#valid+1] = db
                local dt = tostring(buildData.Delay[i].nv and buildData.Delay[i].nv.WaitDuration or 0.1)
                groups[dt] = groups[dt] or {}; groups[dt][#groups[dt]+1] = db
            end
        end
        for dt, list in pairs(groups) do
            for i = 1, #list, 40 do
                if stopBuildRequested then break end
                local ch2 = {}
                for j = i, math.min(i + 39, #list) do ch2[#ch2+1] = list[j] end
                pcall(function() propRF:InvokeServer("Delay time", ch2, dt) end)
                task.wait(0.02)
            end
        end
        for i = 1, #valid, 50 do
            if stopBuildRequested then break end
            local ch2 = {}
            for j = i, math.min(i + 49, #valid) do ch2[#ch2+1] = valid[j] end
            pcall(function() propRF:InvokeServer("Legacy", ch2) end)
            task.wait(0.02)
        end
        setProg("Properties applied.", 80)
    else
        setProg("Warning: PropertiesTool missing.", 80)
    end

    if stopBuildRequested then setProg("Build stopped.", 0, true); isBuilding = false; return end

    local function getBindPort(b)
        if not b then return nil end
        local bf = b:FindFirstChild("BindFire")
        if bf then return bf end
        for _, c in ipairs(b:GetChildren()) do
            if c.Name:sub(1,4) == "Bind" and c.Name ~= "BindingSB" then return c end
        end
        return nil
    end

    if bindRF then
        setProg("Wiring triggers...", 82)
        local bt = ch and ch:FindFirstChild("BindTool") or lp.Backpack:FindFirstChild("BindTool")
        if bt and bt.Parent ~= ch then pcall(function() bt.Parent = ch end); task.wait(0.04) end

        if buttonInst then
            local tg = {}
            for _, p in ipairs(steps and steps[1] and steps[1].pitches or {}) do
                local nb = noteInstances[p]; local port = getBindPort(nb)
                if port then tg[#tg+1] = port end
            end
            local dp = getBindPort(delayInstances[1]); if dp then tg[#tg+1] = dp end
            if #tg > 0 then
                pcall(function() bindRF:InvokeServer({Activate = tg}, {buttonInst}, {}, false, false) end)
            end
        end

        local BATCH_B = 15
        for i = 1, totalDelayCount do
            if stopBuildRequested then break end
            local cd = delayInstances[i]
            if cd then
                local np = steps and steps[i+1] and steps[i+1].pitches or {}
                local tg = {}
                for _, p in ipairs(np) do
                    local port = getBindPort(noteInstances[p]); if port then tg[#tg+1] = port end
                end
                local dp = getBindPort(delayInstances[i+1]); if dp then tg[#tg+1] = dp end
                if #tg > 0 then
                    pcall(function() bindRF:InvokeServer({Activate = tg}, {cd}, {}, false, false) end)
                end
            end
            if i % BATCH_B == 0 then
                RunService.Heartbeat:Wait()
                setProg(string.format("Wiring: %d / %d...", i, totalDelayCount),
                    82 + math.floor((i / math.max(1, totalDelayCount)) * 17))
            end
        end
    else
        setProg("Warning: BindTool missing.", 98)
    end

    if stopBuildRequested then setProg("Build stopped.", 0, true)
    else setProg("Build complete! " .. totalBlocks .. " blocks placed.", 100) end
    isBuilding = false
    updateInventoryDisplay()
end

startBuildBtn.MouseButton1Click:Connect(function()
    if isBuilding then return end
    if not lastConvertedBuildData then
        if not selectedFile or not selectedFile.path then
            buildStatusLbl.TextColor3 = C.Error
            buildStatusLbl.Text = "Please select a MIDI file first."
            return
        end
        if not readfile then
            buildStatusLbl.TextColor3 = C.Error
            buildStatusLbl.Text = "readfile not supported by executor."
            return
        end
        buildStatusLbl.TextColor3 = C.Accent
        buildStatusLbl.Text = "Parsing MIDI..."
        task.wait(0.05)
        local ok, raw = pcall(readfile, selectedFile.path)
        if not (ok and raw) then
            buildStatusLbl.TextColor3 = C.Error
            buildStatusLbl.Text = "Error reading file."
            return
        end
        local s, e = 0, 999999
        if midiRangeSlider then s, e = midiRangeSlider.getRange() end
        local bd, err = convertMidiToBuildData(raw, {
            speed = speedVal, transpose = transposeVal,
            minStep = minStepVal, maxChord = maxChordVal, startSec = s, endSec = e
        })
        if not bd then
            buildStatusLbl.TextColor3 = C.Error
            buildStatusLbl.Text = "Convert error: " .. tostring(err)
            return
        end
        lastConvertedBuildData = bd
        lastConvertedSteps = bd._parsedSteps
        updateInventoryDisplay()
    end
    task.spawn(function() buildMusicInGame(lastConvertedBuildData, lastConvertedSteps) end)
end)

print("[SPRB] MIDI → BABFT Converter loaded.")
