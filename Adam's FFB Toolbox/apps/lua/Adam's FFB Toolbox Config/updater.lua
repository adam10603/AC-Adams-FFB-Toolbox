local _json = require "json"

local M = {}

local versionRequestURL = "https://api.github.com/repos/adam10603/AC-Adams-FFB-Toolbox/releases?per_page=1"
local versionRequestHeaders = {
    ["Accept"]               = "application/vnd.github+json",
    ["X-GitHub-Api-Version"] = "2026-03-10"
}

M.versionStringToNumber = function(str)
    local mult          = 10000
    local versionNumber = 0
    for c in str:gmatch("%d") do
        versionNumber = versionNumber + mult * tonumber(c)
        mult = mult / 10
    end
    return versionNumber
end

M.getCurrentVersionString = function()
    local manifest = ac.INIConfig.load("manifest.ini", ac.INIFormat.Extended)

    local versionString = manifest:get("ABOUT", "VERSION", "")

    if versionString == nil or versionString == "" then return "" end

    return versionString
end

---@param callback fun(versionString: string, releaseNotes: string, downloadURL: string)
M.getLatestVersion = function(callback)

    -- callback("1.5.6", " - Testing\r\n - Patch notes")

    web.get(versionRequestURL, versionRequestHeaders, function (err, response)
        if (err ~= nil and err ~= "") or response.status ~= 200 then
            ac.error("Failed to retrieve the latest version string.")
            return
        end

        local parsed = _json.decode(response.body)

        if parsed[1] and type(parsed[1]["tag_name"]) == "string" and type(parsed[1]["body"]) == "string" and type(parsed[1]["assets"]) == "table" and type(parsed[1]["assets"][1]) == "table" and type(parsed[1]["assets"][1]["browser_download_url"]) == "string" then
            local tag = parsed[1]["tag_name"]
            if string.startsWith(tag, "v") then tag = tag:sub(2) end
            callback(tag, parsed[1]["body"], parsed[1]["assets"][1]["browser_download_url"])
            return
        end

        ac.error("Invalid response when retrieving the latest version string")
    end)
end

-- M.performUpdate = function(downloadURL)
--     web.loadRemoteAssets(downloadURL, function (err, folder)
--         ac.log(err)
--         ac.log(folder)
--     end)
-- end

return M