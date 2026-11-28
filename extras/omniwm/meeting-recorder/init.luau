-- meeting-recorder: shows lắng's recording state on the OmniWM bar.
--
-- lắng has no IPC, so an external script (lang-omniwm-status, run by launchd)
-- reads lắng's log and pushes one packed value:
--   omniwmctl shell set lang.status "<off|idle|recording>|<since epoch s>|<meeting folder or ->"

interval = 1 -- re-render every second so the recording timer ticks

local OPEN_APP = "app-open com.n3rd.MeetingMate" -- OmniWM action: launch / focus lắng

-- "recording|1795834676|2026-11-28_09-57-56" -> { state, since, meeting }
local function parse(raw: string?)
    if type(raw) ~= "string" or raw == "" then
        return nil
    end
    local parts = string.split(raw, "|")
    local meeting = parts[3]
    return {
        state = parts[1] or "off",
        since = tonumber(parts[2]) or 0,
        meeting = if meeting and meeting ~= "-" and meeting ~= "" then meeting else nil,
    }
end

local function clock(seconds: number): string
    local total = math.max(0, math.floor(seconds))
    local h, m, s = total // 3600, (total % 3600) // 60, total % 60
    if h > 0 then
        return string.format("%d:%02d:%02d", h, m, s)
    end
    return string.format("%02d:%02d", m, s)
end

-- One place that reads data; render/popout only turn this into UI.
local function model(ctx: Context)
    local status = parse(ctx.select("vars", "lang.status"))
    local m = {
        state = if status then status.state else "unknown", -- unknown = script not pushing yet / IPC off
        meeting = status and status.meeting,
        elapsed = nil,
        micMissing = false,
        showWhenIdle = ctx.select("settings", "showWhenIdle") == true,
        showTimer = ctx.select("settings", "showTimer") ~= false,
    }
    if m.state == "recording" then
        local now = ctx.select("seconds") -- epoch seconds
        if status and status.since > 0 and type(now) == "number" then
            m.elapsed = now - status.since
        end
        -- Recording but macOS says no app uses the mic -> something is wrong.
        -- Only after 10 s, so the indicator has time to turn on.
        if ctx.select("settings", "micCheck") ~= false and (m.elapsed or 0) > 10 then
            m.micMissing = ctx.select("privacy", "microphone") == false
        end
    end
    return m
end

local LOOK = {
    recording = { symbol = "record.circle.fill", color = "red", label = "Recording" },
    idle = { symbol = "waveform", color = "secondaryForeground", label = "Idle" },
    off = { symbol = "waveform.slash", color = "secondaryForeground", label = "lắng is not running" },
    unknown = { symbol = "questionmark.circle", color = "secondaryForeground", label = "No data (status script or IPC off?)" },
}

function render(ctx: Context)
    local m = model(ctx)
    if m.state ~= "recording" and not m.showWhenIdle then
        return ui.box{ w = 0, h = 0 } -- invisible unless recording
    end
    local look = LOOK[m.state] or LOOK.unknown
    local props = {
        key = "meeting-recorder",
        gap = 5,
        pad = 4,
        radius = 6,
        onClick = ui.popout,
        onRightClick = OPEN_APP,
        help = look.label,
        ui.symbol{ name = if m.micMissing then "exclamationmark.triangle.fill" else look.symbol, size = 13, color = if m.micMissing then "orange" else look.color },
    }
    if m.state == "recording" and m.showTimer and m.elapsed then
        props[#props + 1] = ui.text{ text = clock(m.elapsed), style = "mono", size = 12, reserve = if m.elapsed >= 3600 then "0:00:00" else "00:00" } -- reserve must cover the hour format too
    end
    return ui.row(props)
end

local function line(label: string, value: string, color: string?)
    return ui.row{
        gap = 8,
        -- fixed-width, left-aligned label column so values line up
        ui.stack{ w = 78, align = "leading", ui.text{ text = label, size = 12, color = "secondaryForeground" } },
        ui.text{ text = value, size = 12, color = color },
    }
end

function popout(ctx: Context)
    local m = model(ctx)
    local look = LOOK[m.state] or LOOK.unknown
    local rows = {
        gap = 8,
        pad = 12,
        align = "leading", -- left-align every row instead of centering
        ui.row{
            gap = 6,
            ui.symbol{ name = look.symbol, size = 15, color = look.color },
            ui.text{ text = "lắng", style = "bold", size = 14 },
        },
        line("Status", look.label, if m.state == "recording" then "red" else nil),
    }
    if m.meeting then
        rows[#rows + 1] = line("Meeting", m.meeting)
    end
    if m.elapsed then
        rows[#rows + 1] = line("Elapsed", clock(m.elapsed))
    end
    if m.state == "recording" then
        rows[#rows + 1] = if m.micMissing
            then line("Microphone", "not in use — check lắng!", "orange")
            else line("Microphone", "in use", "green")
    end
    rows[#rows + 1] = ui.row{
        key = "meeting-recorder.open",
        gap = 5,
        pad = 6,
        radius = 6,
        fill = "surface",
        hover = "accent",
        onClick = OPEN_APP,
        ui.symbol{ name = "arrow.up.forward.app", size = 12 },
        ui.text{ text = "Open lắng", size = 12 },
    }
    return ui.column(rows)
end
