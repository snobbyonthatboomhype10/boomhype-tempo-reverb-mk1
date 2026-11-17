// BoomHype Tech - Tempo Reverb MK I
#include "PluginProcessor.h"
#include "PluginEditor.h"

using Attr = juce::AudioParameterFloatAttributes;
using NRange = juce::NormalisableRange<float>;

static juce::String fmtMs  (float v, int) { return juce::String (v, 1) + " ms"; }
static juce::String fmtSec (float v, int) { return juce::String (v, 2) + " s"; }
static juce::String fmtPct (float v, int) { return juce::String (juce::roundToInt (v * 100.f)) + "%"; }
static juce::String fmtDb  (float v, int) { return juce::String (v, 1) + " dB"; }
static juce::String fmtHz  (float v, int) { return v >= 1000.f ? juce::String (v / 1000.f, 1) + " kHz" : juce::String (juce::roundToInt (v)) + " Hz"; }
static juce::String fmtQ   (float v, int) { return "Q " + juce::String (v, 1); }

juce::AudioProcessorValueTreeState::ParameterLayout TempoReverbProcessor::createLayout()
{
    using namespace juce;
    AudioProcessorValueTreeState::ParameterLayout layout;
    auto F = [&] (const char* id, const char* name, NRange r, float def, juce::String (*fmt) (float, int))
    {
        layout.add (std::make_unique<AudioParameterFloat> (ParameterID { id, 1 }, name, r, def, Attr().withStringFromValueFunction (fmt)));
    };
    auto B = [&] (const char* id, const char* name, bool def) { layout.add (std::make_unique<AudioParameterBool> (ParameterID { id, 1 }, name, def)); };

    StringArray types, notes;
    for (int i = 0; i < bh::NumTypes; ++i) types.add (bh::kTypeNames[i]);
    for (int i = 0; i < 9; ++i) notes.add (bh::kNoteNames[i]);

    layout.add (std::make_unique<AudioParameterChoice> (ParameterID { "type", 1 }, "Reverb Type", types, 0));
    B ("sync", "Tempo Sync", true);
    layout.add (std::make_unique<AudioParameterChoice> (ParameterID { "preNote", 1 }, "Pre-Delay Note", notes, 2));
    layout.add (std::make_unique<AudioParameterChoice> (ParameterID { "timeNote", 1 }, "Reverb Time Note", notes, 8));

    F ("predelay", "Pre-Delay", NRange (0.f, 250.f, 0.1f, 0.5f), 25.f, fmtMs);
    F ("decay", "Decay", NRange (0.1f, 20.f, 0.01f, 0.4f), 2.6f, fmtSec);
    F ("size", "Size", NRange (0.f, 1.f, 0.001f), 0.75f, fmtPct);
    F ("diffusion", "Diffusion", NRange (0.f, 1.f, 0.001f), 0.75f, fmtPct);
    F ("damping", "Damping", NRange (0.f, 1.f, 0.001f), 0.45f, fmtPct);
    F ("mod", "Modulation", NRange (0.f, 1.f, 0.001f), 0.35f, fmtPct);
    F ("width", "Width", NRange (0.f, 2.f, 0.001f), 1.f, fmtPct);
    F ("tone", "Tone", NRange (0.f, 1.f, 0.001f), 0.5f, fmtPct);
    F ("character", "Character", NRange (0.f, 1.f, 0.001f), 0.5f, fmtPct);
    F ("mix", "Mix", NRange (0.f, 1.f, 0.001f), 1.f, fmtPct);
    F ("output", "Output", NRange (-24.f, 12.f, 0.1f), 0.f, fmtDb);
    B ("freeze", "Freeze", false);
    B ("bypass", "Bypass", false);

    // EQ (default: post reverb, all five bands bypassed)
    B ("eqPost", "EQ Post", true);
    F ("hpFreq", "High Pass", NRange (20.f, 1000.f, 1.f, 0.4f), 80.f, fmtHz);
    F ("lpFreq", "Low Pass", NRange (2000.f, 20000.f, 1.f, 0.4f), 12000.f, fmtHz);
    B ("hpOn", "High Pass On", true);
    B ("lpOn", "Low Pass On", true);
    const float defF[5] = { 60.f, 250.f, 1200.f, 4000.f, 10000.f }, defQ[5] = { 1.2f, 1.f, 1.4f, 1.f, 1.1f };
    const char* bn[5] = { "LF", "LMF", "MF", "HMF", "HF" };
    for (int i = 0; i < 5; ++i)
    {
        const String n (i);
        layout.add (std::make_unique<AudioParameterFloat> (ParameterID { "g" + n, 1 }, String (bn[i]) + " Gain", NRange (-12.f, 12.f, 0.1f), 0.f, Attr().withStringFromValueFunction (fmtDb)));
        layout.add (std::make_unique<AudioParameterFloat> (ParameterID { "f" + n, 1 }, String (bn[i]) + " Freq", NRange (20.f, 20000.f, 1.f, 0.3f), defF[i], Attr().withStringFromValueFunction (fmtHz)));
        layout.add (std::make_unique<AudioParameterFloat> (ParameterID { "q" + n, 1 }, String (bn[i]) + " Q", NRange (0.3f, 8.f, 0.01f, 0.5f), defQ[i], Attr().withStringFromValueFunction (fmtQ)));
        layout.add (std::make_unique<AudioParameterBool> (ParameterID { "b" + n, 1 }, String (bn[i]) + " Bypass", true));
    }

    // Ducking
    B ("duckOn", "Duck On", false);
    layout.add (std::make_unique<AudioParameterChoice> (ParameterID { "duckSrc", 1 }, "Duck Source", StringArray { "INPUT", "SIDECHAIN" }, 0));
    F ("duckAmt", "Duck Amount", NRange (0.f, 24.f, 0.1f), 12.f, fmtDb);
    F ("duckThr", "Duck Threshold", NRange (-60.f, 0.f, 0.1f), -24.f, fmtDb);
    F ("duckRel", "Duck Release", NRange (20.f, 1500.f, 1.f, 0.5f), 300.f, fmtMs);
    return layout;
}

