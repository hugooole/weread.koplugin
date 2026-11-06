-- Optional SimpleUI Home Screen modules: reading-shelf covers and recommendations,
-- both drawn from local caches. Never touches the network while rendering.
-- Contract: modules/moduleregistry.lua in SimpleUI (not a stable public API).

local logger = require("weread.lib.logger")
local _ = require("weread.lib.plugin_util").tr

local MIN_ROWS, MAX_ROWS, DEFAULT_ROWS = 1, 3, 2 -- rows visible at once
local TARGET_COVER_W, CAPTION_H, ROW_GAP, COL_GAP = 80, 24, 8, 12 -- unscaled px

local Module = {
    name = "simpleui_module",
    registered = false,
    plugin = nil,
}

-- Pure layout maths. Columns follow the width; covers then grow to fill the
-- row exactly, so there is no dead strip on the right at any width.
function Module.layout(width, scale)
    local gap = math.floor(COL_GAP * scale)
    local target = TARGET_COVER_W * scale
    local columns = math.max(1, math.floor((width + gap) / (target + gap)))
    local cover_w = math.max(1, math.floor((width - (columns - 1) * gap) / columns))
    local cover_h = math.floor(cover_w * 3 / 2)
    return {
        columns = columns, gap = gap, cover_w = cover_w, cover_h = cover_h,
        cell_h = cover_h + math.floor(CAPTION_H * scale),
        row_gap = math.floor(ROW_GAP * scale),
    }
end

function Module.clamp_rows(rows)
    rows = math.floor(tonumber(rows) or DEFAULT_ROWS)
    return math.max(MIN_ROWS, math.min(MAX_ROWS, rows))
end

-- Height of the window showing `rows` rows.
function Module.window_height(layout, rows)
    rows = Module.clamp_rows(rows)
    return rows * layout.cell_h + (rows - 1) * layout.row_gap
end

function Module.total_rows(count, columns)
    return math.ceil(count / math.max(1, columns))
end

-- First visible row (zero-based), never past the point where the window would
-- run off the last row: 40 books / 4 columns = 10 rows, 2 visible, max is 8.
function Module.clamp_offset(offset, total_rows, rows)
    local max_offset = math.max(0, total_rows - Module.clamp_rows(rows))
    return math.max(0, math.min(math.floor(tonumber(offset) or 0), max_offset))
end

-- Scrollbar thumb inside a track `height` tall: size shows how much of the
-- list is visible, position shows where the window is.
function Module.thumb(height, total_rows, rows, offset)
    rows = Module.clamp_rows(rows)
    if total_rows <= rows then return nil end
    local thumb_h = math.max(math.floor(height / 8), math.floor(height * rows / total_rows))
    thumb_h = math.min(thumb_h, height)
    local max_offset = total_rows - rows
    local top = math.floor((height - thumb_h) * Module.clamp_offset(offset, total_rows, rows) / max_offset)
    return top, thumb_h
end

-- Session-only first visible row per module instance.
local offsets = {}

function Module:_livePlugin()
    local file_manager = package.loaded["apps/filemanager/filemanager"]
    local fm = file_manager and file_manager.instance
    if fm and type(fm.weread) == "table" then return fm.weread end
    return self.plugin
end

