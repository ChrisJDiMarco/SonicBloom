#include "SonicBloomDSP.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <vector>

namespace {

constexpr float pi = 3.14159265358979323846f;
constexpr float qForThirdOctave = 4.318f;
constexpr size_t crossfeedDelayBufferSize = 128;
constexpr size_t spatialDelayBufferSize = 96;
constexpr size_t lookaheadBufferSize = 512;
constexpr size_t ambienceBufferSize = 4096;
constexpr size_t hrtfTapCount = 12;
constexpr std::array<float, SonicBloomDSPBandCount> bandCenters = {
    20.0f, 25.0f, 31.5f, 40.0f, 50.0f, 63.0f, 80.0f, 100.0f,
    125.0f, 160.0f, 200.0f, 250.0f, 315.0f, 400.0f, 500.0f,
    630.0f, 800.0f, 1000.0f, 1250.0f, 1600.0f, 2000.0f,
    2500.0f, 3150.0f, 4000.0f, 5000.0f, 6300.0f, 8000.0f,
    10000.0f, 12500.0f, 16000.0f, 20000.0f
};
constexpr std::array<float, hrtfTapCount> hrtfNearEar = {
    0.74f, 0.20f, -0.06f, 0.04f, -0.03f, 0.02f,
    -0.015f, 0.01f, -0.006f, 0.004f, 0.0f, 0.0f
};
constexpr std::array<float, hrtfTapCount> hrtfFarEar = {
    0.0f, 0.0f, 0.16f, 0.22f, 0.12f, -0.06f,
    0.04f, -0.02f, 0.015f, -0.01f, 0.006f, 0.0f
};

float clamp(float value, float lower, float upper) {
    return std::max(lower, std::min(value, upper));
}

float dbToGain(float db) {
    return std::pow(10.0f, db / 20.0f);
}

float lerp(float from, float to, float amount) {
    return from + (to - from) * amount;
}

float dynamicsGain(float envelope, float threshold, float ratio, float quietBoost) {
    if (envelope > threshold) {
        return std::pow(envelope / threshold, (1.0f / ratio) - 1.0f);
    }
    const float quiet = 1.0f - clamp(envelope / threshold, 0.0f, 1.0f);
    return 1.0f + quiet * quietBoost;
}

float onePoleAlpha(float frequency, float sampleRate) {
    return 1.0f - std::exp(-2.0f * pi * frequency / std::max(sampleRate, 1.0f));
}

size_t spatialDelayFrames(float sampleRate) {
    const float frames = sampleRate * 0.00035f;
    return static_cast<size_t>(clamp(std::round(frames), 1.0f, static_cast<float>(spatialDelayBufferSize - 1)));
}

size_t crossfeedDelayFrames(float sampleRate) {
    const float frames = sampleRate * 0.00028f;
    return static_cast<size_t>(clamp(std::round(frames), 1.0f, static_cast<float>(crossfeedDelayBufferSize - 1)));
}

size_t boundedDelayFrames(float seconds, float sampleRate) {
    const float frames = std::round(sampleRate * seconds);
    return static_cast<size_t>(clamp(frames, 1.0f, static_cast<float>(ambienceBufferSize - 1)));
}

struct Biquad {
    float b0 = 1.0f;
    float b1 = 0.0f;
    float b2 = 0.0f;
    float a1 = 0.0f;
    float a2 = 0.0f;
    float z1L = 0.0f;
    float z2L = 0.0f;
    float z1R = 0.0f;
    float z2R = 0.0f;

    void setPeaking(float frequency, float sampleRate, float gainDB) {
        if (std::fabs(gainDB) < 0.001f || sampleRate <= 0.0f) {
            b0 = 1.0f;
            b1 = 0.0f;
            b2 = 0.0f;
            a1 = 0.0f;
            a2 = 0.0f;
            return;
        }

        const float safeFrequency = clamp(frequency, 5.0f, sampleRate * 0.45f);
        const float omega = 2.0f * pi * safeFrequency / sampleRate;
        const float sinOmega = std::sin(omega);
        const float cosOmega = std::cos(omega);
        const float alpha = sinOmega / (2.0f * qForThirdOctave);
        const float a = std::pow(10.0f, gainDB / 40.0f);

        const float rawB0 = 1.0f + alpha * a;
        const float rawB1 = -2.0f * cosOmega;
        const float rawB2 = 1.0f - alpha * a;
        const float rawA0 = 1.0f + alpha / a;
        const float rawA1 = -2.0f * cosOmega;
        const float rawA2 = 1.0f - alpha / a;

        b0 = rawB0 / rawA0;
        b1 = rawB1 / rawA0;
        b2 = rawB2 / rawA0;
        a1 = rawA1 / rawA0;
        a2 = rawA2 / rawA0;
    }

    void setBandpass(float frequency, float sampleRate, float quality) {
        if (sampleRate <= 0.0f) {
            return;
        }

        const float safeFrequency = clamp(frequency, 5.0f, sampleRate * 0.45f);
        const float omega = 2.0f * pi * safeFrequency / sampleRate;
        const float sinOmega = std::sin(omega);
        const float cosOmega = std::cos(omega);
        const float alpha = sinOmega / (2.0f * std::max(quality, 0.1f));
        const float rawA0 = 1.0f + alpha;

        b0 = alpha / rawA0;
        b1 = 0.0f;
        b2 = -alpha / rawA0;
        a1 = (-2.0f * cosOmega) / rawA0;
        a2 = (1.0f - alpha) / rawA0;
    }

