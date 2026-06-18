local json = require("json")

local M = {}

M.ffbHistoryBufferCapacity = 1000
M.ffbSampleRateDiv = 1 -- divisor to the sampling rate of the ffb graph. 1 = 333hz, 2 = 167hz etc. this rate will also be the visual frame rate of the graph
M.configVersion = 110

M.generalConfig = {
    ac.StructItem.key("AFFBT_Data"),
    scriptEnabled = ac.StructItem.boolean(),
    autoAdjustGain = ac.StructItem.boolean(),
    autoGainOffset = ac.StructItem.float(), -- used as `gain * (1 + offset)`
    absFilterEnabled = ac.StructItem.boolean(),
    filterEnabled = ac.StructItem.boolean(),
    filterFrequency = ac.StructItem.float(),
    downforceCompMode = ac.StructItem.int32(), -- 0 = off, 1 = percentage, 2 = dynamic range
    downforceCompPercentage = ac.StructItem.float(), -- 0 to 1
    downforceCompDynamicRange = ac.StructItem.float(), -- 0 to 10
    downforceCompMakeupGain = ac.StructItem.boolean(),
    brakeFeel = ac.StructItem.float(),
    brakeFeelWithABS = ac.StructItem.boolean(),
    brakeFeelFilter = ac.StructItem.boolean(),
    brakeFeelExponent = ac.StructItem.float(),
    brakeFeelMakeupGain = ac.StructItem.boolean(),
    lockupFeel = ac.StructItem.float(),
    lockupFeelWithABS = ac.StructItem.boolean(),
    extraSAT = ac.StructItem.float(),
    extraSATSuspensionCompensation = ac.StructItem.boolean(),
    extraSATMakeupGain = ac.StructItem.boolean(),
    oversteerFeel = ac.StructItem.float(),
    oversteerFeelAggression = ac.StructItem.float(),
    oversteerFeelMakeupGain = ac.StructItem.boolean(),
    vibrationSource = ac.StructItem.int32(), -- 0 = off, 1 = braking help, 2 = throttle help, 3 = braking + throttle help, 4 = understeer, 5 = gear shift warning
    vibrationLevel = ac.StructItem.float(),
    vibrationBaseFrequency = ac.StructItem.float(),
    vibrationSharpness = ac.StructItem.float(),
    roadTexture = ac.StructItem.float(),
    roadTextureBypassFilter = ac.StructItem.boolean(),
    peakReduction = ac.StructItem.boolean(),
    ffbLevelAfterFinish = ac.StructItem.float()
}

