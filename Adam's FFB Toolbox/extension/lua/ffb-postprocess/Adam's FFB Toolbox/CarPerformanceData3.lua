-- Car performance analysis and estimation tools based on on static (or setup-dependent) data

local lib = require("AGALib2")
local json = require("json")
local storage = require("Storage")

local M = {}

local tmpVec1 = vec3()
local tmpVec2 = vec3()
local tmpVec3 = vec3()
local tmpVec4 = vec3()

--- Only construct once per car or when the setup changes, not every frame
---@param vehicle ac.StateCar
---@param cPhys ac.StateCarPhysics
function M:new(vehicle, cPhys)
    local brokenEngineINI = true
    local idleRPM         = 0
    local maxRPM          = 0
    local turboData       = {}
    local torqueCurve     = nil

    -- Reading engine data

    local engineINI = ac.INIConfig.carData(vehicle.index, "engine.ini")

    if table.nkeys(engineINI.sections) > 0 then
        brokenEngineINI = false

        torqueCurve = ac.DataLUT11.carData(vehicle.index, engineINI:get("HEADER", "POWER_CURVE", "power.lut")) -- engineINI:tryGetLut("HEADER", "POWER_CURVE")

        if torqueCurve then
            torqueCurve.useCubicInterpolation = true
            torqueCurve.extrapolate           = true
        end

        idleRPM = engineINI:get("ENGINE_DATA", "MINIMUM", 900)
        maxRPM  = math.min(((vehicle.rpmLimiter and vehicle.rpmLimiter ~= 0) and vehicle.rpmLimiter or engineINI:get("ENGINE_DATA", "LIMITER", 99999)), engineINI:get("DAMAGE", "RPM_THRESHOLD", 99999))

        if maxRPM == 99999 then
            maxRPM = ((vehicle.rpmLimiter > 0) and vehicle.rpmLimiter or 8000)
        end

        -- Reading turbo data
        for i = 0, 3, 1 do
            local maxBoost   = engineINI:get("TURBO_" .. i, "MAX_BOOST", 0)
            local wasteGate  = engineINI:get("TURBO_" .. i, "WASTEGATE", 0)
            local boostLimit = math.min(maxBoost, wasteGate)
            if boostLimit ~= 0 then
                local referenceRPM = engineINI:get("TURBO_" .. i, "REFERENCE_RPM", -1)
                local gamma        = engineINI:get("TURBO_" .. i, "GAMMA", -1)

                if referenceRPM ~= -1 and gamma ~= -1 then
                    local ctrl = ac.INIConfig.carData(vehicle.index, "ctrl_turbo" .. i .. ".ini")

                    local controllers = {}

                    for j = 0, 3, 1 do
                        local controllerInput   = ctrl:get("CONTROLLER_" .. j, "INPUT", nil)
                        local controllerCombine = ctrl:get("CONTROLLER_" .. j, "INPUT", nil)
                        local controllerLUT     = ctrl:tryGetLut("CONTROLLER_" .. j, "LUT")

                        if controllerInput and controllerCombine and controllerLUT then
                            controllerLUT.useCubicInterpolation = true
                            controllerLUT.extrapolate = true
                            table.insert(controllers, {
                                input      = controllerInput,
                                combinator = controllerCombine,
                                LUT        = controllerLUT,
                            })
                        end
                    end

                    table.insert(turboData, {
                        boostLimit   = boostLimit,
                        referenceRPM = referenceRPM,
                        gamma        = gamma,
                        controllers  = controllers
                    })
                end
            end
        end
    end

    -- // TODO add MGU as well

    -- Reading drivetrain data

    local carINI               = ac.INIConfig.carData(vehicle.index, "car.ini")
    local setupINI             = ac.INIConfig.carData(vehicle.index, "setup.ini")
    local drivetrainINI        = ac.INIConfig.carData(vehicle.index, "drivetrain.ini")
    local shiftUpTime          = drivetrainINI:get("GEARBOX", "CHANGE_UP_TIME", vehicle.hShifter and 300 or 50) / 1000.0 -- Converted from ms to s
    local shiftDownTime        = drivetrainINI:get("GEARBOX", "CHANGE_DN_TIME", vehicle.hShifter and 300 or 50) / 1000.0 -- Converted from ms to s
    local defaultShiftUp       = drivetrainINI:get("AUTO_SHIFTER", "UP", math.lerp(idleRPM, maxRPM, 0.7))
    local electronicBlip       = drivetrainINI:get("AUTOBLIP", "ELECTRONIC", 0)
    local upshiftPoint1        = drivetrainINI:get("UPSHIFT_PROFILE", "POINT_1", 0) / 1000.0
    local upshiftPoint2        = drivetrainINI:get("UPSHIFT_PROFILE", "POINT_2", 0) / 1000.0
    local downshiftPoint1      = drivetrainINI:get("DOWNSHIFT_PROFILE", "POINT_1", 0) / 1000.0
    local downshiftPoint2      = drivetrainINI:get("DOWNSHIFT_PROFILE", "POINT_2", 0) / 1000.0
    local upshiftClutchFadeT   = (upshiftPoint1 ~= 0 and upshiftPoint2 ~= 0) and (upshiftPoint2 - upshiftPoint1) or 0
    local downshiftClutchFadeT = (downshiftPoint1 ~= 0 and downshiftPoint2 ~= 0) and (downshiftPoint2 - downshiftPoint1) or 0
    local steerAssist          = carINI:get("CONTROLS", "STEER_ASSIST", 1.0)
    local hasSteerAssistSetup  = (setupINI:get("STEER_ASSIST", "TAB", "") ~= "")
    local aeroIni              = ac.INIConfig.carData(vehicle.index, "aero.ini")

    self.__index = self

    local obj = setmetatable({
        vehicle                 = vehicle,
        aeroIni                 = aeroIni,
        brokenEngineIni         = brokenEngineINI,
        baseTorqueCurve         = torqueCurve,
        turboData               = turboData,
        idleRPM                 = idleRPM,
        maxRPM                  = maxRPM,
        RPMRange                = maxRPM - idleRPM,
        shiftUpTime             = shiftUpTime,
        shiftDownTime           = shiftDownTime,
        defaultShiftUpRPM       = defaultShiftUp,
        electronicBlip          = electronicBlip,
        upshiftClutchFadeT      = upshiftClutchFadeT,
        downshiftClutchFadeT    = downshiftClutchFadeT,
        gearRatios              = table.clone(cPhys.gearRatios, true),
        finalDrive              = cPhys.finalRatio,
        targetSlipAngleSmootherFront = lib.SmoothTowards:new(0.1, 0.05, 0.0, 15.0, 7.5),
        targetSlipAngleSmootherRear  = lib.SmoothTowards:new(0.1, 0.05, 0.0, 15.0, 7.5),
        targetSlipRatioSmootherFront = lib.SmoothTowards:new(0.1, 0.05, 0.0, 0.2, 0.1),
        targetSlipRatioSmootherRear  = lib.SmoothTowards:new(0.1, 0.05, 0.0, 0.2, 0.1),
        -- loadAdditiveSmoother    = lib.SmoothTowardsOld:new(1.4, 0.05, 0.0,  2.0, 0.0),
        storedCompoundIndex     = -1,
        frontFrictionLimitAngle = 7.5,
        frontCamberGain         = 0.213,
        frontPressureIdeal      = 23,
        frontPressureFlexGain   = 0.3,
        frontPressureDGain      = 0.0052,
        frontFlexGain           = 0.029,
        frontFZ0                = 3451,
        frontLsExpY             = 0.8,
        frontLsExpX             = 0.8,
        frontDxRef              = 1.8,
        frontDyRef              = 1.8,
        frontBrakeDxMod         = 0.04,
        frontCxMult             = 1.0,
        frontDxCurve            = nil,
        frontDyCurve            = nil,
        frontTireRate           = 250000.0,
        rearFrictionLimitAngle  = 7.5,
        rearCamberGain          = 0.213,
        rearPressureIdeal       = 23,
        rearPressureFlexGain    = 0.3,
        rearPressureDGain       = 0.0052,
        rearFlexGain            = 0.029,
        rearFZ0                 = 3451,
        rearLsExpY              = 0.8,
        rearLsExpX              = 0.8,
        rearDxRef               = 1.8,
        rearDyRef               = 1.8,
        rearBrakeDxMod          = 0.04,
        rearCxMult              = 1.0,
        rearDxCurve             = nil,
        rearDyCurve             = nil,
        rearTireRate            = 250000.0,
        maxEnginePower          = 0,
        steerBasisCenter        = vec3(),
        steerBasisAxis          = vec3(0.0, 0.996194698092, -0.0871557427477), -- 5 deg caster as a fallback value
        frontSuspensionType     = "DWB",
        steerAssist             = steerAssist,
        hasSteerAssistSetup     = hasSteerAssistSetup,
        dfDynamicRangeSmoother  = lib.SmoothTowards:new(0.05, 0.1, 0.0, 10.0, 0.0),
        dfDynamicRange1         = 0.0,
        dfDynamicRange2         = 0.0,
        fAxleDownforce          = 0.0,
        tmpWbTop                = nil,
        tmpWbBottom             = nil,
        lastWingAngles          = {}
    }, self)

    local function findPeakPower()
        if not obj.brokenEngineIni and obj.baseTorqueCurve then
            for rpm = 0.0, 1.0, 0.05 do
                local p = obj:getMaxHP(obj:getAbsoluteRPM(rpm), 1)
                if p > obj.maxEnginePower then obj.maxEnginePower = p end
            end
            return true
        end

        local uiFilePath = ac.getFolder(ac.FolderID.ContentCars) .. "\\" .. vehicle:id() .. "\\ui\\ui_car.json"

        local jsonContent = storage.readFile(uiFilePath)

        if not jsonContent then
            return false
        end

        local success, parsedTable = pcall(function ()
            return json.decode(jsonContent)
        end)

        if not success or type(parsedTable) ~= "table" or type(parsedTable["powerCurve"]) ~= "table" then
            return false
        end

        for _, entry in ipairs(parsedTable["powerCurve"]) do
            if type(entry) ~= "table" then
                return false
            end

            local p = entry[2]
            if type(p) == "string" then
                p = tonumber(p)
            end
            if type(p) ~= "number" then
                return false
            end

            p = p * 1.16 -- rough compensation to match the range that the proper method would return

            if p > obj.maxEnginePower then obj.maxEnginePower = p end
        end

        return true
    end

    if not findPeakPower() then
        obj.maxEnginePower = 250
    end

    local tiresINI = ac.INIConfig.carData(vehicle.index, "tyres.ini")
    obj:readTires(tiresINI)

    local suspensionsIni = ac.INIConfig.carData(vehicle.index, "suspensions.ini")
    obj.frontSuspensionType = suspensionsIni:get("FRONT", "TYPE", obj.frontSuspensionType)

    if obj.frontSuspensionType == "STRUT" then
        local carStrut = suspensionsIni:get("FRONT", "STRUT_CAR", vec3(0.1, 0.5 * 0.996194698092, -0.5 * 0.0871557427477)) -- top
        local tireStrut = suspensionsIni:get("FRONT", "STRUT_TYRE", vec3(0.0, -0.1 * 0.996194698092, 0.1 * 0.0871557427477)) -- bottom
        local offset = suspensionsIni:get("FRONT", "RIM_OFFSET", 0.0)
        carStrut = carStrut + tmpVec1:set(-offset, 0.0, 0.0)
        tireStrut = tireStrut + tmpVec1
        obj.steerBasisCenter:set(carStrut):add(tireStrut):scale(0.5)
        obj.steerBasisAxis:set(carStrut):sub(tireStrut):normalize()

        obj.tmpWbTop = carStrut
        obj.tmpWbBottom = tireStrut
    elseif obj.frontSuspensionType == "DWB" then
        local wbTop = suspensionsIni:get("FRONT", "WBTYRE_TOP", vec3(0.0, 0.1 * 0.996194698092, -0.1 * 0.0871557427477))
        local wbBottom = suspensionsIni:get("FRONT", "WBTYRE_BOTTOM", vec3(0.0, -0.1 * 0.996194698092, 0.1 * 0.0871557427477))
        local offset = suspensionsIni:get("FRONT", "RIM_OFFSET", 0.0)
        wbTop = wbTop + tmpVec1:set(-offset, 0.0, 0.0)
        wbBottom = wbBottom + tmpVec1
        obj.steerBasisCenter:set(wbTop):add(wbBottom):scale(0.5)
        obj.steerBasisAxis:set(wbTop):sub(wbBottom):normalize()

        obj.tmpWbTop = wbTop
        obj.tmpWbBottom = wbBottom
    else
        ac.error("Invalid front suspension type! Reverting to default values ...")
    end

    if aeroIni:get("MAP_0", "NAME", "") ~= "" then
        ac.setMessage("Adam's FFB Toolbox", "Downforce compensation and FFB gain-related options might not work correctly on this car!", nil, 10.0)
    end

    return obj
