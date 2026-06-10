local storage = require "Storage"

local generalConfig = ac.connect(storage.generalConfig)
local carSpecificConfig = ac.connect(storage.carSpecificConfig)
local runtimeData = ac.connect(storage.runtimeData)

-- ============================ storage/config and ui app data connection

runtimeData.appCanRun = false
runtimeData.autoGainLevel = -1

if ac.getPatchVersionCode() < 3465 then
    return
end

local biquadFilter = require("BiquadFilter")
local carPerformanceData = require("CarPerformanceData3")
---@diagnostic disable-next-line: different-requires
local lib = require("AGALib2")

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

storage.ffbHistoryBufferCapacity, runtimeData.ffbRawHistoryHead, runtimeData.ffbRawHistoryCount = lib.StructValueHistory.new(storage.ffbHistoryBufferCapacity)
storage.ffbHistoryBufferCapacity, runtimeData.ffbFinalHistoryHead, runtimeData.ffbFinalHistoryCount = lib.StructValueHistory.new(storage.ffbHistoryBufferCapacity)

local ffbSampleCounter = storage.ffbSampleRateDiv

for i = 0, storage.ffbHistoryBufferCapacity - 1, 1 do
    runtimeData.ffbRawHistoryBuffer[i] = 0.0
    runtimeData.ffbFinalHistoryBuffer[i] = 0.0
end

local function getConfigValue(key) -- includes car overrides
    if carSpecificConfig["OVERRIDE_" .. key] == true then
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
        avgWheelPos.x = math.round(avgWheelPos.x * 1000.0) / 1000.0
        avgWheelPos.y = math.round(avgWheelPos.y * 1000.0) / 1000.0
        avgWheelPos.z = math.round(avgWheelPos.z * 1000.0) / 1000.0
        savedWheelPositions = true
    end

    -- local fWheelWeights   = {lib.zeroGuard(vehicle.wheels[0].load), lib.zeroGuard(vehicle.wheels[1].load)}
    -- local rWheelWeights   = {lib.zeroGuard(vehicle.wheels[2].load), lib.zeroGuard(vehicle.wheels[3].load)}
    -- local allWheelWeights = {fWheelWeights[1], fWheelWeights[2], rWheelWeights[1], rWheelWeights[2]}
    storedFWheelWeights[1] = lib.zeroGuard(vehiclePR.wheels[0].load)
    storedFWheelWeights[2] = lib.zeroGuard(vehiclePR.wheels[1].load)
    storedRWheelWeights[1] = lib.zeroGuard(vehiclePR.wheels[2].load)
    storedRWheelWeights[2] = lib.zeroGuard(vehiclePR.wheels[3].load)
    storedAllWheelWeights[1] = storedFWheelWeights[1]
    storedAllWheelWeights[2] = storedFWheelWeights[2]
    storedAllWheelWeights[3] = storedRWheelWeights[1]
    storedAllWheelWeights[4] = storedRWheelWeights[2]

    tmpTable2[1]            = math.deg(vehiclePR.wheels[0].slipAngle)
    tmpTable2[2]            = math.deg(vehiclePR.wheels[1].slipAngle)
    local frontSlipDeg      = lib.numberGuard(lib.weightedAverage(tmpTable2, storedFWheelWeights))
    tmpTable2[1]            = math.deg(vehiclePR.wheels[2].slipAngle)
    tmpTable2[2]            = math.deg(vehiclePR.wheels[3].slipAngle)
    local rearSlipDeg       = lib.numberGuard(lib.weightedAverage(tmpTable2, storedRWheelWeights))
    tmpTable2[1]            = vehiclePR.wheels[0].slipRatio
    tmpTable2[2]            = vehiclePR.wheels[1].slipRatio
    local frontSlipRatio    = lib.numberGuard(lib.weightedAverage(tmpTable2, storedFWheelWeights))
    tmpTable2[1]            = vehiclePR.wheels[2].slipRatio
    tmpTable2[2]            = vehiclePR.wheels[3].slipRatio
    local rearSlipRatio     = lib.numberGuard(lib.weightedAverage(tmpTable2, storedRWheelWeights))
    tmpTable2[1]            = vehiclePR.wheels[0].ndSlip
    tmpTable2[2]            = vehiclePR.wheels[1].ndSlip
    local frontNdSlip       = lib.numberGuard(lib.weightedAverage(tmpTable2, storedFWheelWeights))
    tmpTable2[1]            = vehiclePR.wheels[2].ndSlip
    tmpTable2[2]            = vehiclePR.wheels[3].ndSlip
    local rearNdSlip        = lib.numberGuard(lib.weightedAverage(tmpTable2, storedRWheelWeights))
    tmpTable4[1]            = vehiclePR.wheels[0].ndSlip
    tmpTable4[2]            = vehiclePR.wheels[1].ndSlip
    tmpTable4[3]            = vehiclePR.wheels[2].ndSlip
    tmpTable4[4]            = vehiclePR.wheels[3].ndSlip
    local totalNdSlip       = lib.numberGuard(lib.weightedAverage(tmpTable4, storedAllWheelWeights))
    tmpTable42[1]           = storedAllWheelWeights[1] * vehiclePR.wheels[0].ndSlip
    tmpTable42[2]           = storedAllWheelWeights[2] * vehiclePR.wheels[1].ndSlip
    tmpTable42[3]           = storedAllWheelWeights[3] * vehiclePR.wheels[2].ndSlip
    tmpTable42[4]           = storedAllWheelWeights[4] * vehiclePR.wheels[3].ndSlip
    local totalNdSlipBiased = lib.numberGuard(lib.weightedAverage(tmpTable4, tmpTable42))

    local wheelbase = math.abs(fAxlePos.z - rAxlePos.z)
    -- local trackWidth      = math.max(math.abs(localWheelPositions[0].x - localWheelPositions[1].x), math.abs(localWheelPositions[2].x - localWheelPositions[3].x))

    -- Updating local wheel velocities
    for i = 0, 3 do
        lib.getPointVelocity(localWheelPositions[i], vehiclePR.localAngularVelocity, vehiclePR.localVelocity, storedLocalWheelVel[i])
    end

    -- lib.weightedVecAverage({storedLocalWheelVel[0], storedLocalWheelVel[1]}, fWheelWeights, storedWeightedFLocalVel)
    lib.getPointVelocity(fAxlePos, vehiclePR.localAngularVelocity, vehiclePR.localVelocity, storedFAxleLocalVel)
    lib.getPointVelocity(rAxlePos, vehiclePR.localAngularVelocity, vehiclePR.localVelocity, storedRAxleLocalVel)
    lib.getPointVelocity(avgWheelPos, vehiclePR.localAngularVelocity, vehiclePR.localVelocity, storedMiddleVel)

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

    -- storedVData.inputData             = inputData
    storedVData.vehiclePR              = vehiclePR
    storedVData.vehicle                = vehicleGR
    storedVData.wheelbase              = wheelbase
    storedVData.wheelbaseFactor        = wheelbase / 2.5
    storedVData.inverseBodyTransformPR = inverseBodyTransformPR -- Used for converting points or vectors from global space to local space
    storedVData.inverseBodyTransformGR = inverseBodyTransformGR
    storedVData.localVel               = storedMiddleVel -- Local velocity vector of the vehicle at the average position of all 4 wheels
    storedVData.localHVelLen           = math.sqrt(storedMiddleVel.x * storedMiddleVel.x + storedMiddleVel.z * storedMiddleVel.z) -- Velocity magnitude of the vehicle on the local horizontal plane (m/s)
    storedVData.localAngularVel        = vehiclePR.localAngularVelocity
    storedVData.localWheelVelocities   = storedLocalWheelVel -- Wheel velocities in local space, 0-based indexing
    storedVData.fWheelWeights          = storedFWheelWeights -- Front wheel loads, for using a weighted average
    storedVData.rWheelWeights          = storedRWheelWeights -- Rear wheel loads, for using a weighted average
    storedVData.travelDirection        = lib.numberGuard(math.deg(math.atan2(storedMiddleVel.x, storedMiddleVel.z))) -- The angle of the vehicle's velocity vector on the local horizontal plane (deg), at the average position of all wheels
    storedVData.frontSlipDeg           = frontSlipDeg -- Average front wheel slip angle, weighted by wheel load (deg)
    storedVData.rearSlipDeg            = rearSlipDeg -- Average rear wheel slip angle, weighted by wheel load (deg)
    storedVData.frontSlipRatio         = frontSlipRatio -- Average front wheel slip angle, weighted by wheel load (deg)
    storedVData.rearSlipRatio          = rearSlipRatio -- Average rear wheel slip angle, weighted by wheel load (deg)
    storedVData.frontNdSlip            = frontNdSlip -- Average normalized front slip, weighted by wheel load
    storedVData.rearNdSlip             = rearNdSlip -- Average normalized rear slip, weighted by wheel load
    storedVData.totalNdSlip            = totalNdSlip
    storedVData.totalNdSlipBiased      = totalNdSlipBiased
    storedVData.fwdVelClamped          = math.max(0.0, storedMiddleVel.z) -- Velocity along the local forwrad axis, positive only (m/s)
    storedVData.fAxleLocalVel          = storedFAxleLocalVel -- Local velocity of the front axle (same as the average of the front wheels)
    storedVData.rAxleLocalVel          = storedRAxleLocalVel -- Local velocity of the rear axle (same as the average of the rear wheels)
    storedVData.fAxleHVelLen           = math.sqrt(storedFAxleLocalVel.x * storedFAxleLocalVel.x + storedFAxleLocalVel.z * storedFAxleLocalVel.z)
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
    local sine = math.sin(phase * 2.0 * math.pi)
    local ret = math.abs(sine) ^ power
    if signedOutput then
        ret = ret * math.sign(sine)
    end
    return ret