M.carSpecificConfig = {
    ac.StructItem.key("AFFBT_PerCarData"),
    OVERRIDE_scriptEnabled = ac.StructItem.boolean(),
    scriptEnabled = ac.StructItem.boolean(),
    OVERRIDE_autoAdjustGain = ac.StructItem.boolean(),
    autoAdjustGain = ac.StructItem.boolean(),
    OVERRIDE_autoGainOffset = ac.StructItem.boolean(),
    autoGainOffset = ac.StructItem.float(),
    OVERRIDE_absFilterEnabled = ac.StructItem.boolean(),
    absFilterEnabled = ac.StructItem.boolean(),
    OVERRIDE_filterEnabled = ac.StructItem.boolean(),
    filterEnabled = ac.StructItem.boolean(),
    OVERRIDE_filterFrequency = ac.StructItem.boolean(),
    filterFrequency = ac.StructItem.float(),
    OVERRIDE_downforceCompMode = ac.StructItem.boolean(),
    downforceCompMode = ac.StructItem.int32(),
    OVERRIDE_downforceCompPercentage = ac.StructItem.boolean(),
    downforceCompPercentage = ac.StructItem.float(),
    OVERRIDE_downforceCompDynamicRange = ac.StructItem.boolean(),
    downforceCompDynamicRange = ac.StructItem.float(),
    OVERRIDE_downforceCompMakeupGain = ac.StructItem.boolean(),
    downforceCompMakeupGain = ac.StructItem.boolean(),
    OVERRIDE_brakeFeel = ac.StructItem.boolean(),
    brakeFeel = ac.StructItem.float(),
    OVERRIDE_brakeFeelWithABS = ac.StructItem.boolean(),
    brakeFeelWithABS = ac.StructItem.boolean(),
    OVERRIDE_brakeFeelFilter = ac.StructItem.boolean(),
    brakeFeelFilter = ac.StructItem.boolean(),
    OVERRIDE_brakeFeelExponent = ac.StructItem.boolean(),
    brakeFeelExponent = ac.StructItem.float(),
    OVERRIDE_brakeFeelMakeupGain = ac.StructItem.boolean(),
    brakeFeelMakeupGain = ac.StructItem.boolean(),
    OVERRIDE_lockupFeel = ac.StructItem.boolean(),
    lockupFeel = ac.StructItem.float(),
    OVERRIDE_lockupFeelWithABS = ac.StructItem.boolean(),
    lockupFeelWithABS = ac.StructItem.boolean(),
    OVERRIDE_extraSAT = ac.StructItem.boolean(),
    extraSAT = ac.StructItem.float(),
    OVERRIDE_extraSATSuspensionCompensation = ac.StructItem.boolean(),
    extraSATSuspensionCompensation = ac.StructItem.boolean(),
    OVERRIDE_extraSATMakeupGain = ac.StructItem.boolean(),
    extraSATMakeupGain = ac.StructItem.boolean(),
    OVERRIDE_oversteerFeel = ac.StructItem.boolean(),
    oversteerFeel = ac.StructItem.float(),
    OVERRIDE_oversteerFeelAggression = ac.StructItem.boolean(),
    oversteerFeelAggression = ac.StructItem.float(),
    OVERRIDE_oversteerFeelMakeupGain = ac.StructItem.boolean(),
    oversteerFeelMakeupGain = ac.StructItem.boolean(),
    OVERRIDE_vibrationSource = ac.StructItem.boolean(),
    vibrationSource = ac.StructItem.int32(),
    OVERRIDE_vibrationLevel = ac.StructItem.boolean(),
    vibrationLevel = ac.StructItem.float(),
    OVERRIDE_vibrationBaseFrequency = ac.StructItem.boolean(),
    vibrationBaseFrequency = ac.StructItem.float(),
    OVERRIDE_vibrationSharpness = ac.StructItem.boolean(),
    vibrationSharpness = ac.StructItem.float(),
    OVERRIDE_roadTexture = ac.StructItem.boolean(),
    roadTexture = ac.StructItem.float(),
    OVERRIDE_roadTextureBypassFilter = ac.StructItem.boolean(),
    roadTextureBypassFilter = ac.StructItem.boolean(),
    OVERRIDE_peakReduction = ac.StructItem.boolean(),
    peakReduction = ac.StructItem.boolean(),
    OVERRIDE_ffbLevelAfterFinish = ac.StructItem.boolean(),
    ffbLevelAfterFinish = ac.StructItem.float()
}

-- defaults should be an inactive state for each effect, but with the script enabled in general
M.defaultSettings = {
    scriptEnabled = true,
    autoAdjustGain = false,
    autoGainOffset = 0.0,
    absFilterEnabled = false,
    filterEnabled = false,
    filterFrequency = 32,
    downforceCompMode = 0,
    downforceCompPercentage = 1.0,
    downforceCompDynamicRange = 2.5,
    downforceCompMakeupGain = true,
    brakeFeel = 0.0,
    brakeFeelWithABS = true,
    brakeFeelFilter = true,
    brakeFeelExponent = 1.0,
    brakeFeelMakeupGain = false,
    lockupFeel = 0.0,
    lockupFeelWithABS = false,
    extraSAT = 0.0,
    extraSATSuspensionCompensation = true,
    extraSATMakeupGain = false,
    oversteerFeel = 0.0,
    oversteerFeelAggression = 1.0,
    oversteerFeelMakeupGain = false,
    vibrationSource = 0,
    vibrationLevel = 0.0,
    vibrationBaseFrequency = 15.0,
    vibrationSharpness = 0.5,
    roadTexture = 0.0,
    roadTextureBypassFilter = false,
    peakReduction = false,
    ffbLevelAfterFinish = 1.0
}

