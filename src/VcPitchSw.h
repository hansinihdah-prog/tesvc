/*
 * VC Pitch Up - AIDL audio effect (android.hardware.audio.effect V2).
 *
 * A PRE_PROC (capture) effect that raises the pitch of the microphone signal.
 * It is built on the AOSP effect-impl framework (EffectImpl / EffectContext /
 * EffectThread), the same base class MediaTek's own pre-processing library
 * uses, so the effect service can load it through audio_effects_config.xml.
 */
#pragma once

#include <aidl/android/hardware/audio/effect/BnEffect.h>
#include <fmq/AidlMessageQueue.h>
#include <memory>
#include <vector>

#include "effect-impl/EffectImpl.h"
#include "pitch.h"

namespace aidl::android::hardware::audio::effect {

class VcPitchContext final : public EffectContext {
  public:
    VcPitchContext(int statusDepth, const Parameter::Common& common);

    RetCode setCommon(const Parameter::Common& common) override;

    // in/out hold `samples` interleaved float samples; they may alias.
    void process(const float* in, float* out, int samples);

  private:
    void reconfigure(const Parameter::Common& common);

    std::unique_ptr<vcp_state> mDsp;
    int mSemitones = 5;
    int mChannels = 1;
    uint32_t mRate = 0;
};

class VcPitchSw final : public EffectImpl {
  public:
    static const std::string kEffectName;
    static const Descriptor kDescriptor;

    VcPitchSw() { LOG(DEBUG) << __func__; }
    ~VcPitchSw() {
        cleanUp();
        LOG(DEBUG) << __func__;
    }

    ndk::ScopedAStatus getDescriptor(Descriptor* _aidl_return) override;
    ndk::ScopedAStatus setParameterSpecific(const Parameter::Specific& specific)
            REQUIRES(mImplMutex) override;
    ndk::ScopedAStatus getParameterSpecific(const Parameter::Id& id, Parameter::Specific* specific)
            REQUIRES(mImplMutex) override;

    std::shared_ptr<EffectContext> createContext(const Parameter::Common& common)
            REQUIRES(mImplMutex) override;
    RetCode releaseContext() REQUIRES(mImplMutex) override;

    std::string getEffectName() override { return kEffectName; }
    IEffect::Status effectProcessImpl(float* in, float* out, int samples)
            REQUIRES(mImplMutex) override;

  private:
    std::shared_ptr<VcPitchContext> mContext GUARDED_BY(mImplMutex);
};

}  // namespace aidl::android::hardware::audio::effect