end

function M:getNormalizedRPM(rpm)
    rpm = rpm or self.vehicle.rpm
    return math.lerpInvSat(rpm, self.idleRPM, self.maxRPM)
end

function M:getAbsoluteRPM(normalizedRPM)
    return math.lerp(self.idleRPM, self.maxRPM, normalizedRPM)
end

-- Max theoretical torque at full throttle
function M:getMaxTQ(rpm, gear)
    if not self.baseTorqueCurve then
        return 0
    end

    local baseTorque = self.baseTorqueCurve:get(rpm)

    local totalBoost = 0.0 -- Total boost from all turbos

    for _, turbo in ipairs(self.turboData) do
        local currentTurboBoost = (rpm / turbo.referenceRPM) ^ turbo.gamma -- 0 -- Boost from this turbo

        if table.nkeys(turbo.controllers) > 0 then
            for _, controller in ipairs(turbo.controllers) do
                local controllerValue = 0 -- Boost from a single controller

                if controller.input == "RPMS" then
                    controller.LUT.useCubicInterpolation = true
                    controllerValue = controller.LUT:get(rpm)
                elseif turbo.controllerInput == "GEAR" then
                    controller.LUT.useCubicInterpolation = false
                    controllerValue = controller.LUT:get(gear)
                end

                if controller.combinator == "ADD" then
                    currentTurboBoost = currentTurboBoost + controllerValue
                elseif controller.combinator == "MULT" then
                    currentTurboBoost = currentTurboBoost * controllerValue
                end
            end
        end

        totalBoost = totalBoost + math.min(currentTurboBoost, turbo.boostLimit)
    end

    return baseTorque * (1.0 + totalBoost)
end