function M.versionMigration(parsedTable)
    if parsedTable._version < 110 then
        parsedTable.vibrationSharpness = M.defaultSettings.vibrationSharpness
        parsedTable.roadTexture = M.defaultSettings.roadTexture
        parsedTable.roadTextureBypassFilter = M.defaultSettings.roadTextureBypassFilter
    end
    return true
end

function M.versionStamp(outputTable)
    outputTable._version = M.configVersion
end

M.defaultCarSpecificSettings = table.clone(M.defaultSettings, "full")

for k, _ in pairs(M.defaultSettings) do
    M.defaultCarSpecificSettings["OVERRIDE_" .. k] = false
end

-- keys that are stored in a preset
M.presetKeys = {}

for k, _ in pairs(M.defaultSettings) do
    if k ~= "scriptEnabled" then
        table.insert(M.presetKeys, k)
    end
end

M.generalConfigKeys = {}
M.carSpecificConfigKeys = {}

for k, _ in pairs(M.defaultSettings) do
    table.insert(M.generalConfigKeys, k)
end

for k, _ in pairs(M.defaultCarSpecificSettings) do
    table.insert(M.carSpecificConfigKeys, k)
end

M.runtimeData = {
    ac.StructItem.key("AFFBT_RuntimeData"),
    -- carName = ac.StructItem.string(64),
    appCanRun = ac.StructItem.boolean(),
    rawFFB = ac.StructItem.float(),
    finalFFB = ac.StructItem.float(),
    ffbRawHistoryBuffer = ac.StructItem.array(ac.StructItem.float(), M.ffbHistoryBufferCapacity),
    ffbRawHistoryHead = ac.StructItem.int32(),
    ffbRawHistoryCount = ac.StructItem.int32(),
    ffbFinalHistoryBuffer = ac.StructItem.array(ac.StructItem.float(), M.ffbHistoryBufferCapacity),
    ffbFinalHistoryHead = ac.StructItem.int32(),
    ffbFinalHistoryCount = ac.StructItem.int32(),
    factoryResetPerformed = ac.StructItem.boolean(), -- for some reason shared events dont trigger, so i have to do this
    appHeartbeatClock = ac.StructItem.double(), -- stops if the ui app is closed
    autoGainLevel = ac.StructItem.int32(), -- integer percentage, negative means not available
    downforceDynamicRange = ac.StructItem.float() -- negative means not available
}

-- Also ensures the directory exists
function M.getUserPresetsDirectory()
    local dirPath = ac.getFolder(ac.FolderID.Cfg) .. "\\apps\\Adam's FFB Toolbox Config\\presets"
    if not io.dirExists(dirPath) then
        io.createDir(dirPath)
    end
    return dirPath
end

-- Also ensures the directory exists
function M.getGeneralConfigDirectory()
    local dirPath = ac.getFolder(ac.FolderID.ExtCfgState) .. "\\lua\\soft_lock\\Adam's FFB Toolbox"
    if not io.dirExists(dirPath) then
        io.createDir(dirPath)
    end
    return dirPath
end

-- Also ensures the directory exists
function M.getCarSpecificConfigDirectory()
    local dirPath = ac.getFolder(ac.FolderID.ExtCfgState) .. "\\lua\\soft_lock\\Adam's FFB Toolbox\\cars"
    if not io.dirExists(dirPath) then
        io.createDir(dirPath)
    end
    return dirPath
end

function M.readFile(filePath)
    local ifp = io.open(filePath, "r")

    if not ifp then
        return nil
    end

    local contents = ifp:read("a")
    ifp:close()

    return contents
end

---Writes data to a file
---@param filePath string Path of the file to write.
---@param content string Content to write.
---@param mode? openmode (OPTIONAL) File writing mode. Default is `w+`.
---@return boolean success
function M.writeFile(filePath, content, mode)
    mode = mode or "w+"

    local ofp = io.open(filePath, mode)

    if not ofp then
        return false
    end

    local ofpSuccess = ofp:write(content)
    ofp:flush()
    ofp:close()

    return ofpSuccess ~= nil