    float processLeft(float input) {
        const float output = b0 * input + z1L;
        z1L = b1 * input - a1 * output + z2L;
        z2L = b2 * input - a2 * output;
        return output;
    }

    float processRight(float input) {
        const float output = b0 * input + z1R;
        z1R = b1 * input - a1 * output + z2R;
        z2R = b2 * input - a2 * output;
        return output;
    }

    void reset() {
        z1L = 0.0f;
        z2L = 0.0f;
        z1R = 0.0f;
        z2R = 0.0f;
    }
};

} // namespace

struct SonicBloomDSPHandle {
    float sampleRate = 48000.0f;
    std::array<float, SonicBloomDSPBandCount> lastEQ = {};
    std::array<Biquad, SonicBloomDSPBandCount> eq = {};
    std::array<Biquad, SonicBloomDSPBandCount> analyzer = {};
    std::array<size_t, SonicBloomDSPBandCount> activeEQ = {};
    size_t activeEQCount = 0;
    float previousInputL = 0.0f;
    float previousInputR = 0.0f;
    float previousOutputL = 0.0f;
    float previousOutputR = 0.0f;
    float bassL = 0.0f;
    float bassR = 0.0f;
    float bassPowerL = 0.0f;
    float bassPowerR = 0.0f;
    float contentLow = 0.0f;
    float contentMidLow = 0.0f;
    float crossfeedL = 0.0f;
    float crossfeedR = 0.0f;
    size_t crossfeedDelayIndex = 0;
    std::array<float, crossfeedDelayBufferSize> crossfeedDelayL = {};
    std::array<float, crossfeedDelayBufferSize> crossfeedDelayR = {};
    float fidelityLowL = 0.0f;
    float fidelityLowR = 0.0f;
    float harshEnvelope = 0.0f;
    float nightEnvelope = 0.0f;
    float nightLowL = 0.0f;
    float nightLowR = 0.0f;
    float nightMidLowL = 0.0f;
    float nightMidLowR = 0.0f;
    float nightMidEnvelope = 0.0f;
    float nightHighEnvelope = 0.0f;
    float limiterGain = 1.0f;
    size_t lookaheadIndex = 0;
    size_t lookaheadFill = 0;
    std::array<float, lookaheadBufferSize> lookaheadL = {};
    std::array<float, lookaheadBufferSize> lookaheadR = {};
    float truePeakPreviousL = 0.0f;
    float truePeakPreviousR = 0.0f;
    float bypassRawPower = 0.0f;
    float bypassProcessedPower = 0.0f;
    float bypassMatchGain = 1.0f;
    size_t spatialDelayIndex = 0;
    std::array<float, spatialDelayBufferSize> spatialDelayL = {};
    std::array<float, spatialDelayBufferSize> spatialDelayR = {};
    size_t ambienceIndex = 0;
    std::array<float, ambienceBufferSize> ambienceL = {};
    std::array<float, ambienceBufferSize> ambienceR = {};
    size_t hrtfIndex = 0;
    std::array<float, hrtfTapCount> hrtfHistoryL = {};
    std::array<float, hrtfTapCount> hrtfHistoryR = {};

    explicit SonicBloomDSPHandle(float initialSampleRate) : sampleRate(initialSampleRate) {
        lastEQ.fill(999.0f);
    }

    void reset(float newSampleRate) {
        sampleRate = newSampleRate > 0.0f ? newSampleRate : 48000.0f;
        previousInputL = 0.0f;
        previousInputR = 0.0f;
        previousOutputL = 0.0f;
        previousOutputR = 0.0f;
        bassL = 0.0f;
        bassR = 0.0f;
        bassPowerL = 0.0f;
        bassPowerR = 0.0f;
        contentLow = 0.0f;
        contentMidLow = 0.0f;
        crossfeedL = 0.0f;
        crossfeedR = 0.0f;
        crossfeedDelayIndex = 0;
        crossfeedDelayL.fill(0.0f);
        crossfeedDelayR.fill(0.0f);
        fidelityLowL = 0.0f;
        fidelityLowR = 0.0f;
        harshEnvelope = 0.0f;
        nightEnvelope = 0.0f;
        nightLowL = 0.0f;
        nightLowR = 0.0f;
        nightMidLowL = 0.0f;
        nightMidLowR = 0.0f;
        nightMidEnvelope = 0.0f;
        nightHighEnvelope = 0.0f;
        limiterGain = 1.0f;
        lookaheadIndex = 0;
        lookaheadFill = 0;
        lookaheadL.fill(0.0f);
        lookaheadR.fill(0.0f);
        truePeakPreviousL = 0.0f;
        truePeakPreviousR = 0.0f;
        bypassRawPower = 0.0f;
        bypassProcessedPower = 0.0f;
        bypassMatchGain = 1.0f;
        spatialDelayIndex = 0;
        spatialDelayL.fill(0.0f);
        spatialDelayR.fill(0.0f);
        ambienceIndex = 0;
        ambienceL.fill(0.0f);
        ambienceR.fill(0.0f);
        hrtfIndex = 0;
        hrtfHistoryL.fill(0.0f);
        hrtfHistoryR.fill(0.0f);
        for (auto &filter : eq) {
            filter.reset();
        }
        for (auto &filter : analyzer) {
            filter.reset();
        }
        activeEQ.fill(0);
        activeEQCount = 0;
        lastEQ.fill(999.0f);
    }