end

local function calcProgressiveFeedback(inputValue, rangeStart, rangeEnd, startingFeedback)
    if inputValue < rangeStart then
        return 0.0
    end

    local initialFadeIn = math.smoothstep(math.lerpInvSat(inputValue, rangeStart, math.lerp(rangeStart, rangeEnd, 0.1)))
    local progression = math.lerpInvSat(inputValue, rangeStart, rangeEnd)
    return (progression ^ 2.0) * initialFadeIn * (1.0 - startingFeedback) + startingFeedback -- was 2.5
end

local function centeringForceMult(normalizedSlipAngle)
    local x = 0.5 * normalizedSlipAngle + 0.5

    if x < 0.0 then
        return -1.0
    elseif x > 1.0 then
        return 1.0
    end

    return 2.0 * math.smootherstep(x) - 1.0
end

local function getExponentialDecayBlend(dt, smoothingTime)
    smoothingTime = math.max(1e-6, smoothingTime)
    return 1.0 - math.exp(-dt / smoothingTime)
end

-- ============================ state

local function getLowPassLimits(cornerFrequency)
    local relationship = 2.5
    local corner = math.min(160.0 / relationship, cornerFrequency)
    local nyquist = math.min(160.0, corner * relationship)
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
    ac.debug("vRef", vRef * 3.6)
    local lowSpeedFade = math.smoothstep(math.lerpInvSat(vData.localHVelLen, 4.0 / 3.6, 12.0 / 3.6)) -- fades out certain effects near a standstill
    local frontWheelLoadAtRest = vData.perfData:getFrontTireLoadAtRest(vData.wheelbase, rAxlePos.z)
    local frontWheelLoadAt70PercentSpeed = vData.perfData:getFrontTireLoadAtNdSpeed(vRefPointNd, vData.wheelbase, rAxlePos.z)
    local mzEstimateAt70PercentSpeed = vData.perfData:getMzEstimate(frontWheelLoadAt70PercentSpeed, vData.vehicle.wheels[1].tyreRadius)
    local frontWheelLoadAtCurrentSpeed = vData.perfData:getFrontTireLoadAtNdSpeed(vData.localHVelLen / topSpeedEst, vData.wheelbase, rAxlePos.z) -- not actual load, but the load according to the prediction algorithm, to be compatible with the rest of the predicted loads
    local mzEstimateAtCurrentSpeed = vData.perfData:getMzEstimate(frontWheelLoadAtCurrentSpeed, vData.vehicle.wheels[1].tyreRadius)
    local mzRatioInFFB = vData.perfData:getMzRatioInFFB(frontWheelLoadAt70PercentSpeed, vData.vehicle.wheels[1].tyreRadius, mzEstimateAt70PercentSpeed) -- when mz peaks what portion of the ffb strength is coming from the mz

    -- ac.debug("mzRatioInFFB", mzRatioInFFB, 0.0, 1.0)

    -- ac.debug("est max front axle mz", mzEstimateAtCurrentSpeed)
    -- ac.debug("est max front axle mz old", vData.perfData:getMzEstimateOld(frontWheelLoadAtCurrentSpeed, vData.vehicle.wheels[1].tyreRadius))
    -- ac.debug("real front axle mz", vData.vehiclePR.wheels[0].mz + vData.vehiclePR.wheels[1].mz)
    -- ac.debug("frontWheelLoadAt70PercentSpeed", frontWheelLoadAt70PercentSpeed)
    -- ac.debug("mzEstimateAt70PercentSpeed", mzEstimateAt70PercentSpeed)
    -- ac.debug("w1 radius", vData.vehicle.wheels[1].tyreRadius)
    -- ac.debug("f tire rate", vData.perfData.frontTireRate)
    -- ac.debug("f fz0", vData.perfData.frontFZ0)
    -- ac.debug("f axis dot", vData.perfData.steerBasisAxis:dot(vec3(0, 1, 0)))

    ac.debug("W1 ndSlip", vData.vehiclePR.wheels[1].ndSlip, 0.0, 1.0)

    ac.debug("DATA", string.format("%.1f\t%.1f\t%.1f\t%.1f\t%.0f\t%.4f\t%.4f", math.abs(vData.vehiclePR.wheels[1].fy), math.abs(vData.vehiclePR.wheels[1].mz), vData.vehiclePR.wheels[1].load, vData.perfData.frontFZ0, vData.perfData.frontTireRate, vData.perfData.steerBasisAxis:dot(vec3(0, 1, 0)), vData.vehicle.wheels[1].tyreRadius))

    local function getFFBBaseStrength(load, mz)
        load = load or frontWheelLoadAt70PercentSpeed
        mz = mz or mzEstimateAt70PercentSpeed
        return vData.perfData:getFFBPeakStrengthEstimate(load, vData.vehicle.wheels[1].tyreRadius, vData.vehicle.ffbBase, mz)
    end

    local ffbBaseStrengthVRef = getFFBBaseStrength()
    local ffbRefLevelVRef = ffbBaseStrengthVRef * ac.getFFBGain() -- signed
    local ffbBaseStrengthVDynamic = getFFBBaseStrength(frontWheelLoadAtCurrentSpeed, mzEstimateAtCurrentSpeed)
    local ffbRefLevelVDynamic = ffbBaseStrengthVDynamic * ac.getFFBGain() -- signed

    local rAxleHVelAngle = lib.numberGuard(math.deg(math.atan2(vData.rAxleLocalVel.x, math.abs(vData.rAxleLocalVel.z)))) -- reflected at 90 degrees
    local rAxleHVelAngleRaw = lib.numberGuard(math.deg(math.atan2(vData.rAxleLocalVel.x, vData.rAxleLocalVel.z))) -- -180 to 180

    ac.debug("ffbRefLevelVRef", ffbRefLevelVRef, 0.0, 1.0)
    -- ac.debug("ffbRefLevelVRef old", vData.perfData:getFFBPeakStrengthEstimateOld(frontWheelLoadAt70PercentSpeed, vData.vehicle.wheels[1].tyreRadius, vData.vehicle.ffbBase, mzEstimateAt70PercentSpeed) * ac.getFFBGain(), 0.0, 1.0)
    local currentEstFFB = vData.perfData:getFFBPeakStrengthEstimateCurrnet(vData.vehicle.wheels[1].tyreRadius, vData.vehicle.ffbBase) * ac.getFFBGain()
    ac.debug("ffb ref current V peak Nd", currentEstFFB, 0.0, 1.0)

    local finalFFB = ffbValue

    -- auto gain

    -- ac.debug("ffb mult", vData.vehicle.ffbMultiplier)
    -- ac.debug("ffb mult func", ac.getFFBGain()) -- only this has a sign

    local function processAutoGain()
        local adjustAutoGain = getConfigValue("autoAdjustGain")
        local autoGainOffset = getConfigValue("autoGainOffset")
        local newMultiplier = 1.0 / ffbBaseStrengthVRef * (1.0 + autoGainOffset)
        newMultiplier = lib.numberGuard(math.round(math.clamp(newMultiplier, 0.2, 5.0) * 100.0) / 100.0, vData.vehicle.ffbMultiplier)
        runtimeData.autoGainLevel = math.round(newMultiplier * 100.0)

        if adjustAutoGain and (now - lastGainChangeAttempt) >= (1.0 / 20.0) then
            ac.debug("ffbMultiplier", vData.vehicle.ffbMultiplier)
            ac.debug("newMultiplier", newMultiplier)
            ac.debug("difference", math.abs(vData.vehicle.ffbMultiplier - newMultiplier))
            lastGainChangeAttempt = now
            if math.abs(vData.vehicle.ffbMultiplier - newMultiplier) > 0.00099 then
                ac.broadcastSharedEvent("AFFBT_setFFBMultiplier", newMultiplier)
                ac.log("SET GAIN")
            end
        end
    end

    processAutoGain()

    -- abs filter

    local absTriggerThreshold = 0.05

    if vData.vehiclePR.wheels[0].abs > absTriggerThreshold or vData.vehiclePR.wheels[1].abs > absTriggerThreshold then
        tSinceLastFrontABSPulse = 0.0
    else
        tSinceLastFrontABSPulse = math.min(3600.0, tSinceLastFrontABSPulse + dt)
    end

    local absFilterBlend = 1.0

    if getConfigValue("absFilterEnabled") then
        local maxFilterRT = 0.0175 --0.0175
        local filterHoldTime = 0.1
        local filterFadeTime = 0.1
        local absFilterMult = math.smoothstep(math.lerpInvSat(tSinceLastFrontABSPulse - filterHoldTime, filterFadeTime, 0.0))
        ac.debug("ABS Filt | wheel 1 ABS", vData.vehiclePR.wheels[1].abs, 0.0, 1.0)
        ac.debug("ABS Filt | absFilterMult", absFilterMult, 0.0, 1.0)
        absFilterBlend = getExponentialDecayBlend(dt, maxFilterRT * absFilterMult)
        ffbABSFiltered = math.lerp(ffbABSFiltered, finalFFB, absFilterBlend)
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

    -- ac.debug("current ffb pred", vData.perfData:getFFBPeakStrengthEstimate((vData.vehiclePR.wheels[0].load + vData.vehiclePR.wheels[1].load) * 0.5, vData.vehicle.wheels[1].tyreRadius, vData.vehicle.ffbBase, (vData.vehiclePR.wheels[0].mz + vData.vehiclePR.wheels[1].mz) * math.sign(-vData.frontSlipDeg)) * math.abs(ac.getFFBGain()), 0.0, 1.0)

    -- local extraSAT = getConfigValue("extraSAT") * (0.2 / (math.max(mzRatioInFFB, 0.05) - 0.02)) -- * ((1.0 / 3.0) / mzRatioInFFB)
    local extraSAT = getConfigValue("extraSAT") * math.max(0.1, 0.5 / mzRatioInFFB - 1.0) -- * ((1.0 / 3.0) / mzRatioInFFB)
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
            -- ac.debug("satCompMult", satCompMult)
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

        local steerAssist = vData.perfData:getSteerAssistValue()

        local dfDynamicRange = vData.perfData:getDownforceMaxDynamicRange()

        local downforceEffect = 1.0
        if dfCompMode == 1 then
            local dfMult = getConfigValue("downforceCompPercentage")
            -- ac.debug("dfMult", dfMult)
            if type(dfMult) == "number" then
                downforceEffect = dfMult
            end
        elseif dfCompMode == 2 then
            downforceEffect = lib.clamp01(getConfigValue("downforceCompDynamicRange") / dfDynamicRange)
        end

        local function getCompensatedFFBMult()
            local standstillLoadFactor = (frontWheelLoadAtRest / vData.perfData.frontFZ0) ^ (1.0 / steerAssist)
            local currentLoadFactor = ((vData.perfData.fAxleDownforce * fDownforceMult + frontWheelLoadAtRest) / vData.perfData.frontFZ0) ^ (1.0 / steerAssist)
            local ret = math.lerp(1.0 / (currentLoadFactor / standstillLoadFactor), 1.0, downforceEffect)
            local midSpeedLoadFactor = (frontWheelLoadAt70PercentSpeed / vData.perfData.frontFZ0) ^ (1.0 / steerAssist)
            local multAtVRef = math.lerp(1.0 / (midSpeedLoadFactor / standstillLoadFactor), 1.0, downforceEffect)
            local makeupGain = 1.0

            if getConfigValue("downforceCompMakeupGain") then
                makeupGain = math.lerp(1.0 / (standstillLoadFactor / midSpeedLoadFactor), 1.0, downforceEffect)
            end

            return lib.numberGuard(math.min(1.0, ret) * makeupGain), lib.numberGuard(math.min(1.0, multAtVRef), 1.0)
        end

        -- ac.debug("downforceEffect", downforceEffect)

        local ffbMult, ffbMultAtVRef = getCompensatedFFBMult()

        finalFFB = finalFFB * ffbMult
        dfMultApplied = ffbMult
        dfMultAtRefSpeed = ffbMultAtVRef

        -- ac.debug("DF comp | mult", ffbMult)
        -- ac.debug("DF comp | top speed est", vData.perfData:getTopSpeedEstimate() * 3.6)
        -- ac.debug("DF comp | top speed est 70%", vData.perfData:getTopSpeedEstimate() * 3.6 * 0.70)
        -- ac.debug("DF comp | dynamic range", dfDynamicRange)
        -- ac.debug("DF comp | real dynamic range", math.max(0.0, vData.perfData.fAxleDownforce * 0.5 / frontWheelLoadAtRest))
        -- ac.debug("DF comp | effect", downforceEffect)
        -- ac.debug("vData.perfData.fAxleDownforce", vData.perfData.fAxleDownforce)
        -- ac.debug("Z) suggested df effect", math.round(lib.clamp01(2.0 / dfDynamicRange), 2) .. " - " .. math.round(lib.clamp01(4.0 / dfDynamicRange), 2))
    end

    ffbRefLevelVDynamic = ffbRefLevelVDynamic * dfMultApplied
    -- ac.debug("ffbRefLevelVDynamic", ffbRefLevelVDynamic)

    -- brake feel

    local brakeFeel = getConfigValue("brakeFeel")
    local brakeFeelWithABS = getConfigValue("brakeFeelWithABS")
    local brakeFeelAllowed = (vData.vehicle.absMode == 0) or brakeFeelWithABS
    if brakeFeelAllowed and brakeFeel > 1e-6 then
        -- ac.debug("brakeFeelClock", os.clock())
        local frontLongitudinalForce = (vData.vehiclePR.wheels[0].fx + vData.vehiclePR.wheels[1].fx) * 0.5
        if getConfigValue("brakeFeelFilter") then
            frontLongitudinalForce = brakeFeelFilter:process(frontLongitudinalForce)
        else
            brakeFeelFilter:reset(frontLongitudinalForce)
        end

        local refForce = vData.perfData:getFrontPeakLongitudinalForceEst(frontWheelLoadAtRest * 1.4) -- the multiplier accounts for weight shifting to the front under braking. downforce is not included in this on purpose so the added force will scale with it
        local frontLongitudinalForceNd = frontLongitudinalForce / refForce
        -- ac.debug("Brk feel | frontLongitudinalForceNd", frontLongitudinalForceNd, 0.0, 2.0)
        local peakFrac = 5.0 -- 3.5 matches SAT
        local longitudinalFeelExponent = getConfigValue("brakeFeelExponent")
        local effectPeakStrength = brakeFeel * ffbRefLevelVRef * dfMultAtRefSpeed
        local longitudinalFeelAdditive = math.max(0.0, lib.signedPow(frontLongitudinalForceNd, longitudinalFeelExponent)) * effectPeakStrength * centeringForceMult(-peakFrac * vData.frontSlipDeg / frontPeakSlipAngle)
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
        prevBrakingSR = math.lerp(prevBrakingSR, math.max(0.0, -vData.frontSlipRatio), absFilterBlend) -- if the abs filter is enabled we also filter the slip ratio here to avoid adding back abs noise
        local frontSRUsed = prevBrakingSR
        local lockupFeelMult = math.lerp(1.0, 1.0 - lockupFeel, math.smoothstep(math.lerpInvSat(frontSRUsed / frontPeakSlipRatio, lockupSRStart, lockupSREnd)))
        finalFFB = finalFFB * lockupFeelMult
    else
        prevBrakingSR = 0.0
    end

    -- oversteer feel

    local oversteerFeelProtectionFade = math.smoothstep(oversteerFeelConditionSmoother:get(math.min((vData.nWheelsAirborne >= 3) and 0.0 or 1.0, 1.0 - lastCollisionProtectionBlend * 0.5), dt)) -- fades out oversteer feel if either car car is airborne or if collision protection is active
    -- ac.debug("oversteerFeelProtectionFade", oversteerFeelProtectionFade, 0.0, 1.0)

    local oversteerFeel = getConfigValue("oversteerFeel")
    if oversteerFeel > 1e-6 then
        -- // TODO maybe add a config slider for where it starts
        -- local oversteerFeelStrength = ffbRefLevelVRef * dfMultAtRefSpeed * oversteerFeel
        local ndSlipAngleThreshold = getConfigValue("oversteerFeelAggression")
        local oversteerFeelStrength = ffbRefLevelVDynamic * oversteerFeel
        local reverseFade = math.smoothstep(1.0 - math.lerpInvSat(math.abs(rAxleHVelAngleRaw), 90.0, 110.0)) -- fading out oversteer feel if the car is reversing
        local rAxleHVelAngleUsed = rAxleHVelAngle -- + (rAxleHVelAngle - prevRAxleHVelAngle) / dt * 0.5
        local oversteerFeelAdditive = math.smoothstep(math.lerpInvSat(math.abs(rAxleHVelAngleUsed) / rearPeakSlipAngle, 0.9 * ndSlipAngleThreshold, 1.4 * ndSlipAngleThreshold)) * math.sign(rAxleHVelAngleUsed) * oversteerFeelStrength
        finalFFB = finalFFB + oversteerFeelAdditive * lowSpeedFade * reverseFade * oversteerFeelProtectionFade

        -- ac.debug("oversteer 1", math.abs(rAxleHVelAngle) / rearPeakSlipAngle, 0.0, 4.0)
        -- ac.debug("oversteer 2", math.abs(rAxleHVelAngle - math.deg(vData.vehiclePR.localAngularVelocity.y) * 0.5) / rearPeakSlipAngle, 0.0, 4.0)
        -- ac.debug("oversteer 2", math.abs(rAxleHVelAngle + (rAxleHVelAngle - prevRAxleHVelAngle) / dt * 0.5) / rearPeakSlipAngle, 0.0, 4.0)

        prevRAxleHVelAngle = rAxleHVelAngle

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

            -- ac.debug("Col prot | W" .. i .. " pos", localWheelPos)
        end
        localFrontZ = localFrontZ * 0.5
        localRearZ = localRearZ * 0.5
        -- ac.debug("carPos2", car.transform:transformPoint(car.graphicsToPhysicsTransform:transformPoint(vec3(-0.876232, 0.210434, 1.64501))))

        local bottomTolerance = vData.vehicle.aabbSize.y * 0.05 + math.lerp(vData.vehicle.rideHeight[0], vData.vehicle.rideHeight[1], lib.inverseLerp(localFrontZ, localRearZ, collisionPhysicsPos.z))

        local collPosTmp = collisionPhysicsPos:clone()
        collPosTmp.y = highestContactPatchY + bottomTolerance
        -- ac.debug("Col prot | collision", collisionPhysicsPos)
        -- ac.debug("Col prot | bottom tolerance", collPosTmp)

        local protectionFadeOutDuration = 0.5
        local maxProtectionTimerDuration = 1.0

        if vData.vehicle.collisionDepth > 1e-6 and collisionPhysicsPos.y > (highestContactPatchY + bottomTolerance) then
            if collisionProtectionTimer < protectionFadeOutDuration * 0.5 then -- yes this is correct
                local minValue = 9999
                for i = 1, preCollisionFFBHistory:getNewestIndex(), 1 do
                    local val = preCollisionFFBHistory:get(i)
                    if math.abs(val) < math.abs(minValue) then -- and math.sign(val) == math.sign(minValue)
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

        local collisionProtectionBlend = math.smoothstep(math.lerpInvSat(collisionProtectionTimer, 0.0, protectionFadeOutDuration))
        collisionProtectionTimer = math.max(0.0, collisionProtectionTimer - dt / 1.0)
        local ffbUsed = finalFFB
        -- ffbUsed = ffbUsed * math.lerp(1.0, 0.75, collisionProtectionBlend) -- is this good
        if collisionProtectionBlend > 1e-6 and math.abs(ffbUsed) < math.abs(ffbPeakProtected) * 0.999 then -- less filtering if the ffb is reducing, this prevents high values from being held too long
            collisionProtectionBlend = math.min(collisionProtectionBlend, 0.1)
        end
        local finalCollisionProtectionBlend = collisionProtectionBlend
        local smoothingTime = 0.22
        -- ac.debug("col smoothing t", getExponentialDecayBlend(dt, smoothingTime * finalCollisionProtectionBlend))
        ffbPeakProtected = math.lerp(ffbPeakProtected, ffbUsed, getExponentialDecayBlend(dt, smoothingTime * finalCollisionProtectionBlend))
        local peakProtectionDiff = 0.075 -- allows a small amount of deviation from the filtered version
        local ffbProtected2 = lib.clampEased(ffbUsed, ffbPeakProtected - math.abs(ffbRefLevelVDynamic) * peakProtectionDiff, ffbPeakProtected + math.abs(ffbRefLevelVDynamic) * peakProtectionDiff, 0.5)
        -- ac.debug("Col prot | protection blend", finalCollisionProtectionBlend, 0.0, 1.0)
        finalFFB = ffbProtected2
        lastCollisionProtectionBlend = finalCollisionProtectionBlend
    else
        ffbPeakProtected = finalFFB
        -- ffbPeakProtected = math.lerp(ffbPeakProtected, finalFFB, getExponentialDecayBlend(dt, 0.22 * 0.5))
        lastCollisionProtectionBlend = 0.0
    end

    -- -- spike removal

    -- if true then
    --     local w0Normal = vData.vehiclePR.wheels[0].load > 1e-6 and vData.vehiclePR.wheels[0].contactNormal or vData.vehicle.wheels[0].up
    --     local w1Normal = vData.vehiclePR.wheels[1].load > 1e-6 and vData.vehiclePR.wheels[1].contactNormal or vData.vehicle.wheels[1].up
    --     local w0NormalChangeRate = lib.numberGuard(lib.angleBetween(w0PrevNormal, w0Normal) / dt)
    --     local w1NormalChangeRate = lib.numberGuard(lib.angleBetween(w1PrevNormal, w1Normal) / dt)
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
    --             if math.abs(val) < math.abs(minValue) then
    --                 minValue = val
    --             end
    --         end
    --         ffbPeakProtected = minValue -- when a collision starts we use the lowest force from the past few updates as the starting point for the filter, this helps reducing the initial spikes more
    --         spikeRemovalTimer = maxProtectionTimerDuration
    --     end

    --     w0PrevSurfaceType = w0SurfaceType
    --     w1PrevSurfaceType = w1SurfaceType

    --     local spikeRemovalBlend = math.smoothstep(math.lerpInvSat(spikeRemovalTimer, 0.0, protectionFadeOutDuration))
    --     spikeRemovalTimer = math.max(0.0, spikeRemovalTimer - dt / 1.0)

    --     if spikeRemovalBlend > 1e-6 and math.abs(finalFFB) < math.abs(ffbPeakProtected) then -- less filtering if the ffb is reducing, this prevents high values from being held too long
    --         spikeRemovalBlend = 0.1 --math.min(0.1, finalCollisionProtectionBlend)
    --     end

    --     ac.debug("spikeRemovalBlend", spikeRemovalBlend, 0.0, 1.0)

    --     finalPeakRemovalBlend = math.max(finalPeakRemovalBlend, spikeRemovalBlend)
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

    -- haptics, after the filter so the vibrations dont get killed by filtering

    local vibrationSource = getConfigValue("vibrationSource")
    local rpmExtrapolation = 0.075 -- controls how long before the shifting point the vibration kicks in. no particular unit, tune by observation
    local rawExtrapolatedRPM = vData.vehiclePR.rpm * (1.0 + vData.vehiclePR.gForces.z * rpmExtrapolation)
    local smoothExtrapolatedRPM = rpmFilter:process(rawExtrapolatedRPM)

    local frontNdSlipAngleAbs = math.abs(vData.frontSlipDeg / frontPeakSlipAngle)
    local rearNdSlipAngleAbs = math.abs(vData.rearSlipDeg / rearPeakSlipAngle)
    local drivenAxleSlipRatio = (vData.vehicle.tractionType == 1) and vData.frontSlipRatio or vData.rearSlipRatio
    local drivenAxlePeakSlipRatio = (vData.vehicle.tractionType == 1) and frontPeakSlipRatio or rearPeakSlipRatio
    local drivenAxleNdSlipAngleAbs = (vData.vehicle.tractionType == 1) and frontNdSlipAngleAbs or rearNdSlipAngleAbs
    local drivenAxleNdSlipRatio = drivenAxleSlipRatio / drivenAxlePeakSlipRatio
    local engagedGear = vData.vehicle.engagedGear

    local canShift = (vData.vehiclePR.gForces.z > 0.005) and (vData.vehiclePR.gas > 0.01) and (math.abs(rAxleHVelAngleRaw) < 90.0) and (drivenAxleNdSlipRatio > 0.01 and drivenAxleNdSlipRatio < 1.5)

    if (engagedGear ~= prevEngagedGear) or (not canShift) then
        shiftWarning = false
        prevShiftWarningReset = now
    end

    if (engagedGear ~= prevEngagedGear) then
        lastEngagedGearChange = now
    end

    prevEngagedGear = engagedGear

    ac.debug("tSinceEngagedGearChanged", (now - lastEngagedGearChange), 0.0, 1.0)

    -- ac.debug("Haptics | raw RPM", rawExtrapolatedRPM, 0, math.round(vData.perfData.maxRPM * 1.2 / 1000) * 1000)
    -- ac.debug("Haptics | smooth RPM", smoothExtrapolatedRPM, 0, math.round(vData.perfData.maxRPM * 1.2 / 1000) * 1000)

    if vibrationSource > 0 then
        local vibrationLevel = getConfigValue("vibrationLevel")
        local vibrationBaseFrequency = getConfigValue("vibrationBaseFrequency")

        if vibrationSource == 5 then

            if not (shiftWarning and canShift) and (now - prevShiftWarningReset > 0.1) then
                if vData.shiftingTable[engagedGear] then
                    shiftWarning = (smoothExtrapolatedRPM >= vData.shiftingTable[engagedGear].upshiftRPM)
                end
            end

            local vibrationFrequency = vibrationBaseFrequency
            local finalFeedback = vibrationFeedbackSmoother:getWithRate(shiftWarning and 1.0 or 0.0, dt, vibrationFrequency * 1.5)

            -- ac.debug("HAP vibration feedback", shiftWarning and 1.0 or 0.0, 0.0, 1.0)
            -- ac.debug("HAP vibration feedback smooth", finalFeedback, 0.0, 1.0)

            if finalFeedback > 0.01 then
                vibrationPhase = (vibrationPhase + vibrationFrequency * dt) % 1.0
                local vibrationAdditive = sineGenerator(vibrationPhase, 0.25, true) * (ffbRefLevelVRef * dfMultAtRefSpeed) * finalFeedback * vibrationLevel
                finalFFB = finalFFB + vibrationAdditive * lowSpeedFade
            else
                vibrationPhase = 0.0
            end

        else

            local feedbackValue = 0.0
            local feedbackRampBegin = 0.4
            local feedbackRampEnd = 1.0
            local feedbackBaseline = 0.3

            ac.debug("rearNdSlip", vData.rearNdSlip, 0.0, 2.0)

            local function getNdSlipRatioTarget(ndSlipAngleAbs, ndTarget)
                return (1.0 - ((0.85 / ndTarget * lib.clamp01(ndSlipAngleAbs)) ^ 2.4)) * ndTarget
                -- return ndTarget
            end

            local function slipRatioFeedbackImpl(currentSlipRatio, peakSlipRatio, currentNdSlipAngleAbs)
                -- return calcProgressiveFeedback(
                --     currentSlipRatio,
                --     peakSlipRatio * math.clamp(getNdSlipRatioTarget(currentNdSlipAngle, feedbackRampBegin), 0.5, 1.0),
                --     peakSlipRatio * math.clamp(getNdSlipRatioTarget(currentNdSlipAngle, feedbackRampEnd), 0.5, 1.0),
                --     feedbackBaseline
                -- )

                -- this version below is less accurate but its needed to keep the values sane for the feedback ramp

                -- local peakUsed = math.lerp(getNdSlipRatioTarget(currentNdSlipAngleAbs, 1.0), 1.0, 0.5)
                local peakUsed = getNdSlipRatioTarget(currentNdSlipAngleAbs * 0.75, 1.0)
                local startMult = peakUsed * feedbackRampBegin
                local endMult = peakUsed * feedbackRampEnd

                -- ac.debug("rampStart", startMult, 0.0, 1.0)
                -- ac.debug("rampEnd", endMult, 0.0, 1.0)

                return calcProgressiveFeedback(
                    currentSlipRatio,
                    peakSlipRatio * startMult,
                    peakSlipRatio * endMult,
                    feedbackBaseline
                )
            end

            -- ac.debug("front peak feedback", getNdSlipRatioTarget(frontNdSlipAngleAbs, 1.0))
            -- ac.debug("frontNdSlipAngle", frontNdSlipAngleAbs, 0.0, 1.0)

            local function getBrakeHelpFeedback() -- only considers front wheels for now
                if vData.vehiclePR.brake > 0.01 and vData.vehicle.absMode < 1 then
                    return slipRatioFeedbackImpl(-vData.frontSlipRatio * math.sign(vData.localVel.z), frontPeakSlipRatio, frontNdSlipAngleAbs)
                end
                return 0.0
            end

            local function getThrottleHelpFeedback()
                local feedbackCooldownAfterShifting = 0.25
                if vData.vehiclePR.gas > 0.01 and vData.vehicle.tractionControlMode < 1 and (now - lastEngagedGearChange) > feedbackCooldownAfterShifting then
                    return slipRatioFeedbackImpl(drivenAxleSlipRatio * math.sign(engagedGear), drivenAxlePeakSlipRatio, drivenAxleNdSlipAngleAbs)
                end

                return 0.0
            end

            if vibrationSource == 1 then
                -- braking help
                feedbackValue = getBrakeHelpFeedback()
            elseif vibrationSource == 2 then
                -- throttle help
                feedbackValue = getThrottleHelpFeedback()
            elseif vibrationSource == 3 then
                -- braking + throttle help
                if drivenAxleSlipRatio * math.sign(engagedGear) < 0.0 then
                    feedbackValue = getBrakeHelpFeedback()
                else
                    feedbackValue = getThrottleHelpFeedback()
                end
            elseif vibrationSource == 4 then
                -- understeer
                -- feedbackValue = math.smoothstep(math.lerpInvSat(math.abs(vData.frontSlipDeg) / frontPeakSlipAngle, 0.9, 1.4))
                feedbackValue = calcProgressiveFeedback(math.abs(vData.frontSlipDeg), frontPeakSlipAngle * 0.95, frontPeakSlipAngle * 1.5, feedbackBaseline)
            end

            local vibrationFrequency = lib.logInterpolation(vibrationBaseFrequency, vibrationBaseFrequency * 2.0, (feedbackValue - feedbackBaseline) / (1.0 - feedbackBaseline))
            local finalFeedback = vibrationFeedbackSmoother:getWithRate(feedbackValue, dt, vibrationFrequency * 1.5)

            ac.debug("HAP vibration feedback", feedbackValue, 0.0, 1.0)
            ac.debug("HAP vibration feedback smooth", finalFeedback, 0.0, 1.0)

            if feedbackValue > 0.01 then
                vibrationPhase = (vibrationPhase + vibrationFrequency * dt) % 1.0
                local vibrationAdditive = sineGenerator(vibrationPhase, 0.25, true) * (ffbRefLevelVRef * dfMultAtRefSpeed) * feedbackValue * 1.5 * vibrationLevel
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

    if math.abs(dt - 0.003) > 1e-6 then
        ac.warn("Delta time is sus")
    end

    local vehicle = ac.getCar(0) or car

    if ac.getCarSetupState() == "validating" or vehicle.isInPit then
        resetInitValues()
        return ffbValue, ffbDamper
    end

    if initialSkips < 2 then -- not necessary anymore with pcall, but whatever
        initialSkips = initialSkips + 1
        return ffbValue, ffbDamper
    end

    ac.debug("Gen | original FFB", ffbValue, -1.0, 1.0)

    local finalFFB = ffbValue

    if getConfigValue("scriptEnabled") then
        local success = false
        success, finalFFB = pcall(function ()
            return processFFB(ffbValue, dt)
        end)

        if not success then
            ac.error("Something exploded")

            return ffbValue, ffbDamper
        end

        -- finalFFB = processFFB(ffbValue, dt)
    else
        onProcessingSkip(ffbValue, vehicle)
    end

    local sim = ac.getSim()

    ac.debug("vehicle.isInPitlane", vehicle.isInPitlane)
    ac.debug("sim.raceFlagType", sim.raceFlagType)
    ac.debug("sim.raceSessionType", sim.raceSessionType)
    ac.debug("sim.isSessionFinished", sim.isSessionFinished) -- turns true after crossing the finish, but im using flag type instead of this
    ac.debug("sim.isSessionStarted", sim.isSessionStarted) -- false before the race start, then stays true after the lights go out until the next session
    ac.debug("sim.currentSessionIndex", sim.currentSessionIndex)
    ac.debug("sim.isOnlineRace", sim.isOnlineRace)

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