-- Books being read first (progress > 0), then the rest, in shelf order.
local function pick_books(shelf)
    local reading, others = {}, {}
    for _i, book in ipairs(shelf or {}) do
        local id = book.book_id or book.bookId
        if id and not tostring(id):match("^MP_WXS_") then
            local bucket = (tonumber(book.progress) or 0) > 0 and reading or others
            bucket[#bucket + 1] = book
        end
    end
    for _i, book in ipairs(others) do reading[#reading + 1] = book end
    return reading
end

function Module:_shelf()
    local plugin = self:_livePlugin()
    if not plugin or not plugin.library_db then return {} end
    local ok, shelf = pcall(function() return plugin.library_db:getShelf() end)
    return ok and pick_books(shelf) or {}
end

-- Recommendations are cached by the Recommendations screen; empty until opened once.
function Module:_recommendations()
    local plugin = self:_livePlugin()
    if not plugin or not plugin.library_db then return {} end
    local ok, books = pcall(function() return plugin.library_db:getRecommendations() end)
    return ok and type(books) == "table" and books or {}
end

local SOURCES = {
    shelf = {
        id = "weread_shelf",
        name = "WeRead",
        books = function(self) return self:_shelf() end,
        caption = function(book)
            local progress = tonumber(book.progress) or 0
            return progress > 0 and (tostring(progress) .. "%") or _("New")
        end,
        empty = "Open the WeRead bookshelf to sync",
        open = "openBookshelf",
    },
    recommend = {
        id = "weread_recommend",
        name = "Recommendations",
        books = function(self) return self:_recommendations() end,
        caption = function(book) return book.author or "" end,
        empty = "Open Recommendations to load",
        open = "showRecommendations",
    },
}

function Module:_build(w, source, rows, ctx)
    local Device = require("device")
    local Font = require("ui/font")
    local Geom = require("ui/geometry")
    local GestureRange = require("ui/gesturerange")
    local FrameContainer = require("ui/widget/container/framecontainer")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local InputContainer = require("ui/widget/container/inputcontainer")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local ImageWidget = require("ui/widget/imagewidget")
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local TextWidget = require("ui/widget/textwidget")
    local VerticalGroup = require("ui/widget/verticalgroup")
    local VerticalSpan = require("ui/widget/verticalspan")
    local Screen = Device.screen

    local scale = Screen:scaleBySize(1000) / 1000
    -- A strip on the right is kept for the scrollbar so covers never sit under it.
    local bar_w, bar_gap = Screen:scaleBySize(4), Screen:scaleBySize(6)
    local layout = Module.layout(w - bar_w - bar_gap, scale)
    local height = Module.window_height(layout, rows)
    local face = Font:getFace("cfont", 11)
    local plugin = self:_livePlugin()
    local cache = plugin and plugin.getShelfCoverCache and plugin:getShelfCoverCache()
    local books = source.books(self)

    local function tap_anywhere()
        return { Tap = { GestureRange:new{ ges = "tap",
            range = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() } } } }
    end

    if #books == 0 then
        local tap = InputContainer:new{
            dimen = Geom:new{ w = w, h = height },
            ges_events = tap_anywhere(),
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = height },
                TextWidget:new{
                    text = _(source.empty), face = Font:getFace("cfont", 14), max_width = w,
                },
            },
        }
        tap.onTap = function(self_, _arg, ges)
            if not (self_.dimen and ges and ges.pos and self_.dimen:contains(ges.pos)) then
                return false
            end
            if plugin and plugin[source.open] then plugin[source.open](plugin) end
            return true
        end
        return tap
    end

    local function make_cell(book)
        local path = cache and cache:pathFor(book)
        local cover
        if path then
            cover = ImageWidget:new{ file = path, width = layout.cover_w, height = layout.cover_h }
        else
            cover = FrameContainer:new{
                width = layout.cover_w, height = layout.cover_h, padding = Screen:scaleBySize(4),
                bordersize = Screen:scaleBySize(1),
                TextBoxWidget:new{ text = book.title or "", face = face,
                    width = layout.cover_w - Screen:scaleBySize(10),
                    height = layout.cover_h - Screen:scaleBySize(10),
                    height_overflow_show_ellipsis = true },
            }
        end
        local cell = InputContainer:new{
            dimen = Geom:new{ w = layout.cover_w, h = layout.cell_h },
            ges_events = tap_anywhere(),
            VerticalGroup:new{
                align = "left",
                cover,
                VerticalSpan:new{ width = Screen:scaleBySize(4) },
                TextWidget:new{ text = source.caption(book), face = face, max_width = layout.cover_w },
            },
        }
        cell.onTap = function(self_, _arg, ges)
            if not (self_.dimen and ges and ges.pos and self_.dimen:contains(ges.pos)) then
                return false
            end
            if plugin and plugin.showBookRecord then plugin:showBookRecord(book) end
            return true
        end
        return cell
    end

    local total_rows = Module.total_rows(#books, layout.columns)
    local key = tostring(ctx and ctx.pfx or "") .. source.id
    local offset = Module.clamp_offset(offsets[key], total_rows, rows)
    offsets[key] = offset

    -- Only the visible rows are built; the rest is reached by scrolling.
    local grid = VerticalGroup:new{ align = "left" }
    local last_row = math.min(total_rows, offset + Module.clamp_rows(rows))
    for row = offset + 1, last_row do
        if row > offset + 1 then grid[#grid + 1] = VerticalSpan:new{ width = layout.row_gap } end
        local line = HorizontalGroup:new{ align = "top" }
        local first = (row - 1) * layout.columns + 1
        for index = first, math.min(first + layout.columns - 1, #books) do
            if index > first then line[#line + 1] = HorizontalSpan:new{ width = layout.gap } end
            line[#line + 1] = make_cell(books[index])
        end
        grid[#grid + 1] = line
    end
    if total_rows <= Module.clamp_rows(rows) then return grid end

    -- Vertical swipe scrolls by one row. The fixed window height means a short
    -- last row never leaves stale pixels behind when the content shrinks.
    local Blitbuffer = require("ffi/blitbuffer")
    local top, thumb_h = Module.thumb(height, total_rows, rows, offset)
    local bar = FrameContainer:new{
        width = bar_w, height = height, padding = 0, margin = 0, bordersize = 0,
        background = Blitbuffer.COLOR_LIGHT_GRAY,
        VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = top },
            FrameContainer:new{
                width = bar_w, height = thumb_h, padding = 0, margin = 0, bordersize = 0,
                background = Blitbuffer.COLOR_BLACK,
                VerticalSpan:new{ width = 0 },
            },
        },
    }
    -- Fixed-width slot for the grid: a short last row must not pull the bar inwards.
    local grid_w = layout.columns * layout.cover_w + (layout.columns - 1) * layout.gap
    local content = HorizontalGroup:new{
        align = "top",
        LeftContainer:new{ dimen = Geom:new{ w = grid_w, h = height }, grid },
        HorizontalSpan:new{ width = math.max(0, w - bar_w - grid_w) },
        bar,
    }
    local area = InputContainer:new{ dimen = Geom:new{ w = w, h = height }, content }
    area.ges_events = { Swipe = { GestureRange:new{ ges = "swipe", range = function() return area.dimen end } } }
    function area:onSwipe(_arg, ges)
        -- Swiping up reveals later rows, like any touch list.
        local delta = ges.direction == "north" and 1 or ges.direction == "south" and -1 or nil
        if not delta then return false end
        local target = Module.clamp_offset(offset + delta, total_rows, rows)
        if target == offset then return true end
        offsets[key] = target
        local screen = ctx and ctx._screen_widget
        if screen and screen._repaintBookMod then screen:_repaintBookMod(source.id) end
        return true
    end
    return area
end

function Module:_descriptor(source)
    local SUISettings = require("infra/sui_store")
    local this = self
    local M = {
        id = source.id,
        name = _(source.name),
        label = _(source.name),
        category = "books",
        default_on = false,
        has_covers = true,
        is_book_mod = true, -- lets SimpleUI repaint this module alone after a swipe
        no_top_margin = false,
    }
    local function rows_key(pfx) return pfx .. source.id .. "_rows" end
    local function get_rows(pfx)
        return Module.clamp_rows(SUISettings:readSetting(rows_key(pfx)))
    end
    function M.isEnabled(pfx)
        return SUISettings:readSetting(pfx .. source.id .. "_enabled") == true
    end
    function M.setEnabled(pfx, on)
        SUISettings:saveSetting(pfx .. source.id .. "_enabled", on)
    end
    function M.build(w, ctx)
        if not M.isEnabled(ctx.pfx) then return nil end
        return this:_build(w, source, get_rows(ctx.pfx), ctx)
    end
    -- SimpleUI measures the widget build() returns; this is only an estimate
    -- for callers that ask before a width is known.
    function M.getHeight(ctx)
        local scale = require("device").screen:scaleBySize(1000) / 1000
        local screen_w = require("device").screen:getWidth()
        return Module.window_height(Module.layout(screen_w, scale), get_rows(ctx and ctx.pfx or ""))
    end
    function M.getMenuItems(ctx_menu)
        local pfx = ctx_menu.pfx
        local Config = require("infra/sui_config")
        return {
            Config.makeSpinItem({
                text_func = function() return _("Visible rows") end,
                title = _("Visible rows"),
                info = _("How many rows of covers to show at once. Swipe up or down to scroll."),
                get = function() return get_rows(pfx) end,
                set = function(value) SUISettings:saveSetting(rows_key(pfx), Module.clamp_rows(value)) end,
                refresh = ctx_menu.refresh,
                value_min = MIN_ROWS,
                value_max = MAX_ROWS,
                value_step = 1,
                value_hold_step = 1,
                default_value = DEFAULT_ROWS,
            }),
        }
    end
    return M
end

function Module:_tryRegister()
    if self.registered then return true end
    local ok, Registry = pcall(require, "modules/moduleregistry")
    if not ok or type(Registry) ~= "table" or type(Registry.register) ~= "function" then
        return false
    end
    for _i, source in ipairs({ SOURCES.shelf, SOURCES.recommend }) do
        local built, descriptor = pcall(function() return self:_descriptor(source) end)
        if not built then
            logger.warn("weread: SimpleUI module descriptor failed:", tostring(descriptor))
            return false
        end
        Registry.register(descriptor)
    end
    self.registered = true
    logger.info("weread: registered SimpleUI home modules")
    return true
end

function Module:register(plugin)
    self.plugin = plugin
    return self:_tryRegister()
end

return Module
