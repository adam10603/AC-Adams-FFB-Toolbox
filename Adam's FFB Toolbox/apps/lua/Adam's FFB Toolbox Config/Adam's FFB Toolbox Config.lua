-- csp doesnt install the files in the right location, so i have to move the folder like this, very fun

local badModulePath = ac.getFolder(ac.FolderID.ExtRoot) .. "\\ffb-postprocess\\Adam's FFB Toolbox"
local goodModulePath = ac.getFolder(ac.FolderID.ExtLua) .. "\\ffb-postprocess\\Adam's FFB Toolbox"
local badModuleDirExists = io.dirExists(badModulePath)
local goodModuleDirExists = io.dirExists(goodModulePath)
if badModuleDirExists and not goodModuleDirExists then
    io.move(badModulePath, goodModulePath)
elseif badModuleDirExists and goodModuleDirExists then
    local anyCopyFailed = false
    io.scanDir(badModulePath, nil, function (fileName, fileAttributes, callbackData)
        local badFilePath = badModulePath .. "\\" .. fileName
        local goodFilePath = goodModulePath .. "\\" .. fileName
        if not fileAttributes.isDirectory and (fileAttributes.creationTime > io.getAttributes(goodFilePath).creationTime) then
            if not io.move(badFilePath, goodFilePath, true) then
                anyCopyFailed = true
            end
        end
    end)

    io.deleteDir(badModulePath)

    if anyCopyFailed then
        ac.error("Plugin cant be updated, blame Ilja")
        ac.setMessage("Adam's FFB Toolbox", "ERROR: Failed to update plugin. Check the mod's page for solutions.", 'illegal', 10.0)
    else
        -- io.deleteDir(badModulePath)
        ac.log("Plugin updated")
    end
end

-- ... onto the rest of the script

local updater = require("updater")
-- local json = require("json")
---@diagnostic disable-next-line: different-requires
local lib = require("../../../extension/lua/ffb-postprocess/Adam's FFB Toolbox/AGALib2")
---@diagnostic disable-next-line: different-requires
local storage = require("../../../extension/lua/ffb-postprocess/Adam's FFB Toolbox/Storage")

local generalConfig = ac.connect(storage.generalConfig)
local carSpecificConfig = ac.connect(storage.carSpecificConfig)
local runtimeData = ac.connect(storage.runtimeData)

local graphWindowMinSize = vec2(300, 150)
local graphWindowMaxSize = vec2(600, 300)
local graphStrokeWidthAtMinSize = 1.5
local ffbGraphPointCount = 333 * 3 / storage.ffbSampleRateDiv

ffbGraphPointCount = math.min(ffbGraphPointCount, storage.ffbHistoryBufferCapacity)

local defaultAppConfig = {
    firstInstallPassed = false, -- set to true once the intro screen is passed for the first time
    biggerFont = false,
    graphZoomed = false,
    graphRawPlot = true,
    graphFinalPlot = true,
    graphWindowPos = vec2(800, 450),
    graphWindowSize = vec2(400, 200),
    graphWindowShowClipping = false,
    graphWindowAlwaysOnTop = false,
    showGraphWindow = false
}

local appConfig = ac.storage(table.clone(defaultAppConfig, "full"), "AFFBT_APP_")

-- appConfig.graphWindowSize = graphWindowDefaultSize

local function getConfigValue(key) -- includes car overrides
    if carSpecificConfig["OVERRIDE_" .. key] == true then
        return carSpecificConfig[key]
    end

    return generalConfig[key]
end

local gameConfigIOMinTime = 0.5

local gameConfigFiles = {}

local function readGameConfigFiles()
    gameConfigFiles["controls.ini"] = ac.INIConfig.load(ac.getFolder(ac.FolderID.Cfg) .. "\\controls.ini")
    -- gameConfigFiles["ffb_tweaks.ini"] = ac.INIConfig.load(ac.getFolder(ac.FolderID.ExtCfgUser) .. "\\ffb_tweaks.ini")
    gameConfigFiles["ffb_tweaks.ini"] = ac.INIConfig.cspModule(ac.CSPModuleID.FFBTweaks)
end

local gameConfigSuggestions = {} -- wont necessarily suggest all of these (see table below), but this also serves as the main list of game settings to hook into
gameConfigSuggestions["controls.ini:STEER:FF_GAIN"] = 0.5
gameConfigSuggestions["controls.ini:FF_ENHANCEMENT:CURBS"] = 0.4
gameConfigSuggestions["controls.ini:FF_ENHANCEMENT:ABS"] = 0.0
gameConfigSuggestions["controls.ini:FF_ENHANCEMENT:ROAD"] = 0.0
gameConfigSuggestions["controls.ini:FF_ENHANCEMENT:SLIPS"] = 0.0
gameConfigSuggestions["controls.ini:FF_TWEAKS:CENTER_BOOST_RANGE"] = 0.0
gameConfigSuggestions["controls.ini:FF_TWEAKS:CENTER_BOOST_GAIN"] = 0.0
gameConfigSuggestions["ffb_tweaks.ini:POSTPROCESSING:RANGE_COMPRESSION"] = 1.0
gameConfigSuggestions["ffb_tweaks.ini:POSTPROCESSING:RANGE_COMPRESSION_ASSIST"] = 0.0

-- this determines which values to actually suggest in the app, otherwise the suggestion value is just use as a default / type reference
local gameConfigSuggestionsConsidered = {}
gameConfigSuggestionsConsidered["controls.ini:FF_ENHANCEMENT:ABS"] = true
gameConfigSuggestionsConsidered["controls.ini:FF_ENHANCEMENT:ROAD"] = true
gameConfigSuggestionsConsidered["controls.ini:FF_ENHANCEMENT:SLIPS"] = true
gameConfigSuggestionsConsidered["controls.ini:FF_TWEAKS:CENTER_BOOST_RANGE"] = true
gameConfigSuggestionsConsidered["controls.ini:FF_TWEAKS:CENTER_BOOST_GAIN"] = true
gameConfigSuggestionsConsidered["ffb_tweaks.ini:POSTPROCESSING:RANGE_COMPRESSION"] = true
gameConfigSuggestionsConsidered["ffb_tweaks.ini:POSTPROCESSING:RANGE_COMPRESSION_ASSIST"] = true

local gameConfigNames = {}
gameConfigNames["controls.ini:STEER:FF_GAIN"] = "Global FFB gain"
gameConfigNames["controls.ini:FF_ENHANCEMENT:CURBS"] = "Kerb effect"
gameConfigNames["controls.ini:FF_ENHANCEMENT:ABS"] = "ABS effect"
gameConfigNames["controls.ini:FF_ENHANCEMENT:ROAD"] = "Road effect"
gameConfigNames["controls.ini:FF_ENHANCEMENT:SLIPS"] = "Slip effect"
gameConfigNames["controls.ini:FF_TWEAKS:CENTER_BOOST_RANGE"] = "Center boost range"
gameConfigNames["controls.ini:FF_TWEAKS:CENTER_BOOST_GAIN"] = "Center boost gain"
gameConfigNames["ffb_tweaks.ini:POSTPROCESSING:RANGE_COMPRESSION"] = "FFB Tweaks: Range compression"
gameConfigNames["ffb_tweaks.ini:POSTPROCESSING:RANGE_COMPRESSION_ASSIST"] = "FFB Tweaks: Range compression assist"

local function deconstructGameConfigKey(combinedGameConfigKey)
    local ret = {}
    for token in string.gmatch(combinedGameConfigKey, "[^:]+") do
        table.insert(ret, token)
    end
    return ret[1], ret[2], ret[3]
end

local function constructGameConfigKey(fileName, section, key)
    return fileName .. ":" .. section .. ":" .. key
end

local currentGameConfigValues = {}

local function readGameConfigValues()
    readGameConfigFiles()
    for k, v in pairs(gameConfigSuggestions) do
        local iniFile, iniSection, iniKey = deconstructGameConfigKey(k)
        currentGameConfigValues[k] = gameConfigFiles[iniFile]:get(iniSection, iniKey, v)
    end
end

readGameConfigValues()

local lastGameConfigWrite = -1
local function saveGameConfigValues(forced) -- also performs a read to keep up with values being changed from other apps or csp itself
    local currentTime = ui.time()

    if not forced and (currentTime - lastGameConfigWrite) < gameConfigIOMinTime then
        return
    end

    lastGameConfigWrite = currentTime

    local modifiedIniFiles = {}
    local reloadControls = false

    for k, v in pairs(gameConfigSuggestions) do
        local iniFile, iniSection, iniKey = deconstructGameConfigKey(k)
        local currentIniValue = gameConfigFiles[iniFile]:get(iniSection, iniKey, v)
        if math.abs(currentIniValue - currentGameConfigValues[k]) > 1e-6 then
            gameConfigFiles[iniFile]:set(iniSection, iniKey, currentGameConfigValues[k])
            modifiedIniFiles[iniFile] = true
            reloadControls = true
        end
    end

    for iniFile, _ in pairs(modifiedIniFiles) do
        gameConfigFiles[iniFile]:save()
    end

    if reloadControls then
        ac.reloadControlSettings()
    end

    readGameConfigValues()
end

