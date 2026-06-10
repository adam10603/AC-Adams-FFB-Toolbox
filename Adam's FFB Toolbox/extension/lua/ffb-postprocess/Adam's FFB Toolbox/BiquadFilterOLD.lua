-- -- BiquadFilter.lua
-- local BiquadFilter = {}
-- BiquadFilter.__index = BiquadFilter

-- ---@alias BiquadFilter.FilterType
-- ---| `BiquadFilter.FilterType.LowPass` @Value: 'LowPass'.
-- ---| `BiquadFilter.FilterType.HighPass` @Value: 'HighPass'.
-- ---| `BiquadFilter.FilterType.Peak` @Value: 'Peak'.
-- BiquadFilter.FilterType = {
--     LowPass = "LowPass", ---@type BiquadFilter.FilterType #Value: 'LowPass'.
--     HighPass = "HighPass", ---@type BiquadFilter.FilterType #Value: 'HighPass'.
--     Peak = "Peak" ---@type BiquadFilter.FilterType #Value: 'Peak'.
-- }

-- ---Calculates filter parameters based on nyquist and corner frequencies
-- ---@param sampleRate number
-- ---@param nyquistFrequency number
-- ---@param cornerFrequency number
-- ---@return number filterSampleRate
-- ---@return number filterFrequency
-- function BiquadFilter.calculateLowPassParameters(sampleRate, nyquistFrequency, cornerFrequency)
--     local frequencyMult = nyquistFrequency * 2.0 / sampleRate

--     return nyquistFrequency * 2.0, cornerFrequency * frequencyMult
-- end

-- ---Creates a new filter
-- ---@param type BiquadFilter.FilterType
-- ---@param sampleRate number
-- ---@param frequency number
-- ---@param Q number
-- ---@param gainDB number
-- ---@return table
-- function BiquadFilter.new(type, sampleRate, frequency, Q, gainDB)
--     local self = setmetatable({}, BiquadFilter)
--     self.type = type or BiquadFilter.FilterType.LowPass
--     self.sampleRate = sampleRate or (1000 / 3)
--     self.frequency = frequency or 100
--     self.Q = Q or 0.7071
--     self.gainDB = gainDB or 0.0

--     -- Coefficients
--     self.b0, self.b1, self.b2 = 0, 0, 0
--     self.a1, self.a2 = 0, 0

--     -- State variables
--     self.x1, self.x2 = 0, 0
--     self.y1, self.y2 = 0, 0

--     self:calculateCoefficients()
--     return self
-- end

-- -- Update parameters (optional)
-- function BiquadFilter:updateParameters(sampleRate, frequency, Q, gainDB)
--     local VERY_SMALL_FLOAT = 1e-12
--     sampleRate = sampleRate or self.sampleRate
--     Q = Q or self.Q
--     gainDB = gainDB or self.gainDB

--     if math.abs(self.sampleRate - sampleRate) > VERY_SMALL_FLOAT
--         or math.abs(self.frequency - frequency) > VERY_SMALL_FLOAT
--         or math.abs(self.Q - Q) > VERY_SMALL_FLOAT
--         or math.abs(self.gainDB - gainDB) > VERY_SMALL_FLOAT then

--         self.frequency = frequency
--         self.Q = Q
--         self.gainDB = gainDB
--         self:calculateCoefficients()
--     end
-- end

-- -- Process a single sample
-- function BiquadFilter:process(input)
--     local output = self.b0 * input + self.b1 * self.x1 + self.b2 * self.x2
--                     - self.a1 * self.y1 - self.a2 * self.y2

--     -- Update state
--     self.x2 = self.x1
--     self.x1 = input
--     self.y2 = self.y1
--     self.y1 = output

--     return output
-- end

-- function BiquadFilter:reset(dcValue)
--     dcValue = dcValue or 0.0
--     self.x1, self.x2 = dcValue, dcValue
--     self.y1, self.y2 = dcValue, dcValue
-- end

-- -- Coefficient calculation
-- function BiquadFilter:calculateCoefficients()
--     local omega = 2.0 * math.pi * self.frequency / self.sampleRate
--     local sinOmega = math.sin(omega)
--     local cosOmega = math.cos(omega)

--     local alpha = sinOmega / (2.0 * self.Q)
--     local A = math.pow(10.0, self.gainDB / 40.0)
--     local a0

--     if self.type == BiquadFilter.FilterType.LowPass then
--         self.b0 = (1 - cosOmega) / 2
--         self.b1 = 1 - cosOmega
--         self.b2 = (1 - cosOmega) / 2
--         a0 = 1 + alpha
--         self.a1 = -2 * cosOmega
--         self.a2 = 1 - alpha

--     elseif self.type == BiquadFilter.FilterType.HighPass then
--         self.b0 = (1 + cosOmega) / 2
--         self.b1 = -(1 + cosOmega)
--         self.b2 = (1 + cosOmega) / 2
--         a0 = 1 + alpha
--         self.a1 = -2 * cosOmega
--         self.a2 = 1 - alpha

--     elseif self.type == BiquadFilter.FilterType.Peak then
--         self.b0 = 1 + (alpha * A)
--         self.b1 = -2 * cosOmega
--         self.b2 = 1 - (alpha * A)
--         a0 = 1 + (alpha / A)
--         self.a1 = -2 * cosOmega
--         self.a2 = 1 - (alpha / A)

--     else
--         error("Unknown filter type: " .. tostring(self.type))
--     end

--     -- Normalize coefficients
--     self.b0 = self.b0 / a0
--     self.b1 = self.b1 / a0
--     self.b2 = self.b2 / a0
--     self.a1 = self.a1 / a0
--     self.a2 = self.a2 / a0
-- end

-- return BiquadFilter