    void configureEQ(const SonicBloomDSPConfig &config) {
        const float resolvedSampleRate = config.sampleRate > 0.0f ? config.sampleRate : sampleRate;
        bool changed = std::fabs(resolvedSampleRate - sampleRate) > 0.001f;
        for (size_t index = 0; index < SonicBloomDSPBandCount; ++index) {
            if (std::fabs(lastEQ[index] - config.eqBandsDB[index]) > 0.001f) {
                changed = true;
                break;
            }
        }

        if (!changed) {
            return;
        }

        sampleRate = resolvedSampleRate;
        activeEQCount = 0;
        for (size_t index = 0; index < SonicBloomDSPBandCount; ++index) {
            lastEQ[index] = config.eqBandsDB[index];
            eq[index].setPeaking(bandCenters[index], sampleRate, config.eqBandsDB[index]);
            analyzer[index].setBandpass(bandCenters[index], sampleRate, qForThirdOctave);
            if (std::fabs(config.eqBandsDB[index]) >= 0.001f) {
                activeEQ[activeEQCount] = index;
                activeEQCount += 1;
            }
        }
    }
};

struct SonicBloomRingBuffer {
    explicit SonicBloomRingBuffer(size_t requestedCapacity)
        : capacity(std::max<size_t>(requestedCapacity, 1)),
          left(capacity),
          right(capacity) {
        for (size_t index = 0; index < capacity; ++index) {
            left[index].store(0.0f, std::memory_order_relaxed);
            right[index].store(0.0f, std::memory_order_relaxed);
        }
    }

    const size_t capacity;
    std::vector<std::atomic<float>> left;
    std::vector<std::atomic<float>> right;
    std::atomic<size_t> readCursor { 0 };
    std::atomic<size_t> writeCursor { 0 };
};

struct SonicBloomDSPConfigBuffer {
    std::atomic<float> sampleRate { 48000.0f };
    std::atomic<float> inputGainDB { 0.0f };
    std::atomic<float> outputGainDB { 0.0f };
    std::atomic<float> bassAmount { 0.0f };
    std::atomic<float> widthAmount { 0.0f };
    std::atomic<float> spatialAmount { 0.0f };
    std::atomic<float> crossfeedAmount { 0.0f };
    std::atomic<float> loudnessAmount { 0.0f };
    std::atomic<float> ambienceAmount { 0.0f };
    std::atomic<float> fidelityAmount { 0.0f };
    std::atomic<float> nightModeAmount { 0.0f };
    std::atomic<float> hrtfAmount { 0.0f };
    std::atomic<float> limiterCeilingDB { -1.0f };
    std::atomic<float> limiterLookaheadMS { 0.2f };
    std::atomic<float> limiterReleaseMS { 120.0f };
    std::atomic<int> bypass { 0 };
    std::atomic<int> loudnessMatchedBypass { 0 };
    std::array<std::atomic<float>, SonicBloomDSPBandCount> eqBandsDB;
    std::atomic<bool> hasConfig { false };

    SonicBloomDSPConfigBuffer() {
        for (auto &band : eqBandsDB) {
            band.store(0.0f, std::memory_order_relaxed);
        }
    }
};

bool ringPop(SonicBloomRingBuffer *ring, float &left, float &right) {
    if (!ring) {
        left = 0.0f;
        right = 0.0f;
        return false;
    }

    while (true) {
        size_t read = ring->readCursor.load(std::memory_order_relaxed);
        const size_t write = ring->writeCursor.load(std::memory_order_acquire);
        if (read >= write) {
            left = 0.0f;
            right = 0.0f;
            return false;
        }

        const size_t slot = read % ring->capacity;
        const float nextLeft = ring->left[slot].load(std::memory_order_relaxed);
        const float nextRight = ring->right[slot].load(std::memory_order_relaxed);
        if (ring->readCursor.compare_exchange_weak(
            read,
            read + 1,
            std::memory_order_acq_rel,
            std::memory_order_relaxed
        )) {
            left = nextLeft;
            right = nextRight;
            return true;
        }
    }
}

SonicBloomDSPHandle *SonicBloomDSPCreate(float sampleRate) {
    return new SonicBloomDSPHandle(sampleRate > 0.0f ? sampleRate : 48000.0f);
}

void SonicBloomDSPDestroy(SonicBloomDSPHandle *handle) {
    delete handle;
}

void SonicBloomDSPReset(SonicBloomDSPHandle *handle, float sampleRate) {
    if (handle) {
        handle->reset(sampleRate);
    }
}

