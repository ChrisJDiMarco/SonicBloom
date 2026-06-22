#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/CoreAudio.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>

#define kSonicBloomDeviceObjectID 2
#define kSonicBloomOutputStreamObjectID 3
#define kSonicBloomInputStreamObjectID 4
#define kSonicBloomChannels 2
#define kSonicBloomDefaultBufferFrames 64
#define kSonicBloomMinBufferFrames 64
#define kSonicBloomMaxBufferFrames 512
#define kSonicBloomReportedLatencyFrames 192
#define kSonicBloomReportedSafetyOffsetFrames 32
#define kSonicBloomRingFrames 32768
#define kSonicBloomZeroTimestampPeriod 512
#define kSonicBloomPropertySISO 'siso'
#define kSonicBloomPropertyTaps 'taps'
#define kSonicBloomPropertyAccesses 'accs'

static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 1;
static UInt32 gIOClientCount = 0;
static Float64 gSampleRate = 48000.0;
static UInt32 gBufferFrameSize = kSonicBloomDefaultBufferFrames;
static UInt64 gClockSeed = 1;
static Float64 gSampleTime = 0.0;
static UInt64 gAnchorHostTime = 0;
static mach_timebase_info_data_t gTimebaseInfo = {0, 0};
static pthread_mutex_t gRingLock = PTHREAD_MUTEX_INITIALIZER;
static float gLoopbackRing[kSonicBloomChannels][kSonicBloomRingFrames];
static UInt32 gRingReadIndex = 0;
static UInt32 gRingWriteIndex = 0;
static UInt32 gRingFrameCount = 0;
#if SONICBLOOM_HAL_TRACE
static UInt32 gTraceWriteMixCount = 0;
static UInt32 gTraceReadInputCount = 0;
#endif

static void SonicBloomLog(const char* message) {
#if SONICBLOOM_HAL_TRACE
    FILE* file = fopen("/tmp/SonicBloomHAL.log", "a");
    if (!file) return;
    fprintf(file, "%s\n", message);
    fclose(file);
#else
    (void)message;
#endif
}

static void SonicBloomLogProperty(const char* phase, AudioObjectID objectID, AudioObjectPropertySelector selector) {
#if SONICBLOOM_HAL_TRACE
    char text[128];
    char fourcc[5] = {
        (char)((selector >> 24) & 0xFF),
        (char)((selector >> 16) & 0xFF),
        (char)((selector >> 8) & 0xFF),
        (char)(selector & 0xFF),
        0
    };
    snprintf(text, sizeof(text), "%s object=%u selector=%s", phase, objectID, fourcc);
    SonicBloomLog(text);
#else
    (void)phase;
    (void)objectID;
    (void)selector;
#endif
}

static void SonicBloomLogIO(const char* phase, UInt32 streamID, UInt32 operationID, UInt32 frames, UInt32 ringFrames) {
#if SONICBLOOM_HAL_TRACE
    char text[160];
    snprintf(text, sizeof(text), "%s stream=%u op=%u frames=%u ring=%u", phase, streamID, operationID, frames, ringFrames);
    SonicBloomLog(text);
#else
    (void)phase;
    (void)streamID;
    (void)operationID;
    (void)frames;
    (void)ringFrames;
#endif
}

