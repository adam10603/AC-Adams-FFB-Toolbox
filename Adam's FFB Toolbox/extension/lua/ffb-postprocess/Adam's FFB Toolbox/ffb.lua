local storage = require "Storage"

local generalConfig = ac.connect(storage.generalConfig)
local carSpecificConfig = ac.connect(storage.carSpecificConfig)
local runtimeData = ac.connect(storage.runtimeData)

-- ============================ storage/config and ui app data connection

runtimeData.appCanRun = false
runtimeData.autoGainLevel = -1
runtimeData.downforceDynamicRange = -1

if ac.getPatchVersionCode() < 3465 then
    return
end

local biquadFilter = require("BiquadFilter")
local carPerformanceData = require("CarPerformanceData3")
---@diagnostic disable-next-line: different-requires
local lib = require("AGALib2")


-- These should speed things up a little
local mathDeg = math.deg
local mathRad = math.rad
local mathSmoothstep = math.smoothstep
local mathSmootherstep = math.smootherstep
local mathLerpInvSat = math.lerpInvSat
local mathLerp = math.lerp
local mathMax = math.max
local mathMin = math.min
local mathRound = math.round
local mathAbs = math.abs
local mathSqrt = math.sqrt
local mathPow = math.pow
local mathSin = math.sin
local mathCos = math.cos
local mathAtan2 = math.atan2
local mathSign = math.sign
local mathClamp = math.clamp
local mathExp = math.exp
local mathPi = math.pi
local mathRandom = math.random
local libZeroGuard = lib.zeroGuard
local libNumberGuard = lib.numberGuard
local libWeightedAverage = lib.weightedAverage
local libGetPointVelocity = lib.getPointVelocity
local libStructValueHistory = lib.StructValueHistory
local libSignedPow = lib.signedPow
local libClampEased = lib.clampEased
local libClamp01 = lib.clamp01
local libInverseLerp = lib.inverseLerp
local libLogInterpolation = lib.logInterpolation

local playerCarID = ac.getCarID(0) or "nil"

local function getGeneralConfigPath()
    return storage.getGeneralConfigDirectory() .. "\\" .. "generalConfig.json"
end

local function getCarSpecificConfigPath()
    return storage.getCarSpecificConfigDirectory() .. "\\" .. playerCarID .. ".json"
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

local function loadStoredSettings()
    local filePath1 = getGeneralConfigPath()

    if io.fileExists(filePath1) then
        local configJSON1 = storage.readFile(filePath1)
        if type(configJSON1) == "string" and string.len(configJSON1) >= 5 then
            if not storage.parseAndLoadSettingsJSON(generalConfig, configJSON1, storage.generalConfigKeys, storage.versionMigration) then
                ac.error("Invalid general config data")
            end
        else
            ac.error("Failed to load general config")
        end
    end

    local filePath2 = getCarSpecificConfigPath()

    if io.fileExists(filePath2) then
        local configJSON2 = storage.readFile(filePath2)
        if type(configJSON2) == "string" and string.len(configJSON2) >= 5 then
            if not storage.parseAndLoadSettingsJSON(carSpecificConfig, configJSON2, storage.carSpecificConfigKeys, storage.versionMigration) then
                ac.error("Invalid car-specific config data")
            end
        else
            ac.error("Failed to load car-specific config")
        end
    end
end

local function serializeGeneralConfig()
    return storage.serializeSettingsJSON(generalConfig, storage.generalConfigKeys, storage.versionStamp)
end

local function serializeCarSpecificConfig()
    return storage.serializeSettingsJSON(carSpecificConfig, storage.carSpecificConfigKeys, storage.versionStamp)
end

local function storeSettings(carSpecific, forced)
    local filePath = carSpecific and getCarSpecificConfigPath() or getGeneralConfigPath()

    storage.writeFileThrottled(filePath, carSpecific and serializeCarSpecificConfig or serializeGeneralConfig, nil, forced)
end

loadDefaultSettings()
loadStoredSettings()

ac.onRelease(function ()
    runtimeData.appCanRun = false
end)

storage.ffbHistoryBufferCapacity, runtimeData.ffbRawHistoryHead, runtimeData.ffbRawHistoryCount = libStructValueHistory.new(storage.ffbHistoryBufferCapacity)
storage.ffbHistoryBufferCapacity, runtimeData.ffbFinalHistoryHead, runtimeData.ffbFinalHistoryCount = libStructValueHistory.new(storage.ffbHistoryBufferCapacity)

local ffbSampleCounter = storage.ffbSampleRateDiv

for i = 0, storage.ffbHistoryBufferCapacity - 1, 1 do
    runtimeData.ffbRawHistoryBuffer[i] = 0.0
    runtimeData.ffbFinalHistoryBuffer[i] = 0.0
end

local cachedOverrideKeys = {} -- avoids string concatenations all the time
local function getConfigValue(key) -- includes car overrides
    local overrideKey = cachedOverrideKeys[key]
    if not overrideKey then
        overrideKey = "OVERRIDE_" .. key
        cachedOverrideKeys[key] = overrideKey
    end
    if carSpecificConfig[overrideKey] == true then
        return carSpecificConfig[key]
    end

    return generalConfig[key]
end

-- ============================ car telemetry stuff

local prevGearSetHash = 0
-- Returns `true` if the gear set hash had to be updated
---@param vehicle ac.StateCar
---@param cPhys ac.StateCarPhysics
local function updateGearSetHash(vehicle, cPhys)

    if vehicle.gearCount < 1 or not cPhys.gearRatios or #cPhys.gearRatios == 0 then return false end

    local currentGearSetHash = 0

    for gear = 1, vehicle.gearCount, 1 do
        currentGearSetHash = currentGearSetHash + (cPhys.gearRatios[gear + 1] * gear * 16)
    end

    currentGearSetHash = currentGearSetHash + cPhys.finalRatio * 1024
    currentGearSetHash = currentGearSetHash + vehicle.rpmLimiter

    local ret = (currentGearSetHash ~= prevGearSetHash)

    prevGearSetHash = currentGearSetHash

    return ret
end

local storedLocalWheelVel      = {[0] = vec3(), vec3(), vec3(), vec3()} -- Stores local wheel velocities to avoid creating new vectors on every update
local localWheelPositions      = {[0] = vec3(), vec3(), vec3(), vec3()} -- Static, only stored when the car first spawns
local savedWheelPositions      = false
local storedCarPerformanceData = nil
local storedShiftingTable      = {}
-- local storedWeightedFLocalVel  = vec3()
local storedFAxleLocalVel      = vec3()
local storedRAxleLocalVel      = vec3()
local storedMiddleVel          = vec3()
local fAxlePos                 = vec3(0.0, -0.2, 1.3)
local rAxlePos                 = vec3(0.0, -0.2, -1.3)
local avgWheelPos              = vec3(0.0, -0.2, 0.0)
local storedFWheelWeights      = {1.0, 1.0}
local storedRWheelWeights      = {1.0, 1.0}
local storedAllWheelWeights    = {1.0, 1.0, 1.0, 1.0}
local storedVData              = {}
local tmpTable2                = {}
local tmpTable4                = {}
local tmpTable42               = {}