ac.onSharedEvent("AFFBT_setFFBMultiplier", function (data)
    if type(data) == "number" then
        ac.setFFBMultiplier(data)
    end
end)

local tooltips = {
    scriptEnabled = "Toggles all FFB processing by this plugin.\nTurning this off leaves the FFB signal unchanged.",
    factoryReset = "Resets all settings to default and removes every per-car config, but keeps your presets.\n\nClick twice to confirm!",
    resetCarSetting = "Removes the car-specific override from this setting.",
    autoAdjustGain = "Automatically sets your per-car FFB gain to the recommended value below.\n\nThe recommended gain will bring the car's actual FFB level in line with your global FFB gain setting.\n\nThis makes the FFB strength feel more consistent across different cars.\n\nWARNING: Avoid using other auto-gain apps when this setting is active, they might conflict with each other.",
    autoGainOffset = "Changes the level that the automatic gain targets.",
    absFilterEnabled = "Applies a small amount of filtering to the FFB only while the ABS is active.\n\nThis will reduce ABS vibrations in your wheel when you're braking, but won't change the FFB in any other situation.\n\nThis is separate from the general filter setting below, the two can be used at the same time.",
    filterEnabled = "Enables the general smoothing of the FFB signal through a low-pass filter.\n\nFiltering can help to reduce unwanted noise or high-frequency vibrations.\n\nThis is separate from AC's built-in filter setting, and using both at the same time is not recommended.",
    filterFrequency = "Lower = more filtering and a smoother FFB signal.",
    downforceCompMode = "Allows you to reduce or remove the extra heaviness in the FFB caused by downforce / aero.\n\nThis is useful for less powerful wheelbases, as it reduces the chance of clipping at high speed.\n\nOnly the general heaviness added by downforce is compensated for, which means grip changes and all other information in the FFB will remain intact.\n\nThis setting has two modes:\n\nPercentage mode = simply lets you choose what % of the car's downforce you want to feel.\n\nDynamic mode (EXPERIMENTAL!) = allows you to set a maximum preferred downforce feel. Cars with less downforce than this remain unchanged. Cars with more downforce than your preference will have their downforce feel scaled down accordingly. This is basically an \"automatic\" mode that adapts to each car.",
    downforceCompPercentage = "How much of the car's downforce you want to feel.\n\n100% = no change, all downforce is felt normally.\n\n0% = all downforce feel is removed, which makes the FFB strength equal at low and high speeds.",
    downforceCompDynamicRange = "The maximum dynamic range* you wish to feel.\n\nCars with less dynamic range than this won't be affected. Cars with more dynamic range than this will have their downforce feel scaled down to match this level.\n\nSet this to a level that you and your wheelbase are OK with, and any car you drive will be adjusted automatically without needing car-specific settings.\n\nFor example if you set this to 0.7 (roughly GT3 level of downforce) then road cars with less aero will be unchanged, but an F1 car will feel as if it only had the downforce of a GT3 car.\n\n*: \"Dynamic range\" is a metric calculated per-car based on the downforce level at top speed. GT3 cars are around 0.7, and F1 cars are around 2.5.",
    downforceCompMakeupGain = "If you reduce downforce in your FFB, this setting will compensate by increasing the overall FFB level accordingly.\n\nThis makes it so the FFB strength at ≈70% of the car's top speed will stay consistent regardless of the downforce settings above.",
    brakeFeel = "Makes the FFB stronger proportional to the braking done by the front wheels.\n\nThis provides additional brake feedback by letting you feel the braking force through your wheel.\n\nCan be especially useful in cars with no ABS.\n\nIt is recommended to also use the lockup feel setting together with this one.",
    brakeFeelWithABS = "Disables the brake feel effect when ABS is present.", -- inverted on ui
    brakeFeelFilter = "Applies a small amount of filtering only to the additional force from the brake feel effect.\n\nNormally the brake feel effect can amplify the feeling of bumps, curbs and other vibrations while braking, which this setting helps to reduce.",
    brakeFeelExponent = "Changes the response curve of the brake feel setting.\n\nUnder 1.0 = the brake feel comes in sooner, but changes less near the maximum.\n\n1.0 = linear response.\n\nOver 1.0 = the brake feel comes in slower at first, but changes faster near the maximum. This can give a more obvious feel in the zone where lockups can happen.",
    brakeFeelMakeupGain = "If you add extra brake feel force, this setting will compensate by decreasing the overall FFB level accordingly.",
    lockupFeel = "Reduces FFB strength when the front wheels lock up.\n\nThis also happens naturally, but this setting will exaggerate the effect.\n\nThis effect is highly recommended if you're also using the brake feel setting, since that setting alone only communicates lockups to a limited extent.",
    lockupFeelWithABS = "Disables the lockup feel effect when ABS is present.\n\nThis will avoid the FFB strength fluctuating even if the ABS momentarily goes over the grip limit slightly.", -- inverted on ui
    extraSAT = "Adds extra self-aligning torque (SAT) to the FFB.\n\nSAT is the part of the FFB that makes the initial force stronger when turning in, then reduce as you steer more and reach the grip limit of the tires.\n\nThis setting will add additional SAT on top of the amount already in the FFB, making it easier to feel the grip limit of the tires and to feel understeer.\n\nThis can be especially useful in cars with a high caster angle.",
    extraSATSuspensionCompensation = "The amount of extra SAT will be scaled according to the car's suspension geometry.\n\nIf a car has weak SAT by default then the added amount will be higher. If a car already has a strong SAT feeling then the added amount will be much less.\n\nThis means the extra SAT you add will feel more consistent across different cars.",
    extraSATMakeupGain = "If you add extra SAT to the FFB, this setting will compensate by decreasing the overall FFB level accordingly.\n\nThis basically turns the extra SAT into something similar to AC's understeer effect.",
    oversteerFeel = "Makes your wheel pull stronger in the countersteer direction when the car slides / oversteers.",
    oversteerFeelAggression = "Determines how large a slide has to be for the oversteer effect to kick in.\n\nLower = the effect already engages in a shallow slide.\n\nHigher = a bigger slide is needed to trigger the effect.",
    oversteerFeelMakeupGain = "If you add extra oversteer force, this setting will compensate by decreasing the overall FFB level accordingly.",
    vibrationSource = "Selects what triggers the vibration effect.\n\nBraking help = progressive vibration during braking when there's no ABS. Starts lighter then gets stronger as you approach the point of locking up.\n\nThrottle help = progressive vibration during acceleration when there's no TCS. Starts lighter then gets stronger as you approach the point of wheelspin.\n\nBraking + throttle help = both of the above, depending on whether you're braking or accelerating.\n\nUndersteer = progressive vibration to warn if you're steering too much. This one starts right around the grip limit and gets stronger the more you push into understeer.\n\nGear shift warning = vibration to signal the need to shift up. This is based on shifting points calculated from the engine's power curve and the gear ratios of the car, or if these can't be calculated then the car's default shifting point is used. The vibration warning is timed in a way that accounts for reaction time, so you'll shift at the correct point by just reacting to it without having to anticipate it.\n\nFor best results AC's own slip effect should be turned off to avoid it conflicting with this vibration effect.",
    vibrationLevel = "The strength of the vibration effect.",
    vibrationBaseFrequency = "The frequency of the vibration effect.\n\nThe actual frequency of the vibration output might be modulated further depending on the vibration source, but this setting is always used as the baseline.",
    peakReduction = "Temporarily filters out sudden peaks from the FFB when a collision is detected.\n\nThis helps to avoid unpleasant or dangerous jolts in your wheel when hitting a wall or another car.",
    ffbLevelAfterFinish = "When you finish a race and get the checkered flag, your FFB strength will be reduced to this level. Upon returning to the pits your FFB will be restored to normal.\n\nThis is for preventing your wheel from going crazy if another car decides to hit you after the race ends, as they sometimes do.\n\n100% = no change.\n\nUnder 100% = reduced FFB post-race (until pitting).",
    fixExtraSettings = "", -- added dynamically in code
    ffbGain = "Controls the FFB multiplier of the current car.",
    DISABLED_ffbGain = "Not available when using \"auto-adjust gain\".\n\nUse the \"auto-gain offset\" setting instead!",
    graphRawPlot = "Adds a graph plot showing the original FFB from AC.",
    graphFinalPlot = "Adds a graph plot showing the final FFB with all the processing from this plugin applied.",
    graphRange = "Changes the scale of the vertical axis of the graph.\n\nNormal = shows the full range of the FFB signal.\n\nZoomed = makes the graph more readable if you use a low FFB strength, but the top and bottom will be cut off.",
    graphWindowShowClipping = "Turns the background of the graph window red if clipping happens.\n\nQuick momentary clipping is usually fine, but if you experience clipping for sustained periods while cornering then you should lower your FFB strength.",
    graphWindowAlwaysOnTop = "Forces the graph window to be drawn on top of other UI apps."
}