SonicBloomDSPMeter SonicBloomDSPProcess(
    SonicBloomDSPHandle *handle,
    const SonicBloomDSPConfig *config,
    const float *inputLeft,
    const float *inputRight,
    float *outputLeft,
    float *outputRight,
    size_t frameCount
) {
    SonicBloomDSPMeter meter = {};
    if (!handle || !config || !inputLeft || !inputRight || !outputLeft || !outputRight) {
        return meter;
    }

    handle->configureEQ(*config);

    const float inputGain = dbToGain(config->inputGainDB);
    const float outputGain = dbToGain(config->outputGainDB);
    const float bassAmount = clamp(config->bassAmount, 0.0f, 1.0f);
    const float widthAmount = clamp(config->widthAmount, 0.0f, 1.0f);
    const float spatialAmount = clamp(config->spatialAmount, 0.0f, 1.0f);
    const float crossfeedAmount = clamp(config->crossfeedAmount, 0.0f, 1.0f);
    const float loudnessAmount = clamp(config->loudnessAmount, 0.0f, 1.0f);
    const float ambienceAmount = clamp(config->ambienceAmount, 0.0f, 1.0f);
    const float fidelityAmount = clamp(config->fidelityAmount, 0.0f, 1.0f);
    const float nightModeAmount = clamp(config->nightModeAmount, 0.0f, 1.0f);
    const float hrtfAmount = clamp(config->hrtfAmount, 0.0f, 1.0f);
    const float limiterCeiling = clamp(dbToGain(config->limiterCeilingDB), 0.05f, 1.0f);
    const bool matchedBypass = config->bypass && config->loudnessMatchedBypass;
    const float dcR = 0.995f;
    const float bassAlpha = onePoleAlpha(120.0f, handle->sampleRate);
    const float bassPowerAlpha = onePoleAlpha(18.0f, handle->sampleRate);
    const float contentLowAlpha = onePoleAlpha(180.0f, handle->sampleRate);
    const float contentMidAlpha = onePoleAlpha(2400.0f, handle->sampleRate);
    const float crossfeedAlpha = onePoleAlpha(700.0f, handle->sampleRate);
    const size_t crossfeedDelay = crossfeedDelayFrames(handle->sampleRate);
    const float fidelityAlpha = onePoleAlpha(2600.0f, handle->sampleRate);
    const float harshAttack = onePoleAlpha(130.0f, handle->sampleRate);
    const float harshRelease = onePoleAlpha(18.0f, handle->sampleRate);
    const float nightSplitAlpha = onePoleAlpha(220.0f, handle->sampleRate);
    const float nightPresenceSplitAlpha = onePoleAlpha(2600.0f, handle->sampleRate);
    const float nightAttack = onePoleAlpha(90.0f, handle->sampleRate);
    const float nightRelease = onePoleAlpha(8.0f, handle->sampleRate);
    const float limiterLookaheadMS = clamp(config->limiterLookaheadMS, 0.2f, 10.0f);
    const float limiterReleaseMS = clamp(config->limiterReleaseMS, 20.0f, 300.0f);
    const float limiterRelease = 1.0f - std::exp(-1.0f / ((limiterReleaseMS * 0.001f) * std::max(handle->sampleRate, 1.0f)));
    const size_t delayFrames = spatialDelayFrames(handle->sampleRate);
    const size_t ambienceDelayA = boundedDelayFrames(0.015f, handle->sampleRate);
    const size_t ambienceDelayB = boundedDelayFrames(0.027f, handle->sampleRate);
    const size_t ambienceDelayC = boundedDelayFrames(0.041f, handle->sampleRate);
    const size_t lookaheadFrames = static_cast<size_t>(clamp(
        std::round(handle->sampleRate * limiterLookaheadMS * 0.001f),
        8.0f,
        static_cast<float>(lookaheadBufferSize - 1)
    ));
    float lowEnergySum = 0.0f;
    float midEnergySum = 0.0f;
    float highEnergySum = 0.0f;
    std::array<float, SonicBloomDSPBandCount> spectrumSums = {};
    auto updateSpectrum = [&](float leftSample, float rightSample) {
        const float mono = (leftSample + rightSample) * 0.5f;
        for (size_t band = 0; band < SonicBloomDSPBandCount; ++band) {
            const float bandSample = handle->analyzer[band].processLeft(mono);
            spectrumSums[band] += bandSample * bandSample;
        }
    };

    for (size_t index = 0; index < frameCount; ++index) {
        float left = inputLeft[index];
        float right = inputRight[index];
        meter.inputPeak = std::max(meter.inputPeak, std::max(std::fabs(left), std::fabs(right)));
        float rawLeft = std::isfinite(left) ? left : 0.0f;
        float rawRight = std::isfinite(right) ? right : 0.0f;
        const float rawMono = (rawLeft + rawRight) * 0.5f;
        handle->contentLow += contentLowAlpha * (rawMono - handle->contentLow);
        handle->contentMidLow += contentMidAlpha * (rawMono - handle->contentMidLow);
        const float lowBand = handle->contentLow;
        const float midBand = handle->contentMidLow - handle->contentLow;
        const float highBand = rawMono - handle->contentMidLow;
        lowEnergySum += lowBand * lowBand;
        midEnergySum += midBand * midBand;
        highEnergySum += highBand * highBand;

        if (config->bypass && !matchedBypass) {
            if (!std::isfinite(left)) {
                left = 0.0f;
            }
            if (!std::isfinite(right)) {
                right = 0.0f;
            }
            meter.outputPeak = std::max(meter.outputPeak, std::max(std::fabs(left), std::fabs(right)));
            outputLeft[index] = left;
            outputRight[index] = right;
            updateSpectrum(left, right);
            continue;
        }

        left *= inputGain;
        right *= inputGain;

        const float dcLeft = left - handle->previousInputL + dcR * handle->previousOutputL;
        const float dcRight = right - handle->previousInputR + dcR * handle->previousOutputR;
        handle->previousInputL = left;
        handle->previousInputR = right;
        handle->previousOutputL = dcLeft;
        handle->previousOutputR = dcRight;
        left = dcLeft;
        right = dcRight;

        for (size_t activeIndex = 0; activeIndex < handle->activeEQCount; ++activeIndex) {
            auto &filter = handle->eq[handle->activeEQ[activeIndex]];
            left = filter.processLeft(left);
            right = filter.processRight(right);
        }

        handle->bassL += bassAlpha * (left - handle->bassL);
        handle->bassR += bassAlpha * (right - handle->bassR);
        const float bassSquaredL = handle->bassL * handle->bassL;
        const float bassSquaredR = handle->bassR * handle->bassR;
        handle->bassPowerL += bassPowerAlpha * (bassSquaredL - handle->bassPowerL);
        handle->bassPowerR += bassPowerAlpha * (bassSquaredR - handle->bassPowerR);
        left += handle->bassL * bassAmount * 0.32f + (bassSquaredL - handle->bassPowerL) * bassAmount * 0.62f;
        right += handle->bassR * bassAmount * 0.32f + (bassSquaredR - handle->bassPowerR) * bassAmount * 0.62f;

        handle->crossfeedL += crossfeedAlpha * (left - handle->crossfeedL);
        handle->crossfeedR += crossfeedAlpha * (right - handle->crossfeedR);
        const size_t crossfeedReadIndex = (handle->crossfeedDelayIndex + crossfeedDelayBufferSize - crossfeedDelay) % crossfeedDelayBufferSize;
        const float delayedCrossfeedL = handle->crossfeedDelayL[crossfeedReadIndex];
        const float delayedCrossfeedR = handle->crossfeedDelayR[crossfeedReadIndex];
        handle->crossfeedDelayL[handle->crossfeedDelayIndex] = handle->crossfeedL;
        handle->crossfeedDelayR[handle->crossfeedDelayIndex] = handle->crossfeedR;
        handle->crossfeedDelayIndex = (handle->crossfeedDelayIndex + 1) % crossfeedDelayBufferSize;
        const float feed = crossfeedAmount * 0.22f;
        const float crossfedLeft = left * (1.0f - feed) + delayedCrossfeedR * feed;
        const float crossfedRight = right * (1.0f - feed) + delayedCrossfeedL * feed;
        left = crossfedLeft;
        right = crossfedRight;

        const size_t readIndex = (handle->spatialDelayIndex + spatialDelayBufferSize - delayFrames) % spatialDelayBufferSize;
        const float delayedSide = (handle->spatialDelayL[readIndex] - handle->spatialDelayR[readIndex]) * 0.5f;
        handle->spatialDelayL[handle->spatialDelayIndex] = left;
        handle->spatialDelayR[handle->spatialDelayIndex] = right;
        handle->spatialDelayIndex = (handle->spatialDelayIndex + 1) % spatialDelayBufferSize;

        const float mid = (left + right) * 0.5f;
        const float side = (left - right) * 0.5f;
        const float widenedSide = side * (1.0f + widthAmount * 0.75f + spatialAmount * 0.85f);
        const float spatialSide = delayedSide * spatialAmount * 0.28f;
        left = mid + widenedSide + spatialSide;
        right = mid - widenedSide - spatialSide;

        const float totalHRTF = clamp(hrtfAmount + spatialAmount * 0.35f, 0.0f, 1.0f);
        if (totalHRTF > 0.0f) {
            handle->hrtfHistoryL[handle->hrtfIndex] = left;
            handle->hrtfHistoryR[handle->hrtfIndex] = right;
            float convolvedL = 0.0f;
            float convolvedR = 0.0f;
            for (size_t tap = 0; tap < hrtfTapCount; ++tap) {
                const size_t historyIndex = (handle->hrtfIndex + hrtfTapCount - tap) % hrtfTapCount;
                const float historyL = handle->hrtfHistoryL[historyIndex];
                const float historyR = handle->hrtfHistoryR[historyIndex];
                convolvedL += hrtfNearEar[tap] * historyL + hrtfFarEar[tap] * historyR;
                convolvedR += hrtfNearEar[tap] * historyR + hrtfFarEar[tap] * historyL;
            }
            handle->hrtfIndex = (handle->hrtfIndex + 1) % hrtfTapCount;
            left = lerp(left, convolvedL, totalHRTF);
            right = lerp(right, convolvedR, totalHRTF);
        }

        if (fidelityAmount > 0.0f) {
            handle->fidelityLowL += fidelityAlpha * (left - handle->fidelityLowL);
            handle->fidelityLowR += fidelityAlpha * (right - handle->fidelityLowR);
            const float highL = left - handle->fidelityLowL;
            const float highR = right - handle->fidelityLowR;
            const float harshPeak = std::max(std::fabs(highL), std::fabs(highR));
            const float harshAlpha = harshPeak > handle->harshEnvelope ? harshAttack : harshRelease;
            handle->harshEnvelope += harshAlpha * (harshPeak - handle->harshEnvelope);
            const float harshness = clamp((handle->harshEnvelope - 0.12f) / 0.26f, 0.0f, 1.0f);
            const float tameGain = 1.0f - harshness * fidelityAmount * 0.72f;
            const float sparkleGain = (1.0f - harshness) * fidelityAmount * 0.34f;
            left = handle->fidelityLowL + highL * tameGain + std::tanh(highL * 8.0f) * sparkleGain;
            right = handle->fidelityLowR + highR * tameGain + std::tanh(highR * 8.0f) * sparkleGain;
        }

        if (ambienceAmount > 0.0f) {
            const size_t readA = (handle->ambienceIndex + ambienceBufferSize - ambienceDelayA) % ambienceBufferSize;
            const size_t readB = (handle->ambienceIndex + ambienceBufferSize - ambienceDelayB) % ambienceBufferSize;
            const size_t readC = (handle->ambienceIndex + ambienceBufferSize - ambienceDelayC) % ambienceBufferSize;
            const float wetL = handle->ambienceR[readA] * 0.42f + handle->ambienceL[readB] * 0.32f + handle->ambienceR[readC] * 0.24f;
            const float wetR = handle->ambienceL[readA] * 0.42f + handle->ambienceR[readB] * 0.32f + handle->ambienceL[readC] * 0.24f;
            const float feedback = ambienceAmount * 0.18f;
            handle->ambienceL[handle->ambienceIndex] = left + wetL * feedback;
            handle->ambienceR[handle->ambienceIndex] = right + wetR * feedback;
            handle->ambienceIndex = (handle->ambienceIndex + 1) % ambienceBufferSize;
            left += wetL * ambienceAmount * 0.24f;
            right += wetR * ambienceAmount * 0.24f;
        } else {
            handle->ambienceL[handle->ambienceIndex] = left;
            handle->ambienceR[handle->ambienceIndex] = right;
            handle->ambienceIndex = (handle->ambienceIndex + 1) % ambienceBufferSize;
        }

        left += std::tanh(left * 2.0f) * loudnessAmount * 0.08f;
        right += std::tanh(right * 2.0f) * loudnessAmount * 0.08f;

        if (nightModeAmount > 0.0f) {
            handle->nightLowL += nightSplitAlpha * (left - handle->nightLowL);
            handle->nightLowR += nightSplitAlpha * (right - handle->nightLowR);
            handle->nightMidLowL += nightPresenceSplitAlpha * (left - handle->nightMidLowL);
            handle->nightMidLowR += nightPresenceSplitAlpha * (right - handle->nightMidLowR);
            const float lowL = handle->nightLowL;
            const float lowR = handle->nightLowR;
            const float midL = handle->nightMidLowL - lowL;
            const float midR = handle->nightMidLowR - lowR;
            const float highL = left - handle->nightMidLowL;
            const float highR = right - handle->nightMidLowR;
            const float lowPeak = std::max(std::fabs(lowL), std::fabs(lowR));
            const float midPeak = std::max(std::fabs(midL), std::fabs(midR));
            const float highPeak = std::max(std::fabs(highL), std::fabs(highR));
            const float lowAlpha = lowPeak > handle->nightEnvelope ? nightAttack : nightRelease;
            const float midAlpha = midPeak > handle->nightMidEnvelope ? nightAttack : nightRelease;
            const float highAlpha = highPeak > handle->nightHighEnvelope ? nightAttack : nightRelease;
            handle->nightEnvelope += lowAlpha * (lowPeak - handle->nightEnvelope);
            handle->nightMidEnvelope += midAlpha * (midPeak - handle->nightMidEnvelope);
            handle->nightHighEnvelope += highAlpha * (highPeak - handle->nightHighEnvelope);

            const float lowGain = lerp(1.0f, dynamicsGain(handle->nightEnvelope, 0.16f, 5.5f, 0.48f), nightModeAmount);
            const float midGain = lerp(1.0f, dynamicsGain(handle->nightMidEnvelope, 0.22f, 2.2f, 0.30f), nightModeAmount);
            const float highGain = lerp(1.0f, dynamicsGain(handle->nightHighEnvelope, 0.20f, 7.0f, 0.02f), nightModeAmount);
            left = lowL * lowGain + midL * midGain + highL * highGain;
            right = lowR * lowGain + midR * midGain + highR * highGain;
        }

        left *= outputGain;
        right *= outputGain;

        handle->lookaheadL[handle->lookaheadIndex] = left;
        handle->lookaheadR[handle->lookaheadIndex] = right;

        float futurePeak = 0.0f;
        const size_t futureCount = std::min(handle->lookaheadFill + 1, lookaheadFrames);
        for (size_t offset = 0; offset < futureCount; ++offset) {
            const size_t sampleIndex = (handle->lookaheadIndex + lookaheadBufferSize - offset) % lookaheadBufferSize;
            const size_t previousIndex = (sampleIndex + lookaheadBufferSize - 1) % lookaheadBufferSize;
            const float sampleL = handle->lookaheadL[sampleIndex];
            const float sampleR = handle->lookaheadR[sampleIndex];
            const float midpointL = (sampleL + handle->lookaheadL[previousIndex]) * 0.5f;
            const float midpointR = (sampleR + handle->lookaheadR[previousIndex]) * 0.5f;
            futurePeak = std::max(futurePeak, std::max(std::fabs(sampleL), std::fabs(sampleR)));
            futurePeak = std::max(futurePeak, std::max(std::fabs(midpointL), std::fabs(midpointR)));
        }

        const bool lookaheadReady = handle->lookaheadFill >= lookaheadFrames;
        const size_t limiterReadIndex = (handle->lookaheadIndex + lookaheadBufferSize - lookaheadFrames) % lookaheadBufferSize;
        float limitedLeft = lookaheadReady ? handle->lookaheadL[limiterReadIndex] : 0.0f;
        float limitedRight = lookaheadReady ? handle->lookaheadR[limiterReadIndex] : 0.0f;
        handle->lookaheadIndex = (handle->lookaheadIndex + 1) % lookaheadBufferSize;
        handle->lookaheadFill = std::min(handle->lookaheadFill + 1, lookaheadFrames);

        const float targetLimiterGain = futurePeak > limiterCeiling ? limiterCeiling / futurePeak : 1.0f;
        if (targetLimiterGain < handle->limiterGain) {
            handle->limiterGain = targetLimiterGain;
        } else {
            handle->limiterGain += (targetLimiterGain - handle->limiterGain) * limiterRelease;
        }

        limitedLeft *= handle->limiterGain;
        limitedRight *= handle->limiterGain;

        const float truePeakL = std::max(std::fabs(limitedLeft), std::fabs((limitedLeft + handle->truePeakPreviousL) * 0.5f));
        const float truePeakR = std::max(std::fabs(limitedRight), std::fabs((limitedRight + handle->truePeakPreviousR) * 0.5f));
        const float truePeak = std::max(truePeakL, truePeakR);
        if (truePeak > limiterCeiling) {
            const float safetyGain = limiterCeiling / truePeak;
            limitedLeft *= safetyGain;
            limitedRight *= safetyGain;
            handle->limiterGain = std::min(handle->limiterGain, safetyGain);
        }
        handle->truePeakPreviousL = limitedLeft;
        handle->truePeakPreviousR = limitedRight;

        if (handle->limiterGain < 0.9999f) {
            meter.gainReductionDB = std::max(meter.gainReductionDB, -20.0f * std::log10(std::max(handle->limiterGain, 0.000001f)));
            meter.limitedSamples += 1;
        }

        left = limitedLeft;
        right = limitedRight;

        if (!std::isfinite(left)) {
            left = 0.0f;
        }
        if (!std::isfinite(right)) {
            right = 0.0f;
        }

        if (matchedBypass) {
            constexpr float powerFloor = 0.00000001f;
            const float rawPower = (rawLeft * rawLeft + rawRight * rawRight) * 0.5f;
            const float processedPower = (left * left + right * right) * 0.5f;
            const float matchAlpha = onePoleAlpha(14.0f, handle->sampleRate);
            handle->bypassRawPower += matchAlpha * (rawPower - handle->bypassRawPower);
            handle->bypassProcessedPower += matchAlpha * (processedPower - handle->bypassProcessedPower);
            const float targetGain = clamp(
                std::sqrt(std::max(handle->bypassProcessedPower, powerFloor) / std::max(handle->bypassRawPower, powerFloor)),
                0.25f,
                4.0f
            );
            handle->bypassMatchGain += matchAlpha * (targetGain - handle->bypassMatchGain);
            left = rawLeft * handle->bypassMatchGain;
            right = rawRight * handle->bypassMatchGain;
        }

        left = clamp(left, -limiterCeiling, limiterCeiling);
        right = clamp(right, -limiterCeiling, limiterCeiling);
        meter.outputPeak = std::max(meter.outputPeak, std::max(std::fabs(left), std::fabs(right)));
        outputLeft[index] = left;
        outputRight[index] = right;
        updateSpectrum(left, right);
    }

    if (frameCount > 0) {
        const float count = static_cast<float>(frameCount);
        meter.lowEnergy = std::sqrt(lowEnergySum / count);
        meter.midEnergy = std::sqrt(midEnergySum / count);
        meter.highEnergy = std::sqrt(highEnergySum / count);
        for (size_t band = 0; band < SonicBloomDSPBandCount; ++band) {
            meter.spectrumBands[band] = std::sqrt(spectrumSums[band] / count);
        }
    }

    return meter;
}