-- Returns all relevant measurements and data related to the vehicle
local function getVehicleData()
    local vehiclePR              = ac.getCarPhysicsRate()
    local inverseBodyTransformPR = vehiclePR.transform:inverse() -- :mul(vehicle.physicsToGraphicsTransform)

    if not savedWheelPositions then
        inverseBodyTransformPR:transformPoint(vehiclePR.wheels[0].position):copyTo(localWheelPositions[0])
        inverseBodyTransformPR:transformPoint(vehiclePR.wheels[1].position):copyTo(localWheelPositions[1])
        inverseBodyTransformPR:transformPoint(vehiclePR.wheels[2].position):copyTo(localWheelPositions[2])
        inverseBodyTransformPR:transformPoint(vehiclePR.wheels[3].position):copyTo(localWheelPositions[3])
        fAxlePos:set(localWheelPositions[0]):add(localWheelPositions[1]):scale(0.5)
        rAxlePos:set(localWheelPositions[2]):add(localWheelPositions[3]):scale(0.5)
        avgWheelPos:set(localWheelPositions[0]):add(localWheelPositions[1]):add(localWheelPositions[2]):add(localWheelPositions[3]):scale(0.25)
        avgWheelPos.x = mathRound(avgWheelPos.x * 1000.0) / 1000.0
        avgWheelPos.y = mathRound(avgWheelPos.y * 1000.0) / 1000.0
        avgWheelPos.z = mathRound(avgWheelPos.z * 1000.0) / 1000.0
        savedWheelPositions = true
    end

    -- local fWheelWeights   = {libZeroGuard(vehicle.wheels[0].load), libZeroGuard(vehicle.wheels[1].load)}
    -- local rWheelWeights   = {libZeroGuard(vehicle.wheels[2].load), libZeroGuard(vehicle.wheels[3].load)}
    -- local allWheelWeights = {fWheelWeights[1], fWheelWeights[2], rWheelWeights[1], rWheelWeights[2]}
    storedFWheelWeights[1] = libZeroGuard(vehiclePR.wheels[0].load)
    storedFWheelWeights[2] = libZeroGuard(vehiclePR.wheels[1].load)
    storedRWheelWeights[1] = libZeroGuard(vehiclePR.wheels[2].load)
    storedRWheelWeights[2] = libZeroGuard(vehiclePR.wheels[3].load)
    -- storedAllWheelWeights[1] = storedFWheelWeights[1]
    -- storedAllWheelWeights[2] = storedFWheelWeights[2]
    -- storedAllWheelWeights[3] = storedRWheelWeights[1]
    -- storedAllWheelWeights[4] = storedRWheelWeights[2]

    tmpTable2[1]            = mathDeg(vehiclePR.wheels[0].slipAngle)
    tmpTable2[2]            = mathDeg(vehiclePR.wheels[1].slipAngle)
    local frontSlipDeg      = libNumberGuard(libWeightedAverage(tmpTable2, storedFWheelWeights))
    tmpTable2[1]            = mathDeg(vehiclePR.wheels[2].slipAngle)
    tmpTable2[2]            = mathDeg(vehiclePR.wheels[3].slipAngle)
    local rearSlipDeg       = libNumberGuard(libWeightedAverage(tmpTable2, storedRWheelWeights))
    tmpTable2[1]            = vehiclePR.wheels[0].slipRatio
    tmpTable2[2]            = vehiclePR.wheels[1].slipRatio
    local frontSlipRatio    = libNumberGuard(libWeightedAverage(tmpTable2, storedFWheelWeights))
    tmpTable2[1]            = vehiclePR.wheels[2].slipRatio
    tmpTable2[2]            = vehiclePR.wheels[3].slipRatio
    local rearSlipRatio     = libNumberGuard(libWeightedAverage(tmpTable2, storedRWheelWeights))
    tmpTable2[1]            = vehiclePR.wheels[0].ndSlip
    tmpTable2[2]            = vehiclePR.wheels[1].ndSlip
    local frontNdSlip       = libNumberGuard(libWeightedAverage(tmpTable2, storedFWheelWeights))
    tmpTable2[1]            = vehiclePR.wheels[2].ndSlip
    tmpTable2[2]            = vehiclePR.wheels[3].ndSlip
    local rearNdSlip        = libNumberGuard(libWeightedAverage(tmpTable2, storedRWheelWeights))
    -- tmpTable4[1]            = vehiclePR.wheels[0].ndSlip
    -- tmpTable4[2]            = vehiclePR.wheels[1].ndSlip
    -- tmpTable4[3]            = vehiclePR.wheels[2].ndSlip
    -- tmpTable4[4]            = vehiclePR.wheels[3].ndSlip
    -- local totalNdSlip       = libNumberGuard(libWeightedAverage(tmpTable4, storedAllWheelWeights))
    -- tmpTable42[1]           = storedAllWheelWeights[1] * vehiclePR.wheels[0].ndSlip
    -- tmpTable42[2]           = storedAllWheelWeights[2] * vehiclePR.wheels[1].ndSlip
    -- tmpTable42[3]           = storedAllWheelWeights[3] * vehiclePR.wheels[2].ndSlip
    -- tmpTable42[4]           = storedAllWheelWeights[4] * vehiclePR.wheels[3].ndSlip
    -- local totalNdSlipBiased = libNumberGuard(libWeightedAverage(tmpTable4, tmpTable42))

    local wheelbase = mathAbs(fAxlePos.z - rAxlePos.z)
    -- local trackWidth      = mathMax(mathAbs(localWheelPositions[0].x - localWheelPositions[1].x), mathAbs(localWheelPositions[2].x - localWheelPositions[3].x))

    -- Updating local wheel velocities
    for i = 0, 3 do
        libGetPointVelocity(localWheelPositions[i], vehiclePR.localAngularVelocity, vehiclePR.localVelocity, storedLocalWheelVel[i])
    end

    -- lib.weightedVecAverage({storedLocalWheelVel[0], storedLocalWheelVel[1]}, fWheelWeights, storedWeightedFLocalVel)
    libGetPointVelocity(fAxlePos, vehiclePR.localAngularVelocity, vehiclePR.localVelocity, storedFAxleLocalVel)
    libGetPointVelocity(rAxlePos, vehiclePR.localAngularVelocity, vehiclePR.localVelocity, storedRAxleLocalVel)
    libGetPointVelocity(avgWheelPos, vehiclePR.localAngularVelocity, vehiclePR.localVelocity, storedMiddleVel)

    local vehicleGR = ac.getCar(0) or car
    local cPhys = ac.getCarPhysics(0)
    local inverseBodyTransformGR = vehicleGR.transform:inverse()

    if vehicleGR == nil then
        ac.log("SHIT")
    end

---@diagnostic disable-next-line: param-type-mismatch
    if not storedCarPerformanceData or updateGearSetHash(vehicleGR, cPhys) then
---@diagnostic disable-next-line: param-type-mismatch
        storedCarPerformanceData = carPerformanceData:new(vehicleGR, cPhys)

        storedShiftingTable = storedCarPerformanceData:calcShiftingTable(0.05, 0.997)
    end

    local wheelAirborneRadiusThreshold = 1.25
    local nFrontWheelsAirborne = 0
    local nRearWheelsAirborne = 0
    local nWheelsAirborne = 0

    for i = 0, 3 do
        local contactDistance = vehiclePR.wheels[i].position:distance(vehiclePR.wheels[i].contactPoint)
        if contactDistance > vehicleGR.wheels[i].tyreRadius * wheelAirborneRadiusThreshold then
            nWheelsAirborne = nWheelsAirborne + 1
            if i < 2 then
                nFrontWheelsAirborne = nFrontWheelsAirborne + 1
            else
                nRearWheelsAirborne = nRearWheelsAirborne + 1
            end
        end
    end

    -- things that arent being used are commented out to save some computation, but they can be uncommented if needed

    storedVData.vehiclePR              = vehiclePR
    storedVData.vehicle                = vehicleGR
    storedVData.wheelbase              = wheelbase

    -- storedVData.wheelbaseFactor        = wheelbase / 2.5

    storedVData.inverseBodyTransformPR = inverseBodyTransformPR -- Used for converting points or vectors from global space to local space
    storedVData.inverseBodyTransformGR = inverseBodyTransformGR
    storedVData.localVel               = storedMiddleVel -- Local velocity vector of the vehicle at the average position of all 4 wheels
    storedVData.localHVelLen           = mathSqrt(storedMiddleVel.x * storedMiddleVel.x + storedMiddleVel.z * storedMiddleVel.z) -- Velocity magnitude of the vehicle on the local horizontal plane (m/s)

    -- storedVData.localAngularVel        = vehiclePR.localAngularVelocity
    -- storedVData.localWheelVelocities   = storedLocalWheelVel -- Wheel velocities in local space, 0-based indexing

    storedVData.fWheelWeights          = storedFWheelWeights -- Front wheel loads, for using a weighted average
    storedVData.rWheelWeights          = storedRWheelWeights -- Rear wheel loads, for using a weighted average

    -- storedVData.travelDirection        = libNumberGuard(mathDeg(mathAtan2(storedMiddleVel.x, storedMiddleVel.z))) -- The angle of the vehicle's velocity vector on the local horizontal plane (deg), at the average position of all wheels

    storedVData.frontSlipDeg           = frontSlipDeg -- Average front wheel slip angle, weighted by wheel load (deg)
    storedVData.rearSlipDeg            = rearSlipDeg -- Average rear wheel slip angle, weighted by wheel load (deg)
    storedVData.frontSlipRatio         = frontSlipRatio -- Average front wheel slip ratio, weighted by wheel load
    storedVData.rearSlipRatio          = rearSlipRatio -- Average rear wheel slip ratio, weighted by wheel load
    storedVData.frontNdSlip            = frontNdSlip -- Average normalized front slip, weighted by wheel load
    storedVData.rearNdSlip             = rearNdSlip -- Average normalized rear slip, weighted by wheel load

    -- storedVData.totalNdSlip            = totalNdSlip
    -- storedVData.totalNdSlipBiased      = totalNdSlipBiased
    -- storedVData.fwdVelClamped          = mathMax(0.0, storedMiddleVel.z) -- Velocity along the local forwrad axis, positive only (m/s)
    -- storedVData.fAxleLocalVel          = storedFAxleLocalVel -- Local velocity of the front axle (same as the average of the front wheels)

    storedVData.rAxleLocalVel          = storedRAxleLocalVel -- Local velocity of the rear axle (same as the average of the rear wheels)

    storedVData.fAxleHVelLen           = mathSqrt(storedFAxleLocalVel.x * storedFAxleLocalVel.x + storedFAxleLocalVel.z * storedFAxleLocalVel.z)
    storedVData.cPhys                  = cPhys
    storedVData.perfData               = storedCarPerformanceData
    storedVData.shiftingTable          = storedShiftingTable
    storedVData.nFrontWheelsAirborne   = nFrontWheelsAirborne
    storedVData.nRearWheelsAirborne    = nRearWheelsAirborne
    storedVData.nWheelsAirborne        = nWheelsAirborne

    return storedVData
end

-- ============================ helpers

local function weightedAverageWheelValue(values, wheelLoads, loadExponent)
    local result = 0.0
    local totalWeight = 0.0

    loadExponent = loadExponent or 1.0

    for i, _ in ipairs(values) do
        local value = values[i]
        local weight = wheelLoads[i] ^ loadExponent
        result = result + value * weight
        totalWeight = totalWeight + weight
    end

    if totalWeight == 0.0 then
        return 0.0
    end

    result = result / totalWeight

    return result
end

local function sineGenerator(phase, power, signedOutput)
    local sine = mathSin(phase * 2.0 * mathPi)
    local ret = libSignedPow(sine, power)
    if not signedOutput then
        ret = ret * 0.5 + 0.5
    end
    return ret