tooltips["controls.ini:STEER:FF_GAIN"] = "Your global FFB level that isn't specific to the car."
tooltips["controls.ini:FF_ENHANCEMENT:CURBS"] = "Adds a vibration effect to curbs that don't have 3D bumps.\n\nAround 40% makes the strength of this match the feel of 3D curbs, which makes curbs feel more consistent.\n\nHowever, this also gets applied on surfaces such as cobblestone, so vintage road courses for example could feel more bumpy than they really are when using this."
tooltips["controls.ini:FF_ENHANCEMENT:ABS"] = "Adds additional vibration when the ABS is active.\n\nHowever, since the ABS in AC produces very crude brake pressure pulses, it can already be felt very clearly in the FFB without needing any extra vibrations."
tooltips["controls.ini:FF_ENHANCEMENT:ROAD"] = "Adds a randomized vibration to the FFB at all times.\n\nIn theory this is there to make flat surfaces feel less boring, but in practice it just adds a very high frequency noise that I don't recommend using."
tooltips["controls.ini:FF_ENHANCEMENT:SLIPS"] = "Adds a vibration effect when the tires go over the grip limit.\n\nThis can generally be useful, however, this plugin provides better alternatives under the haptics section.\n\nKeep this at 0% if you intend to use the haptics from this plugin instead."
tooltips["controls.ini:FF_TWEAKS:CENTER_BOOST_RANGE"] = "This has to do with increasing the FFB when the wheel is centered, but I wouldn't recommend using it."
tooltips["controls.ini:FF_TWEAKS:CENTER_BOOST_GAIN"] = "This has to do with increasing the FFB when the wheel is centered, but I wouldn't recommend using it."
tooltips["ffb_tweaks.ini:POSTPROCESSING:RANGE_COMPRESSION"] = "Attempts to compress the FFB range to avoid clipping on high-downforce cars for example.\n\nHowever, this plugin provides a much better way of doing that, therefore I recommend not using this setting."
tooltips["ffb_tweaks.ini:POSTPROCESSING:RANGE_COMPRESSION_ASSIST"] = "Attempts to compress the FFB range to avoid clipping on high-downforce cars for example.\n\nHowever, this plugin provides a much better way of doing that, therefore I recommend not using this setting."

local sectionPadding = 10
local sliderRightPadding = sectionPadding + 21

local black                = rgbm(0.0, 0.0, 0.0, 1.0)
local white                = rgbm(1.0, 1.0, 1.0, 1.0)
local gray                 = rgbm(0.5, 0.5, 0.5, 1.0)
local controlHoverColor    = rgbm(0.5, 0.5, 0.5, 1.0)
local controlAccentColor   = rgbm(59/255, 159/255, 255/255, 1)
local controlActiveColor   = rgbm(59/255, 159/255, 255/255, 0.4)
local badInputColor        = rgbm(0.5, 0.0, 0.0, 0.6667)
local buttonColor          = rgbm(0.4, 0.4, 0.4, 0.75)
local childBgColor         = rgbm(0.0, 0.0, 0.0, 0.2)
local scrollBarBgColor     = rgbm(0.0, 0.0, 0.0, 0.4)
local scrollBarColor       = buttonColor
local scrollBarHoverColor  = controlHoverColor
local scrollBarActiveColor = controlAccentColor

local graphPadding = 16
local graphBgColor = rgbm(0.0, 0.0, 0.0, 0.4)
local graphBgClippingColor = rgbm(0.5, 0.0, 0.0, 0.6667)
local graphTextColor = rgbm(1.0, 1.0, 1.0, 0.5)
local graphResizeHandleColor = rgbm(1.0, 1.0, 1.0, 0.125)
local graphPlotColors = { rgbm(1.0, 0.0, 0.0, 1.0), controlAccentColor }

local styleColors = {
    { ui.StyleColor.Button, buttonColor },
    { ui.StyleColor.ButtonHovered, controlHoverColor },
    { ui.StyleColor.FrameBgHovered, controlHoverColor },
    { ui.StyleColor.CheckMark, controlAccentColor },
    { ui.StyleColor.ButtonActive, controlActiveColor },
    { ui.StyleColor.FrameBgActive, controlActiveColor },
    { ui.StyleColor.SliderGrab, buttonColor },
    { ui.StyleColor.SliderGrabActive, controlAccentColor },
    { ui.StyleColor.HeaderHovered, controlHoverColor },
    { ui.StyleColor.HeaderActive, controlActiveColor },
    { ui.StyleColor.TextSelectedBg, controlAccentColor },
    { ui.StyleColor.ChildBg, childBgColor },
    { ui.StyleColor.TabActive, controlAccentColor },
    { ui.StyleColor.TabHovered, controlHoverColor },
    { ui.StyleColor.ScrollbarBg, scrollBarBgColor },
    { ui.StyleColor.ScrollbarGrab, scrollBarColor },
    { ui.StyleColor.ScrollbarGrabHovered, scrollBarHoverColor },
    { ui.StyleColor.ScrollbarGrabActive, scrollBarActiveColor }
}

local function pushStyle()
    ui.pushFont(appConfig.biggerFont and ui.Font.Main or ui.Font.Small)

    for _, styleColor in ipairs(styleColors) do
        ui.pushStyleColor(styleColor[1], styleColor[2])
    end
end