static void NotifyGlobalProperty(AudioObjectID objectID, AudioObjectPropertySelector selector) {
    if (!gHost || !gHost->PropertiesChanged) return;
    AudioObjectPropertyAddress address = {
        selector,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    gHost->PropertiesChanged(gHost, objectID, 1, &address);
}

static void NotifySampleRateChanged(void) {
    NotifyGlobalProperty(kSonicBloomDeviceObjectID, kAudioDevicePropertyNominalSampleRate);
    NotifyGlobalProperty(kSonicBloomOutputStreamObjectID, kAudioStreamPropertyVirtualFormat);
    NotifyGlobalProperty(kSonicBloomOutputStreamObjectID, kAudioStreamPropertyPhysicalFormat);
    NotifyGlobalProperty(kSonicBloomInputStreamObjectID, kAudioStreamPropertyVirtualFormat);
    NotifyGlobalProperty(kSonicBloomInputStreamObjectID, kAudioStreamPropertyPhysicalFormat);
}

static AudioStreamBasicDescription SonicBloomFormat(void) {
    AudioStreamBasicDescription format;
    memset(&format, 0, sizeof(format));
    format.mSampleRate = gSampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian;
    format.mBytesPerPacket = sizeof(float) * kSonicBloomChannels;
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = sizeof(float) * kSonicBloomChannels;
    format.mChannelsPerFrame = kSonicBloomChannels;
    format.mBitsPerChannel = 32;
    return format;
}

static AudioStreamRangedDescription SonicBloomRangedFormat(void) {
    AudioStreamRangedDescription ranged;
    ranged.mFormat = SonicBloomFormat();
    ranged.mSampleRateRange.mMinimum = 44100.0;
    ranged.mSampleRateRange.mMaximum = 96000.0;
    return ranged;
}

static bool IsDevice(AudioObjectID objectID) { return objectID == kSonicBloomDeviceObjectID; }
static bool IsOutputStream(AudioObjectID objectID) { return objectID == kSonicBloomOutputStreamObjectID; }
static bool IsInputStream(AudioObjectID objectID) { return objectID == kSonicBloomInputStreamObjectID; }
static bool IsStream(AudioObjectID objectID) { return IsOutputStream(objectID) || IsInputStream(objectID); }

static void EnsureTimebaseInfo(void) {
    if (gTimebaseInfo.denom == 0) {
        mach_timebase_info(&gTimebaseInfo);
    }
}

static Float64 HostTicksToSeconds(UInt64 ticks) {
    EnsureTimebaseInfo();
    return ((Float64)ticks * (Float64)gTimebaseInfo.numer / (Float64)gTimebaseInfo.denom) / 1000000000.0;
}

static UInt64 SecondsToHostTicks(Float64 seconds) {
    EnsureTimebaseInfo();
    return (UInt64)((seconds * 1000000000.0 * (Float64)gTimebaseInfo.denom / (Float64)gTimebaseInfo.numer) + 0.5);
}

static OSStatus WriteData(UInt32 inDataSize, UInt32* outDataSize, void* outData, const void* source, UInt32 sourceSize) {
    if (inDataSize < sourceSize) {
        return kAudioHardwareBadPropertySizeError;
    }
    memcpy(outData, source, sourceSize);
    *outDataSize = sourceSize;
    return kAudioHardwareNoError;
}

static OSStatus WriteUInt32(UInt32 inDataSize, UInt32* outDataSize, void* outData, UInt32 value) {
    return WriteData(inDataSize, outDataSize, outData, &value, sizeof(value));
}

static OSStatus WriteFloat64(UInt32 inDataSize, UInt32* outDataSize, void* outData, Float64 value) {
    return WriteData(inDataSize, outDataSize, outData, &value, sizeof(value));
}

static OSStatus WriteString(UInt32 inDataSize, UInt32* outDataSize, void* outData, CFStringRef value) {
    CFStringRef retained = CFRetain(value);
    return WriteData(inDataSize, outDataSize, outData, &retained, sizeof(retained));
}

static OSStatus WriteAudioBufferList(UInt32 inDataSize, UInt32* outDataSize, void* outData, UInt32 channels) {
    const UInt32 size = sizeof(AudioBufferList);
    if (inDataSize < size) {
        return kAudioHardwareBadPropertySizeError;
    }
    AudioBufferList* list = (AudioBufferList*)outData;
    list->mNumberBuffers = 1;
    list->mBuffers[0].mNumberChannels = channels;
    list->mBuffers[0].mDataByteSize = 0;
    list->mBuffers[0].mData = NULL;
    *outDataSize = size;
    return kAudioHardwareNoError;
}

static Boolean SonicBloom_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus SonicBloom_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus SonicBloom_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus SonicBloom_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus SonicBloom_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);

static HRESULT SonicBloom_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG SonicBloom_AddRef(void* inDriver);
static ULONG SonicBloom_Release(void* inDriver);
static OSStatus SonicBloom_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus SonicBloom_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus SonicBloom_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus SonicBloom_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus SonicBloom_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus SonicBloom_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus SonicBloom_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus SonicBloom_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus SonicBloom_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus SonicBloom_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus SonicBloom_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus SonicBloom_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus SonicBloom_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus SonicBloom_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,
    SonicBloom_QueryInterface,
    SonicBloom_AddRef,
    SonicBloom_Release,
    SonicBloom_Initialize,
    SonicBloom_CreateDevice,
    SonicBloom_DestroyDevice,
    SonicBloom_AddDeviceClient,
    SonicBloom_RemoveDeviceClient,
    SonicBloom_PerformDeviceConfigurationChange,
    SonicBloom_AbortDeviceConfigurationChange,
    SonicBloom_HasProperty,
    SonicBloom_IsPropertySettable,
    SonicBloom_GetPropertyDataSize,
    SonicBloom_GetPropertyData,
    SonicBloom_SetPropertyData,
    SonicBloom_StartIO,
    SonicBloom_StopIO,
    SonicBloom_GetZeroTimeStamp,
    SonicBloom_WillDoIOOperation,
    SonicBloom_BeginIOOperation,
    SonicBloom_DoIOOperation,
    SonicBloom_EndIOOperation
};

