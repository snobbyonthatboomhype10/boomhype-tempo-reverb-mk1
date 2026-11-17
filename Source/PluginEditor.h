// BoomHype Tech - Tempo Reverb MK I  -  resizable vintage-rack editor
#pragma once
#include "PluginProcessor.h"

struct Skin { juce::Colour p1, p2, p3, accent; bool darkInk; };
extern const Skin kSkins[bh::NumTypes];

inline juce::Font bhFont (float h, bool bold = true)
{
    return juce::Font (juce::FontOptions (juce::jmax (6.f, h), bold ? juce::Font::bold : juce::Font::plain));
}

//==============================================================================
class BHLook : public juce::LookAndFeel_V4
{
public:
    const Skin* skin = &kSkins[0];
    void drawRotarySlider (juce::Graphics&, int x, int y, int w, int h, float pos, float startA, float endA, juce::Slider&) override;
    void drawButtonBackground (juce::Graphics&, juce::Button&, const juce::Colour&, bool over, bool down) override;
    void drawButtonText (juce::Graphics&, juce::TextButton&, bool over, bool down) override;
    juce::Font getTextButtonFont (juce::TextButton&, int h) override { return bhFont ((float) h * 0.46f); }
    juce::Font getLabelFont (juce::Label& l) override { return bhFont ((float) l.getHeight() * 0.68f); }
};

//==============================================================================
// Needle VU. GR mode: 0 .. -20 dB.  Output mode: -20 .. +3 VU
class VuMeter : public juce::Component
{
public:
    explicit VuMeter (bool gr) : isGR (gr) { needle = target = gr ? 0.f : -20.f; }
    void setValue (float v) { target = v; }
    void tick() { needle += (target - needle) * 0.2f; repaint(); }
    void paint (juce::Graphics& g) override;
private:
    float angleFor (float v) const;
    bool isGR; float needle = 0.f, target = 0.f;
};

//==============================================================================
// Large spectral EQ: live analyser + response curve + draggable nodes
class EqDisplay : public juce::Component
{
public:
    explicit EqDisplay (TempoReverbProcessor& p);
    const Skin* skin = &kSkins[0];
    void tick();
    void paint (juce::Graphics&) override;
    void mouseDown (const juce::MouseEvent&) override;
    void mouseDrag (const juce::MouseEvent&) override;
    void mouseUp (const juce::MouseEvent&) override;
    void mouseDoubleClick (const juce::MouseEvent&) override;
    void mouseWheelMove (const juce::MouseEvent&, const juce::MouseWheelDetails&) override;
private:
    juce::Rectangle<float> area() const { return getLocalBounds().toFloat().reduced (getHeight() * 0.04f); }
    float fToX (float f) const { auto r = area(); return r.getX() + r.getWidth() * (float) (std::log (f / 20.f) / std::log (1000.f)); }
    float xToF (float x) const { auto r = area(); return 20.f * std::pow (1000.f, juce::jlimit (0.f, 1.f, (x - r.getX()) / r.getWidth())); }
    float gToY (float g) const { auto r = area(); return r.getCentreY() - g / 15.f * r.getHeight() * 0.5f; }
    float yToG (float y) const { auto r = area(); return juce::jlimit (-12.f, 12.f, (r.getCentreY() - y) / (r.getHeight() * 0.5f) * 15.f); }
    juce::Point<float> nodePos (int i) const;
    int nearestNode (juce::Point<float> p, float maxDist) const;
    void setP (const juce::String& id, float plain);
    void gesture (const juce::String& id, bool begin);
    TempoReverbProcessor& proc;
    juce::dsp::FFT fft; juce::dsp::WindowingFunction<float> window;
    std::array<float, TempoReverbProcessor::fftSize / 2> spec {};
    std::array<float, TempoReverbProcessor::fftSize * 2> fftData {};
    int dragNode = -1, selected = 2;
};

//==============================================================================
class TempoReverbEditor : public juce::AudioProcessorEditor, private juce::Timer
{
public:
    explicit TempoReverbEditor (TempoReverbProcessor&);
    ~TempoReverbEditor() override;
    void paint (juce::Graphics&) override;
    void resized() override;

private:
    struct Knob
    {
        juce::Slider s; juce::String name; juce::Rectangle<int> cell;
        std::unique_ptr<juce::AudioProcessorValueTreeState::SliderAttachment> att;
    };
    using BtnAtt = juce::AudioProcessorValueTreeState::ButtonAttachment;

    Knob* addKnob (const juce::String& id, const juce::String& name);
    void addToggle (juce::TextButton& b, const juce::String& text, const juce::String& paramId);
    void timerCallback() override;
    void applySkin();
    void selectType (int i);
    void setP (const juce::String& id, float plain);
    void drawPanel (juce::Graphics&, juce::Rectangle<int>, const juce::String& title, float sc);
    void drawLcd (juce::Graphics&, juce::Rectangle<int>, const juce::String& text);

    TempoReverbProcessor& proc;
    BHLook laf;
    int lastType = -1;

    std::vector<std::unique_ptr<Knob>> knobs;
    Knob* characterKnob = nullptr; Knob* preKnob = nullptr; Knob* decayKnob = nullptr;
    std::array<juce::TextButton, bh::NumTypes> typeBtn;
    std::array<juce::TextButton, 9> preBtn, timeBtn;
    std::array<juce::TextButton, 5> bandBtn;
    juce::TextButton syncBtn, freezeBtn, bypassBtn, duckBtn, srcBtn, eqPosBtn, hpBtn, lpBtn;
    VuMeter grMeter { true }, outMeter { false };
    EqDisplay eq;
    std::vector<std::unique_ptr<BtnAtt>> btnAtts;

    juce::Rectangle<int> pTempo, pReverb, pDuck, pOut, lcdHead, lcdBpm, lcdPre, lcdTime, rHeader, rLabelTime, rLabelPre;
    float scale = 1.f;

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (TempoReverbEditor)
};
