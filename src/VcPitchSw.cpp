#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <memory>

#include <aidl/android/hardware/audio/effect/DefaultExtension.h>
#define LOG_TAG "AHAL_VcPitch"
#include <android-base/logging.h>
#include <sys/system_properties.h>

#include "VcPitchSw.h"

using aidl::android::hardware::audio::effect::DefaultExtension;
using aidl::android::hardware::audio::effect::Descriptor;
using aidl::android::hardware::audio::effect::Flags;
using aidl::android::hardware::audio::effect::IEffect;
using aidl::android::hardware::audio::effect::VcPitchSw;
using aidl::android::hardware::audio::effect::VendorExtension;
using aidl::android::media::audio::common::AudioUuid;

namespace {

// Custom effect type and implementation UUIDs. They must match the "type" and
// "uuid" attributes written into audio_effects_config.xml by the module.
//   type: 5d3f7a1e-2b64-4c8e-9a10-7e4b2c6d8f31
//   uuid: c1a94e7b-6f23-4d85-b0e2-3a97d5f1c842
const AudioUuid kTypeUuid = {static_cast<int32_t>(0x5d3f7a1e), 0x2b64, 0x4c8e, 0x9a10,
                             {0x7e, 0x4b, 0x2c, 0x6d, 0x8f, 0x31}};
const AudioUuid kImplUuid = {static_cast<int32_t>(0xc1a94e7b), 0x6f23, 0x4d85, 0xb0e2,
                             {0x3a, 0x97, 0xd5, 0xf1, 0xc8, 0x42}};

constexpr int kDefaultSemitones = 5;
constexpr const char* kConfPath = "/vendor/etc/vcpitch.conf";
constexpr const char* kPropName = "debug.vcpitch.semitones";

// Pitch shift in semitones, -12..12 (0 = bypass). Read every time a recording
// starts: the config file (written by vc.sh) wins, then the system property,
// then the built-in default.
int readSemitones() {
    int value = kDefaultSemitones;
    bool fromFile = false;
    if (FILE* f = fopen(kConfPath, "re")) {
        int n = 0;
        if (fscanf(f, "%d", &n) == 1) {
            value = n;
            fromFile = true;
        }
        fclose(f);
    }
    if (!fromFile) {
        char buf[PROP_VALUE_MAX] = {0};
        if (__system_property_get(kPropName, buf) > 0) {
            char* end = nullptr;
            const long n = strtol(buf, &end, 10);
            if (end != buf) value = static_cast<int>(n);
        }
    }
    return vcp_clamp_semi(value);
}

}  // namespace

extern "C" binder_exception_t createEffect(const AudioUuid* in_impl_uuid,
                                           std::shared_ptr<IEffect>* instanceSpp) {
    if (!in_impl_uuid || *in_impl_uuid != kImplUuid) {
        LOG(ERROR) << __func__ << " uuid not supported";
        return EX_ILLEGAL_ARGUMENT;
    }
    if (!instanceSpp) {
        LOG(ERROR) << __func__ << " invalid input parameter!";
        return EX_ILLEGAL_ARGUMENT;
    }
    *instanceSpp = ndk::SharedRefBase::make<VcPitchSw>();
    LOG(DEBUG) << __func__ << " instance " << instanceSpp->get() << " created";
    return EX_NONE;
}

extern "C" binder_exception_t queryEffect(const AudioUuid* in_impl_uuid, Descriptor* _aidl_return) {
    if (!in_impl_uuid || *in_impl_uuid != kImplUuid) {
        LOG(ERROR) << __func__ << " uuid not supported";
        return EX_ILLEGAL_ARGUMENT;
    }
    if (!_aidl_return) return EX_ILLEGAL_ARGUMENT;
    *_aidl_return = VcPitchSw::kDescriptor;
    return EX_NONE;
}