static AudioServerPlugInDriverInterface* gDriverInterfacePtr = &gDriverInterface;

__attribute__((visibility("default")))
void* SonicBloomHAL_Create(CFAllocatorRef allocator, CFUUIDRef requestedTypeUUID) {
    if (!CFEqual(requestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return NULL;
    }
    SonicBloom_AddRef(NULL);
    return &gDriverInterfacePtr;
}

static HRESULT SonicBloom_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    CFUUIDRef requestedUUID = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (CFEqual(requestedUUID, IUnknownUUID) || CFEqual(requestedUUID, kAudioServerPlugInDriverInterfaceUUID)) {
        SonicBloom_AddRef(inDriver);
        *outInterface = &gDriverInterfacePtr;
        CFRelease(requestedUUID);
        return S_OK;
    }
    *outInterface = NULL;
    CFRelease(requestedUUID);
    return E_NOINTERFACE;
}

static ULONG SonicBloom_AddRef(void* inDriver) { return __sync_add_and_fetch(&gRefCount, 1); }
static ULONG SonicBloom_Release(void* inDriver) { return __sync_sub_and_fetch(&gRefCount, 1); }

static OSStatus SonicBloom_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    gHost = inHost;
    gAnchorHostTime = mach_absolute_time();
    SonicBloomLog("Initialize");
    return kAudioHardwareNoError;
}

static OSStatus SonicBloom_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID) {
    if (outDeviceObjectID) {
        *outDeviceObjectID = kSonicBloomDeviceObjectID;
    }
    SonicBloomLog("CreateDevice");
    return kAudioHardwareNoError;
}

static OSStatus SonicBloom_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) { return kAudioHardwareNoError; }
static OSStatus SonicBloom_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo) { return kAudioHardwareNoError; }
static OSStatus SonicBloom_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo) { return kAudioHardwareNoError; }
static OSStatus SonicBloom_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo) { return kAudioHardwareNoError; }
static OSStatus SonicBloom_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo) { return kAudioHardwareNoError; }

static Boolean SonicBloom_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress) {
    UInt32 size = 0;
    return SonicBloom_GetPropertyDataSize(inDriver, inObjectID, inClientProcessID, inAddress, 0, NULL, &size) == kAudioHardwareNoError;
}

static OSStatus SonicBloom_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable) {
    *outIsSettable = IsDevice(inObjectID) && (
        inAddress->mSelector == kAudioDevicePropertyNominalSampleRate ||
        inAddress->mSelector == kAudioDevicePropertyBufferFrameSize
    );
    return SonicBloom_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress) ? kAudioHardwareNoError : kAudioHardwareUnknownPropertyError;
}

