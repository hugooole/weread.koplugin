-- Optional SimpleUI integration: native Quick Actions with the WeRead icon.
-- SimpleUI's registries are not a stable public API, so every access is pcall-guarded.

local logger = require("weread.lib.logger")
local _ = require("weread.lib.plugin_util").tr

local source = debug.getinfo(1, "S").source or ""
local integration_dir = source:sub(1, 1) == "@"
    and source:sub(2):match("^(.*)/[^/]+$") or nil
local icon_path = integration_dir
    and integration_dir:gsub("/integrations$", "") .. "/icons/weread-w-book.svg"
    or nil

local Integration = {
    name = "simpleui",
    registered = false,
    plugin = nil,
}

-- Resolve the live plugin at click time: the FileManager and the reader each
-- own a separate plugin instance, and the one captured at registration may be gone.
function Integration:_livePlugin()
    local file_manager = package.loaded["apps/filemanager/filemanager"]
    local fm = file_manager and file_manager.instance
    if fm and type(fm.weread) == "table" then return fm.weread end
    return self.plugin
end

function Integration:_call(method)
    local plugin = self:_livePlugin()
    if not plugin or type(plugin[method]) ~= "function" then return false end
    plugin[method](plugin)
    return true
end

function Integration:_actions()
    return {
        {
            id = "weread_bookshelf",
            label = _("WeRead"),
            method = "openBookshelf",
        },
        {
            id = "weread_recommendations",
            label = _("Recommendations"),
            method = "showRecommendations",
        },
    }
end

function Integration:_tryRegister()
    if self.registered then return true end
    local ok, QA = pcall(require, "features/sui_quickactions")
    if not ok or type(QA) ~= "table" or type(QA.register) ~= "function" then
        return false
    end
    for _i, action in ipairs(self:_actions()) do
        QA.register({
            id = action.id,
            label = action.label,
            icon = icon_path,
            is_in_place = false,
            execute = function()
                return self:_call(action.method)
            end,
        })
    end
    self.registered = true
    logger.info("weread: registered SimpleUI quick actions")
    return true
end

function Integration:register(plugin)
    self.plugin = plugin
    return self:_tryRegister()
end

return Integration
