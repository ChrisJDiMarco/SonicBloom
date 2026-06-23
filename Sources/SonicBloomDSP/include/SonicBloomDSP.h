#ifndef SONIC_BLOOM_DSP_H
#define SONIC_BLOOM_DSP_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

enum {
    SonicBloomDSPBandCount = 31,
    SonicBloomDSPHRTFTapCount = 128
};

typedef struct SonicBloomDSPHandle SonicBloomDSPHandle;
typedef struct SonicBloomDSPConfigBuffer SonicBloomDSPConfigBuffer;
typedef struct SonicBloomRingBuffer SonicBloomRingBuffer;

typedef struct {
    float sampleRate;
    float inputGainDB;
    float outputGainDB;
    float bassAmount;
    float widthAmount;
    float spatialAmount;
    float crossfeedAmount;
    float loudnessAmount;
    float ambienceAmount;
    float fidelityAmount;
    float nightModeAmount;
    float masteringAmount;
    float hrtfAmount;
    float limiterCeilingDB;
    float limiterLookaheadMS;
    float limiterReleaseMS;
    int bypass;
    int loudnessMatchedBypass;
    float eqBandsDB[SonicBloomDSPBandCount];
    int hrtfKernelTapCount;
    float hrtfNearEar[SonicBloomDSPHRTFTapCount];
    float hrtfFarEar[SonicBloomDSPHRTFTapCount];
    float hrtfRoomNear[SonicBloomDSPHRTFTapCount];
    float hrtfRoomFar[SonicBloomDSPHRTFTapCount];
} SonicBloomDSPConfig;

typedef struct {
    float inputPeak;
    float outputPeak;
    float gainReductionDB;
    float lowEnergy;
    float midEnergy;
    float highEnergy;
    float spectrumBands[SonicBloomDSPBandCount];
    unsigned int limitedSamples;
} SonicBloomDSPMeter;

SonicBloomDSPHandle *SonicBloomDSPCreate(float sampleRate);
void SonicBloomDSPDestroy(SonicBloomDSPHandle *handle);
void SonicBloomDSPReset(SonicBloomDSPHandle *handle, float sampleRate);
SonicBloomDSPMeter SonicBloomDSPProcess(
    SonicBloomDSPHandle *handle,
    const SonicBloomDSPConfig *config,
    const float *inputLeft,
    const float *inputRight,
    float *outputLeft,
    float *outputRight,
    size_t frameCount
);

SonicBloomDSPConfigBuffer *SonicBloomDSPConfigBufferCreate(void);
void SonicBloomDSPConfigBufferDestroy(SonicBloomDSPConfigBuffer *buffer);
void SonicBloomDSPConfigBufferWrite(SonicBloomDSPConfigBuffer *buffer, const SonicBloomDSPConfig *config);
int SonicBloomDSPConfigBufferRead(const SonicBloomDSPConfigBuffer *buffer, SonicBloomDSPConfig *config);

SonicBloomRingBuffer *SonicBloomRingBufferCreate(size_t capacityFrames);
void SonicBloomRingBufferDestroy(SonicBloomRingBuffer *ring);
void SonicBloomRingBufferClear(SonicBloomRingBuffer *ring);
size_t SonicBloomRingBufferWrite(
    SonicBloomRingBuffer *ring,
    const float *left,
    const float *right,
    size_t frameCount
);
size_t SonicBloomRingBufferRead(
    SonicBloomRingBuffer *ring,
    float *left,
    float *right,
    size_t frameCount
);
size_t SonicBloomRingBufferReadInterleaved(
    SonicBloomRingBuffer *ring,
    float *output,
    size_t frameCount,
    size_t channels
);
size_t SonicBloomRingBufferTrim(SonicBloomRingBuffer *ring, size_t maxFrames);
size_t SonicBloomRingBufferAvailable(const SonicBloomRingBuffer *ring);
unsigned long long SonicBloomRingBufferUnderflowFrames(const SonicBloomRingBuffer *ring);
unsigned long long SonicBloomRingBufferDroppedFrames(const SonicBloomRingBuffer *ring);
void SonicBloomRingBufferResetStats(SonicBloomRingBuffer *ring);

#ifdef __cplusplus
}
#endif

#endif
