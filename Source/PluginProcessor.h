// BoomHype Tech - Tempo Reverb MK I
#pragma once
#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_dsp/juce_dsp.h>
#include <atomic>
#include <array>
#include <vector>
#include "ReverbEngine.h"

class TempoReverbProcessor : public juce::AudioProcessor
{
public:
    TempoReverbProcessor();
    ~TempoReverbProcessor() override = default;

    void prepareToPlay (double sampleRate, int samplesPerBlock) override;
    void releaseResources() override {}
    bool isBusesLayoutSupported (const BusesLayout& layouts) const override;
    void processBlock (juce::AudioBuffer<float>&, juce::MidiBuffer&) override;

    juce::AudioProcessorEditor* createEditor() override;
    bool hasEditor() const override { return true; }

    const juce::String getName() const override { return "Tempo Reverb MK I"; }
    bool acceptsMidi() const override { return false; }
    bool producesMidi() const override { return false; }
    bool isMidiEffect() const override { return false; }
    double getTailLengthSeconds() const override { return 32.0; }

    int getNumPrograms() override { return 1; }
    int getCurrentProgram() override { return 0; }
    void setCurrentProgram (int) override {}
    const juce::String getProgramName (int) override { return {}; }
    void changeProgramName (int, const juce::String&) override {}

    void getStateInformation (juce::MemoryBlock& destData) override;
    void setStateInformation (const void* data, int sizeInBytes) override;

    static juce::AudioProcessorValueTreeState::ParameterLayout createLayout();
    float get (const juce::String& id) const { return apvts.getRawParameterValue (id)->load(); }

    // A/B compare (message thread only)
    void abSwitch (int slot);
    int abSlot() const { return abCurrent; }

    juce::AudioProcessorValueTreeState apvts;

    // shared with the editor (meters, read-outs, analyser)
    std::atomic<float> grDb { 0.f }, outRmsDb { -90.f }, inPeakDb { -90.f }, bpmEff { 120.f }, effDecay { 2.f }, effPre { 20.f };
    std::atomic<bool> hostHasBpm { false };
    static constexpr int scopeSize = 16384;
    std::array<float, scopeSize> scope {};
    std::atomic<int> scopeWrite { 0 };

private:

    bh::Engine engine;
    bh::CutFilter hp, lp;
    bh::Biquad band[5];
    bool bandOn[5] {};
    std::vector<float> dryL, dryR, wetL, wetR;
    double sr = 44100.0;
    float envDet = 0.f, grSmooth = 0.f;
    juce::SmoothedValue<float> mixSm, outSm, trimSm;

    juce::ValueTree abState[2];
    int abCurrent = 0;

    void updateEq();
    void applyEq (float* l, float* r, int n, bool post);

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (TempoReverbProcessor)
};