SonicBloomDSPConfigBuffer *SonicBloomDSPConfigBufferCreate(void) {
    return new SonicBloomDSPConfigBuffer();
}

void SonicBloomDSPConfigBufferDestroy(SonicBloomDSPConfigBuffer *buffer) {
    delete buffer;
}

void SonicBloomDSPConfigBufferWrite(SonicBloomDSPConfigBuffer *buffer, const SonicBloomDSPConfig *config) {
    if (!buffer || !config) {
        return;
    }

    buffer->sampleRate.store(config->sampleRate, std::memory_order_relaxed);
    buffer->inputGainDB.store(config->inputGainDB, std::memory_order_relaxed);
    buffer->outputGainDB.store(config->outputGainDB, std::memory_order_relaxed);
    buffer->bassAmount.store(config->bassAmount, std::memory_order_relaxed);
    buffer->widthAmount.store(config->widthAmount, std::memory_order_relaxed);
    buffer->spatialAmount.store(config->spatialAmount, std::memory_order_relaxed);
    buffer->crossfeedAmount.store(config->crossfeedAmount, std::memory_order_relaxed);
    buffer->loudnessAmount.store(config->loudnessAmount, std::memory_order_relaxed);
    buffer->ambienceAmount.store(config->ambienceAmount, std::memory_order_relaxed);
    buffer->fidelityAmount.store(config->fidelityAmount, std::memory_order_relaxed);
    buffer->nightModeAmount.store(config->nightModeAmount, std::memory_order_relaxed);
    buffer->hrtfAmount.store(config->hrtfAmount, std::memory_order_relaxed);
    buffer->limiterCeilingDB.store(config->limiterCeilingDB, std::memory_order_relaxed);
    buffer->limiterLookaheadMS.store(config->limiterLookaheadMS, std::memory_order_relaxed);
    buffer->limiterReleaseMS.store(config->limiterReleaseMS, std::memory_order_relaxed);
    buffer->bypass.store(config->bypass, std::memory_order_relaxed);
    buffer->loudnessMatchedBypass.store(config->loudnessMatchedBypass, std::memory_order_relaxed);
    for (size_t index = 0; index < SonicBloomDSPBandCount; ++index) {
        buffer->eqBandsDB[index].store(config->eqBandsDB[index], std::memory_order_relaxed);
    }
    buffer->hasConfig.store(true, std::memory_order_release);
}