end

local function calcProgressiveFeedback(inputValue, rangeStart, rangeEnd, startingFeedback)
    if inputValue < rangeStart then
        return 0.0, 0.0
    end

    local initialFadeIn = mathSmoothstep(mathLerpInvSat(inputValue, rangeStart, mathLerp(rangeStart, rangeEnd, 0.1)))
    local progression = mathLerpInvSat(inputValue, rangeStart, rangeEnd)
    local fullRangeFeedback = (progression ^ 2.0) * initialFadeIn -- was 2.5
    return fullRangeFeedback * (1.0 - startingFeedback) + startingFeedback, fullRangeFeedback
end

local function centeringForceMult(normalizedSlipAngle)
    local x = 0.5 * normalizedSlipAngle + 0.5

    if x < 0.0 then
        return -1.0
    elseif x > 1.0 then
        return 1.0
    end

    return 2.0 * mathSmootherstep(x) - 1.0
end

local function getExponentialDecayBlend(dt, smoothingTime)
    smoothingTime = mathMax(1e-6, smoothingTime)
    return 1.0 - mathExp(-dt / smoothingTime)
end

-- ============================ state

local function getLowPassLimits(cornerFrequency)
    local relationship = 2.5
    local corner = mathMin(166.0 / relationship, cornerFrequency)
    local nyquist = mathMin(166.0, corner * relationship)
    return nyquist, corner
end

local physicsUpdateRate = 1000.0 / 3.0

local filter = biquadFilter.new("LowPass", biquadFilter.calculateLowPassParameters(physicsUpdateRate, getLowPassLimits(32.0)))
local brakeFeelFilter = biquadFilter.new("LowPass", biquadFilter.calculateLowPassParameters(physicsUpdateRate, getLowPassLimits(18.0)))
local rpmFilter = biquadFilter.new("LowPass", biquadFilter.calculateLowPassParameters(physicsUpdateRate, getLowPassLimits(24.0)))
local tSinceLastFrontABSPulse = 3600.0
local ffbABSFiltered = 0.0
local ffbPeakProtected = 0.0
local vibrationPhase = 0.0
local shiftWarning = false
local prevShiftWarningReset = 0.0
local prevEngagedGear = 0
local collisionProtectionTimer = 0.0
local configStoreCycle = false -- ensures that we only write up to 1 file per update to not take up too much time at once
local preCollisionFFBHistory = lib.ValueHistory:new(3)
local postRaceMultBlendSmoother = lib.SmoothTowards:new(1.0, 1.0, 0.0, 1.0, 0.0)
local tSinceRaceFinished = 0.0 -- only used for killing the ffb, dont use it for anything else
local initialSkips = 0
local vibrationFeedbackSmoother = lib.SmoothTowards:new(15.0, 0.05, 0.0, 1.0, 0.0)
local prevBrakingSR = 0.0
local oversteerFeelConditionSmoother = lib.SmoothTowards:new(4.0, 1.0, 0.0, 1.0, 1.0)
local lastCollisionProtectionBlend = 0.0
local lastEngagedGearChange = 0.0

-- local w0PrevNormal = vec3(0.0, 1.0, 0.0)
-- local w1PrevNormal = vec3(0.0, 1.0, 0.0)
-- local w0PrevSurfaceType = 0
-- local w1PrevSurfaceType = 0
-- local spikeRemovalTimer = 0.0

-- ============================ events

local function resetInitValues()
    storedCarPerformanceData = nil
    savedWheelPositions = false
    tSinceRaceFinished = 0.0
    postRaceMultBlendSmoother:reset()
    initialSkips = 0
    preCollisionFFBHistory:clear()
    vibrationFeedbackSmoother:reset()
    oversteerFeelConditionSmoother:reset()
    lastCollisionProtectionBlend = 0.0
    lastEngagedGearChange = 0.0
end

local function onFactoryReset()
    local dir = storage.getCarSpecificConfigDirectory()
    io.scanDir(dir, "*.json", function (fileName, fileAttributes, callbackData)
        io.deleteFile(dir .. "\\" .. fileName)
    end)

    resetInitValues()

    storeSettings(true, true)
    storeSettings(false, true)
end

ac.onCarJumped(0, function (carIndex)
    resetInitValues()
end)

ac.onSessionStart(function (sessionIndex, restarted)
    ac.log("SESSION START")
    resetInitValues()
end)

-- ============================ ffb processing

---@param surfaceType ac.SurfaceExtendedType
---@return number strengthMult, number velocityMult
local function getRoadTextureSurfaceParams(surfaceType) -- just based on vibes tbh
    if surfaceType == ac.SurfaceExtendedType.Base or surfaceType == ac.SurfaceExtendedType.Kerb or surfaceType == ac.SurfaceExtendedType.Old then
        return 1.0, 1.0
    end

    if surfaceType == ac.SurfaceExtendedType.ExtraTurf then
        return 0.5, 2.0
    end

    if surfaceType == ac.SurfaceExtendedType.Grass or surfaceType == ac.SurfaceExtendedType.Gravel or surfaceType == ac.SurfaceExtendedType.Sand then
        return 2.0, 0.5
    end

    if surfaceType == ac.SurfaceExtendedType.Snow or surfaceType == ac.SurfaceExtendedType.Ice then
        return 0.5, 1.0
    end

    return 1.0, 1.0
end

local roadTextureFilter1 = biquadFilter.new("HighPass", physicsUpdateRate, 55.0) -- high pass
local roadTextureFilter2 = biquadFilter.new("LowPass", biquadFilter.calculateLowPassParameters(physicsUpdateRate, 100.0, 75.0)) -- low pass
local prevFilteredNoise = 0.0
local prevSurfaceTypeStrength = 1.0
local function getRoadTextureNoise(fAxleHVelLen, frontAxleLoad, currentFrontAxleLoadEst, frontLsExpY, frontNdSlip, w0SurfaceType, w1SurfaceType)
    if frontAxleLoad < 1e-6 then
        return 0.0
    end

    local roadTextureV0 = 10.0 / 3.6
    local roadTextureV1 = 300.0 / 3.6
    local roadTextureV1OverV0 = roadTextureV1 / roadTextureV0
    local roadTextureBandStartV1 = 55.0
    local roadTextureBandStartV0 = roadTextureBandStartV1 / roadTextureV1OverV0
    local roadTextureBandEndV1 = 75.0
    local roadTextureBandEndV0 = roadTextureBandEndV1 / roadTextureV1OverV0
    local roadTextureNyquistV1 = 100.0
    local roadTextureNyquistV0 = roadTextureNyquistV1 / roadTextureV1OverV0

    local w0SurfaceTypeStrength, w0SpeedMult = getRoadTextureSurfaceParams(w0SurfaceType)
    local w1SurfaceTypeStrength, w1SpeedMult = getRoadTextureSurfaceParams(w1SurfaceType)
    local surfaceTypeStrengthMult = mathLerp(prevSurfaceTypeStrength, (w0SurfaceTypeStrength + w1SurfaceTypeStrength) * 0.5, getExponentialDecayBlend(0.003, 0.05))
    prevSurfaceTypeStrength = surfaceTypeStrengthMult
    local surfaceTypeSpeedMult = (w0SpeedMult + w1SpeedMult) * 0.5 -- technically the two speeds should be used to generate 2 different noise patterns, but this will do

    local velocityT = mathSmoothstep(mathLerpInvSat(fAxleHVelLen * surfaceTypeSpeedMult, roadTextureV0, roadTextureV1))
    -- local velocityT = mathLerpInvSat(fAxleHVelLen, roadTextureV0, roadTextureV1)
    local bandStart = mathLerp(roadTextureBandStartV0, roadTextureBandStartV1, velocityT)
    local bandEnd = mathLerp(roadTextureBandEndV0, roadTextureBandEndV1, velocityT * 0.9 + 0.1) -- the modified T allows slightly more high frequencies at low speed
    local nyquist = mathLerp(roadTextureNyquistV0, roadTextureNyquistV1, velocityT * 0.9 + 0.1)
    -- local bandStart = libLogInterpolation(roadTextureBandStartV0, roadTextureBandStartV1, velocityT)
    -- local bandEnd = libLogInterpolation(roadTextureBandEndV0, roadTextureBandEndV1, velocityT)
    -- local nyquist = libLogInterpolation(roadTextureNyquistV0, roadTextureNyquistV1, velocityT)
    nyquist = mathMin(166.0, nyquist)
    bandEnd = mathMin(nyquist * 0.9, bandEnd)
    roadTextureFilter1:updateParameters(physicsUpdateRate, bandStart)
    roadTextureFilter2:updateParameters(biquadFilter.calculateLowPassParameters(physicsUpdateRate, nyquist, bandEnd))
    local loadMult = (frontAxleLoad / currentFrontAxleLoadEst) ^ frontLsExpY
    local velocityMult = mathSmoothstep(mathLerpInvSat(fAxleHVelLen, 0.1 * roadTextureV0, mathMin(roadTextureV0 * 1.0, roadTextureV1)))
    local slipMult = mathAbs(2.0 * frontNdSlip / (frontNdSlip * frontNdSlip + 1.0))
    if frontNdSlip < 1.0 then
        slipMult = slipMult * 0.75 + 0.25
    end

    ac.debug("Hap | road texture surface type mult", surfaceTypeStrengthMult, 0.0, 1.0)

    local input = mathRandom()
    local filteredNoise = roadTextureFilter2:process(roadTextureFilter1:process(input)) * loadMult * velocityMult * slipMult * 6.0 -- correction factor for roughly 1.0 magnitude on average
    filteredNoise = mathLerp(prevFilteredNoise, filteredNoise, getExponentialDecayBlend(0.003, 0.005)) -- this just very slightly takes the edge off at higher speeds
    prevFilteredNoise = filteredNoise
    return libClampEased(filteredNoise, -2.0, 2.0, 0.25) * surfaceTypeStrengthMult -- this is applied outside the clamp