-- Max theoretical power at full throttle
function M:getMaxHP(rpm, gear)
    return self:getMaxTQ(rpm, gear) * rpm / 5252.0
end

function M:getGearRatio(gear)
    gear = gear or self.vehicle.gear
    return self.gearRatios[gear + 1] or math.NaN
end

function M:getDrivetrainRatio(gear)
    gear = gear or self.vehicle.gear
    return self:getGearRatio(gear) * self.finalDrive
end

function M:getRPMInGear(gear, currentRPM)
    currentRPM = currentRPM or self.vehicle.rpm
    return self:getGearRatio(gear) / self:getGearRatio(self.vehicle.gear) * currentRPM
end

function M:calcShiftingTable(minNormRPM, maxNormRPM)
    local gearData = {}

    if self.vehicle.gearCount < 2 then
        return gearData
    end

    local minRPM          = self:getAbsoluteRPM(minNormRPM)
    local maxShiftRPM     = self:getAbsoluteRPM(maxNormRPM)
    local defaultFallback = self.defaultShiftUpRPM

    for gear = 1, self.vehicle.gearCount - 1, 1 do
        local bestUpshiftRPM = defaultFallback

        if self.vehicle.mgukDeliveryCount == 0 then
            local bestArea = 0
            local areaSkew = 1.0 --math.lerp(1.0, 1.0, (gear - 1) / (self.vehicle.gearCount - 2)) -- shifts the bias of the power integral higher as the gear number increases
            local nextOverCurrentRatio = self:getGearRatio(gear + 1) / self:getGearRatio(gear)
            for i = 0, 300, 1 do
                local upshiftRPM = self:getAbsoluteRPM(i / 300.0)
                local nextGearRPM = upshiftRPM * nextOverCurrentRatio
                if nextGearRPM > minRPM then
                    local area = 0
                    for j = 0, 100, 1 do
                        local simRPM = math.lerp(nextGearRPM, upshiftRPM, j / 100.0)
                        area = area + self:getMaxHP(simRPM, gear + 1) / 100.0 * math.lerp(1.0, areaSkew, (j / 100.0))
                    end
                    if area > bestArea then
                        bestArea = area
                        bestUpshiftRPM = upshiftRPM
                    end
                end
            end
        end

        gearData[gear] = {
            upshiftRPM = math.min(bestUpshiftRPM, maxShiftRPM),
            gearStartRPM = (gear == 1) and self.idleRPM or (gearData[gear - 1].upshiftRPM * self:getGearRatio(gear) / self:getGearRatio(gear - 1))
        }
    end

    -- Setting first and last by hand
    gearData[1].gearStartRPM = math.max((self:getGearRatio(2) / self:getGearRatio(1)) * gearData[2].gearStartRPM, self.idleRPM)
    gearData[self.vehicle.gearCount] = {
        upshiftRPM = 9999999,
        gearStartRPM = gearData[self.vehicle.gearCount - 1].upshiftRPM * self:getGearRatio(self.vehicle.gearCount) / self:getGearRatio(self.vehicle.gearCount - 1)
    }

    return gearData
end

function M:readTires(tiresINI)
    local frontTireKey = (self.vehicle.compoundIndex == 0) and "FRONT" or ("FRONT_" .. self.vehicle.compoundIndex)
    local rearTireKey = (self.vehicle.compoundIndex == 0) and "REAR" or ("REAR_" .. self.vehicle.compoundIndex)

    self.frontFrictionLimitAngle = tiresINI:get(frontTireKey, "FRICTION_LIMIT_ANGLE", 6.3)
    self.frontCamberGain         = tiresINI:get(frontTireKey, "CAMBER_GAIN", 0.213)
    self.frontPressureIdeal      = tiresINI:get(frontTireKey, "PRESSURE_IDEAL", 23)
    self.frontPressureFlexGain   = tiresINI:get(frontTireKey, "PRESSURE_FLEX_GAIN", 0.3)
    self.frontPressureDGain      = tiresINI:get(frontTireKey, "PRESSURE_D_GAIN", 0.0052)
    self.frontFlexGain           = tiresINI:get(frontTireKey, "FLEX_GAIN", 0.0290)
    self.frontFZ0                = tiresINI:get(frontTireKey, "FZ0", 3451)
    self.frontLsExpY             = tiresINI:get(frontTireKey, "LS_EXPY", 0.8)
    self.frontLsExpX             = tiresINI:get(frontTireKey, "LS_EXPX", 0.8)
    self.frontDxRef              = tiresINI:get(frontTireKey, "DX_REF", 1.8)
    self.frontDyRef              = tiresINI:get(frontTireKey, "DY_REF", 1.8)
    self.frontBrakeDxMod         = tiresINI:get(frontTireKey, "BRAKE_DX_MOD", 0.04)
    self.frontCxMult             = tiresINI:get(frontTireKey, "CX_MULT", 1.0)
    self.frontDxCurve            = tiresINI:tryGetLut(frontTireKey, "DX_CURVE")
    self.frontDyCurve            = tiresINI:tryGetLut(frontTireKey, "DY_CURVE")
    self.frontTireRate           = tiresINI:get(frontTireKey, "RATE", 250000.0)

    self.rearFrictionLimitAngle = tiresINI:get(rearTireKey, "FRICTION_LIMIT_ANGLE", 6.3)
    self.rearCamberGain         = tiresINI:get(rearTireKey, "CAMBER_GAIN", 0.213)
    self.rearPressureIdeal      = tiresINI:get(rearTireKey, "PRESSURE_IDEAL", 23)
    self.rearPressureFlexGain   = tiresINI:get(rearTireKey, "PRESSURE_FLEX_GAIN", 0.3)
    self.rearPressureDGain      = tiresINI:get(rearTireKey, "PRESSURE_D_GAIN", 0.0052)
    self.rearFlexGain           = tiresINI:get(rearTireKey, "FLEX_GAIN", 0.0290)
    self.rearFZ0                = tiresINI:get(rearTireKey, "FZ0", 3451)
    self.rearLsExpY             = tiresINI:get(rearTireKey, "LS_EXPY", 0.8)
    self.rearLsExpX             = tiresINI:get(rearTireKey, "LS_EXPX", 0.8)
    self.rearDxRef              = tiresINI:get(rearTireKey, "DX_REF", 1.8)
    self.rearDyRef              = tiresINI:get(rearTireKey, "DY_REF", 1.8)
    self.rearBrakeDxMod         = tiresINI:get(rearTireKey, "BRAKE_DX_MOD", 0.04)
    self.rearCxMult             = tiresINI:get(rearTireKey, "CX_MULT", 1.0)
    self.rearDxCurve            = tiresINI:tryGetLut(rearTireKey, "DX_CURVE")
    self.rearDyCurve            = tiresINI:tryGetLut(rearTireKey, "DY_CURVE")
    self.rearTireRate           = tiresINI:get(rearTireKey, "RATE", 250000.0)

    self.storedCompoundIndex = self.vehicle.compoundIndex
end

-- function M:getSlipLoadAdditive(vData)
--     if self.lastCompound ~= self.vehicle.compoundIndex then
--         self:readTires()
--     end

--     local avgLoad = (self.vehicle.wheels[0].load + self.vehicle.wheels[1].load) * 0.5
--     local minLoad = avgLoad * (math.sqrt(math.lerpInvSat(vData.localHVelLen, 0, 15.0)) * 0.6 + 1.0) -- Assume some amount of load to get close to the cornering slip angle right away