---@diagnostic disable-next-line: cast-local-type
    local postRaceFFBMultSmooth = math.lerp(1.0, getConfigValue("ffbLevelAfterFinish"), math.smoothstep(postRaceMultBlendSmoother:get((tSinceRaceFinished - 1.0) > 1e-6 and 1.0 or 0.0, dt)))

    finalFFB = finalFFB * postRaceFFBMultSmooth

    ac.debug("postRaceMultSmooth", postRaceFFBMultSmooth)

    -- no more modifying ffb after this

    local finalGuardedFFB = lib.numberGuard(finalFFB, ffbValue)

    ac.debug("Gen | Final FFB", finalGuardedFFB, -1.0, 1.0)

    runtimeData.rawFFB = ffbValue
    runtimeData.finalFFB = finalGuardedFFB

    ffbSampleCounter = ffbSampleCounter - 1
    if ffbSampleCounter <= 0 then
        ffbSampleCounter = storage.ffbSampleRateDiv
        runtimeData.ffbRawHistoryHead, runtimeData.ffbRawHistoryCount = lib.StructValueHistory.push(runtimeData.ffbRawHistoryBuffer, storage.ffbHistoryBufferCapacity, runtimeData.ffbRawHistoryHead, runtimeData.ffbRawHistoryCount, ffbValue)
        runtimeData.ffbFinalHistoryHead, runtimeData.ffbFinalHistoryCount = lib.StructValueHistory.push(runtimeData.ffbFinalHistoryBuffer, storage.ffbHistoryBufferCapacity, runtimeData.ffbFinalHistoryHead, runtimeData.ffbFinalHistoryCount, finalFFB)
    end

    return finalGuardedFFB, ffbDamper -- what even is the damper in this context? its always 0 even with damping enabled in the ffb settings
end