static OSStatus SonicBloom_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize) {
    const AudioObjectPropertySelector selector = inAddress->mSelector;
    SonicBloomLogProperty("Size", inObjectID, selector);
    if (selector == kAudioObjectPropertyCustomPropertyInfoList || selector == kSonicBloomPropertyTaps || selector == kSonicBloomPropertyAccesses) {
        *outDataSize = 0;
        return kAudioHardwareNoError;
    }
    if (selector == kAudioObjectPropertyClass || selector == kAudioObjectPropertyBaseClass || selector == kAudioObjectPropertyOwner ||
        selector == kAudioPlugInPropertyTranslateUIDToDevice ||
        selector == kSonicBloomPropertySISO ||
        selector == kAudioDevicePropertyTransportType || selector == kAudioDevicePropertyDeviceIsAlive || selector == kAudioDevicePropertyDeviceIsRunning ||
        selector == kAudioDevicePropertyDeviceCanBeDefaultDevice || selector == kAudioDevicePropertyDeviceCanBeDefaultSystemDevice ||
        selector == kAudioDevicePropertyIsHidden ||
        selector == kAudioDevicePropertyLatency || selector == kAudioDevicePropertySafetyOffset || selector == kAudioDevicePropertyBufferFrameSize || selector == kAudioDevicePropertyClockDomain || selector == kAudioDevicePropertyClockAlgorithm || selector == kAudioDevicePropertyClockIsStable ||
        selector == kAudioStreamPropertyIsActive || selector == kAudioStreamPropertyDirection || selector == kAudioStreamPropertyTerminalType ||
        selector == kAudioStreamPropertyStartingChannel || selector == kAudioStreamPropertyLatency || selector == kAudioDevicePropertyZeroTimeStampPeriod) {
        *outDataSize = sizeof(UInt32);
        return kAudioHardwareNoError;
    }
    if (selector == kAudioDevicePropertyNominalSampleRate) {
        *outDataSize = sizeof(Float64);
        return kAudioHardwareNoError;
    }
    if (IsDevice(inObjectID) && selector == kAudioDevicePropertyBufferFrameSizeRange) {
        *outDataSize = sizeof(AudioValueRange);
        return kAudioHardwareNoError;
    }
    if (selector == kAudioObjectPropertyName || selector == kAudioObjectPropertyManufacturer || selector == kAudioObjectPropertyModelName ||
        selector == kAudioPlugInPropertyBundleID ||
        selector == kAudioDevicePropertyDeviceUID || selector == kAudioDevicePropertyModelUID || selector == kAudioDevicePropertyConfigurationApplication) {
        *outDataSize = sizeof(CFStringRef);
        return kAudioHardwareNoError;
    }
    if (inObjectID == kAudioObjectPlugInObject && selector == kAudioPlugInPropertyDeviceList) {
        *outDataSize = sizeof(AudioObjectID);
        return kAudioHardwareNoError;
    }
    if (inObjectID == kAudioObjectPlugInObject && (selector == kAudioPlugInPropertyBoxList || selector == kAudioPlugInPropertyClockDeviceList)) {
        *outDataSize = 0;
        return kAudioHardwareNoError;
    }
    if (selector == kAudioObjectPropertyOwnedObjects) {
        if (inObjectID == kAudioObjectPlugInObject) {
            *outDataSize = sizeof(AudioObjectID);
            return kAudioHardwareNoError;
        }
        if (IsDevice(inObjectID)) {
            *outDataSize = sizeof(AudioObjectID) * 2;
            return kAudioHardwareNoError;
        }
    }
    if (IsDevice(inObjectID) && selector == kAudioDevicePropertyStreams) {
        if (inAddress->mScope == kAudioObjectPropertyScopeInput || inAddress->mScope == kAudioObjectPropertyScopeOutput) {
            *outDataSize = sizeof(AudioObjectID);
        } else {
            *outDataSize = sizeof(AudioObjectID) * 2;
        }
        return kAudioHardwareNoError;
    }
    if (IsDevice(inObjectID) && selector == kAudioObjectPropertyControlList) {
        *outDataSize = 0;
        return kAudioHardwareNoError;
    }
    if (IsDevice(inObjectID) && selector == kAudioDevicePropertyRelatedDevices) {
        *outDataSize = sizeof(AudioObjectID);
        return kAudioHardwareNoError;
    }
    if (IsDevice(inObjectID) && selector == kAudioDevicePropertyStreamConfiguration) {
        *outDataSize = sizeof(AudioBufferList);
        return kAudioHardwareNoError;
    }
    if (IsDevice(inObjectID) && selector == kAudioDevicePropertyAvailableNominalSampleRates) {
        *outDataSize = sizeof(AudioValueRange) * 3;
        return kAudioHardwareNoError;
    }
    if (IsDevice(inObjectID) && selector == kAudioDevicePropertyPreferredChannelsForStereo) {
        *outDataSize = sizeof(UInt32) * 2;
        return kAudioHardwareNoError;
    }
    if (IsStream(inObjectID) && (selector == kAudioStreamPropertyVirtualFormat || selector == kAudioStreamPropertyPhysicalFormat)) {
        *outDataSize = sizeof(AudioStreamBasicDescription);
        return kAudioHardwareNoError;
    }
    if (IsStream(inObjectID) && (selector == kAudioStreamPropertyAvailableVirtualFormats || selector == kAudioStreamPropertyAvailablePhysicalFormats)) {
        *outDataSize = sizeof(AudioStreamRangedDescription);
        return kAudioHardwareNoError;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus SonicBloom_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    const AudioObjectPropertySelector selector = inAddress->mSelector;
    SonicBloomLogProperty("Data", inObjectID, selector);
    if (selector == kAudioObjectPropertyCustomPropertyInfoList || selector == kSonicBloomPropertyTaps || selector == kSonicBloomPropertyAccesses) {
        *outDataSize = 0;
        return kAudioHardwareNoError;
    }
    if (selector == kAudioObjectPropertyClass || selector == kAudioObjectPropertyBaseClass) {
        UInt32 classID = kAudioObjectClassID;
        if (inObjectID == kAudioObjectPlugInObject) classID = kAudioPlugInClassID;
        if (IsDevice(inObjectID)) classID = kAudioDeviceClassID;
        if (IsStream(inObjectID)) classID = kAudioStreamClassID;
        return WriteUInt32(inDataSize, outDataSize, outData, classID);
    }
    if (selector == kAudioObjectPropertyOwner) {
        UInt32 owner = IsStream(inObjectID) ? kSonicBloomDeviceObjectID : kAudioObjectPlugInObject;
        return WriteUInt32(inDataSize, outDataSize, outData, owner);
    }
    if (selector == kAudioObjectPropertyName) {
        if (inObjectID == kAudioObjectPlugInObject) return WriteString(inDataSize, outDataSize, outData, CFSTR("SonicBloom HAL"));
        if (IsOutputStream(inObjectID)) return WriteString(inDataSize, outDataSize, outData, CFSTR("SonicBloom Output Stream"));
        if (IsInputStream(inObjectID)) return WriteString(inDataSize, outDataSize, outData, CFSTR("SonicBloom Input Stream"));
        return WriteString(inDataSize, outDataSize, outData, CFSTR("SonicBloom Output"));
    }
    if (selector == kAudioObjectPropertyManufacturer) return WriteString(inDataSize, outDataSize, outData, CFSTR("SonicBloom"));
    if (selector == kAudioObjectPropertyModelName) return WriteString(inDataSize, outDataSize, outData, CFSTR("SonicBloom Virtual Duplex Driver"));
    if (selector == kAudioPlugInPropertyBundleID) return WriteString(inDataSize, outDataSize, outData, CFSTR("com.chrisdimarco.sonicbloom.hal"));
    if (inObjectID == kAudioObjectPlugInObject && selector == kAudioPlugInPropertyDeviceList) {
        AudioObjectID object = kSonicBloomDeviceObjectID;
        return WriteData(inDataSize, outDataSize, outData, &object, sizeof(object));
    }
    if (inObjectID == kAudioObjectPlugInObject && (selector == kAudioPlugInPropertyBoxList || selector == kAudioPlugInPropertyClockDeviceList)) {
        *outDataSize = 0;
        return kAudioHardwareNoError;
    }
    if (inObjectID == kAudioObjectPlugInObject && selector == kAudioPlugInPropertyTranslateUIDToDevice) {
        if (inQualifierDataSize != sizeof(CFStringRef) || inQualifierData == NULL) {
            return kAudioHardwareBadPropertySizeError;
        }
        CFStringRef uid = *((const CFStringRef*)inQualifierData);
        AudioObjectID object = CFEqual(uid, CFSTR("com.chrisdimarco.sonicbloom.output")) ? kSonicBloomDeviceObjectID : kAudioObjectUnknown;
        return WriteUInt32(inDataSize, outDataSize, outData, object);
    }
    if (selector == kAudioDevicePropertyDeviceUID) return WriteString(inDataSize, outDataSize, outData, CFSTR("com.chrisdimarco.sonicbloom.output"));
    if (selector == kAudioDevicePropertyModelUID) return WriteString(inDataSize, outDataSize, outData, CFSTR("com.chrisdimarco.sonicbloom.model"));
    if (selector == kAudioDevicePropertyConfigurationApplication) return WriteString(inDataSize, outDataSize, outData, CFSTR("com.chrisdimarco.sonicbloom"));
    if (selector == kAudioObjectPropertyOwnedObjects) {
        if (inObjectID == kAudioObjectPlugInObject) {
            AudioObjectID object = kSonicBloomDeviceObjectID;
            return WriteData(inDataSize, outDataSize, outData, &object, sizeof(object));
        }
        if (IsDevice(inObjectID)) {
            AudioObjectID objects[2] = { kSonicBloomOutputStreamObjectID, kSonicBloomInputStreamObjectID };
            return WriteData(inDataSize, outDataSize, outData, objects, sizeof(objects));
        }
    }
    if (IsDevice(inObjectID) && selector == kAudioDevicePropertyStreams) {
        if (inAddress->mScope == kAudioObjectPropertyScopeOutput) {
            AudioObjectID stream = kSonicBloomOutputStreamObjectID;
            return WriteData(inDataSize, outDataSize, outData, &stream, sizeof(stream));
        }
        if (inAddress->mScope == kAudioObjectPropertyScopeInput) {
            AudioObjectID stream = kSonicBloomInputStreamObjectID;
            return WriteData(inDataSize, outDataSize, outData, &stream, sizeof(stream));
        }
        AudioObjectID streams[2] = { kSonicBloomOutputStreamObjectID, kSonicBloomInputStreamObjectID };
        return WriteData(inDataSize, outDataSize, outData, streams, sizeof(streams));
    }
    if (IsDevice(inObjectID) && selector == kAudioObjectPropertyControlList) {
        *outDataSize = 0;
        return kAudioHardwareNoError;
    }
    if (IsDevice(inObjectID) && selector == kAudioDevicePropertyStreamConfiguration) {
        const UInt32 channels = (inAddress->mScope == kAudioObjectPropertyScopeInput || inAddress->mScope == kAudioObjectPropertyScopeOutput) ? kSonicBloomChannels : kSonicBloomChannels * 2;
        return WriteAudioBufferList(inDataSize, outDataSize, outData, channels);
    }
    if (selector == kAudioDevicePropertyTransportType) return WriteUInt32(inDataSize, outDataSize, outData, kAudioDeviceTransportTypeVirtual);
    if (selector == kSonicBloomPropertySISO) return WriteUInt32(inDataSize, outDataSize, outData, 1);
    if (selector == kAudioDevicePropertyClockDomain) return WriteUInt32(inDataSize, outDataSize, outData, 0);
    if (selector == kAudioDevicePropertyClockAlgorithm) return WriteUInt32(inDataSize, outDataSize, outData, kAudioDeviceClockAlgorithmRaw);
    if (selector == kAudioDevicePropertyIsHidden) return WriteUInt32(inDataSize, outDataSize, outData, 0);
    if (selector == kAudioDevicePropertyDeviceIsAlive || selector == kAudioDevicePropertyDeviceCanBeDefaultDevice || selector == kAudioDevicePropertyDeviceCanBeDefaultSystemDevice || selector == kAudioDevicePropertyClockIsStable) return WriteUInt32(inDataSize, outDataSize, outData, 1);
    if (selector == kAudioDevicePropertyDeviceIsRunning) return WriteUInt32(inDataSize, outDataSize, outData, gIOClientCount > 0 ? 1 : 0);
    if (selector == kAudioDevicePropertyLatency) return WriteUInt32(inDataSize, outDataSize, outData, kSonicBloomReportedLatencyFrames);
    if (selector == kAudioDevicePropertySafetyOffset) return WriteUInt32(inDataSize, outDataSize, outData, kSonicBloomReportedSafetyOffsetFrames);
    if (selector == kAudioStreamPropertyLatency) return WriteUInt32(inDataSize, outDataSize, outData, 0);
    if (selector == kAudioDevicePropertyBufferFrameSize) return WriteUInt32(inDataSize, outDataSize, outData, gBufferFrameSize);
    if (IsDevice(inObjectID) && selector == kAudioDevicePropertyBufferFrameSizeRange) {
        AudioValueRange range = { kSonicBloomMinBufferFrames, kSonicBloomMaxBufferFrames };
        return WriteData(inDataSize, outDataSize, outData, &range, sizeof(range));
    }
    if (selector == kAudioDevicePropertyZeroTimeStampPeriod) return WriteUInt32(inDataSize, outDataSize, outData, kSonicBloomZeroTimestampPeriod);
    if (selector == kAudioDevicePropertyNominalSampleRate) return WriteFloat64(inDataSize, outDataSize, outData, gSampleRate);
    if (IsDevice(inObjectID) && selector == kAudioDevicePropertyAvailableNominalSampleRates) {
        AudioValueRange ranges[3] = {{44100.0, 44100.0}, {48000.0, 48000.0}, {96000.0, 96000.0}};
        return WriteData(inDataSize, outDataSize, outData, ranges, sizeof(ranges));
    }
    if (IsDevice(inObjectID) && selector == kAudioDevicePropertyPreferredChannelsForStereo) {
        UInt32 channels[2] = {1, 2};
        return WriteData(inDataSize, outDataSize, outData, channels, sizeof(channels));
    }
    if (IsDevice(inObjectID) && selector == kAudioDevicePropertyRelatedDevices) {
        AudioObjectID device = kSonicBloomDeviceObjectID;
        return WriteData(inDataSize, outDataSize, outData, &device, sizeof(device));
    }
    if (IsStream(inObjectID) && selector == kAudioStreamPropertyIsActive) return WriteUInt32(inDataSize, outDataSize, outData, 1);
    if (IsStream(inObjectID) && selector == kAudioStreamPropertyDirection) return WriteUInt32(inDataSize, outDataSize, outData, IsInputStream(inObjectID) ? 1 : 0);
    if (IsStream(inObjectID) && selector == kAudioStreamPropertyTerminalType) return WriteUInt32(inDataSize, outDataSize, outData, IsInputStream(inObjectID) ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
    if (IsStream(inObjectID) && selector == kAudioStreamPropertyStartingChannel) return WriteUInt32(inDataSize, outDataSize, outData, 1);
    if (IsStream(inObjectID) && (selector == kAudioStreamPropertyVirtualFormat || selector == kAudioStreamPropertyPhysicalFormat)) {
        AudioStreamBasicDescription format = SonicBloomFormat();
        return WriteData(inDataSize, outDataSize, outData, &format, sizeof(format));
    }
    if (IsStream(inObjectID) && (selector == kAudioStreamPropertyAvailableVirtualFormats || selector == kAudioStreamPropertyAvailablePhysicalFormats)) {
        AudioStreamRangedDescription format = SonicBloomRangedFormat();
        return WriteData(inDataSize, outDataSize, outData, &format, sizeof(format));
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus SonicBloom_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData) {
    if (IsDevice(inObjectID) && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize != sizeof(Float64) || inData == NULL) {
            return kAudioHardwareBadPropertySizeError;
        }
        const Float64 rate = *((const Float64*)inData);
        if (rate == 44100.0 || rate == 48000.0 || rate == 96000.0) {
            if (gSampleRate != rate) {
                gSampleRate = rate;
                gClockSeed += 1;
                NotifySampleRateChanged();
            }
            return kAudioHardwareNoError;
        }
        return kAudioHardwareIllegalOperationError;
    }
    if (IsDevice(inObjectID) && inAddress->mSelector == kAudioDevicePropertyBufferFrameSize) {
        if (inDataSize != sizeof(UInt32) || inData == NULL) {
            return kAudioHardwareBadPropertySizeError;
        }
        const UInt32 frameSize = *((const UInt32*)inData);
        if (frameSize < kSonicBloomMinBufferFrames || frameSize > kSonicBloomMaxBufferFrames) {
            return kAudioHardwareIllegalOperationError;
        }
        if (gBufferFrameSize != frameSize) {
            gBufferFrameSize = frameSize;
            NotifyGlobalProperty(kSonicBloomDeviceObjectID, kAudioDevicePropertyBufferFrameSize);
        }
        return kAudioHardwareNoError;
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus SonicBloom_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadDeviceError;
    const UInt32 previousCount = __sync_fetch_and_add(&gIOClientCount, 1);
    SonicBloomLogIO("StartIO", inDeviceObjectID, 0, inClientID, previousCount + 1);
    if (previousCount == 0) {
        gAnchorHostTime = mach_absolute_time();
        gSampleTime = 0.0;
        NotifyGlobalProperty(kSonicBloomDeviceObjectID, kAudioDevicePropertyDeviceIsRunning);
    }
    return kAudioHardwareNoError;
}

static OSStatus SonicBloom_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    if (!IsDevice(inDeviceObjectID)) return kAudioHardwareBadDeviceError;
    if (gIOClientCount == 0) return kAudioHardwareNoError;
    const UInt32 newCount = __sync_sub_and_fetch(&gIOClientCount, 1);
    SonicBloomLogIO("StopIO", inDeviceObjectID, 0, inClientID, newCount);
    if (newCount == 0) {
        NotifyGlobalProperty(kSonicBloomDeviceObjectID, kAudioDevicePropertyDeviceIsRunning);
    }
    return kAudioHardwareNoError;
}

static OSStatus SonicBloom_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    const UInt64 now = mach_absolute_time();
    if (gAnchorHostTime == 0) {
        gAnchorHostTime = now;
    }
    const Float64 elapsedSeconds = HostTicksToSeconds(now - gAnchorHostTime);
    const UInt64 frame = (UInt64)(elapsedSeconds * gSampleRate);
    const UInt64 periodFrame = (frame / kSonicBloomZeroTimestampPeriod) * kSonicBloomZeroTimestampPeriod;
    gSampleTime = (Float64)periodFrame;
    *outSampleTime = gSampleTime;
    *outHostTime = gAnchorHostTime + SecondsToHostTicks((Float64)periodFrame / gSampleRate);
    *outSeed = gClockSeed;
    return kAudioHardwareNoError;
}

static OSStatus SonicBloom_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    *outWillDo = (inOperationID == kAudioServerPlugInIOOperationWriteMix || inOperationID == kAudioServerPlugInIOOperationReadInput);
    *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus SonicBloom_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    return kAudioHardwareNoError;
}