--     local flexGainMult  = 1.0 + 12.0 * self.frontFlexGain -- 6.0 * flexGain ?
--     local refLoad       = 2.0 * self.frontFZ0
--     local loadAdditive0 = math.sqrt(math.max(minLoad, self.vehicle.wheels[0].load) / refLoad) * flexGainMult
--     local loadAdditive1 = math.sqrt(math.max(minLoad, self.vehicle.wheels[1].load) / refLoad) * flexGainMult

--     return lib.numberGuard(lib.weightedAverage({loadAdditive0, loadAdditive1}, vData.fWheelWeights), 0)
-- end

function M:getTargetSlipEstimate(vData, front)
    local wheelIndex1        = front and 0 or 2
    local wheelIndex2        = front and 1 or 3
    local frictionLimitAngle = front and self.frontFrictionLimitAngle or self.rearFrictionLimitAngle
    local camberGain         = front and self.frontCamberGain or self.rearCamberGain
    local pressureIdeal      = front and self.frontPressureIdeal or self.rearPressureIdeal
    local pressureFlexGain   = front and self.frontPressureFlexGain or self.rearPressureFlexGain
    local pressureDGain      = front and self.frontPressureDGain or self.rearPressureDGain
    local flexGain           = front and self.frontFlexGain or self.rearFlexGain
    local fz0                = front and self.frontFZ0 or self.rearFZ0

    local camberAdditive0 = camberGain * math.sin(math.rad(self.vehicle.wheels[wheelIndex1].camber))
    local camberAdditive1 = camberGain * math.sin(math.rad(self.vehicle.wheels[wheelIndex2].camber))

    local pressureFlexGainMult = (pressureFlexGain / 3.7)

    local pressureDiff0 = (pressureIdeal - self.vehicle.wheels[wheelIndex1].tyrePressure)
    local pressureDiff1 = (pressureIdeal - self.vehicle.wheels[wheelIndex2].tyrePressure)

    local dGainPressureMult0 = ((self.vehicle.wheels[wheelIndex1].tyrePressure < pressureIdeal) and 1.5 or 1.0)
    local dGainPressureMult1 = ((self.vehicle.wheels[wheelIndex2].tyrePressure < pressureIdeal) and 1.5 or 1.0)

    local pressureFlexGain0 = pressureDiff0 * pressureFlexGainMult - math.abs(pressureDiff0 * dGainPressureMult0) * pressureDGain * 1.7 - 0.005 * math.abs(self.vehicle.wheels[wheelIndex1].tyreCoreTemperature - self.vehicle.wheels[wheelIndex1].tyreOptimumTemperature)
    local pressureFlexGain1 = pressureDiff1 * pressureFlexGainMult - math.abs(pressureDiff1 * dGainPressureMult1) * pressureDGain * 1.7 - 0.005 * math.abs(self.vehicle.wheels[wheelIndex2].tyreCoreTemperature - self.vehicle.wheels[wheelIndex2].tyreOptimumTemperature)

    local loadMult = 1.0 / (2.0 * fz0) * (5.5 * (flexGain - 0.03))

    local avgLoad = (self.vehicle.wheels[wheelIndex1].load + self.vehicle.wheels[wheelIndex2].load) * 0.5
    local minLoad = avgLoad * 1.6 -- Assume some amount of load to get close to the cornering slip angle right away

    local loadAdditive0 = math.max(minLoad, self.vehicle.wheels[wheelIndex1].load) * loadMult + pressureFlexGain0
    local loadAdditive1 = math.max(minLoad, self.vehicle.wheels[wheelIndex2].load) * loadMult + pressureFlexGain1

    local targetSlipAngle = lib.weightedAverage({frictionLimitAngle + camberAdditive0 + loadAdditive0, frictionLimitAngle + camberAdditive1 + loadAdditive1}, front and vData.fWheelWeights or vData.rWheelWeights)
    local targetSlipRatio = math.sin(math.rad(lib.weightedAverage({frictionLimitAngle + camberAdditive0, frictionLimitAngle + camberAdditive1}, front and vData.fWheelWeights or vData.rWheelWeights))) / (front and self.frontCxMult or self.rearCxMult) * 0.87 -- close estimate

    return math.clamp(lib.numberGuard(targetSlipAngle), 5, 14), math.clamp(lib.numberGuard(targetSlipRatio), 0.05, 0.2) -- Clamp the target to a safe range


    -- Different attempt, usually better but can mess up more at high tire pressures

    -- local camberAdditive0 = camberGain * math.sin(math.rad(self.vehicle.wheels[0].camber))
    -- local camberAdditive1 = camberGain * math.sin(math.rad(self.vehicle.wheels[1].camber))

    -- local pressureDiff0 = (self.vehicle.wheels[0].tyrePressure - pressureIdeal)
    -- local pressureDiff1 = (self.vehicle.wheels[1].tyrePressure - pressureIdeal)

    -- -- local dGainPressureMult0 = ((self.vehicle.wheels[0].tyrePressure < pressureIdeal) and 1.5 or 1.0)
    -- -- local dGainPressureMult1 = ((self.vehicle.wheels[1].tyrePressure < pressureIdeal) and 1.5 or 1.0)

    -- local avgLoad = (self.vehicle.wheels[0].load + self.vehicle.wheels[1].load) * 0.5
    -- local minLoad = avgLoad * 1.6 -- Assume some amount of load to get close to the cornering slip angle right away

    -- local loadAdditive0 = math.sqrt(math.max(minLoad, self.vehicle.wheels[0].load) / (2.0 * fz0)) * (1.0 + 6.0 * flexGain) - (pressureDiff0 * pressureDGain * 2.0 * math.lerp(frictionLimitAngle / 6.3, 1.0, 0.6)) - (pressureDiff0 * (pressureFlexGain / 4.0) * math.lerp(frictionLimitAngle / 6.3, 1.0, 0.6)) - (0.012 * math.max(0.0, car.wheels[0].tyreCoreTemperature - car.wheels[0].tyreOptimumTemperature))
    -- local loadAdditive1 = math.sqrt(math.max(minLoad, self.vehicle.wheels[1].load) / (2.0 * fz0)) * (1.0 + 6.0 * flexGain) - (pressureDiff1 * pressureDGain * 2.0 * math.lerp(frictionLimitAngle / 6.3, 1.0, 0.6)) - (pressureDiff1 * (pressureFlexGain / 4.0) * math.lerp(frictionLimitAngle / 6.3, 1.0, 0.6)) - (0.012 * math.max(0.0, car.wheels[1].tyreCoreTemperature - car.wheels[1].tyreOptimumTemperature))

    -- local targetSlip = lib.weightedAverage({(frictionLimitAngle - 1.25) + camberAdditive0 + loadAdditive0, (frictionLimitAngle - 1.25) + camberAdditive1 + loadAdditive1}, vData.fWheelWeights)

    -- return math.clamp(lib.numberGuard(targetSlip), 6, 11) -- Clamp the target to a safe range
end