namespace aidl::android::hardware::audio::effect {

// ---------------------------------------------------------------- context

VcPitchContext::VcPitchContext(int statusDepth, const Parameter::Common& common)
    : EffectContext(statusDepth, common) {
    reconfigure(common);
}

RetCode VcPitchContext::setCommon(const Parameter::Common& common) {
    const RetCode ret = EffectContext::setCommon(common);
    if (ret == RetCode::SUCCESS) {
        const int ch = static_cast<int>(
                ::aidl::android::hardware::audio::common::getChannelCount(
                        common.input.base.channelMask));
        const uint32_t rate = static_cast<uint32_t>(common.input.base.sampleRate);
        // Only rebuild the DSP when the stream layout really changed, so a
        // repeated identical setParameter(common) does not cause a glitch.
        if (ch != mChannels || rate != mRate) reconfigure(common);
    }
    return ret;
}

void VcPitchContext::reconfigure(const Parameter::Common& common) {
    mChannels = static_cast<int>(::aidl::android::hardware::audio::common::getChannelCount(
            common.input.base.channelMask));
    mRate = static_cast<uint32_t>(common.input.base.sampleRate);
    mSemitones = readSemitones();
    if (!mDsp) mDsp = std::make_unique<vcp_state>();
    vcp_reset(mDsp.get());
    vcp_configure(mDsp.get(), mRate, mSemitones);
    LOG(INFO) << "vcpitch: semitones=" << mSemitones << " rate=" << mRate
              << " channels=" << mChannels;
}

void VcPitchContext::process(const float* in, float* out, int samples) {
    if (samples <= 0) return;
    const bool unsupported = (mChannels < 1 || mChannels > VCP_MAXCH || mRate < 8000 ||
                              mRate > VCP_MAX_RATE || !mDsp);
    if (mSemitones == 0 || unsupported) {
        if (in != out) std::copy(in, in + samples, out);
        return;
    }
    const uint32_t frames = static_cast<uint32_t>(samples / mChannels);
    vcp_run(mDsp.get(), mChannels, /* float */ 5, in, out, frames, /* accumulate */ 0);
    const int done = static_cast<int>(frames) * mChannels;
    if (done < samples && in != out) std::copy(in + done, in + samples, out + done);
}

// ----------------------------------------------------------------- effect

const std::string VcPitchSw::kEffectName = "VcPitchUp";

const Descriptor VcPitchSw::kDescriptor = {
        .common = {.id = {.type = kTypeUuid, .uuid = kImplUuid, .proxy = std::nullopt},
                   .flags = {.type = Flags::Type::PRE_PROC, .volume = Flags::Volume::NONE},
                   .name = VcPitchSw::kEffectName,
                   .implementor = "vcpitch"}};

ndk::ScopedAStatus VcPitchSw::getDescriptor(Descriptor* _aidl_return) {
    *_aidl_return = kDescriptor;
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus VcPitchSw::setParameterSpecific(const Parameter::Specific& specific) {
    RETURN_IF(Parameter::Specific::vendorEffect != specific.getTag(), EX_ILLEGAL_ARGUMENT,
              "EffectNotSupported");
    RETURN_IF(!mContext, EX_NULL_POINTER, "nullContext");
    // The pitch is configured through vcpitch.conf / the system property,
    // vendor parameters are accepted and ignored.
    return ndk::ScopedAStatus::ok();
}

ndk::ScopedAStatus VcPitchSw::getParameterSpecific(const Parameter::Id& id,
                                                   Parameter::Specific* specific) {
    RETURN_IF(Parameter::Id::vendorEffectTag != id.getTag(), EX_ILLEGAL_ARGUMENT, "wrongIdTag");
    VendorExtension extension;
    DefaultExtension defaultExt;
    RETURN_IF(STATUS_OK != extension.extension.setParcelable(defaultExt), EX_ILLEGAL_ARGUMENT,
              "setParcelableFailed");
    specific->set<Parameter::Specific::vendorEffect>(extension);
    return ndk::ScopedAStatus::ok();
}

std::shared_ptr<EffectContext> VcPitchSw::createContext(const Parameter::Common& common) {
    if (mContext) {
        LOG(DEBUG) << __func__ << " context already exist";
    } else {
        mContext = std::make_shared<VcPitchContext>(1 /* statusFmqDepth */, common);
    }
    return mContext;
}

RetCode VcPitchSw::releaseContext() {
    if (mContext) mContext.reset();
    return RetCode::SUCCESS;
}

// Runs in the EffectThread worker; in and out are the same work buffer.
IEffect::Status VcPitchSw::effectProcessImpl(float* in, float* out, int samples) {
    if (mContext) {
        mContext->process(in, out, samples);
    } else if (in != out) {
        std::copy(in, in + samples, out);
    }
    return {STATUS_OK, samples, samples};
}

}  // namespace aidl::android::hardware::audio::effect