static void PushLoopbackFrame(float left, float right) {
    if (gRingFrameCount == kSonicBloomRingFrames) {
        gRingReadIndex = (gRingReadIndex + 1) % kSonicBloomRingFrames;
        gRingFrameCount -= 1;
    }
    gLoopbackRing[0][gRingWriteIndex] = left;
    gLoopbackRing[1][gRingWriteIndex] = right;
    gRingWriteIndex = (gRingWriteIndex + 1) % kSonicBloomRingFrames;
    gRingFrameCount += 1;
}

static bool PopLoopbackFrame(float* left, float* right) {
    if (gRingFrameCount == 0) {
        *left = 0.0f;
        *right = 0.0f;
        return false;
    }
    *left = gLoopbackRing[0][gRingReadIndex];
    *right = gLoopbackRing[1][gRingReadIndex];
    gRingReadIndex = (gRingReadIndex + 1) % kSonicBloomRingFrames;
    gRingFrameCount -= 1;
    return true;
}

static void TrimLoopbackQueue(UInt32 maxFrames) {
    while (gRingFrameCount > maxFrames) {
        gRingReadIndex = (gRingReadIndex + 1) % kSonicBloomRingFrames;
        gRingFrameCount -= 1;
    }
}

static UInt32 MaxLoopbackQueueFrames(UInt32 ioFrames) {
    const UInt32 lowLatencyFloor = kSonicBloomDefaultBufferFrames * 2;
    return ioFrames > lowLatencyFloor ? ioFrames : lowLatencyFloor;
}