function M:updateTireTelemetry(vData, dt)
    if self.storedCompoundIndex ~= self.vehicle.compoundIndex then
        local tiresINI = ac.INIConfig.carData(vData.vehicle.index, "tyres.ini")
        self:readTires(tiresINI)
    end

    local oneFrontGrounded = (vData.vehicle.wheels[0].loadK > 0.0 or vData.vehicle.wheels[1].loadK > 0.0)

    if not oneFrontGrounded then return end

    local frontPeakSlipAngle, frontPeakSlipRatio = self:getTargetSlipEstimate(vData, true)
    local rearPeakSlipAngle, rearPeakSlipRatio = self:getTargetSlipEstimate(vData, false)

    self.targetSlipAngleSmootherFront:get(frontPeakSlipAngle, dt)
    self.targetSlipAngleSmootherRear:get(rearPeakSlipAngle, dt)
    self.targetSlipRatioSmootherFront:get(frontPeakSlipRatio, dt)
    self.targetSlipRatioSmootherRear:get(rearPeakSlipRatio, dt)
end

function M:getTargetFrontSlipAngle()
    return self.targetSlipAngleSmootherFront.state
end

function M:getTargetRearSlipAngle()
    return self.targetSlipAngleSmootherRear.state
end

function M:getTargetFrontSlipRatio()
    return self.targetSlipRatioSmootherFront.state
end

function M:getTargetRearSlipRatio()
    return self.targetSlipRatioSmootherRear.state
end

---Hi
---@param load number
---@param curve ac.DataLUT11
---@param fz0 number
---@param lsExp number
---@param dRef number
---@return number
local function peakGripEstImpl(load, curve, fz0, lsExp, dRef)
    local magicNumber1 = 0.9
    local magicNumber2 = 1.5
    local magicNumber3 = -500
    local efficiency = 0.71

    if curve then
        curve.useCubicInterpolation = true
        curve.extrapolate = true
        local d = curve:get(load * magicNumber1)

        return (math.max(10.0, d * load)) -- no magic numbers needed?
    end

    return efficiency * math.max(10.0, (math.pow(load * magicNumber1 / fz0, lsExp) * fz0 / magicNumber1 * dRef) * magicNumber2 + magicNumber3)
end

function M:getFrontPeakLateralForceEst(load)
    return peakGripEstImpl(load, self.frontDyCurve, self.frontFZ0, self.frontLsExpY, self.frontDyRef)
end

function M:getFrontPeakLongitudinalForceEst(load)
    return peakGripEstImpl(load, self.frontDxCurve, self.frontFZ0, self.frontLsExpX, self.frontDxRef)
end

function M:getRearPeakLateralForceEst(load)
    return peakGripEstImpl(load, self.rearDyCurve, self.rearFZ0, self.rearLsExpY, self.rearDyRef)
end

function M:getRearPeakLongitudinalForceEst(load)
    return peakGripEstImpl(load, self.rearDxCurve, self.rearFZ0, self.rearLsExpX, self.rearDxRef)
end

-- :)
-- function M:calcContactPatchLength(radius, deflection)
--     local v = radius - deflection
--     if v <= 0.0 or radius <= v then
--         return 0.0
--     else
--         return math.sqrt(radius * radius - v * v) * 2.0
--     end
-- end

local function getContactPatchLengthEstimateImpl(load, staticWheelRadius, tireRate)
    if load <= 0.0 then
        return 0.0
    end
    local v = staticWheelRadius - (load / tireRate)
    return math.sqrt((staticWheelRadius * staticWheelRadius) - (v * v)) * 2.0
end

-- local function getContactPatchLengthEstimateImpl(load, staticWheelRadius, tireRate)
--     if load <= 0.0 then
--         return 0.0
--     end
--     staticWheelRadius = staticWheelRadius
--     local v = load / tireRate
--     return math.sqrt((staticWheelRadius * staticWheelRadius) - (v * v)) * 2.0
-- end

function M:getFrontContactPatchLengthEstimate(load, staticWheelRadius)
    return getContactPatchLengthEstimateImpl(load, staticWheelRadius, self.frontTireRate)
end

function M:getRearContactPatchLengthEstimate(load, staticWheelRadius)
    return getContactPatchLengthEstimateImpl(load, staticWheelRadius, self.rearTireRate)
end

local peakCorneringWeightShift = 1.7
local peakSATWeightShift = 1.6

---Returns the expected peak
---@param staticTireRadius number Front tire radius (static)
---@param ffbBase number vehicle.ffbBase
---@return number FFBPeakEstimate Estimated peak FFB strength before being multiplied by either the global FFB gain or the per-car FFB gain.
function M:getFFBPeakStrengthEstimateCurrnet(staticTireRadius, ffbBase)
    local mz = (self.vehicle.wheels[0].mz + self.vehicle.wheels[1].mz)
    local load1 = self.vehicle.wheels[0].load
    local load2 = self.vehicle.wheels[1].load
    local lateralForce1 = self.vehicle.wheels[0].fy
    local lateralForce2 = self.vehicle.wheels[1].fy
    local loadedRadius1 = self.vehicle.wheels[0].tyreLoadedRadius
    local loadedRadius2 = self.vehicle.wheels[1].tyreLoadedRadius
    local totalContactForce = vec3()
    tmpVec2:set(lateralForce1, load1, 0.0)
    tmpVec1:set(0.0, -loadedRadius1, 0.0):sub(self.steerBasisCenter):cross(tmpVec2)
    totalContactForce:add(tmpVec1)
    tmpVec2:set(-lateralForce2, load2, 0.0)
    tmpVec1:set(0.0, -loadedRadius2, 0.0):sub(self.steerBasisCenter):cross(tmpVec2):scale(-1.0)
    totalContactForce:add(tmpVec1)
    local steerAxisTorque = self.steerBasisAxis:dot(totalContactForce)
    local mzMult = self.steerBasisAxis:dot(tmpVec1:set(0.0, 1.0, 0.0))
    steerAxisTorque = steerAxisTorque + mz * mzMult
    steerAxisTorque = steerAxisTorque * 0.75
    local ffbStrength = steerAxisTorque / 600.0 * ffbBase
    return ffbStrength
end

-- ---Returns the expected peak
-- ---@param avgWheelLoad number Per-wheel load in N
-- ---@param staticTireRadius number Front tire radius (static)
-- ---@param ffbBase number vehicle.ffbBase
-- ---@param mz? number (OPTIONAL) For the whole front axle, in Nm
-- ---@return number FFBPeakEstimate Estimated peak FFB strength before being multiplied by either the global FFB gain or the per-car FFB gain.
-- function M:getFFBPeakStrengthEstimate(avgWheelLoad, staticTireRadius, ffbBase, mz)
--     mz = mz or self:getMzEstimate(avgWheelLoad, staticTireRadius)
--     local load1 = avgWheelLoad * peakSATWeightShift
--     local load2 = avgWheelLoad * (2.0 - peakSATWeightShift)
--     local lateralForce1 = self:getFrontPeakLateralForceEst(load1) * 0.843
--     local lateralForce2 = self:getFrontPeakLateralForceEst(load2) * 0.843 * 0.95
--     -- local lateralForce1 = self:getFrontPeakLateralForceEst(load1) * 0.78
--     -- local lateralForce2 = self:getFrontPeakLateralForceEst(load2) * 0.78 * 0.95
--     local loadedRadius1 = staticTireRadius - load1 / self.frontTireRate
--     local loadedRadius2 = staticTireRadius - load2 / self.frontTireRate
--     local totalContactForce = vec3()
--     tmpVec2:set(lateralForce1, load1, 0.0)
--     tmpVec1:set(0.0, -loadedRadius1, 0.0):sub(self.steerBasisCenter):cross(tmpVec2)
--     totalContactForce:add(tmpVec1)
--     tmpVec2:set(-lateralForce2, load2, 0.0)
--     tmpVec1:set(0.0, -loadedRadius2, 0.0):sub(self.steerBasisCenter):cross(tmpVec2):scale(-1.0)
--     totalContactForce:add(tmpVec1)
--     local steerAxisTorque = self.steerBasisAxis:dot(totalContactForce)
--     local mzMult = self.steerBasisAxis:dot(tmpVec1:set(0.0, 1.0, 0.0))
--     steerAxisTorque = math.abs(steerAxisTorque) + mz * mzMult * 0.65
--     -- steerAxisTorque = math.abs(steerAxisTorque) + mz * mzMult
--     local ffbStrength = steerAxisTorque / 600.0 * ffbBase
--     return ffbStrength
-- end