int SonicBloomDSPConfigBufferRead(const SonicBloomDSPConfigBuffer *buffer, SonicBloomDSPConfig *config) {
    if (!buffer || !config || !buffer->hasConfig.load(std::memory_order_acquire)) {
        return 0;
    }

    config->sampleRate = buffer->sampleRate.load(std::memory_order_relaxed);
    config->inputGainDB = buffer->inputGainDB.load(std::memory_order_relaxed);
    config->outputGainDB = buffer->outputGainDB.load(std::memory_order_relaxed);
    config->bassAmount = buffer->bassAmount.load(std::memory_order_relaxed);
    config->widthAmount = buffer->widthAmount.load(std::memory_order_relaxed);
    config->spatialAmount = buffer->spatialAmount.load(std::memory_order_relaxed);
    config->crossfeedAmount = buffer->crossfeedAmount.load(std::memory_order_relaxed);
    config->loudnessAmount = buffer->loudnessAmount.load(std::memory_order_relaxed);
    config->ambienceAmount = buffer->ambienceAmount.load(std::memory_order_relaxed);
    config->fidelityAmount = buffer->fidelityAmount.load(std::memory_order_relaxed);
    config->nightModeAmount = buffer->nightModeAmount.load(std::memory_order_relaxed);
    config->hrtfAmount = buffer->hrtfAmount.load(std::memory_order_relaxed);
    config->limiterCeilingDB = buffer->limiterCeilingDB.load(std::memory_order_relaxed);
    config->limiterLookaheadMS = buffer->limiterLookaheadMS.load(std::memory_order_relaxed);
    config->limiterReleaseMS = buffer->limiterReleaseMS.load(std::memory_order_relaxed);
    config->bypass = buffer->bypass.load(std::memory_order_relaxed);
    config->loudnessMatchedBypass = buffer->loudnessMatchedBypass.load(std::memory_order_relaxed);
    for (size_t index = 0; index < SonicBloomDSPBandCount; ++index) {
        config->eqBandsDB[index] = buffer->eqBandsDB[index].load(std::memory_order_relaxed);
    }
    return 1;
}

