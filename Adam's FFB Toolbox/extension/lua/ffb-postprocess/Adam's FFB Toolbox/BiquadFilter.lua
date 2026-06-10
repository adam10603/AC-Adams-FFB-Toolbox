-- BiquadFilter.lua

---@class BiquadFilter
---@field type "LowPass"|"HighPass"|"Peak"
---@field sampleRate number Sample rate in Hz.
---@field frequency number Cutoff or center frequency in Hz.
---@field Q number Filter Q factor (resonance).
---@field gainDB number Gain in decibels. Used by peak filters.
---@field b0 number Feedforward coefficient b0.
---@field b1 number Feedforward coefficient b1.
---@field b2 number Feedforward coefficient b2.
---@field a1 number Feedback coefficient a1.
---@field a2 number Feedback coefficient a2.
---@field x1 number Previous input sample.
---@field x2 number Input sample from two processing steps ago.
---@field y1 number Previous output sample.
---@field y2 number Output sample from two processing steps ago.
local BiquadFilter = {}
BiquadFilter.__index = BiquadFilter

---Calculates low-pass filter parameters based on nyquist and corner frequencies.
---@param sampleRate number Sample rate in Hz.
---@param nyquistFrequency number Nyquist frequency in Hz.
---@param cornerFrequency number Corner frequency in Hz.
---@return number filterSampleRate Derived filter sample rate.
---@return number filterFrequency Scaled filter frequency.
function BiquadFilter.calculateLowPassParameters(sampleRate, nyquistFrequency, cornerFrequency)
    local frequencyMult = nyquistFrequency * 2.0 / sampleRate

    return nyquistFrequency * 2.0, cornerFrequency * frequencyMult
end

---Creates a new biquad filter instance.
---@param type? "LowPass"|"HighPass"|"Peak" Filter type.
---@param sampleRate? number Sample rate in Hz.
---@param frequency? number Cutoff or center frequency in Hz.
---@param Q? number Filter Q factor (resonance).
---@param gainDB? number Gain in decibels. Used by peak filters.
---@return BiquadFilter
function BiquadFilter.new(type, sampleRate, frequency, Q, gainDB)
    local self = setmetatable({}, BiquadFilter)

    self.type = type or "LowPass"
    self.sampleRate = sampleRate or (1000 / 3)
    self.frequency = frequency or 100
    self.Q = Q or 0.7071
    self.gainDB = gainDB or 0.0

    -- Coefficients
    self.b0, self.b1, self.b2 = 0, 0, 0
    self.a1, self.a2 = 0, 0

    -- State variables
    self.x1, self.x2 = 0, 0
    self.y1, self.y2 = 0, 0

    self:calculateCoefficients()

    return self
end

---Updates filter parameters and recalculates coefficients if any value changes.
---@param sampleRate? number New sample rate in Hz. Uses the current value if nil.
---@param frequency? number New cutoff or center frequency in Hz. Uses the current value if nil.
---@param Q? number New Q factor (resonance). Uses the current value if nil.
---@param gainDB? number New gain in decibels. Uses the current value if nil.
function BiquadFilter:updateParameters(sampleRate, frequency, Q, gainDB)
    local VERY_SMALL_FLOAT = 1e-12

    sampleRate = sampleRate or self.sampleRate
    frequency = frequency or self.frequency
    Q = Q or self.Q
    gainDB = gainDB or self.gainDB

    if math.abs(self.sampleRate - sampleRate) > VERY_SMALL_FLOAT
        or math.abs(self.frequency - frequency) > VERY_SMALL_FLOAT
        or math.abs(self.Q - Q) > VERY_SMALL_FLOAT
        or math.abs(self.gainDB - gainDB) > VERY_SMALL_FLOAT then

        self.sampleRate = sampleRate
        self.frequency = frequency
        self.Q = Q
        self.gainDB = gainDB

        self:calculateCoefficients()
    end
end

---Processes a single sample through the filter.
---@param input number Input sample value.
---@return number output Filtered output sample.
function BiquadFilter:process(input)
    local output = self.b0 * input + self.b1 * self.x1 + self.b2 * self.x2
                    - self.a1 * self.y1 - self.a2 * self.y2

    -- Update state
    self.x2 = self.x1
    self.x1 = input
    self.y2 = self.y1
    self.y1 = output

    return output
end

---Resets the filter history/state variables.
---
---Useful when reusing a filter or preventing startup transients.
---All input and output history values are initialized to the specified value.
---@param dcValue? number Initial value for filter history. Defaults to 0.
function BiquadFilter:reset(dcValue)
    dcValue = dcValue or 0.0

    self.x1, self.x2 = dcValue, dcValue
    self.y1, self.y2 = dcValue, dcValue
end

---Initializes internal coefficients. No need to call manually.
function BiquadFilter:calculateCoefficients()
    local omega = 2.0 * math.pi * self.frequency / self.sampleRate
    local sinOmega = math.sin(omega)
    local cosOmega = math.cos(omega)

    local alpha = sinOmega / (2.0 * self.Q)
    local A = math.pow(10.0, self.gainDB / 40.0)
    local a0

    if self.type == "LowPass" then
        self.b0 = (1 - cosOmega) / 2
        self.b1 = 1 - cosOmega
        self.b2 = (1 - cosOmega) / 2
        a0 = 1 + alpha
        self.a1 = -2 * cosOmega
        self.a2 = 1 - alpha

    elseif self.type == "HighPass" then
        self.b0 = (1 + cosOmega) / 2
        self.b1 = -(1 + cosOmega)
        self.b2 = (1 + cosOmega) / 2
        a0 = 1 + alpha
        self.a1 = -2 * cosOmega
        self.a2 = 1 - alpha

    elseif self.type == "Peak" then
        self.b0 = 1 + (alpha * A)
        self.b1 = -2 * cosOmega
        self.b2 = 1 - (alpha * A)
        a0 = 1 + (alpha / A)
        self.a1 = -2 * cosOmega
        self.a2 = 1 - (alpha / A)

    else
        error("Unknown filter type: " .. tostring(self.type))
    end

    -- Normalize coefficients
    self.b0 = self.b0 / a0
    self.b1 = self.b1 / a0
    self.b2 = self.b2 / a0
    self.a1 = self.a1 / a0
    self.a2 = self.a2 / a0
end

return BiquadFilter