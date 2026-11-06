-- Focused tests for the optional SimpleUI quick-action and home-module integration.

package.path = "./?.lua;./?/init.lua;" .. package.path

package.preload["weread.lib.logger"] = function()
    return { info = function() end, warn = function() end, err = function() end }
end
package.preload["weread.lib.plugin_util"] = function()
    return { tr = function(text) return text end }
end

local checks = 0
local function expect(condition, message)
    checks = checks + 1
    if not condition then error(message or ("check " .. checks .. " failed")) end
end

local Actions = require("integrations.simpleui")
local HomeModule = require("integrations.simpleui_module")

-- Without SimpleUI both integrations stay optional and silent.
expect(Actions:register({}) == false, "quick actions should be skipped without SimpleUI")
expect(HomeModule:register({}) == false, "home module should be skipped without SimpleUI")

local registered_actions, registered_modules = {}, {}
package.preload["features/sui_quickactions"] = function()
    return { register = function(descriptor)
        registered_actions[descriptor.id] = descriptor
    end }
end
package.preload["modules/moduleregistry"] = function()
    return { register = function(mod) registered_modules[mod.id] = mod end }
end
package.preload["infra/sui_store"] = function()
    local values = {}
    return {
        readSetting = function(_self, key) return values[key] end,
        saveSetting = function(_self, key, value) values[key] = value end,
    }
end
package.preload["device"] = function()
    return { screen = {
        scaleBySize = function(_self, n) return n end,
        getWidth = function() return 600 end,
    } }
end

local opened, recommended = 0, 0
local plugin = {
    openBookshelf = function() opened = opened + 1 end,
    showRecommendations = function() recommended = recommended + 1 end,
}

expect(Actions:register(plugin) == true, "quick actions did not register")
local shelf = registered_actions["weread_bookshelf"]
local recs = registered_actions["weread_recommendations"]
expect(shelf and recs, "expected bookshelf and recommendations actions")
expect(shelf.icon and shelf.icon:match("icons/weread%-w%-book%.svg$"),
    "quick action did not use the WeRead icon")
expect(shelf.is_in_place == false, "quick action should open its own window")
shelf.execute()
recs.execute()
expect(opened == 1 and recommended == 1, "quick actions did not reach the plugin methods")
expect(Actions:register(plugin) == true and Actions.registered, "registration should be idempotent")

expect(HomeModule:register(plugin) == true, "home module did not register")
local registered_module = registered_modules["weread_shelf"]
local recommend_module = registered_modules["weread_recommend"]
expect(recommend_module and recommend_module.category == "books" and recommend_module.isEnabled("p_") == false,
    "recommendation module missing, mis-categorised or not default-off")
expect(recommend_module.getHeight({ pfx = "p_" }) == registered_module.getHeight({ pfx = "p_" }),
    "both home modules should share one height at the default row count")
recommend_module.setEnabled("p_", true)
expect(registered_module.isEnabled("p_") == false and recommend_module.isEnabled("p_") == true,
    "home module enable flags must be independent")
expect(registered_module.id == "weread_shelf" and registered_module.category == "books",
    "home module used the wrong id/category")
expect(registered_module.isEnabled("p_") == false, "home module must default to off")
registered_module.setEnabled("p_", true)
expect(registered_module.isEnabled("p_") == true, "home module enable toggle did not persist")
expect(type(registered_module.getHeight({ pfx = "p_" })) == "number"
        and registered_module.getHeight({ pfx = "p_" }) > 0,
    "home module height must be a positive number")
expect(registered_module.build(300, { pfx = "other_" }) == nil,
    "disabled home module must not build a widget")

