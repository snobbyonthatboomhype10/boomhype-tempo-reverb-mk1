// BoomHype Tech - Tempo Reverb MK I  -  resizable brushed-metal editor
#pragma once
#include "PluginProcessor.h"
#include "Ui.h"
#include "EqDisplay.h"

class TempoReverbEditor : public juce::AudioProcessorEditor, private juce::Timer
{
public:
    explicit TempoReverbEditor (TempoReverbProcessor&);
    ~TempoReverbEditor() override;
    void paint (juce::Graphics&) override;
    void resized() override;

    static constexpr float DW = 1960.f, DH = 1170.f;

private:
    using SA = juce::AudioProcessorValueTreeState::SliderAttachment;
    using BA = juce::AudioProcessorValueTreeState::ButtonAttachment;
    struct Placed { juce::Component* c; juce::Rectangle<float> r; };

    ui::KnobComp* addKnob (const juce::String& id, const juce::String& label, ui::ScaleKind kind, ui::Cap cap, float size,
                           std::function<juce::String (double)> fmt, float x, float y);
    ui::BellButton* addToggle (const juce::String& text, const juce::String& paramId, float x, float y, float w, float h, bool jewel = true, float fpx = 14.f);
    void place (juce::Component& c, float x, float y, float w, float h);
    void timerCallback() override;
    void applySkin();
    void selectProgram (int t);
    void setP (const juce::String& id, float plain);
    void rebuildBackground();
    void drawStatic (juce::Graphics& g);

    TempoReverbProcessor& proc;
    int lastType = -1, activeBand = 0;
    float sc = 1.f;
    juce::Image bg;

    std::vector<Placed> placed;
    std::vector<std::unique_ptr<ui::KnobComp>> knobs;
    std::vector<std::unique_ptr<ui::BellButton>> bells;
    std::vector<std::unique_ptr<SA>> sAtt;
    std::vector<std::unique_ptr<BA>> bAtt;
    std::array<ui::BellButton*, 8> prog {};
    std::array<ui::NoteKey*, 12> timeKeys {};
    std::array<ui::NoteKey*, 9> pdKeys {};
    std::array<std::unique_ptr<ui::NoteKey>, 21> keyStore;
    std::array<ui::KnobComp*, 5> gainK {}, freqK {}, qK {};
    std::array<ui::BellButton*, 5> bandByp {};
    ui::KnobComp *modK = nullptr, *duckAmtK = nullptr, *duckSensK = nullptr, *duckRelK = nullptr;
    ui::BellButton *abA = nullptr, *abB = nullptr;
    ui::ChipGroup hpChips { juce::StringArray { "OFF", "6", "12", "24" } }, lpChips { juce::StringArray { "OFF", "6", "12", "24" } },
                  prePost { juce::StringArray { "PRE", "POST" } };
    ui::LcdBox tempoLcd { true }, timeLcd { false }, pdLcd { false };
    ui::VuMeter grMeter { true }, outMeter { false };
    EqDisplay eq;
    float dragStartVal = 0.f;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (TempoReverbEditor)
};