TempoReverbProcessor::TempoReverbProcessor()
    : AudioProcessor (BusesProperties()
                          .withInput ("Input", juce::AudioChannelSet::stereo(), true)
                          .withOutput ("Output", juce::AudioChannelSet::stereo(), true)
                          .withInput ("Sidechain", juce::AudioChannelSet::stereo(), false)),
      apvts (*this, nullptr, "STATE", createLayout())
{
}

bool TempoReverbProcessor::isBusesLayoutSupported (const BusesLayout& l) const
{
    if (l.getMainOutputChannelSet() != juce::AudioChannelSet::stereo()) return false;
    if (l.getMainInputChannelSet() != l.getMainOutputChannelSet()) return false;
    const auto sc = l.getChannelSet (true, 1);
    return sc.isDisabled() || sc == juce::AudioChannelSet::stereo();
}

void TempoReverbProcessor::prepareToPlay (double sampleRate, int samplesPerBlock)
{
    sr = sampleRate;
    engine.prepare (sampleRate, samplesPerBlock);
    const size_t n = (size_t) std::max (samplesPerBlock, 8192);
    dryL.assign (n, 0.f); dryR.assign (n, 0.f); wetL.assign (n, 0.f); wetR.assign (n, 0.f);
    for (auto* b : { &hp, &lp }) b->reset();
    for (auto& b : band) b.reset();
    envDet = grSmooth = 0.f; outSmooth = -90.f; fftIdx = 0;
}

void TempoReverbProcessor::updateEq()
{
    hpOn = get ("hpOn") > 0.5f; lpOn = get ("lpOn") > 0.5f;
    hp.c = bh::makeHP (sr, get ("hpFreq"));
    lp.c = bh::makeLP (sr, get ("lpFreq"));
    for (int i = 0; i < 5; ++i)
    {
        const juce::String n (i);
        bandOn[i] = get ("b" + n) < 0.5f && std::abs (get ("g" + n)) > 0.01f;
        band[i].c = bh::makePeak (sr, get ("f" + n), get ("q" + n), get ("g" + n));
    }
}

void TempoReverbProcessor::applyEq (float* l, float* r, int n)
{
    if (hpOn) for (int i = 0; i < n; ++i) { l[i] = hp.process (0, l[i]); r[i] = hp.process (1, r[i]); }
    if (lpOn) for (int i = 0; i < n; ++i) { l[i] = lp.process (0, l[i]); r[i] = lp.process (1, r[i]); }
    for (int b = 0; b < 5; ++b)
        if (bandOn[b]) for (int i = 0; i < n; ++i) { l[i] = band[b].process (0, l[i]); r[i] = band[b].process (1, r[i]); }
}