local function popStyle()
    ui.popStyleColor(#styleColors)
    ui.popFont()
end

local zeroVec = vec2() -- Do not modify
local tmpVec1 = vec2()
local tmpVec2 = vec2()
local tmpVec3 = vec2()

local factoryPresets = {}
factoryPresets["Author's preference"] = '{"extraSAT":1.5,"filterFrequency":32,"extraSATSuspensionCompensation":true,"extraSATMakeupGain":true,"oversteerFeel":0.69999998807907,"autoAdjustGain":true,"oversteerFeelMakeupGain":false,"_version":100,"downforceCompMode":2,"lockupFeelWithABS":false,"downforceCompPercentage":1,"ffbLevelAfterFinish":0.050000000745058,"oversteerFeelAggression":1,"downforceCompDynamicRange":1.2999999523163,"vibrationBaseFrequency":15,"downforceCompMakeupGain":true,"brakeFeelFilter":true,"brakeFeel":0.69999998807907,"filterEnabled":false,"brakeFeelExponent":2,"vibrationSource":2,"brakeFeelWithABS":true,"vibrationLevel":0.18000000715256,"autoGainOffset":0,"brakeFeelMakeupGain":false,"absFilterEnabled":true,"lockupFeel":0.80000001192093,"peakReduction":true}'

-- Checking if a new version is available

local newVersionAvailable = false

updater.getLatestVersion(function (versionString, releaseNotes, downloadURL)
    local currentVersion = updater.versionStringToNumber(updater.getCurrentVersionString())
    local latestVersion = updater.versionStringToNumber(versionString)

    if currentVersion ~= 0 and latestVersion ~= 0 and latestVersion > currentVersion and releaseNotes ~= "" and downloadURL ~= "" then
        newVersionAvailable = true
        tooltips["releaseNotes"] = "Release notes for version " .. versionString .. ":\n\n" .. releaseNotes
        -- newVersionURL = downloadURL
    end
end)

local function isPresetNameValid(presetName)
    return presetName:match("^[%w _%-%']+$")
end

local storedPresetList = {}
local storedPaddedPresetList = {} -- avoids unnecessary allocations on the presets ui page
local lastPresetScan = -1
local function getPresetList()
    local currentTime = ui.time()

    if (currentTime - lastPresetScan) < 2.0 then -- throttling dir scans to every 2 seconds
        return storedPresetList, storedPaddedPresetList
    end

    lastPresetScan = currentTime

    local presetsDir = storage.getUserPresetsDirectory()
    table.clear(storedPresetList)
    table.clear(storedPaddedPresetList)

    for presetName, _ in pairs(factoryPresets) do
        table.insert(storedPresetList, "*" .. presetName)
    end

    io.scanDir(presetsDir, "*.json", function (fileName, fileAttributes)
        table.insert(storedPresetList, fileName:sub(1, #fileName - 5))
    end)

    storedPaddedPresetList = table.map(storedPresetList, function (item)
        return " " .. item
    end)

    return storedPresetList, storedPaddedPresetList
end

local function markPresetCacheDirty()
    lastPresetScan = -1
end

local function loadPreset(presetName)
    local presetJSON = nil

    if factoryPresets[presetName] then
        presetJSON = factoryPresets[presetName]
    else
        local presetPath = storage.getUserPresetsDirectory() .. "\\" .. presetName .. ".json"
        presetJSON = storage.readFile(presetPath)
    end

    if type(presetJSON) ~= "string" or string.len(presetJSON) < 5 then
        return false
    end

    return storage.parseAndLoadSettingsJSON(generalConfig, presetJSON, storage.presetKeys, storage.versionMigration)
end

local function deletePreset(presetName)
    local presetPath = storage.getUserPresetsDirectory() .. "\\" .. presetName .. ".json"
    local ret = false

    if io.fileExists(presetPath) then
        ret = io.deleteFile(presetPath)
    end

    if ret then
        markPresetCacheDirty()
    end

    return ret
end

local function savePreset(presetName)
    if factoryPresets[presetName] then
        return false
    end

    local presetPath = storage.getUserPresetsDirectory() .. "\\" .. presetName .. ".json"

    local content = storage.serializeSettingsJSON(generalConfig, storage.presetKeys, storage.versionStamp)

    if not content then
        return false
    end

    if not storage.writeFile(presetPath, content) then
        return false
    end

    markPresetCacheDirty()
    return true
end

local enableClicked = 0
local function enableScript()
    -- applying settings

    gameConfigFiles["ffb_tweaks.ini"]:set("POSTPROCESSING_SCRIPT", "IMPLEMENTATION", "Adam's FFB Toolbox")
    gameConfigFiles["ffb_tweaks.ini"]:set("POSTPROCESSING_SCRIPT", "ENABLED", 1)
    gameConfigFiles["ffb_tweaks.ini"]:set("BASIC", "ENABLED", 1)
    gameConfigFiles["ffb_tweaks.ini"]:save()

    enableClicked = os.clock()

    -- csp cannot keep its ini formats consistent with itself so i have to do this jank shit here, very fun once again

    local iniPath = ac.getFolder(ac.FolderID.ExtCfgUser) .. "\\ffb_tweaks.ini"
    local iniContents = storage.readFile(iniPath)

    if type(iniContents) == "string" then
        iniContents = iniContents:replace("IMPLEMENTATION='Adam\\'s FFB Toolbox'", "IMPLEMENTATION=Adam's FFB Toolbox")
        storage.writeFile(iniPath, iniContents)
    end

    gameConfigFiles["ffb_tweaks.ini"] = ac.INIConfig.cspModule(ac.CSPModuleID.FFBTweaks) -- not necessary but just to be sure

    -- fr tho Ilja gets tens of thousands of $ every month on pateron and half the shit he makes doesnt fucking work so i have to find all kinds of workarounds for everything
    -- half the api in csp is also completely fucking broken and full of events that dont fire, variables that have the wrong values etc.
    -- did i even mention that the reason i include an open source json library with my mods is because the json parsing built into csp is (or at least was) broken? thats fun too
    -- not the kind of work id award millions to, but what do i know
    -- anyway hopefully this works, and if it doesnt then go bother Ilja about it not me

    ac.reloadControlSettings()
end

local function loadDefaultSettings()
    pcall(function ()
        for k, v in pairs(storage.defaultSettings) do
            generalConfig[k] = v
        end

        for k, v in pairs(storage.defaultCarSpecificSettings) do
            carSpecificConfig[k] = v
        end
    end)
end

local function factoryReset()
    loadDefaultSettings()

    for k, v in pairs(defaultAppConfig) do
        if vec2.isvec2(v) or vec3.isvec3(v) or rgbm.isrgbm(v) then
---@diagnostic disable-next-line: param-type-mismatch
            appConfig[k]:set(v)
        else
            appConfig[k] = v
        end
    end

    runtimeData.factoryResetPerformed = true
end

local function addTooltipToLastItem(tooltipKey, disabled)
    if ui.itemHovered() and tooltipKey then
        if disabled then
            local disabledKey = "DISABLED_" .. tooltipKey

            if tooltips[disabledKey] then
                ui.setTooltip(tooltips[disabledKey])
                return
            end
        end

        if tooltips[tooltipKey] then
            ui.setTooltip(tooltips[tooltipKey])
            return
        end
    end
end

local function showCheckbox(cfgTable, cfgKey, name, inverted, disabled, textColor, indent)
    indent = indent or sectionPadding
    local val = not cfgTable[cfgKey]
    if not inverted then val = not val end
    ui.offsetCursorX(indent)
    if disabled then ui.pushDisabled() end
    if textColor then ui.pushStyleColor(ui.StyleColor.Text, textColor) end
    ui.pushID("CHECKBOX_" .. cfgKey)
    if ui.checkbox(name, val) and not disabled then
        cfgTable[cfgKey] = not cfgTable[cfgKey]
    end
    ui.popID()
    if textColor then ui.popStyleColor(1) end
    if disabled then ui.popDisabled() end
    addTooltipToLastItem(cfgKey)
end

local function showConfigSlider(cfgTable, cfgKey, name, format, minVal, maxVal, displayValueMult, width, indent, disabled, textColor, onInteract, onHover)
    displayValueMult = displayValueMult or 1.0
    indent = indent or sectionPadding
    width = width or ui.availableSpaceX()
    local displayVal = cfgTable[cfgKey] * displayValueMult
    ui.offsetCursorX(indent)
    ui.setNextItemWidth(width - indent)
    if disabled then ui.pushDisabled() end
    if textColor then ui.pushStyleColor(ui.StyleColor.Text, textColor) end
    local value, changed = ui.slider("##" .. cfgKey, displayVal, minVal, maxVal, name .. ": " .. format)
    if textColor then ui.popStyleColor(1) end
    if disabled then ui.popDisabled() end
    value = math.clamp(value, minVal, maxVal) / displayValueMult
    local changedFr = math.abs(value - displayVal) > (1e-5 * (maxVal - minVal))
    local isHovered = ui.itemHovered()
    local isActive = ui.itemActive()
    if not isActive then addTooltipToLastItem(cfgKey, disabled) end
    if onHover and isHovered then onHover() end
    if onInteract and isActive then onInteract() end
    local newValue = changedFr and value or (math.clamp(displayVal, minVal, maxVal) / displayValueMult)
    if changedFr then
        cfgTable[cfgKey] = newValue
    end
    return newValue
end

local function showDummyLine(lineHeightMult)
    lineHeightMult = lineHeightMult or 1.0
    ui.dummy(tmpVec1:set(ui.availableSpaceX(), ui.frameHeight() * lineHeightMult))
end

local function showHeader(text)
    showDummyLine(0.25)
    ui.alignTextToFramePadding()
    ui.setNextTextBold()
    ui.textWrapped(text)
end

local function showButton(text, iconButton, tooltipKey, callback, callbackData, indent, textColor)
    indent = indent or sectionPadding
    ui.offsetCursorX(indent)
    if textColor and not iconButton then
        ui.pushStyleColor(ui.StyleColor.Text, textColor)
    end
    local clicked = false
    if iconButton then
        clicked = ui.iconButton(text, nil, textColor)
    else
        clicked = ui.button(text, tmpVec1:set(ui.availableSpaceX() - indent, ui.frameHeight()))
    end
    if textColor and not iconButton then
        ui.popStyleColor(1)
    end
    addTooltipToLastItem(tooltipKey)
    if clicked and callback then callback(callbackData) end
    return clicked
end

local function showCompactDropdown(label, tooltipKey, values, selectedIndex, indent, textColor)
    indent = indent or sectionPadding
    ui.offsetCursorX(indent)
    ui.pushItemWidth(ui.availableSpaceX() * 0.5)
    if textColor then
        ui.pushStyleColor(ui.StyleColor.Text, textColor)
    end
    local selection = ui.combo(string.format("%s - %s", label, values[selectedIndex]), selectedIndex, ui.ComboFlags.NoPreview, values)
    if textColor then
        ui.popStyleColor(1)
    end
    addTooltipToLastItem(tooltipKey)
    ui.popItemWidth()
    return selection + 0
end

local function getSliderWidth(padding)
    padding = padding or sectionPadding
    return ui.availableSpaceX() - padding
end

-- returns whether the setting is displayed with an override value
local function overridableItemWrapper(perCarTab, cfgKey, drawItemCallback)
    local overrideKey = "OVERRIDE_" .. cfgKey
    local overrideActive = perCarTab and (carSpecificConfig[overrideKey] == true)
    local textColor = white
    local stylesPushed = 0
    local ret = false
    if perCarTab then
        ret = overrideActive
        if overrideActive then
            textColor = white
        else
            textColor = gray
            carSpecificConfig[cfgKey] = generalConfig[cfgKey] -- the actual ffb script doesnt depend on these being set to the global values if theres no override, this is just so the values on the ui make sense
        end
    end
    drawItemCallback(textColor)
    if perCarTab then
        if ui.itemActive() then
            carSpecificConfig[overrideKey] = true
            overrideActive = true
        end
        if overrideActive then
            ui.sameLine()
            ui.pushID("RESET_OVERRIDE_" .. cfgKey) -- this is necessary because otherwise the buttons end up having the same ID which makes them unclickable
            local resetClicked = showButton(ui.Icons.Restart, true, "resetCarSetting", nil, nil, -3)
            ui.popID()
            if resetClicked then
                overrideActive = false
                ret = false
                carSpecificConfig[overrideKey] = false
                carSpecificConfig[cfgKey] = generalConfig[cfgKey]
            end
        end
    end

    if stylesPushed > 0 then ui.popStyleColor(stylesPushed) end

    return ret
end

local function drawGainAndFilteringSection(perCarTab)
    local configTable = perCarTab and carSpecificConfig or generalConfig

    showHeader("Auto-adjust FFB gain:")
    overridableItemWrapper(perCarTab, "autoAdjustGain", function (textColor)
        showCheckbox(configTable, "autoAdjustGain", "Auto-adjust gain", false, false, textColor)
    end)
    if configTable.autoAdjustGain then
        overridableItemWrapper(perCarTab, "autoGainOffset", function (textColor)
            showConfigSlider(configTable, "autoGainOffset", "Auto-gain offset", "%.f%%", -50.0, 50.0, 100.0, getSliderWidth(sliderRightPadding), sectionPadding, false, textColor)
        end)
    end
    ui.pushStyleColor(ui.StyleColor.Text, controlAccentColor)
    ui.offsetCursorX(sectionPadding)
    ui.textWrapped((runtimeData.autoGainLevel < 0) and "Suggested car FFB gain: N/A" or string.format("Suggested car FFB gain: %d%%", runtimeData.autoGainLevel))
    ui.popStyleColor(1)

    showHeader("ABS filter:")
    overridableItemWrapper(perCarTab, "absFilterEnabled", function (textColor)
        showCheckbox(configTable, "absFilterEnabled", "Reduce ABS vibrations", false, false, textColor)
    end)

    showHeader("General filter:")
    overridableItemWrapper(perCarTab, "filterEnabled", function (textColor)
        showCheckbox(configTable, "filterEnabled", "Enable FFB filter", false, false, textColor)
    end)
    if configTable.filterEnabled then
        overridableItemWrapper(perCarTab, "filterFrequency", function (textColor)
            showConfigSlider(configTable, "filterFrequency", "Filter frequency", "%.f Hz", 10.0, 50.0, 1.0, getSliderWidth(sliderRightPadding), sectionPadding, false, textColor)
        end)
    end
end

local function drawGeneralForceSection(perCarTab)
    local configTable = perCarTab and carSpecificConfig or generalConfig

    showHeader("Downforce compensation:")
    overridableItemWrapper(perCarTab, "downforceCompMode", function (textColor)
        configTable.downforceCompMode = showCompactDropdown("Mode", "downforceCompMode", {"Off", "Percentage", "Dynamic"}, configTable["downforceCompMode"] + 1, sectionPadding, textColor) - 1
    end)
    if configTable.downforceCompMode == 1 then
        overridableItemWrapper(perCarTab, "downforceCompPercentage", function (textColor)
            showConfigSlider(configTable, "downforceCompPercentage", "Downforce feel", "%.f%%", 0.0, 100.0, 100.0, getSliderWidth(sliderRightPadding), sectionPadding, false, textColor)
        end)
    elseif configTable.downforceCompMode == 2 then
        overridableItemWrapper(perCarTab, "downforceCompDynamicRange", function (textColor)
            showConfigSlider(configTable, "downforceCompDynamicRange", "Dynamic range cap", "%.2f", 0.0, 2.5, 1.0, getSliderWidth(sliderRightPadding), sectionPadding, false, textColor)
        end)
        ui.pushStyleColor(ui.StyleColor.Text, controlAccentColor)
        ui.offsetCursorX(sectionPadding)
        ui.textWrapped((runtimeData.downforceDynamicRange < 0.0) and "Current car's dynamic range: N/A" or string.format("Current car's dynamic range: %.2f", runtimeData.downforceDynamicRange))
        ui.popStyleColor(1)
    end
    -- if configTable.downforceCompMode ~= 0 then
    overridableItemWrapper(perCarTab, "downforceCompMakeupGain", function (textColor)
        showCheckbox(configTable, "downforceCompMakeupGain", "Compensate FFB strength", false, false, textColor)
    end)
    -- end

    showHeader("Brake feel:")
    overridableItemWrapper(perCarTab, "brakeFeel", function (textColor)
        showConfigSlider(configTable, "brakeFeel", "Brake feel", "%.f%%", 0.0, 150.0, 100.0, getSliderWidth(sliderRightPadding), sectionPadding, false, textColor)
    end)
    overridableItemWrapper(perCarTab, "brakeFeelExponent", function (textColor)
        showConfigSlider(configTable, "brakeFeelExponent", "Brake feel exponent", "%.2f", 0.5, 2.5, 1.0, getSliderWidth(sliderRightPadding), sectionPadding, false, textColor)
    end)
    overridableItemWrapper(perCarTab, "brakeFeelWithABS", function (textColor)
        showCheckbox(configTable, "brakeFeelWithABS", "Disable if ABS is available", true, false, textColor)
    end)
    overridableItemWrapper(perCarTab, "brakeFeelFilter", function (textColor)
        showCheckbox(configTable, "brakeFeelFilter", "Filter brake forces", false, false, textColor)
    end)
    overridableItemWrapper(perCarTab, "brakeFeelMakeupGain", function (textColor)
        showCheckbox(configTable, "brakeFeelMakeupGain", "Compensate FFB strength", false, false, textColor)
    end)

    showHeader("Lockup feel:")
    overridableItemWrapper(perCarTab, "lockupFeel", function (textColor)
        showConfigSlider(configTable, "lockupFeel", "Lockup feedback", "%.f%%", 0.0, 100.0, 100.0, getSliderWidth(sliderRightPadding), sectionPadding, false, textColor)
    end)
    overridableItemWrapper(perCarTab, "lockupFeelWithABS", function (textColor)
        showCheckbox(configTable, "lockupFeelWithABS", "Disable if ABS is available", true, false, textColor)
    end)

    showHeader("Self-aligning torque:")
    overridableItemWrapper(perCarTab, "extraSAT", function (textColor)
        showConfigSlider(configTable, "extraSAT", "Extra SAT", "%.f%%", 0.0, 300.0, 100.0, getSliderWidth(sliderRightPadding), sectionPadding, false, textColor)
    end)
    overridableItemWrapper(perCarTab, "extraSATSuspensionCompensation", function (textColor)
        showCheckbox(configTable, "extraSATSuspensionCompensation", "Compensate for suspension geometry", false, false, textColor)
    end)
    overridableItemWrapper(perCarTab, "extraSATMakeupGain", function (textColor)
        showCheckbox(configTable, "extraSATMakeupGain", "Compensate FFB strength", false, false, textColor)
    end)

    showHeader("Oversteer feel:")
    overridableItemWrapper(perCarTab, "oversteerFeel", function (textColor)
        showConfigSlider(configTable, "oversteerFeel", "Oversteer feedback", "%.f%%", 0.0, 150.0, 100.0, getSliderWidth(sliderRightPadding), sectionPadding, false, textColor)
    end)
    overridableItemWrapper(perCarTab, "oversteerFeelAggression", function (textColor)
        showConfigSlider(configTable, "oversteerFeelAggression", "Slip angle threshold", "%.f%%", 50.0, 150.0, 100.0, getSliderWidth(sliderRightPadding), sectionPadding, false, textColor)
    end)
    overridableItemWrapper(perCarTab, "oversteerFeelMakeupGain", function (textColor)
        showCheckbox(configTable, "oversteerFeelMakeupGain", "Compensate FFB strength", false, false, textColor)
    end)
end

local function drawHapticsSection(perCarTab)
    local configTable = perCarTab and carSpecificConfig or generalConfig

    showHeader("Vibration:")
    overridableItemWrapper(perCarTab, "vibrationSource", function (textColor)
        configTable.vibrationSource = showCompactDropdown("Vibration source", "vibrationSource", {"Off", "Braking help", "Throttle help", "Braking + throttle help", "Understeer", "Gear shift warning"}, configTable["vibrationSource"] + 1, sectionPadding, textColor) - 1
    end)
    overridableItemWrapper(perCarTab, "vibrationLevel", function (textColor)
        showConfigSlider(configTable, "vibrationLevel", "Vibration level", "%.f%%", 0.0, 50.0, 100.0, getSliderWidth(sliderRightPadding), sectionPadding, false, textColor)
    end)
    overridableItemWrapper(perCarTab, "vibrationBaseFrequency", function (textColor)
        showConfigSlider(configTable, "vibrationBaseFrequency", "Base frequency", "%.f Hz", 10.0, 30.0, 1.0, getSliderWidth(sliderRightPadding), sectionPadding, false, textColor)
    end)
end

local function drawSafetySection(perCarTab)
    local configTable = perCarTab and carSpecificConfig or generalConfig

    showHeader("Collision protection:")
    overridableItemWrapper(perCarTab, "peakReduction", function (textColor)
        showCheckbox(configTable, "peakReduction", "Enable collision force reduction", false, false, textColor)
    end)

    showHeader("Post-race FFB:")
    overridableItemWrapper(perCarTab, "ffbLevelAfterFinish", function (textColor)
        showConfigSlider(configTable, "ffbLevelAfterFinish", "FFB level after finish", "%.f%%", 0.0, 100.0, 100.0, getSliderWidth(sliderRightPadding), sectionPadding, false, textColor)
    end)
end

local function addTabItem(tabName, reservedYSpace, content)
    ui.tabItem(tabName, function ()
        ui.childWindow(tabName .. "_content", tmpVec3:set(ui.availableSpaceX(), ui.availableSpaceY() - reservedYSpace), false, ui.WindowFlags.NoBackground, function ()
            content()
            showDummyLine(0.5)
        end)
    end)
end

-- local treeNodeOverrideStatus = {}
-- local function generateTreeNodeParams(title, perCarTab, drawSectionCallback)
--     local finalTitle = title
--     if perCarTab then
--         if treeNodeOverrideStatus[title] then
--             finalTitle = "🔵 " .. title
--         else
--             finalTitle = "⚪ " .. title
--         end
--     end

--     return finalTitle, function ()
--         local result = drawSectionCallback()
--         if perCarTab then
--             treeNodeOverrideStatus[title] = result
--         end
--     end
-- end

local function drawCompleteSettingsPage(perCarTab)
    overridableItemWrapper(perCarTab, "scriptEnabled", function(textColor)
        showCheckbox(generalConfig, "scriptEnabled", "Enable FFB processing", false, false, textColor, 0)
    end)
    showDummyLine(0.5)

    ui.treeNode("Strength and filtering", function ()
        drawGainAndFilteringSection(perCarTab)
        showDummyLine(0.5)
    end)

    ui.treeNode("General force effects", function ()
        drawGeneralForceSection(perCarTab)
        showDummyLine(0.5)
    end)

    ui.treeNode("Haptics", function ()
        drawHapticsSection(perCarTab)
        showDummyLine(0.5)
    end)

    ui.treeNode("Safety", function ()
        drawSafetySection(perCarTab)
        showDummyLine(0.5)
    end)
end

local currentPresetName   = ""
local saveFeedbackStart   = -1
local loadFeedbackStart   = -1
local deleteFeedbackStart = -1
local badPresetName       = false
local function drawCompletePresetsPage()
    ui.text("Preset name:")

    ui.setNextItemWidth(ui.availableSpaceX())
    if badPresetName then
        ui.pushStyleColor(ui.StyleColor.FrameBg, badInputColor)
    end
    currentPresetName = ui.inputText("", currentPresetName, ui.InputTextFlags.RetainSelection) --:gsub("%*", "")
    if badPresetName then
        ui.popStyleColor(1)
    end

    badPresetName = string.len(currentPresetName) > 0 and not isPresetNameValid(currentPresetName)

    local loadText = "⤴️ Load"
    local loadFlags = ui.ButtonFlags.None
    if loadFeedbackStart ~= -1 then
        if ui.time() - loadFeedbackStart > 1.0 then
            loadFeedbackStart = -1
        else
            ui.setNextTextBold()
            loadText = "Loaded!"
            loadFlags = ui.ButtonFlags.Disabled
        end
    end
    local loadClicked = ui.button(loadText, tmpVec1:set(ui.availableSpaceX() / 3.0, ui.frameHeight()), loadFlags)

    ui.sameLine()
    local saveText = "💾 Save"
    local saveFlags = ui.ButtonFlags.None
    if saveFeedbackStart ~= -1 then
        if ui.time() - saveFeedbackStart > 1.0 then
            saveFeedbackStart = -1
        else
            ui.setNextTextBold()
            saveText = "Saved!"
            saveFlags = ui.ButtonFlags.Disabled
        end
    end
    local saveClicked = ui.button(saveText, tmpVec1:set(ui.availableSpaceX() / 2.0, ui.frameHeight()), saveFlags)

    ui.sameLine()
    local deleteText = "❌ Delete"
    local deleteFlags = ui.ButtonFlags.None
    if deleteFeedbackStart ~= -1 then
        if ui.time() - deleteFeedbackStart > 1.0 then
            deleteFeedbackStart = -1
        else
            ui.setNextTextBold()
            deleteText = "Deleted!"
            deleteFlags = ui.ButtonFlags.Disabled
        end
    end
    local deleteClicked = ui.button(deleteText, tmpVec1:set(ui.availableSpaceX(), ui.frameHeight()), deleteFlags)

    if not badPresetName then
        if saveClicked and currentPresetName:len() > 0   then if savePreset(currentPresetName)   then saveFeedbackStart = ui.time() end end
        if loadClicked and currentPresetName:len() > 0   then if loadPreset(currentPresetName)   then loadFeedbackStart = ui.time() end end
        if deleteClicked and currentPresetName:len() > 0 then if deletePreset(currentPresetName) then deleteFeedbackStart = ui.time() end end
    end

    showDummyLine(0.5)
    ui.text("Saved presets:")

    local presetNames, paddedPresetNames = getPresetList()

    ui.childWindow("presetList", tmpVec1:set(ui.availableSpaceX(), ui.windowHeight() - ui.getCursorY() - ui.StyleVar.WindowPadding - 100), false, ui.WindowFlags.NoTitleBar + ui.WindowFlags.NoMove + ui.WindowFlags.NoResize, function ()
        -- ui.alignTextToFramePadding()
        showDummyLine(0.0)
        for i, preset in ipairs(presetNames) do
            local isSelected = (preset == currentPresetName or (string.startsWith(preset, "*") and string.sub(preset, 2) == currentPresetName))
            if isSelected then ui.setNextTextBold() end
            if ui.selectable(paddedPresetNames[i], isSelected) then
                currentPresetName = preset:gsub("%*", "")
            end
        end
        return 0
    end)

    showDummyLine(0.5)

    if showButton("📁 Open presets folder", false, nil, nil, nil, 0) then
        os.openInExplorer(storage.getUserPresetsDirectory())
    end
end

local function drawACSettingSlider(fileName, section, key, format, minValue, maxValue, valueMult)
    local combinedKey = constructGameConfigKey(fileName, section, key)

    local disableSuggestion = (not gameConfigSuggestionsConsidered[combinedKey])

    if (not disableSuggestion and not gameConfigSuggestions[combinedKey]) or not gameConfigNames[combinedKey] then
        return
    end

    local settingName = gameConfigNames[combinedKey]

    showConfigSlider(currentGameConfigValues, combinedKey, settingName, format, minValue, maxValue, valueMult, getSliderWidth(0), 0)

    if not disableSuggestion and (math.abs(currentGameConfigValues[combinedKey] - gameConfigSuggestions[combinedKey]) > 1e-6) then
        ui.setCursorX(0)
        ui.textWrapped("⚠️ Suggested value: " .. string.format(format, gameConfigSuggestions[combinedKey] * valueMult))
    else
        ui.setCursorX(0)
        ui.textWrapped("")
    end
end

local ffbGainSliderMin = 40.0
local ffbGainSliderMax = 250.0

local function drawCompleteACSettingsPage()

    local currentFFBGain = ac.getCar(0).ffbMultiplier
    local currentFFBGainPerc = currentFFBGain * 100.0
    local dummyConfigTable = {
        ffbGain = currentFFBGain
    }

    if currentFFBGainPerc < ffbGainSliderMin then
        ffbGainSliderMin = math.max(0.0, math.floor(currentFFBGainPerc / 10.0) * 10.0)
    end

    if currentFFBGainPerc > ffbGainSliderMax then
        ffbGainSliderMax = math.min(1000.0, math.ceil(currentFFBGainPerc / 50.0) * 50.0)
    end

    showDummyLine(0.5)
    showConfigSlider(dummyConfigTable, "ffbGain", "Car FFB gain", "%.f%%", ffbGainSliderMin, ffbGainSliderMax, 100.0, getSliderWidth(0), 0, getConfigValue("autoAdjustGain"))
    ui.textWrapped("")

    if math.abs(currentFFBGain - dummyConfigTable.ffbGain) > 1e-6 then
        ac.setFFBMultiplier(dummyConfigTable.ffbGain)
    end

    showDummyLine(0.5)
    drawACSettingSlider("controls.ini", "STEER", "FF_GAIN", "%.f%%", 0.0, 100.0, 100.0)
    showDummyLine(0.5)
    drawACSettingSlider("controls.ini", "FF_ENHANCEMENT", "CURBS", "%.f%%", 0.0, 100.0, 100.0)
    showDummyLine(0.5)
    drawACSettingSlider("controls.ini", "FF_ENHANCEMENT", "ROAD", "%.f%%", 0.0, 100.0, 100.0)
    showDummyLine(0.5)
    drawACSettingSlider("controls.ini", "FF_ENHANCEMENT", "SLIPS", "%.f%%", 0.0, 100.0, 100.0)
    showDummyLine(0.5)
    drawACSettingSlider("controls.ini", "FF_ENHANCEMENT", "ABS", "%.f%%", 0.0, 100.0, 100.0)
    showDummyLine(0.5)

    local extraWarningTable = {
        "controls.ini:FF_TWEAKS:CENTER_BOOST_RANGE",
        "controls.ini:FF_TWEAKS:CENTER_BOOST_GAIN",
        "ffb_tweaks.ini:POSTPROCESSING:RANGE_COMPRESSION",
        "ffb_tweaks.ini:POSTPROCESSING:RANGE_COMPRESSION_ASSIST"
    }

    local extraFixTooltip = "It seems you have other setting in AC / Content Manager that may interfere with the experience.\n\nYou can set these to the recommended values by clicking this button.\n\nThe settings in question are:\n"
    local extraSettingsToFix = {}

    for _, extraWarningConfigKey in ipairs(extraWarningTable) do
        if gameConfigSuggestionsConsidered[extraWarningConfigKey] then
            if math.abs(gameConfigSuggestions[extraWarningConfigKey] - currentGameConfigValues[extraWarningConfigKey]) > 1e-6 then
                extraFixTooltip = extraFixTooltip .. "\n • " .. gameConfigNames[extraWarningConfigKey]
                table.insert(extraSettingsToFix, extraWarningConfigKey)
            end
        end
    end

    if #extraSettingsToFix > 0 then
        tooltips.fixExtraSettings = extraFixTooltip
        if showButton("⚠️ Fix other settings", false, "fixExtraSettings") then
            for _, k in ipairs(extraSettingsToFix) do
                if gameConfigSuggestionsConsidered[k] then
                    currentGameConfigValues[k] = gameConfigSuggestions[k]
                end
            end

            saveGameConfigValues(true)
        end
    end

    saveGameConfigValues()
    showDummyLine(0.5)
end

local function graphYLabelToString(value)
    local value = math.round(value, 3)

    local sign = ""

    if value > 0.0 then
        sign = "+"
    elseif value == 0 then
        sign = "  "
    end

    return sign .. string.format("%.1f", value)
end

local function showValueHistoryGraph(pos, size, xResolution, yMin, yMax, yDiv, plotNames, plotColors, plotRLCallbacks, clippingSourcePlotIndex)

    local leftPadding = 0 --36
    local lineHeight = ui.textLineHeight()
    local backgroundFillColor = graphBgColor

    local function isValueValidAndClipping(v)
        -- return true
        if v == nil then
            return false
        end
        return (v < -1.0) or (v > 1.0)
    end

    if appConfig.graphWindowShowClipping and clippingSourcePlotIndex ~= nil and isValueValidAndClipping(plotRLCallbacks[clippingSourcePlotIndex](0)) == true then
        backgroundFillColor = graphBgClippingColor
    end

    ui.drawRectFilled(tmpVec1:set(pos.x + leftPadding, pos.y), tmpVec2:set(pos.x + size.x, pos.y + size.y), backgroundFillColor)

    local yDivColorFaint = rgbm(1.0, 1.0, 1.0, 0.125)
    local yDivColorBright = rgbm(1.0, 1.0, 1.0, 0.75)
    for y = yMin, yMax, yDiv do
        local progression = math.lerpInvSat(y, yMin, yMax)
        local yCoord = pos.y + size.y * progression
        -- if progression > 0.501 then
        --     yCoord = math.floor(yCoord)
        -- elseif progression < 0.499 then
        --     yCoord = math.ceil(yCoord)
        -- else
        --     yCoord = math.round(yCoord)
        -- end
        yCoord = math.round(yCoord)
        ui.drawLine(tmpVec1:set(pos.x + leftPadding, yCoord), tmpVec2:set(pos.x + size.x, yCoord), (progression > 0.499 and progression < 0.501) and yDivColorBright or yDivColorFaint, 1)
    end

    -- ui.drawText(graphYLabelToString(yMax), tmpVec1:set(pos.x, pos.y - lineHeight * 0.5))
    -- ui.drawText(graphYLabelToString((yMin + yMax) * 0.5), tmpVec1:set(pos.x, pos.y + size.y * 0.5 - lineHeight * 0.5))
    -- ui.drawText(graphYLabelToString(yMin), tmpVec1:set(pos.x, pos.y + size.y - lineHeight * 0.5))

    local yTextColor = graphTextColor
    ui.drawText(graphYLabelToString(yMax), tmpVec1:set(pos.x, pos.y - lineHeight * 0.0), yTextColor)
    ui.drawText(graphYLabelToString(yMin), tmpVec1:set(pos.x, pos.y + size.y - lineHeight * 1.0), yTextColor)

    ui.setCursor(pos)
    ui.childWindow("AFFBT_FFBGraphPlots", size, false, bit.bor(ui.WindowFlags.NoDecoration, ui.WindowFlags.NoInputs, ui.WindowFlags.NoBackground), function ()
        for plotIndex, plotRLCallback in ipairs(plotRLCallbacks) do
            if plotRLCallback ~= nil then
                local pointCount = 0
                for i = 0, xResolution - 1, 1 do
                    local progressRL = i / (xResolution - 1)
                    local progressLR = 1.0 - progressRL
                    local dataPoint = plotRLCallback(i)
                    if dataPoint == nil then
                        break
                    end
                    pointCount = pointCount + 1
                    tmpVec2:set(math.lerp(leftPadding, size.x, progressLR), math.lerp(size.y, 0.0, lib.inverseLerp(yMin, yMax, dataPoint)))
                    -- rounding display coords to 1/4 of a pixel to reduce visual shimmering caused by miniscule changes in the signal
                    -- tmpVec2.x = math.round(tmpVec2.x * 4.0) / 4.0
                    tmpVec2.y = math.round(tmpVec2.y * 4.0) / 4.0
                    ui.pathLineTo(tmpVec2)
                end
                if pointCount > 1 then
                    local strokeBaseWidth = math.pow(((appConfig.graphWindowSize.x / graphWindowMinSize.x) + (appConfig.graphWindowSize.y / graphWindowMinSize.y)) * 0.5, 0.66667) * graphStrokeWidthAtMinSize
                    local strokeModifier = 1
                    if #plotRLCallbacks > 1 then
                        strokeModifier = math.lerp(0.9, 1.1, (plotIndex - 1) / (#plotRLCallbacks - 1)) -- if some plots have the exact same value, this small stroke offset ensures that the color of the top one can come through without much weirdness around the edges where the plots below could bleed through due to anti aliasing
                    end
                    ui.pathSmoothStroke(plotColors[plotIndex], false, strokeBaseWidth * strokeModifier)
                elseif pointCount == 1 then
                    ui.pathClear()
                end
            end
        end
    end)
end

local function graphRLCallbackImpl(buffer, capacity, head, count, indexRL0based)
    local rightIndex = lib.StructValueHistory.getNewestIndex(buffer, capacity, head, count)
    local index = rightIndex - indexRL0based
    if index < 0 then
        return nil
    end
    return lib.StructValueHistory.get(buffer, capacity, head, count, index)
end

local function graphRawRLCallback(indexRL0based)
    return graphRLCallbackImpl(runtimeData.ffbRawHistoryBuffer, storage.ffbHistoryBufferCapacity, runtimeData.ffbRawHistoryHead, runtimeData.ffbRawHistoryCount, indexRL0based)
end

local function graphFinalRLCallback(indexRL0based)
    return graphRLCallbackImpl(runtimeData.ffbFinalHistoryBuffer, storage.ffbHistoryBufferCapacity, runtimeData.ffbFinalHistoryHead, runtimeData.ffbFinalHistoryCount, indexRL0based)
end

-- the highest index plot from the enabled ones will be used to determine clipping
local graphPlotNamesTable = { "Original FFB", "Final FFB" }
local graphPlotConfigKeysTable = { "graphRawPlot", "graphFinalPlot" }
local graphPlotCallbacksTable = { graphRawRLCallback, graphFinalRLCallback }
local graphWindowBeingDragged = false
local graphWindowBeingResized = false
local tmpPlotNames = {}
local tmpPlotColors = {}
local tmpPlotCallbacks = {}
local unclampedWindowSize = appConfig.graphWindowSize
local function drawCompleteFFBGraphToolWindow()
    ui.toolWindow("AFFBT_FFBGraph", appConfig.graphWindowPos, appConfig.graphWindowSize, false, true, function ()

        if appConfig.graphWindowAlwaysOnTop then
            ui.bringWindowToFront()
        end

        -- close button

        ui.pushStyleColor(ui.StyleColor.Button, rgbm(0.0, 0.0, 0.0, 0.0))
        ui.pushStyleColor(ui.StyleColor.ButtonHovered, rgbm(139/255, 39/255, 44/255, 1.0)) -- replicating the default colors of a close button in csp apps
        ui.pushStyleColor(ui.StyleColor.ButtonActive, rgbm(204/255, 17/255, 26/255,1.0))
        ui.setCursorX(appConfig.graphWindowSize.x - 24)
        ui.setCursorY(0)
        if ui.smallButton("X") then
            appConfig.showGraphWindow = false
        end
        ui.popStyleColor(3)

        pushStyle()
        local graphResizeHandleSize = 16

        -- storing input stuff

        local leftMouseDown = ui.mouseDown(ui.MouseButton.Left)
        local mouseLocalPos = ui.mouseLocalPos()
        local mouseOverResizeHandle = mouseLocalPos.x >= (appConfig.graphWindowSize.x - graphResizeHandleSize) and mouseLocalPos.y >= (appConfig.graphWindowSize.y - graphResizeHandleSize) and mouseLocalPos.x <= appConfig.graphWindowSize.x and mouseLocalPos.y <= appConfig.graphWindowSize.y

        -- drawing graph

        table.clear(tmpPlotNames)
        table.clear(tmpPlotColors)
        table.clear(tmpPlotCallbacks)
        for i = 1, #graphPlotConfigKeysTable, 1 do
            if appConfig[graphPlotConfigKeysTable[i]] then
                table.insert(tmpPlotNames, graphPlotNamesTable[i])
                table.insert(tmpPlotColors, graphPlotColors[i])
                table.insert(tmpPlotCallbacks, graphPlotCallbacksTable[i])
            end
        end
        local graphLocalPos = vec2(graphPadding, graphPadding)
        local graphSize = vec2(appConfig.graphWindowSize.x - 2 * graphPadding, appConfig.graphWindowSize.y - 2 * graphPadding)
        local graphYMin = appConfig.graphZoomed and -0.5 or -1.0
        local graphYMax = appConfig.graphZoomed and 0.5 or 1.0
        local graphYDiv = 0.25
        showValueHistoryGraph(graphLocalPos, graphSize, ffbGraphPointCount, graphYMin, graphYMax, graphYDiv, tmpPlotNames, tmpPlotColors, tmpPlotCallbacks, (#tmpPlotCallbacks > 0) and #tmpPlotCallbacks or nil)

        -- resize handle

        ui.pathLineTo(tmpVec1:set(appConfig.graphWindowSize.x - graphResizeHandleSize, appConfig.graphWindowSize.y))
        ui.pathLineTo(tmpVec1:set(appConfig.graphWindowSize.x, appConfig.graphWindowSize.y))
        ui.pathLineTo(tmpVec1:set(appConfig.graphWindowSize.x, appConfig.graphWindowSize.y - graphResizeHandleSize))
        local resizeHandleColor = graphResizeHandleColor
        if mouseOverResizeHandle and not graphWindowBeingResized then
            resizeHandleColor = controlActiveColor
        elseif graphWindowBeingResized then
            resizeHandleColor = controlAccentColor
        end
        ui.pathFillConvex(resizeHandleColor)

        -- dragging and resizing logic

        if leftMouseDown and ui.windowHovered() then
            if not graphWindowBeingDragged and mouseOverResizeHandle then
                graphWindowBeingResized = true
            else
                if not graphWindowBeingResized then
                    graphWindowBeingDragged = true
                end
            end
        end

        if not leftMouseDown then
            graphWindowBeingDragged = false
            graphWindowBeingResized = false
        end

        if graphWindowBeingDragged then
            appConfig.graphWindowPos = appConfig.graphWindowPos + ui.mouseDragDelta(ui.MouseButton.Left, 0)
            ui.resetMouseDragDelta(ui.MouseButton.Left)
        end

        if graphWindowBeingResized then
            unclampedWindowSize = unclampedWindowSize + ui.mouseDragDelta(ui.MouseButton.Left, 0)
            local unclampedAvgSize = (unclampedWindowSize.x + unclampedWindowSize.y) * 0.5
            local fixedAspectRatio = 2.0
            unclampedWindowSize.x = unclampedAvgSize * (fixedAspectRatio / ((fixedAspectRatio + 1.0) * 0.5))
            unclampedWindowSize.y = unclampedWindowSize.x * 0.5
            appConfig.graphWindowSize = vec2(math.clamp(unclampedWindowSize.x, graphWindowMinSize.x, graphWindowMaxSize.x), math.clamp(unclampedWindowSize.y, graphWindowMinSize.y, graphWindowMaxSize.y))
            ui.resetMouseDragDelta(ui.MouseButton.Left)
        else
            unclampedWindowSize = appConfig.graphWindowSize
        end

        if mouseOverResizeHandle or graphWindowBeingResized then
            ui.setMouseCursor(ui.MouseCursor.ResizeNWSE)
        end

        popStyle()
    end)
end

local function drawCompleteGraphPage()
    showHeader("Plots:")

    for i = 1, #graphPlotConfigKeysTable, 1 do
        showCheckbox(appConfig, graphPlotConfigKeysTable[i], graphPlotNamesTable[i], false, false, nil, sectionPadding)
        if appConfig[graphPlotConfigKeysTable[i]] then
            ui.sameLine()
            ui.setCursorX(ui.textLineHeight() * 9.0)
            ui.icon(ui.Icons.Record, ui.textLineHeight() * 1.6, graphPlotColors[i])
        end
    end

    -- showDummyLine(0.5)
    showHeader("Display settings:")

    showCheckbox(appConfig, "graphWindowAlwaysOnTop", "Always on top", false, false, nil, sectionPadding)

    showCheckbox(appConfig, "graphWindowShowClipping", "Show clipping", false, false, nil, sectionPadding)

    local rangeSetting = showCompactDropdown("Graph range", "graphRange", { "Normal", "Zoomed" }, appConfig.graphZoomed and 2 or 1, sectionPadding)
    appConfig.graphZoomed = (rangeSetting > 1)

    showDummyLine(0.5)

    if showButton(appConfig.showGraphWindow and "Hide graph" or "Show graph", false, nil, nil, nil, sectionPadding) then
        appConfig.showGraphWindow = not appConfig.showGraphWindow
    end
end

function script.windowMain(dt)

    if not runtimeData.appCanRun then
        if ac.getPatchVersionCode() < 3465 then
            ui.pushStyleColor(ui.StyleColor.Text, rgbm(1.0, 0.0, 0.0, 1.0))
            ui.textWrapped("Update CSP to 0.2.11 or newer!\nOlder versions are not supported.")
            ui.popStyleColor(1)
        else
            ui.textWrapped("The FFB post-processing script is not enabled.")
            local currentClock = os.clock()
            if (currentClock - enableClicked) >= 3.0 then
                showDummyLine()
                showButton("Enable", false, nil, enableScript)
            end
            showDummyLine()
            ui.textWrapped("If you can't enable it from here then something isn't working right. Try restarting the game, or double checking the instructions and re-installing the mod.")
        end

        return
    end

    pushStyle()

    runtimeData.appHeartbeatClock = os.clock()

    if not appConfig.firstInstallPassed then
        local message = "This seems to be your first time using this plugin.\n\nFor the best experience it's recommended to use certain values for AC's built-in FFB settings.\n\nThe recommended FFB settings are:\n"

        for k, v in pairs(gameConfigSuggestions) do
            if gameConfigSuggestionsConsidered[k] then
                message = message .. "\n" .. gameConfigNames[k] .. " = " .. v * 100.0 -- // FIXME shouldnt rely on every setting being a percentage
            end
        end

        message = message .. "\n\nYou can also change these any time from this app!\n\nClick this button to apply the settings above (others like gain won't be affected):"

        showDummyLine(0.5)
        ui.textWrapped(message)
        showDummyLine(0.5)

        if showButton("✅ Apply recommended settings", false, nil, nil, nil, 0) then
            for k, v in pairs(gameConfigSuggestions) do
                if gameConfigSuggestionsConsidered[k] then
                    currentGameConfigValues[k] = v
                end
            end

            saveGameConfigValues(true)

            appConfig.firstInstallPassed = true
        end

        showDummyLine(0.5)
        ui.textWrapped("... or you can continue without changing anything:")
        showDummyLine(0.5)

        if showButton("👉 Continue with current settings", false, nil, nil, nil, 0) then
            appConfig.firstInstallPassed = true
        end

        popStyle()
        return
    end

    local reservedYSpace = newVersionAvailable and (ui.textLineHeight() * 4.0) or 0.0

    ui.tabBar("Tabs", ui.TabBarFlags.NoTooltip + ui.TabBarFlags.FittingPolicyScroll, function()

        addTabItem("Global", reservedYSpace, function ()
            showDummyLine(0.5)
            ui.textWrapped("These are your global settings regardless of car.\nHowever, car-specific overrides always take priority.")
            showDummyLine(0.5)

            drawCompleteSettingsPage(false)
        end)

        addTabItem("Car-Specific", reservedYSpace, function ()
            showDummyLine(0.5)
            ui.textWrapped("Settings you change here will only apply to this car.\nSettings in gray follow their global value (no override).")
            showDummyLine(0.5)

            drawCompleteSettingsPage(true)
        end)

        addTabItem("AC", reservedYSpace, function ()
            showDummyLine(0.5)
            ui.textWrapped("These are shortcuts to AC's own FFB settings.")
            showDummyLine(0.5)

            drawCompleteACSettingsPage()
        end)

        addTabItem("Presets", reservedYSpace, function ()
            showDummyLine(0.5)
            ui.textWrapped("You can save or load presets here.\nBeware that presets only store the global settings!\nFactory presets are marked with a * symbol.")
            showDummyLine(0.5)

            drawCompletePresetsPage()
        end)

        addTabItem("Graph", reservedYSpace, function ()
            showDummyLine(0.5)
            ui.textWrapped("Here you can set up a graph window that can show how the plugin changes your FFB.")
            -- showDummyLine(0.5)

            drawCompleteGraphPage()
        end)
    end)

    if newVersionAvailable then
        showDummyLine(0.5)
        -- 📲
        local updateClicked = showButton("          Update available! Click to download!", false, "releaseNotes", nil, nil, 0, rgbm(1.0, 0.9, 0.0, 1.0))
        ui.addIcon(ui.Icons.Download, ui.textLineHeight(), 0.5 - ui.textLineHeight() * 0.0245)
        if updateClicked then
            os.execute("start https://www.overtake.gg/downloads/adams-ffb-toolbox.84691/")
        end
    end

    popStyle()
end

function script.renderGraphWindow(dt)
    if not runtimeData.appCanRun then
        return
    end

    pushStyle()
    if appConfig.showGraphWindow then
        drawCompleteFFBGraphToolWindow()
    end
    popStyle()
end

local resetClicked = 0
function script.windowSettings(dt)
    pushStyle()
    ui.dummy(tmpVec1:set(200, 20))

    appConfig.biggerFont = showCompactDropdown("Font size", nil, {"Small", "Normal"}, appConfig.biggerFont and 2 or 1, 0) >= 2
    showDummyLine(1.0)

    if resetClicked > 3.0 then
        resetClicked = 0
    end

    if resetClicked > 0 then
        resetClicked = resetClicked + dt
    end

    if showButton(resetClicked > 0 and "⚠️ Confirm?" or "⚠️ Factory reset", false, "factoryReset", nil, nil, 0) then
        if resetClicked > 0.2 then
            factoryReset()
            resetClicked = 0
        elseif resetClicked == 0 then
            resetClicked = resetClicked + dt
        end
    end

    ui.dummy(tmpVec1:set(200, 20))

    popStyle()
end