end

local function onProcessingSkip(ffbValue, vehicle) -- clears any leftover state from all the effects when the overall processing is disabled
    ffbABSFiltered = ffbValue
    brakeFeelFilter:reset(0.0)
    ffbPeakProtected = ffbValue
    filter:reset(ffbValue)
    shiftWarning = false
    vibrationPhase = 0.0
    vibrationFeedbackSmoother:reset()
    preCollisionFFBHistory:clear()
    prevEngagedGear = vehicle.engagedGear
    prevBrakingSR = 0.0
    oversteerFeelConditionSmoother:reset()
    lastCollisionProtectionBlend = 0.0
    runtimeData.autoGainLevel = -1
    runtimeData.downforceDynamicRange = -1
    -- w0PrevSurfaceType = vehicle.wheels[0].surfaceExtendedType -- should be vehicle PR but its probably ok
    -- w1PrevSurfaceType = vehicle.wheels[1].surfaceExtendedType
    -- w0PrevNormal:set(0.0, 1.0, 0.0)
    -- w1PrevNormal:set(0.0, 1.0, 0.0)
end

local lastGainChangeAttempt = 0.0
-- local prevRAxleHVelAngle = 0.0

local function processFFB(ffbValue, dt)

    local vData = getVehicleData()
    vData.perfData:updateTireTelemetry(vData, dt)
    vData.perfData:updateDownforceTelemetry(vData.vehiclePR, vData.wheelbase, rAxlePos.z, vData.cPhys, dt)

    local now = os.clock()

    local vRefPointNd = 0.7

    local frontPeakSlipAngle = vData.perfData:getTargetFrontSlipAngle()
    local rearPeakSlipAngle = vData.perfData:getTargetRearSlipAngle()
    local frontPeakSlipRatio = vData.perfData:getTargetFrontSlipRatio()
    local rearPeakSlipRatio = vData.perfData:getTargetRearSlipRatio()
    local topSpeedEst = vData.perfData:getTopSpeedEstimate()
    local vRef = topSpeedEst * vRefPointNd
    ac.debug("Gen | vRef", vRef * 3.6)
    local lowSpeedFade = mathSmoothstep(mathLerpInvSat(vData.localHVelLen, 4.0 / 3.6, 12.0 / 3.6)) -- fades out certain effects near a standstill
    local frontWheelLoadAtRest = vData.perfData:getFrontTireLoadAtRest(vData.wheelbase, rAxlePos.z)
    local frontWheelLoadAt70PercentSpeed = vData.perfData:getFrontTireLoadAtNdSpeed(vRefPointNd, vData.wheelbase, rAxlePos.z)
    local mzEstimateAt70PercentSpeed = vData.perfData:getMzEstimate(frontWheelLoadAt70PercentSpeed, vData.vehicle.wheels[1].tyreRadius)
    local frontWheelLoadAtCurrentSpeed = vData.perfData:getFrontTireLoadAtNdSpeed(vData.localHVelLen / topSpeedEst, vData.wheelbase, rAxlePos.z) -- not actual load, but the load according to the prediction algorithm, to be compatible with the rest of the predicted loads
    local mzEstimateAtCurrentSpeed = vData.perfData:getMzEstimate(frontWheelLoadAtCurrentSpeed, vData.vehicle.wheels[1].tyreRadius)
    local mzRatioInFFB = vData.perfData:getMzRatioInFFB(frontWheelLoadAt70PercentSpeed, vData.vehicle.wheels[1].tyreRadius, mzEstimateAt70PercentSpeed) -- when mz peaks what portion of the ffb strength is coming from the mz

    ac.debug("Tel | front nd slip", vData.frontNdSlip, 0.0, 2.0)
    ac.debug("Tel | rear nd slip", vData.rearNdSlip, 0.0, 2.0)

    -- ac.debug("W1 surface,", vData.vehiclePR.wheels[1].surfaceExtendedType)

    ac.debug("Gen | Mz ratio in FFB", mzRatioInFFB, 0.0, 1.0)

    -- ac.debug("est max front axle mz", mzEstimateAtCurrentSpeed)
    -- ac.debug("est max front axle mz old", vData.perfData:getMzEstimateOld(frontWheelLoadAtCurrentSpeed, vData.vehicle.wheels[1].tyreRadius))
    -- ac.debug("real front axle mz", vData.vehiclePR.wheels[0].mz + vData.vehiclePR.wheels[1].mz)
    -- ac.debug("frontWheelLoadAt70PercentSpeed", frontWheelLoadAt70PercentSpeed)
    -- ac.debug("mzEstimateAt70PercentSpeed", mzEstimateAt70PercentSpeed)
    -- ac.debug("w1 radius", vData.vehicle.wheels[1].tyreRadius)
    -- ac.debug("f tire rate", vData.perfData.frontTireRate)
    -- ac.debug("f fz0", vData.perfData.frontFZ0)
    -- ac.debug("f axis dot", vData.perfData.steerBasisAxis:dot(vec3(0, 1, 0)))

    -- ac.debug("W1 FX", vData.vehiclePR.wheels[1].fy)
    -- ac.debug("W1 FX est", vData.perfData:getFrontPeakLateralForceEst(vData.vehiclePR.wheels[1].load))
    -- ac.debug("max rpm", vData.perfData.maxRPM)

    -- ac.debug("DATA", string.format("%.1f\t%.1f\t%.1f\t%.1f\t%.0f\t%.4f\t%.4f", mathAbs(vData.vehiclePR.wheels[1].fy), mathAbs(vData.vehiclePR.wheels[1].mz), vData.vehiclePR.wheels[1].load, vData.perfData.frontFZ0, vData.perfData.frontTireRate, vData.perfData.steerBasisAxis:dot(vec3(0, 1, 0)), vData.vehicle.wheels[1].tyreRadius))

    local function getFFBBaseStrength(load, mz)
        load = load or frontWheelLoadAt70PercentSpeed
        mz = mz or mzEstimateAt70PercentSpeed
        return vData.perfData:getFFBPeakStrengthEstimate(load, vData.vehicle.wheels[1].tyreRadius, vData.vehicle.ffbBase, mz)
    end

    local ffbBaseStrengthVRef = getFFBBaseStrength()
    local ffbRefLevelVRef = ffbBaseStrengthVRef * ac.getFFBGain() -- includes inversion sign
    local ffbBaseStrengthVDynamic = getFFBBaseStrength(frontWheelLoadAtCurrentSpeed, mzEstimateAtCurrentSpeed)
    local ffbRefLevelVDynamic = ffbBaseStrengthVDynamic * ac.getFFBGain() -- includes inversion sign

    local rAxleHVelAngle = libNumberGuard(mathDeg(mathAtan2(vData.rAxleLocalVel.x, mathAbs(vData.rAxleLocalVel.z)))) -- reflected at 90 degrees
    local rAxleHVelAngleRaw = libNumberGuard(mathDeg(mathAtan2(vData.rAxleLocalVel.x, vData.rAxleLocalVel.z))) -- -180 to 180

    -- ac.debug("Gen | FFB est at vRef", ffbRefLevelVRef, -1.0, 1.0)

    -- local currentEstFFB = vData.perfData:getFFBPeakStrengthEstimateCurrent(vData.vehicle.ffbBase) * ac.getFFBGain()
    -- ac.debug("current est ffb", currentEstFFB, -1.0, 1.0)
    -- local frontSlipAngleNdAbs = mathAbs(vData.frontSlipDeg / frontPeakSlipAngle)
    -- if frontSlipAngleNdAbs > 0.35 and frontSlipAngleNdAbs < 0.45 and (vData.vehiclePR.wheels[0].load + vData.vehiclePR.wheels[1].load) > (frontWheelLoadAtCurrentSpeed * 2.0 * 0.5) and vData.vehiclePR.wheels[0].load > 0.0 and vData.vehiclePR.wheels[1].load > 0.0 and mathAbs(currentEstFFB) > 0.01 and vData.vehiclePR.wheels[0].surfaceExtendedType == ac.SurfaceExtendedType.Base and vData.vehiclePR.wheels[1].surfaceExtendedType == ac.SurfaceExtendedType.Base then
    --     ac.debug("ffb est ratio", mathAbs(ffbRefLevelVDynamic) / mathAbs(currentEstFFB))
    -- end

    local finalFFB = ffbValue

    -- auto gain

    local adjustAutoGain = getConfigValue("autoAdjustGain")
    local autoGainOffset = getConfigValue("autoGainOffset")
    local newGainMultiplier = 1.0 / ffbBaseStrengthVRef * (1.0 + autoGainOffset)
    newGainMultiplier = libNumberGuard(mathRound(mathClamp(newGainMultiplier, 0.2, 5.0) * 100.0) / 100.0, vData.vehicle.ffbMultiplier)
    runtimeData.autoGainLevel = mathRound(newGainMultiplier * 100.0)

    if adjustAutoGain and (now - lastGainChangeAttempt) >= (1.0 / 15.0) then
        lastGainChangeAttempt = now
        if mathAbs(vData.vehicle.ffbMultiplier - newGainMultiplier) > 0.00099 then
            ac.broadcastSharedEvent("AFFBT_setFFBMultiplier", newGainMultiplier)
        end
    end

    -- abs filter

    local absTriggerThreshold = 0.05

    if vData.vehiclePR.wheels[0].abs > absTriggerThreshold or vData.vehiclePR.wheels[1].abs > absTriggerThreshold then
        tSinceLastFrontABSPulse = 0.0
    else
        tSinceLastFrontABSPulse = mathMin(3600.0, tSinceLastFrontABSPulse + dt)
    end

    local absFilterBlend = 1.0

    if getConfigValue("absFilterEnabled") then
        local maxFilterRT = 0.0175 --0.0175
        local filterHoldTime = 0.1
        local filterFadeTime = 0.1
        local absFilterMult = mathSmoothstep(mathLerpInvSat(tSinceLastFrontABSPulse - filterHoldTime, filterFadeTime, 0.0))
        ac.debug("ABS Filt | current mult", absFilterMult, 0.0, 1.0)
        absFilterBlend = getExponentialDecayBlend(dt, maxFilterRT * absFilterMult)
        ffbABSFiltered = mathLerp(ffbABSFiltered, finalFFB, absFilterBlend)
        finalFFB = ffbABSFiltered
    else
        ffbABSFiltered = finalFFB
    end

    -- extra sat

    -- ac.debug("W1 FX", vData.vehiclePR.wheels[1].fy)
    -- ac.debug("W1 MZ", vData.vehiclePR.wheels[1].mz, -250, 250)
    -- ac.debug("W1 peak FX", vData.perfData:getFrontPeakLateralForceEst(vData.vehiclePR.wheels[1].load))
    -- ac.debug("W1 load", vData.vehiclePR.wheels[1].load)
    -- ac.debug("W0 load", vData.vehiclePR.wheels[0].load)
    -- ac.debug("W1 radius", vData.vehicle.wheels[1].tyreRadius)
    -- ac.debug("W1 radius 2", vData.vehicle.wheels[1].tyreLoadedRadius)
    -- ac.debug("W1 contact", vData.vehiclePR.wheels[1].contactPoint)
    -- ac.debug("W1 fake contact", vData.vehiclePR.transform:transformPoint(vData.inverseBodyTransformPR:transformPoint(vData.vehiclePR.wheels[1].position) - vec3(0.0, vData.vehicle.wheels[1].tyreLoadedRadius)))

    -- ac.debug("w1SteerCenter", vData.vehiclePR.wheels[1].position + vData.perfData.steerBasisCenter)
    -- ac.debug("w1SteerAxis1", vData.vehiclePR.wheels[1].position + vData.perfData.steerBasisCenter + vData.perfData.steerBasisAxis * 0.15)
    -- ac.debug("w1SteerAxis2", vData.vehiclePR.wheels[1].position + vData.perfData.steerBasisCenter - vData.perfData.steerBasisAxis * 0.15)

    -- if vData.perfData.tmpWbTop and vData.perfData.tmpWbBottom then
    --     ac.debug("wb top", vData.vehiclePR.wheels[0].transform:transformPoint(vData.perfData.tmpWbTop * vec3(-1, 1, 1)))
    --     ac.debug("wb bottom", vData.vehiclePR.wheels[0].transform:transformPoint(vData.perfData.tmpWbBottom * vec3(-1, 1, 1)))

    --     -- ac.debug("wb top raw", vData.perfData.tmpWbTop)
    --     -- ac.debug("wb bottom raw", vData.perfData.tmpWbBottom)
    -- end

    -- ac.debug("current ffb pred", vData.perfData:getFFBPeakStrengthEstimate((vData.vehiclePR.wheels[0].load + vData.vehiclePR.wheels[1].load) * 0.5, vData.vehicle.wheels[1].tyreRadius, vData.vehicle.ffbBase, (vData.vehiclePR.wheels[0].mz + vData.vehiclePR.wheels[1].mz) * mathSign(-vData.frontSlipDeg)) * mathAbs(ac.getFFBGain()), 0.0, 1.0)

    local extraSAT = getConfigValue("extraSAT")

    if getConfigValue("extraSATSuspensionCompensation") then
        extraSAT = extraSAT * mathMax(0.1, 0.5 / mzRatioInFFB - 1.0)
    end

    if extraSAT > 1e-6 then
        -- tmpVec1:set(vData.perfData.steerBasisAxis):mul(xMirrorVec)
        -- tmpVec2:set(vData.perfData.steerBasisAxis)
        -- local frontSATFFB = (
        --     vData.vehiclePR.wheels[0].mz * tmpVec1:dot(vData.vehiclePR.wheels[0].contactNormal) +
        --     vData.vehiclePR.wheels[1].mz * tmpVec2:dot(vData.vehiclePR.wheels[1].contactNormal)
        -- )
        local steeringRackExtraTorque = vData.perfData:getSteeringRackTorqueFromFrontMz(vData.vehiclePR.wheels[0].mz, vData.vehiclePR.wheels[1].mz, vData.vehiclePR.wheels[0].contactNormal, vData.vehiclePR.wheels[1].contactNormal)
        local extraSATMult = extraSAT * lowSpeedFade
        local addedSAT = steeringRackExtraTorque / 600.0 * vData.vehicle.ffbBase * ac.getFFBGain() * extraSATMult
        finalFFB = finalFFB + addedSAT

        if getConfigValue("extraSATMakeupGain") then
            local satCompMult = 1.0 / (1.0 + mzRatioInFFB * extraSAT)
            finalFFB = finalFFB * satCompMult
        end

        -- ac.debug("Estimate with SAT", ac.getFFBGain() * vData.perfData:getFFBPeakStrengthEstimate(frontWheelLoadAt70PercentSpeed, vData.vehicle.wheels[1].tyreRadius, vData.vehicle.ffbBase, mzEstimate * extraSAT))
        -- ac.debug("W1 CP est", vData.perfData:getFrontContactPatchLengthEstimate(vData.vehicle.wheels[1].load, vData.vehicle.wheels[1].tyreRadius))
    end

    -- downforce compensation

    local dfMultApplied = 1.0
    local dfMultAtRefSpeed = 1.0

    local dfCompMode = getConfigValue("downforceCompMode")
    if dfCompMode > 0 then

        local fDownforceMult = 0.27 * 2.0 -- // TODO figure this out

        local steerAssist = vData.perfData:getSteerAssistValue() -- sadly i cant get steer assist values from the setup screen, very cool
        ac.debug("DF Comp | steer assist", steerAssist)

        local dfDynamicRange = vData.perfData:getDownforceMaxDynamicRange()

        local downforceEffect = 1.0
        if dfCompMode == 1 then
            local dfMult = getConfigValue("downforceCompPercentage")
            if type(dfMult) == "number" then
                downforceEffect = dfMult
            end
        elseif dfCompMode == 2 then
            downforceEffect = libClamp01(getConfigValue("downforceCompDynamicRange") / dfDynamicRange)
        end

        runtimeData.downforceDynamicRange = mathMax(0.0, dfDynamicRange)

        local standstillLoadFactor = (frontWheelLoadAtRest / vData.perfData.frontFZ0) ^ steerAssist
        local currentLoadFactor = ((vData.perfData.fAxleDownforce * fDownforceMult + frontWheelLoadAtRest) / vData.perfData.frontFZ0) ^ steerAssist
        local ret = mathLerp(1.0 / (currentLoadFactor / standstillLoadFactor), 1.0, downforceEffect)
        local midSpeedLoadFactor = (frontWheelLoadAt70PercentSpeed / vData.perfData.frontFZ0) ^ steerAssist
        local multAtVRef = mathLerp(1.0 / (midSpeedLoadFactor / standstillLoadFactor), 1.0, downforceEffect)
        local makeupGain = 1.0

        if getConfigValue("downforceCompMakeupGain") then
            makeupGain = 1.0 / multAtVRef --mathLerp(1.0 / (standstillLoadFactor / midSpeedLoadFactor), 1.0, downforceEffect)
        end

        local ffbMult, ffbMultAtVRef = libNumberGuard(mathMin(1.0, ret) * makeupGain), libNumberGuard(mathMin(1.0, multAtVRef), 1.0)

        finalFFB = finalFFB * ffbMult
        dfMultApplied = ffbMult
        dfMultAtRefSpeed = ffbMultAtVRef
    else
        runtimeData.downforceDynamicRange = -1.0
    end

    ffbRefLevelVDynamic = ffbRefLevelVDynamic * dfMultApplied
    ac.debug("Gen | FFB est at vCurrent", ffbRefLevelVDynamic, -1.0, 1.0)

    -- brake feel

    local brakeFeel = getConfigValue("brakeFeel")
    local brakeFeelWithABS = getConfigValue("brakeFeelWithABS")
    local brakeFeelAllowed = (vData.vehicle.absMode == 0) or brakeFeelWithABS
    if brakeFeelAllowed and brakeFeel > 1e-6 then
        local frontLongitudinalForce = (vData.vehiclePR.wheels[0].fx + vData.vehiclePR.wheels[1].fx) * 0.5
        if getConfigValue("brakeFeelFilter") then
            frontLongitudinalForce = brakeFeelFilter:process(frontLongitudinalForce)
        else
            brakeFeelFilter:reset(frontLongitudinalForce)
        end

        local refForce = vData.perfData:getFrontPeakLongitudinalForceEst(frontWheelLoadAtRest * 1.4) -- the multiplier accounts for weight shifting to the front under braking. downforce is not included in this on purpose so the added force will scale with it
        local frontLongitudinalForceNd = frontLongitudinalForce / refForce
        ac.debug("Brk feel | front brake force nd", frontLongitudinalForceNd, 0.0, 2.0)
        local peakFrac = 5.0 -- 3.5 matches SAT
        local longitudinalFeelExponent = getConfigValue("brakeFeelExponent")
        local effectPeakStrength = brakeFeel * ffbRefLevelVRef * dfMultAtRefSpeed
        local longitudinalFeelAdditive = mathMax(0.0, libSignedPow(frontLongitudinalForceNd, longitudinalFeelExponent)) * effectPeakStrength * centeringForceMult(-peakFrac * vData.frontSlipDeg / frontPeakSlipAngle)
        longitudinalFeelAdditive = longitudinalFeelAdditive * lowSpeedFade
        finalFFB = finalFFB + longitudinalFeelAdditive

        if getConfigValue("brakeFeelMakeupGain") then
            finalFFB = finalFFB / ((effectPeakStrength * 0.5) / (ffbRefLevelVRef * dfMultAtRefSpeed) + 1.0) -- using reduced strength for the compensation because it will never be combined with full lateral force
        end
    else
        brakeFeelFilter:reset(0.0)
    end

    -- lockup feel

    local lockupFeel = getConfigValue("lockupFeel")
    local lockupFeelWithABS = getConfigValue("lockupFeelWithABS")
    local lockupFeelAllowed = (vData.vehicle.absMode == 0) or lockupFeelWithABS
    if lockupFeelAllowed and lockupFeel > 1e-6 then
        local lockupSRStart = 1.0
        local lockupSREnd = 2.0
        prevBrakingSR = mathLerp(prevBrakingSR, mathMax(0.0, -vData.frontSlipRatio), absFilterBlend) -- if the abs filter is enabled we also filter the slip ratio here to avoid adding back abs noise
        local frontSRUsed = prevBrakingSR
        local lockupFeelMult = mathLerp(1.0, 1.0 - lockupFeel, mathSmoothstep(mathLerpInvSat(frontSRUsed / frontPeakSlipRatio, lockupSRStart, lockupSREnd)))
        finalFFB = finalFFB * lockupFeelMult
    else
        prevBrakingSR = 0.0
    end

    -- oversteer feel

    local oversteerFeelProtectionFade = mathSmoothstep(oversteerFeelConditionSmoother:get(mathMin((vData.nWheelsAirborne >= 3) and 0.0 or 1.0, 1.0 - lastCollisionProtectionBlend * 0.5), dt)) -- fades out oversteer feel if either car car is airborne or if collision protection is active

    local oversteerFeel = getConfigValue("oversteerFeel")
    if oversteerFeel > 1e-6 then
        -- // TODO maybe add a config slider for where it starts
        -- local oversteerFeelStrength = ffbRefLevelVRef * dfMultAtRefSpeed * oversteerFeel
        local ndSlipAngleThreshold = getConfigValue("oversteerFeelAggression")
        local oversteerFeelStrength = ffbRefLevelVDynamic * oversteerFeel
        local reverseFade = mathSmoothstep(1.0 - mathLerpInvSat(mathAbs(rAxleHVelAngleRaw), 90.0, 110.0)) -- fading out oversteer feel if the car is reversing
        local rAxleHVelAngleUsed = rAxleHVelAngle -- + (rAxleHVelAngle - prevRAxleHVelAngle) / dt * 0.5
        local oversteerFeelAdditive = mathSmoothstep(mathLerpInvSat(mathAbs(rAxleHVelAngleUsed) / rearPeakSlipAngle, 0.9 * ndSlipAngleThreshold, 1.4 * ndSlipAngleThreshold)) * mathSign(rAxleHVelAngleUsed) * oversteerFeelStrength
        finalFFB = finalFFB + oversteerFeelAdditive * lowSpeedFade * reverseFade * oversteerFeelProtectionFade

        -- ac.debug("oversteer 1", mathAbs(rAxleHVelAngle) / rearPeakSlipAngle, 0.0, 4.0)
        -- ac.debug("oversteer 2", mathAbs(rAxleHVelAngle - mathDeg(vData.vehiclePR.localAngularVelocity.y) * 0.5) / rearPeakSlipAngle, 0.0, 4.0)
        -- ac.debug("oversteer 2", mathAbs(rAxleHVelAngle + (rAxleHVelAngle - prevRAxleHVelAngle) / dt * 0.5) / rearPeakSlipAngle, 0.0, 4.0)

        -- prevRAxleHVelAngle = rAxleHVelAngle

        if getConfigValue("oversteerFeelMakeupGain") then
            finalFFB = finalFFB * (1.0 / (oversteerFeel + 1.0)) -- // TODO maybe slightly reduced strength for this?
        end
    end

    -- collision protection

    if getConfigValue("peakReduction") then
        local collisionPhysicsPos = vData.vehicle.graphicsToPhysicsTransform:transformPoint(vData.vehicle.collisionPosition)

        local highestContactPatchY = -9999.9
        local carInvTransform = vData.inverseBodyTransformGR
        local localFrontZ = 0.0
        local localRearZ = 0.0
        for i = 0, 3 do
            local localWheelPos = carInvTransform:transformPoint(vData.vehicle.wheels[i].position) -- physics pos
            local localContactPatch = localWheelPos - vec3(0.0, vData.vehicle.wheels[i].tyreLoadedRadius, 0.0)
            if localContactPatch.y > highestContactPatchY then
                highestContactPatchY = localContactPatch.y
            end

            if i < 2 then
                localFrontZ = localFrontZ + localWheelPos.z
            else
                localRearZ = localRearZ + localWheelPos.z
            end
        end
        localFrontZ = localFrontZ * 0.5
        localRearZ = localRearZ * 0.5
        -- ac.debug("carPos2", car.transform:transformPoint(car.graphicsToPhysicsTransform:transformPoint(vec3(-0.876232, 0.210434, 1.64501))))

        local bottomTolerance = vData.vehicle.aabbSize.y * 0.05 + mathLerp(vData.vehicle.rideHeight[0], vData.vehicle.rideHeight[1], libInverseLerp(localFrontZ, localRearZ, collisionPhysicsPos.z))

        -- local collPosTmp = collisionPhysicsPos:clone()
        -- collPosTmp.y = highestContactPatchY + bottomTolerance
        -- ac.debug("Col prot | collision", collisionPhysicsPos)
        -- ac.debug("Col prot | bottom tolerance", collPosTmp)

        local protectionFadeOutDuration = 0.5
        local maxProtectionTimerDuration = 1.0

        if vData.vehicle.collisionDepth > 1e-6 and collisionPhysicsPos.y > (highestContactPatchY + bottomTolerance) then
            if collisionProtectionTimer < protectionFadeOutDuration * 0.5 then -- yes this is correct
                local minValue = 9999
                for i = 1, preCollisionFFBHistory:getNewestIndex(), 1 do
                    local val = preCollisionFFBHistory:get(i)
                    if mathAbs(val) < mathAbs(minValue) then -- and mathSign(val) == mathSign(minValue)
                        minValue = val
                    end
                end
                if minValue ~= 9999 then
                    ffbPeakProtected = minValue -- when a collision starts we use the lowest force from the past few updates as the starting point for the filter, this helps reducing the initial spikes more
                end
            end
            collisionProtectionTimer = maxProtectionTimerDuration
        end

        if collisionProtectionTimer > 1e-6 then
            if (vData.localVel:length() > 12.0 / 3.6) and vData.nWheelsAirborne > 0 then
                collisionProtectionTimer = maxProtectionTimerDuration
            end
        end

        local collisionProtectionBlend = mathSmoothstep(mathLerpInvSat(collisionProtectionTimer, 0.0, protectionFadeOutDuration))
        collisionProtectionTimer = mathMax(0.0, collisionProtectionTimer - dt / 1.0)
        local ffbUsed = finalFFB
        -- ffbUsed = ffbUsed * mathLerp(1.0, 0.75, collisionProtectionBlend) -- is this good
        if collisionProtectionBlend > 1e-6 and mathAbs(ffbUsed) < mathAbs(ffbPeakProtected) * 0.999 then -- less filtering if the ffb is reducing, this prevents high values from being held too long
            collisionProtectionBlend = mathMin(collisionProtectionBlend, 0.1)
        end
        local finalCollisionProtectionBlend = collisionProtectionBlend
        local smoothingTime = 0.22
        ffbPeakProtected = mathLerp(ffbPeakProtected, ffbUsed, getExponentialDecayBlend(dt, smoothingTime * finalCollisionProtectionBlend))
        local peakProtectionDiff = 0.075 -- allows a small amount of deviation from the filtered version
        local ffbProtected2 = libClampEased(ffbUsed, ffbPeakProtected - mathAbs(ffbRefLevelVDynamic) * peakProtectionDiff, ffbPeakProtected + mathAbs(ffbRefLevelVDynamic) * peakProtectionDiff, 0.5)
        ac.debug("Col prot | protection blend", finalCollisionProtectionBlend, 0.0, 1.0)
        finalFFB = ffbProtected2
        lastCollisionProtectionBlend = finalCollisionProtectionBlend
    else
        ffbPeakProtected = finalFFB
        lastCollisionProtectionBlend = 0.0
    end

    -- road texture

    local extraAdditivePostFilter = 0.0
    local roadTextureSetting = getConfigValue("roadTexture")
    if roadTextureSetting > 1e-6 then
        local roadTextureNoise = getRoadTextureNoise(
            vData.fAxleHVelLen,
            vData.vehiclePR.wheels[0].load + vData.vehiclePR.wheels[1].load,
            frontWheelLoadAtCurrentSpeed * 2.0,
            vData.perfData.frontLsExpY,
            vData.frontNdSlip,
            vData.vehiclePR.wheels[0].surfaceExtendedType,
            vData.vehiclePR.wheels[1].surfaceExtendedType
        )
        ac.debug("Hap | road texture", roadTextureNoise, -1.0, 1.0)
        local roadTextureAdditive = ffbRefLevelVDynamic * roadTextureSetting * roadTextureNoise
        if getConfigValue("roadTextureBypassFilter") then
            extraAdditivePostFilter = roadTextureAdditive
        else
            finalFFB = finalFFB + roadTextureAdditive
        end
    end


    -- -- spike removal

    -- if true then
    --     local w0Normal = vData.vehiclePR.wheels[0].load > 1e-6 and vData.vehiclePR.wheels[0].contactNormal or vData.vehicle.wheels[0].up
    --     local w1Normal = vData.vehiclePR.wheels[1].load > 1e-6 and vData.vehiclePR.wheels[1].contactNormal or vData.vehicle.wheels[1].up
    --     local w0NormalChangeRate = libNumberGuard(lib.angleBetween(w0PrevNormal, w0Normal) / dt)
    --     local w1NormalChangeRate = libNumberGuard(lib.angleBetween(w1PrevNormal, w1Normal) / dt)
    --     w0PrevNormal:set(w0Normal)
    --     w1PrevNormal:set(w1Normal)
    --     local w0DamperVel = vData.vehiclePR.wheels[0].damperSpeed
    --     local w1DamperVel = vData.vehiclePR.wheels[1].damperSpeed
    --     local w0SurfaceType = vData.vehiclePR.wheels[0].surfaceExtendedType
    --     local w1SurfaceType = vData.vehiclePR.wheels[1].surfaceExtendedType

    --     local damperVelThreshold = 1.1
    --     local normalChangeRateThreshold = 100.0

    --     local protectionFadeOutDuration = 0.15
    --     local maxProtectionTimerDuration = 0.3

    --     if w0NormalChangeRate > normalChangeRateThreshold or w1NormalChangeRate > normalChangeRateThreshold or w0DamperVel > damperVelThreshold or w1DamperVel > damperVelThreshold or w0SurfaceType ~= w0PrevSurfaceType or w1SurfaceType ~= w1PrevSurfaceType then
    --         local minValue = 9999.0
    --         for i = 1, preCollisionFFBHistory:getNewestIndex(), 1 do
    --             local val = preCollisionFFBHistory:get(i)
    --             if mathAbs(val) < mathAbs(minValue) then
    --                 minValue = val
    --             end
    --         end
    --         ffbPeakProtected = minValue -- when a collision starts we use the lowest force from the past few updates as the starting point for the filter, this helps reducing the initial spikes more
    --         spikeRemovalTimer = maxProtectionTimerDuration
    --     end

    --     w0PrevSurfaceType = w0SurfaceType
    --     w1PrevSurfaceType = w1SurfaceType

    --     local spikeRemovalBlend = mathSmoothstep(mathLerpInvSat(spikeRemovalTimer, 0.0, protectionFadeOutDuration))
    --     spikeRemovalTimer = mathMax(0.0, spikeRemovalTimer - dt / 1.0)

    --     if spikeRemovalBlend > 1e-6 and mathAbs(finalFFB) < mathAbs(ffbPeakProtected) then -- less filtering if the ffb is reducing, this prevents high values from being held too long
    --         spikeRemovalBlend = 0.1 --mathMin(0.1, finalCollisionProtectionBlend)
    --     end

    --     ac.debug("spikeRemovalBlend", spikeRemovalBlend, 0.0, 1.0)

    --     finalPeakRemovalBlend = mathMax(finalPeakRemovalBlend, spikeRemovalBlend)
    --     -- ac.debug("W1 normal angular vel", w1NormalChangeRate, 0.0, 100.0)
    --     -- ac.debug("W1 damper vel", vData.vehiclePR.wheels[1].damperSpeed, -1.0, 1.0)
    -- else
    --     w0PrevSurfaceType = vData.vehiclePR.wheels[0].surfaceExtendedType
    --     w1PrevSurfaceType = vData.vehiclePR.wheels[1].surfaceExtendedType
    --     w0PrevNormal:set(0.0, 1.0, 0.0)
    --     w1PrevNormal:set(0.0, 1.0, 0.0)
    -- end

    -- general filter

    if getConfigValue("filterEnabled") then
        local filterFrequency = getConfigValue("filterFrequency")