---Returns the expected peak
---@param avgWheelLoad number Per-wheel load in N
---@param staticTireRadius number Front tire radius (static)
---@param ffbBase number vehicle.ffbBase
---@param mz? number (OPTIONAL) For the whole front axle, in Nm
---@return number FFBPeakEstimate Estimated peak FFB strength before being multiplied by either the global FFB gain or the per-car FFB gain.
function M:getFFBPeakStrengthEstimate(avgWheelLoad, staticTireRadius, ffbBase, mz)
    mz = mz or self:getMzEstimate(avgWheelLoad, staticTireRadius)
    local load1 = avgWheelLoad * peakSATWeightShift
    local load2 = avgWheelLoad * (2.0 - peakSATWeightShift)
    local lateralForce1 = self:getFrontPeakLateralForceEst(load1) * 0.78
    local lateralForce2 = self:getFrontPeakLateralForceEst(load2) * 0.78 * 0.95
    local loadedRadius1 = staticTireRadius - load1 / self.frontTireRate
    local loadedRadius2 = staticTireRadius - load2 / self.frontTireRate
    local totalContactForce = vec3()
    tmpVec2:set(lateralForce1, load1, 0.0)
    tmpVec1:set(0.0, -loadedRadius1, 0.0):sub(self.steerBasisCenter):cross(tmpVec2)
    totalContactForce:add(tmpVec1)
    tmpVec2:set(-lateralForce2, load2, 0.0)
    tmpVec1:set(0.0, -loadedRadius2, 0.0):sub(self.steerBasisCenter):cross(tmpVec2):scale(-1.0)
    totalContactForce:add(tmpVec1)
    local steerAxisTorque = self.steerBasisAxis:dot(totalContactForce)
    local mzMult = self.steerBasisAxis:dot(tmpVec1:set(0.0, 1.0, 0.0))
    steerAxisTorque = math.abs(steerAxisTorque) + mz * mzMult
    local ffbStrength = steerAxisTorque / 600.0 * ffbBase
    return ffbStrength
end

-- function M:getMzRatioInFFB(avgWheelLoad, staticTireRadius, mz)
--     mz = mz or self:getMzEstimate(avgWheelLoad, staticTireRadius)
--     local load1 = avgWheelLoad * peakSATWeightShift
--     local load2 = avgWheelLoad * (2.0 - peakSATWeightShift)
--     local lateralForce1 = self:getFrontPeakLateralForceEst(load1) * 0.843
--     local lateralForce2 = self:getFrontPeakLateralForceEst(load2) * 0.843 * 0.95
--     local loadedRadius1 = staticTireRadius - load1 / self.frontTireRate
--     local loadedRadius2 = staticTireRadius - load2 / self.frontTireRate
--     local totalContactForce = vec3()
--     tmpVec2:set(lateralForce1, load1, 0.0)
--     tmpVec1:set(0.0, -loadedRadius1, 0.0):sub(self.steerBasisCenter):cross(tmpVec2)
--     totalContactForce:add(tmpVec1)
--     tmpVec2:set(-lateralForce2, load2, 0.0)
--     tmpVec1:set(0.0, -loadedRadius2, 0.0):sub(self.steerBasisCenter):cross(tmpVec2):scale(-1.0)
--     totalContactForce:add(tmpVec1)
--     local steerAxisTorque = self.steerBasisAxis:dot(totalContactForce)
--     local mzMult = self.steerBasisAxis:dot(tmpVec1:set(0.0, 1.0, 0.0))
--     steerAxisTorque = math.abs(steerAxisTorque)
--     local addedMz = (mz * mzMult * 0.65)

--     -- ac.debug("mz est fx rat", math.abs(self.vehicle.wheels[0].fy + self.vehicle.wheels[1].fy) / (lateralForce1 + lateralForce2))
--     -- ac.debug("mz est mz rat", math.abs(self.vehicle.wheels[0].mz + self.vehicle.wheels[1].mz) / addedMz)
--     return addedMz / (steerAxisTorque + addedMz)
-- end

function M:getMzRatioInFFB(avgWheelLoad, staticTireRadius, mz)
    mz = mz or self:getMzEstimate(avgWheelLoad, staticTireRadius)
    local load1 = avgWheelLoad * peakSATWeightShift
    local load2 = avgWheelLoad * (2.0 - peakSATWeightShift)
    local lateralForce1 = self:getFrontPeakLateralForceEst(load1) * 0.78
    local lateralForce2 = self:getFrontPeakLateralForceEst(load2) * 0.78 * 0.95
    local loadedRadius1 = staticTireRadius - load1 / self.frontTireRate
    local loadedRadius2 = staticTireRadius - load2 / self.frontTireRate
    local totalContactForce = vec3()
    tmpVec2:set(lateralForce1, load1, 0.0)
    tmpVec1:set(0.0, -loadedRadius1, 0.0):sub(self.steerBasisCenter):cross(tmpVec2)
    totalContactForce:add(tmpVec1)
    tmpVec2:set(-lateralForce2, load2, 0.0)
    tmpVec1:set(0.0, -loadedRadius2, 0.0):sub(self.steerBasisCenter):cross(tmpVec2):scale(-1.0)
    totalContactForce:add(tmpVec1)
    local steerAxisTorque = self.steerBasisAxis:dot(totalContactForce)
    local mzMult = self.steerBasisAxis:dot(tmpVec1:set(0.0, 1.0, 0.0))
    steerAxisTorque = math.abs(steerAxisTorque)
    local totalMz = mz * mzMult

    -- ac.debug("mz est fx rat", math.abs(self.vehicle.wheels[0].fy + self.vehicle.wheels[1].fy) / (lateralForce1 + lateralForce2))
    -- ac.debug("mz est mz rat", math.abs(self.vehicle.wheels[0].mz + self.vehicle.wheels[1].mz) / addedMz)
    return totalMz / (steerAxisTorque + totalMz)
end

-- not multiplied by any gain setting, only processed through the suspension geometry
function M:getSteeringRackTorqueFromFrontMz(wheel0Mz, wheel1Mz, wheel0Normal, wheel1Normal)
    tmpVec3:set(self.steerBasisAxis):mul(tmpVec4:set(-1.0, 1.0, 1.0))
    local steeringRackTorque = (
        wheel0Mz * tmpVec3:dot(wheel0Normal) +
        wheel1Mz * self.steerBasisAxis:dot(wheel1Normal)
    )
    return steeringRackTorque
end