SonicBloomRingBuffer *SonicBloomRingBufferCreate(size_t capacityFrames) {
    return new SonicBloomRingBuffer(capacityFrames);
}

void SonicBloomRingBufferDestroy(SonicBloomRingBuffer *ring) {
    delete ring;
}

void SonicBloomRingBufferClear(SonicBloomRingBuffer *ring) {
    if (!ring) {
        return;
    }
    ring->readCursor.store(0, std::memory_order_release);
    ring->writeCursor.store(0, std::memory_order_release);
}

size_t SonicBloomRingBufferWrite(
    SonicBloomRingBuffer *ring,
    const float *left,
    const float *right,
    size_t frameCount
) {
    if (!ring || !left || frameCount == 0) {
        return 0;
    }

    for (size_t index = 0; index < frameCount; ++index) {
        const size_t write = ring->writeCursor.load(std::memory_order_relaxed);
        const size_t minimumRead = write >= ring->capacity ? write - ring->capacity + 1 : 0;
        size_t observedRead = ring->readCursor.load(std::memory_order_acquire);
        while (observedRead < minimumRead &&
               !ring->readCursor.compare_exchange_weak(
                   observedRead,
                   minimumRead,
                   std::memory_order_acq_rel,
                   std::memory_order_relaxed
               )) {}

        const size_t slot = write % ring->capacity;
        ring->left[slot].store(left[index], std::memory_order_relaxed);
        ring->right[slot].store(right ? right[index] : left[index], std::memory_order_relaxed);
        ring->writeCursor.store(write + 1, std::memory_order_release);
    }

    return frameCount;
}