-- A plugin without a shelf cache must not break the empty state decision.
expect(#HomeModule:_shelf() == 0, "missing library_db should yield an empty shelf")
plugin.library_db = { getShelf = function()
    return {
        { book_id = "MP_WXS_1", title = "article", progress = 5 },
        { book_id = "a", title = "unread" },
        { book_id = "b", title = "reading", progress = 30 },
    }
end }
local picked = HomeModule:_shelf()
expect(#picked == 2 and picked[1].book_id == "b" and picked[2].book_id == "a",
    "shelf should skip public accounts and list books in progress first")

-- Recommendations come from the local cache only.
expect(#HomeModule:_recommendations() == 0, "missing cache should yield no recommendations")
local fetched = false
plugin.library_db.getRecommendations = function()
    fetched = true
    return { { bookId = "1" }, { bookId = "2" }, { bookId = "3" }, { bookId = "4" }, { bookId = "5" } }
end
expect(#HomeModule:_recommendations() == 5 and fetched,
    "recommendations should return the whole cache; the row layout decides how many to draw")

-- Adaptive layout: covers fill the row at any width, columns follow the width.
for _i, width in ipairs({ 300, 450, 600, 777, 1200 }) do
    local lay = HomeModule.layout(width, 1)
    local used = lay.columns * lay.cover_w + (lay.columns - 1) * lay.gap
    expect(used <= width and width - used < lay.columns,
        "covers must fill the row width (width " .. width .. ", used " .. used .. ")")
    expect(lay.cover_h == math.floor(lay.cover_w * 3 / 2), "covers must keep a 2:3 ratio")
end
expect(HomeModule.layout(1200, 1).columns > HomeModule.layout(300, 1).columns,
    "a wider module should fit more columns")
expect(HomeModule.layout(10, 1).columns == 1 and HomeModule.layout(10, 1).cover_w >= 1,
    "a tiny width must still give one valid column")
expect(HomeModule.layout(600, 2).columns < HomeModule.layout(600, 1).columns,
    "a larger UI scale should fit fewer covers per row")
expect(HomeModule.layout(600, 1).cover_w > 80 * 0.9,
    "adaptive covers should not shrink far below the target width")

-- Window height follows the visible row count and is clamped to 1..3 (default 2).
local lay = HomeModule.layout(600, 1)
local h1, h2, h3 = HomeModule.window_height(lay, 1), HomeModule.window_height(lay, 2), HomeModule.window_height(lay, 3)
expect(h1 == lay.cell_h and h1 < h2 and h2 < h3, "more visible rows must reserve more height")
expect(HomeModule.window_height(lay, 0) == h1 and HomeModule.window_height(lay, 99) == h3
        and HomeModule.window_height(lay, nil) == h2,
    "visible rows must be clamped to 1..3 and default to 2")

-- Vertical scrolling: whole rows, clamped so the window never runs off the end.
local rows_total = HomeModule.total_rows(40, 4)
expect(rows_total == 10 and HomeModule.total_rows(41, 4) == 11 and HomeModule.total_rows(0, 4) == 0,
    "total row count is wrong")
expect(HomeModule.clamp_offset(0, 10, 2) == 0 and HomeModule.clamp_offset(-5, 10, 2) == 0,
    "scroll offset must not go above the first row")
expect(HomeModule.clamp_offset(8, 10, 2) == 8 and HomeModule.clamp_offset(99, 10, 2) == 8,
    "scroll offset must stop where the last row is still visible")
expect(HomeModule.clamp_offset(5, 2, 2) == 0 and HomeModule.clamp_offset(5, 0, 2) == 0,
    "a list that fits the window must not scroll")
expect(HomeModule.clamp_offset(nil, 10, 2) == 0, "missing offset must start at the top")

-- Scrollbar thumb: hidden when everything fits, sized by visibility, pinned at both ends.
expect(HomeModule.thumb(300, 2, 2, 0) == nil, "no scrollbar when the list fits the window")
local top0, size0 = HomeModule.thumb(300, 10, 2, 0)
local topN, sizeN = HomeModule.thumb(300, 10, 2, 8)
expect(top0 == 0 and size0 == 60 and size0 == sizeN, "thumb should be rows/total of the track")
expect(topN + sizeN == 300, "thumb must reach the bottom of the track at the last row")
local _t, tiny = HomeModule.thumb(300, 1000, 2, 0)
expect(tiny >= 37, "thumb must keep a usable minimum size")
local midTop = HomeModule.thumb(300, 10, 2, 4)
expect(midTop > top0 and midTop < topN, "thumb should move monotonically with the offset")

-- The visible-rows setting is persisted, clamped and exposed through a spin item.
local store = require("infra/sui_store")
store:saveSetting("r_weread_shelf_rows", 3)
local reserved = registered_module.getHeight({ pfx = "r_" })
store:saveSetting("r_weread_shelf_rows", 9)
expect(registered_module.getHeight({ pfx = "r_" }) == reserved, "out-of-range rows setting was not clamped")
package.preload["infra/sui_config"] = function()
    return { makeSpinItem = function(opts) return opts end }
end
local spin = registered_module.getMenuItems({ pfx = "r_", refresh = function() end })[1]
expect(spin.value_min == 1 and spin.value_max == 3 and spin.default_value == 2,
    "visible-rows spin item has the wrong bounds")
spin.set(1)
expect(spin.get() == 1 and registered_module.getHeight({ pfx = "r_" }) < reserved,
    "visible-rows spin item did not persist its value")
expect(registered_module.is_book_mod == true and recommend_module.is_book_mod == true,
    "modules must be book modules so SimpleUI can repaint them after a swipe")

print(("simpleui_integration_spec: %d checks"):format(checks))