-- ---Returns the expected peak
-- ---@param avgWheelLoad number Per-wheel load in N
-- ---@param staticTireRadius number Front tire radius (static)
-- ---@param ffbBase number vehicle.ffbBase
-- ---@param mz? number (OPTIONAL) In Nm
-- ---@return number FFBPeakEstimate Estimated peak FFB strength before being multiplied by either the global FFB gain or the per-car FFB gain.
-- function M:getFFBPeakStrengthEstimateOld(avgWheelLoad, staticTireRadius, ffbBase, mz)
--     mz = mz or self:getMzEstimate(avgWheelLoad, staticTireRadius)
--     local load1 = avgWheelLoad * peakSATWeightShift
--     local load2 = avgWheelLoad * (2.0 - peakSATWeightShift)
--     local lateralForce1 = self:getFrontPeakLateralForceEst(load1) * 0.78
--     local lateralForce2 = self:getFrontPeakLateralForceEst(load2) * 0.78 * 0.96 -- slightly reduced because of cringe camber and stuff
--     local loadedRadius1 = staticTireRadius - load1 / self.frontTireRate
--     local loadedRadius2 = staticTireRadius - load2 / self.frontTireRate
--     local totalContactForce = vec3()
--     tmpVec2:set(lateralForce1, 0.0, 0.0)
--     tmpVec1:set(0.0, -loadedRadius1, 0.0):sub(self.steerBasisCenter):cross(tmpVec2)
--     totalContactForce:add(tmpVec1)
--     tmpVec2:set(lateralForce2, 0.0, 0.0)
--     tmpVec1:set(0.0, -loadedRadius2, 0.0):sub(self.steerBasisCenter):cross(tmpVec2)
--     totalContactForce:add(tmpVec1)
--     local steerAxisTorque = self.steerBasisAxis:dot(totalContactForce)
--     local mzMult = self.steerBasisAxis:dot(tmpVec1:set(0.0, 1.0, 0.0))
--     steerAxisTorque = math.abs(steerAxisTorque) + mz * mzMult
--     local ffbStrength = steerAxisTorque / 600.0 * ffbBase
--     return ffbStrength
-- end

-- ---Returns the expected peak
-- ---@param avgWheelLoad number Per-wheel load in N
-- ---@param staticTireRadius number Front tire radius (static)
-- ---@param ffbBase number vehicle.ffbBase
-- ---@param mz? number (OPTIONAL) In Nm
-- ---@return number FFBPeakEstimate Estimated peak FFB strength before being multiplied by either the global FFB gain or the per-car FFB gain.
-- function M:getFFBPeakStrengthEstimateOlder(avgWheelLoad, staticTireRadius, ffbBase, mz)
--     mz = mz or self:getMzEstimate(avgWheelLoad, staticTireRadius)
--     -- local lateralForce = (self:getFrontPeakLateralForceEst(avgWheelLoad * peakCorneringWeightShift) + self:getFrontPeakLateralForceEst(avgWheelLoad * (2.0 - peakCorneringWeightShift)))
--     local lateralForce = (self:getFrontPeakLateralForceEst(avgWheelLoad * peakSATWeightShift) + self:getFrontPeakLateralForceEst(avgWheelLoad * (2.0 - peakSATWeightShift)) * 0.95) * 0.78 -- the lateral curve is roughly 0.78 at the point where SAT peaks. also using a multiplier for the inside wheel grip to account for cringe camber and stuff
--     local loadedRadius = staticTireRadius - avgWheelLoad / self.frontTireRate
--     tmpVec2:set(lateralForce, 0.0, 0.0)
--     tmpVec1:set(0.0, -loadedRadius, 0.0):sub(self.steerBasisCenter):cross(tmpVec2)
--     local steerAxisTorque = tmpVec1:dot(self.steerBasisAxis)
--     local mzMult = self.steerBasisAxis:dot(tmpVec1:set(0.0, 1.0, 0.0))
--     -- steerAxisTorque = math.abs(steerAxisTorque) + mz * 0.55 * mzMult
--     steerAxisTorque = math.abs(steerAxisTorque) + mz * mzMult
--     local ffbStrength = steerAxisTorque / 600.0 * ffbBase
--     return ffbStrength
-- end

-- -- For the whole front axle under cornering, but not compensated for suspension geometry yet. In Nm.
-- function M:getMzEstimate(avgWheelLoad, staticTireRadius)
--     local loadMz1 = avgWheelLoad * peakSATWeightShift
--     local loadMz2 = avgWheelLoad * (2.0 - peakSATWeightShift)

--     local cpLen1 = self:getFrontContactPatchLengthEstimate(loadMz1, staticTireRadius)
--     local cpLen2 = self:getFrontContactPatchLengthEstimate(loadMz2, staticTireRadius)

--     local mz1 = self:getRearPeakLateralForceEst(loadMz1) * 0.843 * cpLen1 / 1.45 * 0.11
--     local mz2 = self:getRearPeakLateralForceEst(loadMz2) * 0.843 * cpLen2 / 1.45 * 0.11

--     return (mz1 + mz2)
-- end

-- For the whole front axle under cornering, but not compensated for suspension geometry yet. In Nm.
function M:getMzEstimate(avgWheelLoad, staticTireRadius)
    local loadMz1 = avgWheelLoad * peakSATWeightShift
    local loadMz2 = avgWheelLoad * (2.0 - peakSATWeightShift)

    local cpLen1 = self:getFrontContactPatchLengthEstimate(loadMz1, staticTireRadius)
    local cpLen2 = self:getFrontContactPatchLengthEstimate(loadMz2, staticTireRadius)

    local mz1 = self:getRearPeakLateralForceEst(loadMz1) * 0.78 * cpLen1 / 1.45 * 0.11
    local mz2 = self:getRearPeakLateralForceEst(loadMz2) * 0.78 * cpLen2 / 1.45 * 0.11

    return (mz1 + mz2)
end

-- -- For the whole front axle under cornering, but not compensated for suspension geometry yet. In Nm.
-- function M:getMzEstimateOld(avgWheelLoad, staticTireRadius)
--     -- local cpLen = self:getFrontContactPatchLengthEstimate(avgWheelLoad, staticTireRadius)
--     -- return (self:getRearPeakLateralForceEst(avgWheelLoad * peakCorneringWeightShift) + self:getRearPeakLateralForceEst(avgWheelLoad * (2.0 - peakCorneringWeightShift))) * cpLen * 0.12 * 0.55
--     local loadPeak1 = avgWheelLoad * peakCorneringWeightShift
--     local loadPeak2 = avgWheelLoad * (2.0 - peakCorneringWeightShift)
--     local loadMz1 = avgWheelLoad * peakSATWeightShift
--     local loadMz2 = avgWheelLoad * (2.0 - peakSATWeightShift)

--     local cpLen1 = self:getFrontContactPatchLengthEstimate(loadMz1, staticTireRadius)
--     local cpLen2 = self:getFrontContactPatchLengthEstimate(loadMz2, staticTireRadius)

--     local mz1 = self:getRearPeakLateralForceEst(loadMz1) * 0.78 * cpLen1 * 0.12
--     local mz2 = self:getRearPeakLateralForceEst(loadMz2) * 0.78 * cpLen2 * 0.12

--     -- return (mz1 + mz2) * 0.65 -- for old cp length
--     return (mz1 + mz2) * 0.12
-- end