size_t SonicBloomRingBufferRead(
    SonicBloomRingBuffer *ring,
    float *left,
    float *right,
    size_t frameCount
) {
    if (!ring || !left || !right || frameCount == 0) {
        return 0;
    }

    size_t framesRead = 0;
    for (size_t index = 0; index < frameCount; ++index) {
        float nextLeft = 0.0f;
        float nextRight = 0.0f;
        if (ringPop(ring, nextLeft, nextRight)) {
            framesRead += 1;
        }
        left[index] = nextLeft;
        right[index] = nextRight;
    }
    return framesRead;
}

size_t SonicBloomRingBufferReadInterleaved(
    SonicBloomRingBuffer *ring,
    float *output,
    size_t frameCount,
    size_t channels
) {
    if (!ring || !output || frameCount == 0 || channels == 0) {
        return 0;
    }

    size_t framesRead = 0;
    for (size_t frame = 0; frame < frameCount; ++frame) {
        float left = 0.0f;
        float right = 0.0f;
        if (ringPop(ring, left, right)) {
            framesRead += 1;
        }

        const size_t base = frame * channels;
        output[base] = left;
        if (channels > 1) {
            output[base + 1] = right;
        }
        for (size_t channel = 2; channel < channels; ++channel) {
            output[base + channel] = 0.0f;
        }
    }

    return framesRead;
}

size_t SonicBloomRingBufferTrim(SonicBloomRingBuffer *ring, size_t maxFrames) {
    if (!ring) {
        return 0;
    }

    while (true) {
        size_t read = ring->readCursor.load(std::memory_order_acquire);
        const size_t write = ring->writeCursor.load(std::memory_order_acquire);
        const size_t available = write > read ? write - read : 0;
        if (available <= maxFrames) {
            return 0;
        }

        const size_t targetRead = write - maxFrames;
        if (ring->readCursor.compare_exchange_weak(
            read,
            targetRead,
            std::memory_order_acq_rel,
            std::memory_order_relaxed
        )) {
            return available - maxFrames;
        }
    }
}

size_t SonicBloomRingBufferAvailable(const SonicBloomRingBuffer *ring) {
    if (!ring) {
        return 0;
    }

    const size_t read = ring->readCursor.load(std::memory_order_acquire);
    const size_t write = ring->writeCursor.load(std::memory_order_acquire);
    return std::min(write - read, ring->capacity);
}