---@diagnostic disable-next-line: param-type-mismatch
        filter:updateParameters(biquadFilter.calculateLowPassParameters(physicsUpdateRate, getLowPassLimits(filterFrequency)))
        local filteredFFB = filter:process(finalFFB)
        finalFFB = filteredFFB
    else
        filter:reset(finalFFB)
    end

    finalFFB = finalFFB + extraAdditivePostFilter

    -- haptics, after the filter so the vibrations dont get killed by filtering

    local vibrationSource = getConfigValue("vibrationSource")
    local rpmExtrapolation = 0.075 -- controls how long before the shifting point the vibration kicks in. no particular unit, tune by observation
    local rawExtrapolatedRPM = vData.vehiclePR.rpm * (1.0 + vData.vehiclePR.gForces.z * rpmExtrapolation)
    local smoothExtrapolatedRPM = rpmFilter:process(rawExtrapolatedRPM)

    local frontNdSlipAngleAbs = mathAbs(vData.frontSlipDeg / frontPeakSlipAngle)
    local rearNdSlipAngleAbs = mathAbs(vData.rearSlipDeg / rearPeakSlipAngle)
    local drivenAxleSlipRatio = (vData.vehicle.tractionType == 1) and vData.frontSlipRatio or vData.rearSlipRatio
    local drivenAxlePeakSlipRatio = (vData.vehicle.tractionType == 1) and frontPeakSlipRatio or rearPeakSlipRatio
    local drivenAxleNdSlipAngleAbs = (vData.vehicle.tractionType == 1) and frontNdSlipAngleAbs or rearNdSlipAngleAbs
    local drivenAxleNdSlipRatio = drivenAxleSlipRatio / drivenAxlePeakSlipRatio
    local engagedGear = vData.vehicle.engagedGear

    local canShift = (vData.vehiclePR.gForces.z > 0.005) and (vData.vehiclePR.gas > 0.01) and (mathAbs(rAxleHVelAngleRaw) < 90.0) and (drivenAxleNdSlipRatio > 0.01 and drivenAxleNdSlipRatio < 1.5)

    if (engagedGear ~= prevEngagedGear) or (not canShift) then
        shiftWarning = false
        prevShiftWarningReset = now
    end

    if (engagedGear ~= prevEngagedGear) then
        lastEngagedGearChange = now
    end

    prevEngagedGear = engagedGear

    if vibrationSource > 0 then
        local vibrationLevel = getConfigValue("vibrationLevel")
        local vibrationBaseFrequency = getConfigValue("vibrationBaseFrequency")
        local sineVibrationExponent = mathMax(1e-6, (1.0 - getConfigValue("vibrationSharpness")) ^ 2.0)

        if vibrationSource == 5 then

            if not (shiftWarning and canShift) and (now - prevShiftWarningReset > 0.1) then
                if vData.shiftingTable[engagedGear] then
                    shiftWarning = (smoothExtrapolatedRPM >= vData.shiftingTable[engagedGear].upshiftRPM)
                end
            end

            local vibrationFrequency = vibrationBaseFrequency
            local finalFeedback = vibrationFeedbackSmoother:getWithRate(shiftWarning and 1.0 or 0.0, dt, vibrationFrequency * 1.25) -- was 1.5

            ac.debug("Hap | vibration feedback raw", shiftWarning and 1.0 or 0.0, 0.0, 1.0)
            ac.debug("Hap | vibration feedback smooth", finalFeedback, 0.0, 1.0)

            if finalFeedback > 0.01 then
                vibrationPhase = (vibrationPhase + vibrationFrequency * dt) % 1.0
                local vibrationAdditive = sineGenerator(vibrationPhase, sineVibrationExponent, true) * (ffbRefLevelVRef * dfMultAtRefSpeed) * finalFeedback * vibrationLevel
                finalFFB = finalFFB + vibrationAdditive * lowSpeedFade
            else
                vibrationPhase = 0.0
            end

        else

            local feedbackValue = 0.0
            local feedbackFullRange = 0.0
            local feedbackRampBegin = 0.5
            local feedbackRampEnd = 1.0
            local feedbackBrakeInputOffset = 0.1 -- used for an earlier or later warning than normal. positive is earlier
            local feedbackBaseline = 0.3
            local frequencyRampEnd = 2.0

            local function getNdSlipRatioTarget(ndSlipAngleAbs, ndTarget)
                return (1.0 - ((0.85 / ndTarget * libClamp01(ndSlipAngleAbs)) ^ 2.4)) * ndTarget
                -- return ndTarget
            end

            local function slipRatioFeedbackImpl(currentSlipRatio, peakSlipRatio, currentNdSlipAngleAbs)
                -- return calcProgressiveFeedback(
                --     currentSlipRatio,
                --     peakSlipRatio * mathClamp(getNdSlipRatioTarget(currentNdSlipAngle, feedbackRampBegin), 0.5, 1.0),
                --     peakSlipRatio * mathClamp(getNdSlipRatioTarget(currentNdSlipAngle, feedbackRampEnd), 0.5, 1.0),
                --     feedbackBaseline
                -- )

                -- this version below is less accurate but its needed to keep the values sane for the feedback ramp

                -- local peakUsed = mathLerp(getNdSlipRatioTarget(currentNdSlipAngleAbs, 1.0), 1.0, 0.5)
                local peakUsed = getNdSlipRatioTarget(currentNdSlipAngleAbs * 0.75, 1.0)
                local startMult = peakUsed * feedbackRampBegin
                local endMult = peakUsed * feedbackRampEnd

                return calcProgressiveFeedback(
                    currentSlipRatio,
                    peakSlipRatio * startMult,
                    peakSlipRatio * endMult,
                    feedbackBaseline
                )
            end

            local function getBrakeHelpFeedback() -- only considers front wheels for now
                if vData.vehiclePR.brake > 0.01 and vData.vehicle.absMode < 1 then
                    local baseValue = -vData.frontSlipRatio * mathSign(vData.localVel.z)
                    baseValue = baseValue + feedbackBrakeInputOffset * frontPeakSlipRatio
                    return slipRatioFeedbackImpl(baseValue, frontPeakSlipRatio, frontNdSlipAngleAbs)
                end
                return 0.0, 0.0
            end

            local function getThrottleHelpFeedback()
                local feedbackCooldownAfterShifting = 0.25
                if vData.vehiclePR.gas > 0.01 and vData.vehicle.tractionControlMode < 1 and (now - lastEngagedGearChange) > feedbackCooldownAfterShifting then
                    return slipRatioFeedbackImpl(drivenAxleSlipRatio * mathSign(engagedGear), drivenAxlePeakSlipRatio, drivenAxleNdSlipAngleAbs)
                end

                return 0.0, 0.0
            end

            if vibrationSource == 1 then
                -- braking help
                feedbackValue, feedbackFullRange = getBrakeHelpFeedback()
            elseif vibrationSource == 2 then
                -- throttle help
                feedbackValue, feedbackFullRange = getThrottleHelpFeedback()
            elseif vibrationSource == 3 then
                -- braking + throttle help
                if drivenAxleSlipRatio * mathSign(engagedGear) < 0.0 then
                    feedbackValue, feedbackFullRange = getBrakeHelpFeedback()
                else
                    feedbackValue, feedbackFullRange = getThrottleHelpFeedback()
                end
            elseif vibrationSource == 4 then
                -- understeer
                -- feedbackValue = mathSmoothstep(mathLerpInvSat(mathAbs(vData.frontSlipDeg) / frontPeakSlipAngle, 0.9, 1.4))
                feedbackValue, feedbackFullRange = calcProgressiveFeedback(mathAbs(vData.frontSlipDeg), frontPeakSlipAngle * 0.95, frontPeakSlipAngle * 1.5, feedbackBaseline)
            end

            local vibrationFrequency = libLogInterpolation(vibrationBaseFrequency, vibrationBaseFrequency * frequencyRampEnd, feedbackFullRange)
            local finalFeedback = vibrationFeedbackSmoother:getWithRate(feedbackValue, dt, vibrationFrequency * 1.5)

            ac.debug("Hap | vibration feedback raw", feedbackValue, 0.0, 1.0)
            ac.debug("Hap | vibration feedback smooth", finalFeedback, 0.0, 1.0)

            if feedbackValue > 0.01 then
                vibrationPhase = (vibrationPhase + vibrationFrequency * dt) % 1.0
                local vibrationAdditive = sineGenerator(vibrationPhase, sineVibrationExponent, true) * (ffbRefLevelVRef * dfMultAtRefSpeed) * feedbackValue * 1.5 * vibrationLevel -- the 1.5 is because feedbackValue can be <1 so it compensates for the average strength
                finalFFB = finalFFB + vibrationAdditive * lowSpeedFade
            else
                vibrationPhase = 0.0
            end

        end
    else
        shiftWarning = false
        vibrationPhase = 0.0
        vibrationFeedbackSmoother:reset()
        prevEngagedGear = vData.vehicle.engagedGear
    end

    return finalFFB