-- function M:getMzEstimateOlder(avgWheelLoad, staticTireRadius)
--     local cpLen = self:getFrontContactPatchLengthEstimate(avgWheelLoad, staticTireRadius)
--     return (self:getRearPeakLateralForceEst(avgWheelLoad * peakCorneringWeightShift) + self:getRearPeakLateralForceEst(avgWheelLoad * (2.0 - peakCorneringWeightShift))) * cpLen * 0.12 * 0.55
--     -- local loadPeak1 = avgWheelLoad * peakCorneringWeightShift
--     -- local loadPeak2 = avgWheelLoad * (2.0 - peakCorneringWeightShift)
--     -- local loadMz1 = avgWheelLoad * peakSATWeightShift
--     -- local loadMz2 = avgWheelLoad * (2.0 - peakSATWeightShift)
    
--     -- local cpLen1 = self:getFrontContactPatchLengthEstimate(loadMz1, staticTireRadius)
--     -- local cpLen2 = self:getFrontContactPatchLengthEstimate(loadMz2, staticTireRadius)

--     -- local mz1 = self:getRearPeakLateralForceEst(loadMz1) * 0.78 * cpLen1 * 0.12
--     -- local mz2 = self:getRearPeakLateralForceEst(loadMz2) * 0.78 * cpLen2 * 0.12

--     -- return (mz1 + mz2) * 0.667
-- end

-- Crude estimation, only based on power and nothing else, could be improved. In m/s.
function M:getTopSpeedEstimate()
    -- return (math.sqrt(vData.perfData.maxEnginePower * 80.0) + 75) / 3.6
    -- return (math.sqrt(perfData.maxEnginePower * 0.78 * 80.0) + 100) / 3.6
    -- return (math.sqrt(perfData.maxEnginePower * 0.78 * 70.0) + 110) / 3.6
    -- return math.max(1.0, (math.sqrt(self.maxEnginePower * 0.78 * 60.0) + 120) / 3.6)
    return math.max(1.0, (math.tanh(self.maxEnginePower * 0.78 / 400.0) * 230.0 + 117.0) / 3.6) -- much better than sqrt
end

---comment
---@param vehiclePR ac.StateCarPhysicsRate
---@param wheelbase number
---@param rearAxleZ number
---@param cPhys ac.StateCarPhysics
---@param dt number
function M:updateDownforceTelemetry(vehiclePR, wheelbase, rearAxleZ, cPhys, dt)
    local velSquared = vehiclePR.localVelocity.z * vehiclePR.localVelocity.z
    local baseTireLoad = self:getFrontTireLoadAtRest(wheelbase, rearAxleZ)

    self.fAxleDownforce = 0.0
    local fAxleDownforceAtVMax = 0.0
    local topSpeedEst = self:getTopSpeedEstimate()
    local zeroVec = vec3.new(0.0, 0.0, 0.0)

    -- at high speed we take a snapshot of the actual wing lift values rather than the ones predicted at a standstill. this (more or less) accounts for dynamic wing controllers that change things.
    -- EDIT: ignored for now
    local phase2ConditionsMet = (vehiclePR.localVelocity.z > topSpeedEst * 0.5) and (vehiclePR.gas > 0.5) and (math.abs(vehiclePR.steer * self.vehicle.steerLock) < 20.0) and (not self.vehicle.drsActive)

    local wingsChanged = false -- why is there no api to detect setup changes ????

    if #cPhys.wings > 0 then
        for i = 0, #cPhys.wings - 1, 1 do
            local wingPosition = self.aeroIni:get("WING_" .. i, "POSITION", zeroVec)
            local wingCl = 0.0

            -- if math.abs(vehiclePR.localVelocity.z) < 1.0 then
            --     if self.lastWingAngles[i] == nil or (math.abs(cPhys.wings[i].angle - self.lastWingAngles[i]) >= 0.51) then
            --         wingsChanged = true
            --     end
            --     self.lastWingAngles[i] = cPhys.wings[i].angle
            -- end

            if self.lastWingAngles[i] == nil or (vehiclePR.localVelocity:length() < 1.0 and math.abs(cPhys.wings[i].angle - self.lastWingAngles[i]) >= 0.9) then -- // FIXME this sometimes triggers for no reason when it shouldnt, but hard to fix because csp cannot fire events correctly, very fun
                wingsChanged = true
                self.lastWingAngles[i] = cPhys.wings[i].angle
            end

            local wingArea   = self.aeroIni:get("WING_" .. i, "CHORD", 1.0) * self.aeroIni:get("WING_" .. i, "SPAN", 1.0)
            local wingCl     = ac.DataLUT11.carData(car.index, self.aeroIni:get("WING_" .. i, "LUT_AOA_CL", ""))
            local wingClGain = self.aeroIni:get("WING_" .. i, "CL_GAIN", 1.0)
            local staticCl   = wingCl:get(cPhys.wings[i].angle) * wingClGain * wingArea
            local currentCl  = cPhys.wings[i].cl
            local vMaxClUsed = phase2ConditionsMet and currentCl or staticCl

            self.fAxleDownforce = self.fAxleDownforce + (velSquared * staticCl * (wingPosition.z - rearAxleZ) / wheelbase) * 0.5 -- *0.5 should not be needed here but it somehow works so i wont question it

            local wingDownforceAtVMax = vMaxClUsed * topSpeedEst * topSpeedEst * 0.5
            fAxleDownforceAtVMax = fAxleDownforceAtVMax + wingDownforceAtVMax * (wingPosition.z - rearAxleZ) / wheelbase
        end
    end

    if wingsChanged then
        self.dfDynamicRange1 = 0.0
        self.dfDynamicRange2 = 0.0
        self.dfDynamicRangeSmoother.state = 0.0
    end

    local dynamicRange = math.max(1e-6, fAxleDownforceAtVMax * 0.5 / baseTireLoad)

    if phase2ConditionsMet then
        if self.dfDynamicRange2 == 0.0 then
            self.dfDynamicRange2 = dynamicRange
        end
    else
        if self.dfDynamicRange1 == 0.0 then
            self.dfDynamicRange1 = dynamicRange
        end
    end

    if self.dfDynamicRangeSmoother.state == 0.0 then
        self.dfDynamicRangeSmoother.state = dynamicRange
    else
        local target = (self.dfDynamicRange2 == 0.0) and self.dfDynamicRange1 or self.dfDynamicRange2
        self.dfDynamicRangeSmoother:get(target, dt)
    end
end

function M:getDownforceMaxDynamicRange()
    return self.dfDynamicRangeSmoother.state -- 4.57
end

function M:getSteerAssistValue()
    return self.hasSteerAssistSetup and 1.0 or self.steerAssist -- // TODO is this right?
end

function M:getFrontTireLoadAtRest(wheelbase, rearAxleZ)
    return math.abs(rearAxleZ) / wheelbase * self.vehicle.mass * 9.81 * 0.5 -- // TODO maybe somehow take dry mass or something so it doesnt change over a race?
end

function M:getRearTireLoadAtRest(wheelbase, rearAxleZ)
    return (1.0 - math.abs(rearAxleZ) / wheelbase) * self.vehicle.mass * 9.81 * 0.5
end

function M:getFrontTireLoadAtNdSpeed(normalizedSpeed, wheelbase, rearAxleZ)
    return (self:getDownforceMaxDynamicRange() * (normalizedSpeed ^ 2.0) + 1.0) * self:getFrontTireLoadAtRest(wheelbase, rearAxleZ)
end

function M:getRearTireLoadAtNdSpeed(normalizedSpeed, wheelbase, rearAxleZ)
    return (self:getDownforceMaxDynamicRange() * (normalizedSpeed ^ 2.0) + 1.0) * self:getFrontTireLoadAtRest(wheelbase, rearAxleZ)
end

return M