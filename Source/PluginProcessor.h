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
    double getTailLengthSeconds() const override { return 20.0; }

    int getNumPrograms() override { return 1; }
    int getCurrentProgram() override { return 0; }
    void setCurrentProgram (int) override {}
    const juce::String getProgramName (int) override { return {}; }
    void changeProgramName (int, const juce::String&) override {}

    void getStateInformation (juce::MemoryBlock& destData) override;
    void setStateInformation (const void* data, int sizeInBytes) override;

    static juce::AudioProcessorValueTreeState::ParameterLayout createLayout();
    float get (const juce::String& id) const { return apvts.getRawParameterValue (id)->load(); }

    juce::AudioProcessorValueTreeState apvts;

    // values shared with the editor (meters, tempo read-outs, analyser)
    std::atomic<float> grDb { 0.f }, outRmsDb { -90.f }, hostBpm { 120.f }, effDecay { 2.f }, effPre { 20.f };
    static constexpr int fftOrder = 11, fftSize = 1 << fftOrder;
    std::array<float, fftSize> fftSnapshot {};
    std::atomic<bool> fftReady { false };

private:
    void updateEq();
    void applyEq (float* l, float* r, int n);

    bh::Engine engine;
    bh::Biquad hp, lp, band[5];
    bool hpOn = true, lpOn = true, bandOn[5] {};
    std::vector<float> dryL, dryR, wetL, wetR;
    double sr = 44100.0;
    float envDet = 0.f, grSmooth = 0.f, outSmooth = -90.f;
    std::array<float, fftSize> fftFifo {};
    int fftIdx = 0;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (TempoReverbProcessor)
};