static void CopyOutputToLoopback(const float* samples, UInt32 frames) {
    if (!samples) return;
    pthread_mutex_lock(&gRingLock);
    for (UInt32 frame = 0; frame < frames; frame++) {
        PushLoopbackFrame(
            samples[(frame * kSonicBloomChannels)],
            samples[(frame * kSonicBloomChannels) + 1]
        );
    }
    TrimLoopbackQueue(MaxLoopbackQueueFrames(frames));
    pthread_mutex_unlock(&gRingLock);
}

static void CopyLoopbackToInput(float* samples, UInt32 frames) {
    if (!samples) return;
    pthread_mutex_lock(&gRingLock);
    for (UInt32 frame = 0; frame < frames; frame++) {
        float left = 0.0f;
        float right = 0.0f;
        PopLoopbackFrame(&left, &right);
        samples[(frame * kSonicBloomChannels)] = left;
        samples[(frame * kSonicBloomChannels) + 1] = right;
    }
    pthread_mutex_unlock(&gRingLock);
}

static OSStatus SonicBloom_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer) {
    if (!IsDevice(inDeviceObjectID) || !IsStream(inStreamObjectID)) return kAudioHardwareBadObjectError;
    if (inOperationID == kAudioServerPlugInIOOperationWriteMix && IsOutputStream(inStreamObjectID)) {
        CopyOutputToLoopback((const float*)ioMainBuffer, inIOBufferFrameSize);
#if SONICBLOOM_HAL_TRACE
        if ((++gTraceWriteMixCount % 100) == 1) SonicBloomLogIO("WriteMix", inStreamObjectID, inOperationID, inIOBufferFrameSize, gRingFrameCount);
#endif
        return kAudioHardwareNoError;
    }
    if (inOperationID == kAudioServerPlugInIOOperationReadInput && IsInputStream(inStreamObjectID)) {
        CopyLoopbackToInput((float*)ioMainBuffer, inIOBufferFrameSize);
#if SONICBLOOM_HAL_TRACE
        if ((++gTraceReadInputCount % 100) == 1) SonicBloomLogIO("ReadInput", inStreamObjectID, inOperationID, inIOBufferFrameSize, gRingFrameCount);
#endif
        return kAudioHardwareNoError;
    }
    return kAudioHardwareNoError;
}

static OSStatus SonicBloom_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    return kAudioHardwareNoError;
}