void TempoReverbProcessor::processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer&)
{
    juce::ScopedNoDenormals noDenormals;
    const int n = buffer.getNumSamples();
    auto main = getBusBuffer (buffer, true, 0);
    if (main.getNumChannels() < 2) return;

    // ---- host tempo
    double bpm = 120.0;
    if (auto* ph = getPlayHead())
        if (auto pos = ph->getPosition())
            if (auto b = pos->getBpm()) bpm = juce::jlimit (20.0, 400.0, *b);
    hostBpm.store ((float) bpm);

    if (get ("bypass") > 0.5f) return;

    if ((size_t) n > dryL.size()) { dryL.resize ((size_t) n); dryR.resize ((size_t) n); wetL.resize ((size_t) n); wetR.resize ((size_t) n); }

    // ---- parameters
    bh::Params p;
    p.type = (int) get ("type");
    const bool sync = get ("sync") > 0.5f;
    const double barMs = 240000.0 / bpm;
    p.predelayMs = sync ? (float) (bh::kNoteFrac[(int) get ("preNote")] * barMs) : get ("predelay");
    p.decay = sync ? (float) juce::jlimit (0.1, 20.0, bh::kNoteFrac[(int) get ("timeNote")] * barMs * 0.001) : get ("decay");
    p.size = get ("size"); p.diffusion = get ("diffusion"); p.damping = get ("damping"); p.mod = get ("mod");
    p.width = get ("width"); p.tone = get ("tone"); p.character = get ("character"); p.freeze = get ("freeze") > 0.5f;
    effPre.store (p.predelayMs); effDecay.store (p.decay);
    engine.setParams (p);
    updateEq();
    const bool eqPost = get ("eqPost") > 0.5f;

    // ---- copy dry, build wet input
    float* L = main.getWritePointer (0);
    float* R = main.getWritePointer (1);
    std::copy (L, L + n, dryL.begin()); std::copy (R, R + n, dryR.begin());
    std::copy (L, L + n, wetL.begin()); std::copy (R, R + n, wetR.begin());

    // ---- detector (input or sidechain)
    const bool duckOn = get ("duckOn") > 0.5f;
    const float *detL = dryL.data(), *detR = dryR.data();
    if (duckOn && (int) get ("duckSrc") == 1)
        if (auto* sb = getBus (true, 1))
            if (sb->isEnabled())
            {
                auto sc = getBusBuffer (buffer, true, 1);
                if (sc.getNumChannels() >= 1) { detL = sc.getReadPointer (0); detR = sc.getReadPointer (sc.getNumChannels() > 1 ? 1 : 0); }
            }

    if (! eqPost) applyEq (wetL.data(), wetR.data(), n);
    engine.process (wetL.data(), wetR.data(), n);
    if (eqPost) applyEq (wetL.data(), wetR.data(), n);

    // ---- ducking
    const float amount = get ("duckAmt"), thr = get ("duckThr"), rel = get ("duckRel");
    const float aEnvA = 1.f - std::exp (-1.f / (0.004f * (float) sr)), aEnvR = 1.f - std::exp (-1.f / (0.08f * (float) sr));
    const float aGrA = 1.f - std::exp (-1.f / (0.010f * (float) sr)), aGrR = 1.f - std::exp (-1.f / (rel * 0.001f * (float) sr));
    float grMax = 0.f;
    if (duckOn)
    {
        for (int i = 0; i < n; ++i)
        {
            const float x = std::max (std::abs (detL[i]), std::abs (detR[i]));
            envDet += (x - envDet) * (x > envDet ? aEnvA : aEnvR);
            const float envDb = 20.f * std::log10 (envDet + 1e-6f);
            const float target = amount * juce::jlimit (0.f, 1.f, (envDb - thr) / 10.f);
            grSmooth += (target - grSmooth) * (target > grSmooth ? aGrA : aGrR);
            const float g = bh::dbToLin (-grSmooth);
            wetL[(size_t) i] *= g; wetR[(size_t) i] *= g;
            grMax = std::max (grMax, grSmooth);
        }
    }
    else { grSmooth = 0.f; envDet = 0.f; }
    grDb.store (grSmooth);

    // ---- mix / output
    const float mix = get ("mix"), outG = bh::dbToLin (get ("output"));
    const float gd = std::cos (mix * 1.5707963f), gw = std::sin (mix * 1.5707963f) * outG;
    double sumSq = 0.0;
    for (int i = 0; i < n; ++i)
    {
        L[i] = dryL[(size_t) i] * gd * outG + wetL[(size_t) i] * gw * 1.0f;
        R[i] = dryR[(size_t) i] * gd * outG + wetR[(size_t) i] * gw * 1.0f;
        sumSq += 0.5 * ((double) L[i] * L[i] + (double) R[i] * R[i]);
        fftFifo[(size_t) fftIdx++] = 0.5f * (L[i] + R[i]);
        if (fftIdx >= fftSize) { fftSnapshot = fftFifo; fftReady.store (true); fftIdx = 0; }
    }
    outRmsDb.store (10.f * std::log10 ((float) (sumSq / (double) n) + 1e-12f));
}

juce::AudioProcessorEditor* TempoReverbProcessor::createEditor() { return new TempoReverbEditor (*this); }

void TempoReverbProcessor::getStateInformation (juce::MemoryBlock& dest)
{
    if (auto xml = apvts.copyState().createXml()) copyXmlToBinary (*xml, dest);
}
void TempoReverbProcessor::setStateInformation (const void* data, int size)
{
    if (auto xml = getXmlFromBinary (data, size))
        if (xml->hasTagName (apvts.state.getType())) apvts.replaceState (juce::ValueTree::fromXml (*xml));
}

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter() { return new TempoReverbProcessor(); }