end

function script.update(ffbValue, ffbDamper, steerInput, steerInputSpeed, dt)

    if runtimeData.factoryResetPerformed then
        runtimeData.factoryResetPerformed = false
        onFactoryReset()
    else
        if (os.clock() - runtimeData.appHeartbeatClock) < 7.0 then -- no need to continue writing files if the ui app isnt running since the settings wont be changing
            storeSettings(configStoreCycle)
            configStoreCycle = not configStoreCycle
        end
    end

    runtimeData.appCanRun = true

    if mathAbs(dt - 0.003) > 1e-6 then
        ac.warn("Delta time is sus")
    end

    local vehicle = ac.getCar(0) or car

    if initialSkips < 2 then -- not necessary anymore with pcall, but whatever
        initialSkips = initialSkips + 1
        return ffbValue, ffbDamper
    end

    ac.debug("Gen | original FFB", ffbValue, -1.0, 1.0)

    local finalFFB = ffbValue
    local scriptEnabled = getConfigValue("scriptEnabled")

    if scriptEnabled and not (ac.getCarSetupState() == "validating" or vehicle.isInPit) then -- sadly there is no good way to detect if the player is on the setup screen
        local success = false
        success, finalFFB = pcall(processFFB, ffbValue, dt)

        if not success then
            ac.error("Something exploded. This should stop in a second or so, otherwise something is up.")

            return ffbValue, ffbDamper
        end

        finalFFB = libNumberGuard(finalFFB, ffbValue)

        -- finalFFB = processFFB(ffbValue, dt)
    else
        onProcessingSkip(ffbValue, vehicle)
    end

    local sim = ac.getSim()

    -- ac.debug("vehicle.isInPitlane", vehicle.isInPitlane)
    -- ac.debug("sim.raceFlagType", sim.raceFlagType)
    -- ac.debug("sim.raceSessionType", sim.raceSessionType)
    -- ac.debug("sim.isSessionFinished", sim.isSessionFinished) -- turns true after crossing the finish, but im using flag type instead of this
    -- ac.debug("sim.isSessionStarted", sim.isSessionStarted) -- false before the race start, then stays true after the lights go out until the next session
    -- ac.debug("sim.currentSessionIndex", sim.currentSessionIndex)
    -- ac.debug("sim.isOnlineRace", sim.isOnlineRace)
    -- ac.debug("sim.sessionTimeLeft", sim.sessionTimeLeft)

    -- post-race fade
    -- this is outside the main ffb processing function because it needs to keep track of sessions, so it needs to run on every update

    if sim.isOnlineRace and sim.isSessionStarted and sim.raceSessionType == ac.SessionType.Race then
        if sim.raceFlagType == ac.FlagType.Finished and tSinceRaceFinished >= 0.0 then
            if vehicle.isInPitlane then
                tSinceRaceFinished = -1.0 -- negative means we won't decrease ffb in the current session again
            else
                tSinceRaceFinished = tSinceRaceFinished + dt
            end
        end
    else
        tSinceRaceFinished = 0.0 -- reset this to 0 when a different session is detected
    end

    local postRaceFFBMultRawBlend = ((tSinceRaceFinished - 1.0) > 1e-6) and 1.0 or 0.0
    local postRaceFFBMultSmooth = mathLerp(1.0, getConfigValue("ffbLevelAfterFinish"), mathSmoothstep(postRaceMultBlendSmoother:get(postRaceFFBMultRawBlend, dt)))
    postRaceFFBMultSmooth = scriptEnabled and postRaceFFBMultSmooth or 1.0

    finalFFB = finalFFB * postRaceFFBMultSmooth

    ac.debug("Gen | current post race mult", postRaceFFBMultSmooth, 0.0, 1.0)

    -- no more modifying ffb after this

    local finalGuardedFFB = libNumberGuard(finalFFB, ffbValue)

    ac.debug("Gen | final FFB", finalGuardedFFB, -1.0, 1.0)

    runtimeData.rawFFB = ffbValue
    runtimeData.finalFFB = finalGuardedFFB

    ffbSampleCounter = ffbSampleCounter - 1
    if ffbSampleCounter <= 0 then
        ffbSampleCounter = storage.ffbSampleRateDiv
        runtimeData.ffbRawHistoryHead, runtimeData.ffbRawHistoryCount = libStructValueHistory.push(
            runtimeData.ffbRawHistoryBuffer,
            storage.ffbHistoryBufferCapacity,
            runtimeData.ffbRawHistoryHead,
            runtimeData.ffbRawHistoryCount,
            ffbValue
        )
        runtimeData.ffbFinalHistoryHead, runtimeData.ffbFinalHistoryCount = libStructValueHistory.push(
            runtimeData.ffbFinalHistoryBuffer,
            storage.ffbHistoryBufferCapacity,
            runtimeData.ffbFinalHistoryHead,
            runtimeData.ffbFinalHistoryCount,
            finalGuardedFFB
        )
    end

    return finalGuardedFFB, ffbDamper
end