end

M._lastWriteTimes = {}
M._lastWrittenContent = {}

---Writes data to a file, but only if the data has changed since the last call to write the same file, and only if a 3-second cooldown period has also passed since the last write to the same file.
---@param filePath string Path to the file to write.
---@param contentCallback fun(): string? Function that returns the content to write. It will only be called when the write timer allows the file to be written, which can save resources by generating the content only on demand. If this returns `nil` then nothing will be written to the file.
---@param mode? openmode (OPTIONAL) File writing mode. Default is `w+`.
---@param forced? boolean (OPTIONAL) Bypasses the cooldown and previous content check, always forces a write.
---@return boolean success Returns `true` only if the file was written to.
function M.writeFileThrottled(filePath, contentCallback, mode, forced)
    mode = mode or "w+"

    local now = os.clock()

    if not forced and M._lastWriteTimes[filePath] ~= nil and (now - M._lastWriteTimes[filePath]) < 3.0 then
        return false
    end

    M._lastWriteTimes[filePath] = now

    local content = contentCallback()

    if content == nil then
        return false
    end

    if not forced and M._lastWrittenContent[filePath] ~= nil and content == M._lastWrittenContent[filePath] then
        return false
    end

    M._lastWrittenContent[filePath] = content

    return M.writeFile(filePath, content, mode)
end

---Parses and loads a JSON string into a settings table.
---@param targetTable table The table to load settings into.
---@param jsonString string The JSON string to be parsed.
---@param validKeys? table (OPTIONAL) A list of keys that determines what gets transferred into the target table. If omitted then all matching keys between the JSON and the target table will be loaded.
---@param versionMigrationCallback? fun(parsedTable: table): boolean (OPTIONAL) Callback to perform config version migration. Returns `true` if either no migration is needed or it has been performed, `false` if loading should be aborted.
---@return boolean success Indicates if any settings were loaded into the target table.
function M.parseAndLoadSettingsJSON(targetTable, jsonString, validKeys, versionMigrationCallback)
    if type(jsonString) ~= "string" or string.len(jsonString) < 5 then
        return false
    end

    local success, presetTable = pcall(json.decode, jsonString)

    if not success or type(presetTable) ~= "table" then
        return false
    end

    if versionMigrationCallback then
        if not versionMigrationCallback(presetTable) then
            return false
        end
    end

    local anySettingLoaded = false

    local function loopBody(configKey)
        if presetTable[configKey] ~= nil and type(targetTable[configKey]) == type(presetTable[configKey]) then
            targetTable[configKey] = presetTable[configKey]
            anySettingLoaded = true
        end
    end

    if validKeys then
        for _, configKey in ipairs(validKeys) do
            loopBody(configKey)
        end
    else
        for configKey, _ in pairs(targetTable) do
            loopBody(configKey)
        end
    end

    return anySettingLoaded
end

---Generates a JSON string from a settings table.
---@param sourceTable table The table that will be turned into a JSON string.
---@param validKeys? table (OPTIONAL) A list of keys that determines what gets serialized from the source table. If omitted then all values of the source table will make it into the JSON.
---@param versionStampCallback? fun(outputTable: table) (OPTIONAL) Callback to insert version information into the final table that will get serialized.
---@return string? result
function M.serializeSettingsJSON(sourceTable, validKeys, versionStampCallback)

    local outputTable = {}

    local function loopBody(configKey)
        ---@diagnostic disable-next-line: assign-type-mismatch
        outputTable[configKey] = sourceTable[configKey]
    end

    if validKeys then
        for _, configKey in ipairs(validKeys) do
            loopBody(configKey)
        end
    else
        for configKey, _ in pairs(sourceTable) do
            loopBody(configKey)
        end
    end

    if versionStampCallback then
        versionStampCallback(outputTable)
    end

    local success, presetJSON = pcall(json.encode, outputTable)

    if not success then
        return nil
    end

    return presetJSON
end

return M