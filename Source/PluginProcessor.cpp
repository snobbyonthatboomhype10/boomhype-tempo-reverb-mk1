// BoomHype Tech - Tempo Reverb MK I
#include "PluginProcessor.h"
#include "PluginEditor.h"

using Attr = juce::AudioParameterFloatAttributes;
using NRange = juce::NormalisableRange<float>;

static juce::String fmtMs  (float v, int) { return juce::String (juce::roundToInt (v)) + " ms"; }
static juce::String fmtPct (float v, int) { return juce::String (juce::roundToInt (v * 100.f)) + "%"; }
static juce::String fmtDb  (float v, int) { return juce::String (v, 1) + " dB"; }
static juce::String fmtHz  (float v, int) { return v >= 1000.f ? juce::String (v / 1000.f, 2) + " kHz" : juce::String (juce::roundToInt (v)) + " Hz"; }
static juce::String fmtQ   (float v, int) { return "Q " + juce::String (v, 1); }
static juce::String fmtBpm (float v, int) { return juce::String (juce::roundToInt (v)) + " BPM"; }

static NRange logRange (float lo, float hi)
{
    return NRange (lo, hi,
                   [] (float s, float e, float v) { return s * std::pow (e / s, v); },
                   [] (float s, float e, float v) { return std::log (juce::jlimit (s, e, v) / s) / std::log (e / s); },
                   [] (float s, float e, float v) { return juce::jlimit (s, e, v); });
}

juce::AudioProcessorValueTreeState::ParameterLayout TempoReverbProcessor::createLayout()
{
    using namespace juce;
    AudioProcessorValueTreeState::ParameterLayout layout;
    auto F = [&] (const String& id, const String& name, NRange r, float def, String (*fmt) (float, int))
    {
        layout.add (std::make_unique<AudioParameterFloat> (ParameterID { id, 1 }, name, r, def, Attr().withStringFromValueFunction (fmt)));
    };
    auto B = [&] (const String& id, const String& name, bool def) { layout.add (std::make_unique<AudioParameterBool> (ParameterID { id, 1 }, name, def)); };

    StringArray types, notes, slopes { "OFF", "6", "12", "24" };
    for (int i = 0; i < bh::NumTypes; ++i) types.add (bh::kTypeNames[i]);
    for (int i = 0; i < bh::kNumPre; ++i) notes.add (bh::kPreNames[i]);
    StringArray tnotes;
    for (int i = 0; i < bh::kNumTime; ++i) tnotes.add (bh::kTimeNames[i]);

    layout.add (std::make_unique<AudioParameterChoice> (ParameterID { "type", 1 }, "Reverb Type", types, 0));
    B ("sync", "Tempo Sync", true);
    F ("bpm", "Manual Tempo", NRange (40.f, 240.f, 1.f), 120.f, fmtBpm);
    layout.add (std::make_unique<AudioParameterChoice> (ParameterID { "preNote", 1 }, "Pre-Delay Note", notes, 1));
    layout.add (std::make_unique<AudioParameterChoice> (ParameterID { "timeNote", 1 }, "Reverb Time Note", tnotes, 2));
    F ("preMs", "Pre-Delay", NRange (0.f, 250.f, 0.1f), 125.f, fmtMs);
    F ("timeMs", "Reverb Time", NRange (100.f, 16000.f, 1.f, 0.5f), 2000.f, fmtMs);

    F ("size", "Size", NRange (0.f, 1.f, 0.001f), 0.78f, fmtPct);
    F ("diffusion", "Diffusion", NRange (0.f, 1.f, 0.001f), 0.65f, fmtPct);
    F ("damping", "Damping", NRange (0.f, 1.f, 0.001f), 0.45f, fmtPct);
    F ("width", "Width", NRange (0.f, 1.f, 0.001f), 0.85f, fmtPct);
    F ("mod", "Modulation", NRange (0.f, 1.f, 0.001f), 0.40f, fmtPct);
    F ("tone", "Tone", NRange (0.f, 1.f, 0.001f), 0.55f, fmtPct);
    B ("modOn", "Mod On", true);
    B ("freeze", "Freeze", false);

    B ("duckOn", "Duck On", false);
    F ("duckAmt", "Duck Amount", NRange (0.f, 1.f, 0.001f), 0.5f, fmtPct);
    F ("duckSens", "Duck Sens", NRange (0.f, 1.f, 0.001f), 0.5f, fmtPct);
    F ("duckRel", "Duck Release", NRange (0.f, 500.f, 1.f), 150.f, fmtMs);

    F ("mix", "Mix", NRange (0.f, 1.f, 0.001f), 0.35f, fmtPct);
    F ("output", "Output", NRange (-12.f, 12.f, 0.1f), 0.f, fmtDb);
    F ("trim", "Input", NRange (-12.f, 12.f, 0.1f), 0.f, fmtDb);
    B ("bypass", "Bypass", false);

    B ("eqPost", "EQ Post", true);
    F ("hpF", "High Pass", logRange (20.f, 20000.f), 80.f, fmtHz);
    F ("lpF", "Low Pass", logRange (20.f, 20000.f), 12000.f, fmtHz);
    layout.add (std::make_unique<AudioParameterChoice> (ParameterID { "hpS", 1 }, "High Pass Slope", slopes, 2));
    layout.add (std::make_unique<AudioParameterChoice> (ParameterID { "lpS", 1 }, "Low Pass Slope", slopes, 2));

    const float defF[5] = { 60.f, 250.f, 1200.f, 4000.f, 10000.f }, defQ[5] = { 1.2f, 1.f, 1.4f, 1.f, 1.1f };
    const char* bn[5] = { "LF", "LMF", "MF", "HMF", "HF" };
    for (int i = 0; i < 5; ++i)
    {
        const String n (i), nm (bn[i]);
        F ("g" + n, nm + " Gain", NRange (-12.f, 12.f, 0.1f), 0.f, fmtDb);
        F ("f" + n, nm + " Freq", logRange (20.f, 20000.f), defF[i], fmtHz);
        F ("q" + n, nm + " Q", logRange (0.3f, 8.f), defQ[i], fmtQ);
        B ("b" + n, nm + " Bypass", true);
    }
    return layout;
}

TempoReverbProcessor::TempoReverbProcessor()
    : AudioProcessor (BusesProperties()
                          .withInput ("Input", juce::AudioChannelSet::stereo(), true)
                          .withOutput ("Output", juce::AudioChannelSet::stereo(), true)
                          .withInput ("Sidechain", juce::AudioChannelSet::stereo(), false)),
      apvts (*this, nullptr, "STATE", createLayout())
{
    abState[0] = apvts.copyState();
    abState[1] = apvts.copyState();
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
    hp.reset(); lp.reset();
    for (auto& b : band) b.reset();
    envDet = grSmooth = 0.f;
    mixSm.reset (sampleRate, 0.03); outSm.reset (sampleRate, 0.03); trimSm.reset (sampleRate, 0.03);
    mixSm.setCurrentAndTargetValue (get ("mix"));
    outSm.setCurrentAndTargetValue (bh::dbToLin (get ("output")));
    trimSm.setCurrentAndTargetValue (bh::dbToLin (get ("trim")));
}

void TempoReverbProcessor::updateEq()
{
    hp.set (sr, get ("hpF"), (int) get ("hpS"), true);
    lp.set (sr, get ("lpF"), (int) get ("lpS"), false);
    for (int i = 0; i < 5; ++i)
    {
        const juce::String n (i);
        bandOn[i] = get ("b" + n) < 0.5f && std::abs (get ("g" + n)) > 0.01f;
        band[i].c = bh::makePeak (sr, get ("f" + n), get ("q" + n), get ("g" + n));
    }
}

void TempoReverbProcessor::applyEq (float* l, float* r, int n, bool)
{
    if (hp.n > 0) for (int i = 0; i < n; ++i) { l[i] = hp.process (0, l[i]); r[i] = hp.process (1, r[i]); }
    if (lp.n > 0) for (int i = 0; i < n; ++i) { l[i] = lp.process (0, l[i]); r[i] = lp.process (1, r[i]); }
    for (int b = 0; b < 5; ++b)
        if (bandOn[b]) for (int i = 0; i < n; ++i) { l[i] = band[b].process (0, l[i]); r[i] = band[b].process (1, r[i]); }
}

static inline float softLimit (float x)
{
    const float a = std::abs (x);
    if (a < 0.8f) return x;
    const float y = 0.8f + 0.2f * std::tanh ((a - 0.8f) / 0.2f);
    return x < 0.f ? -y : y;
}

void TempoReverbProcessor::processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer&)
{
    juce::ScopedNoDenormals noDenormals;
    const int n = buffer.getNumSamples();
    auto main = getBusBuffer (buffer, true, 0);
    if (main.getNumChannels() < 2) return;

    // ---- tempo: host if it provides one, otherwise the manual tempo window
    double bpm = (double) get ("bpm"); bool host = false;
    if (auto* ph = getPlayHead())
        if (auto pos = ph->getPosition())
            if (auto b = pos->getBpm()) { bpm = juce::jlimit (20.0, 400.0, *b); host = true; }
    bpmEff.store ((float) bpm); hostHasBpm.store (host);

    float* L = main.getWritePointer (0);
    float* R = main.getWritePointer (1);

    auto pushScope = [&] (const float* a, const float* b, int count)
    {
        int w = scopeWrite.load();
        for (int i = 0; i < count; ++i) { scope[(size_t) w] = 0.5f * (a[i] + b[i]); w = (w + 1) & (scopeSize - 1); }
        scopeWrite.store (w);
    };

    if (get ("bypass") > 0.5f)
    {
        pushScope (L, R, n); grDb.store (0.f); outRmsDb.store (-90.f);
        return;
    }

    if ((size_t) n > dryL.size()) { dryL.resize ((size_t) n); dryR.resize ((size_t) n); wetL.resize ((size_t) n); wetR.resize ((size_t) n); }

    // ---- parameters
    bh::Params p;
    p.type = (int) get ("type");
    const bool sync = get ("sync") > 0.5f;
    const double barMs = 240000.0 / bpm;
    p.predelayMs = sync ? (float) (bh::kPreFrac[juce::jlimit (0, bh::kNumPre - 1, (int) get ("preNote"))] * barMs) : get ("preMs");
    p.predelayMs = juce::jlimit (0.f, 250.f, p.predelayMs);
    p.decay = sync ? (float) juce::jlimit (0.1, 32.0, bh::kTimeFrac[juce::jlimit (0, bh::kNumTime - 1, (int) get ("timeNote"))] * barMs * 0.001) : get ("timeMs") * 0.001f;
    p.size = get ("size"); p.diffusion = get ("diffusion"); p.damping = get ("damping");
    p.mod = get ("modOn") > 0.5f ? get ("mod") : 0.f;
    p.width = get ("width") * 1.3f; p.tone = get ("tone"); p.character = bh::kCharacter[p.type];
    p.freeze = get ("freeze") > 0.5f;
    effPre.store (p.predelayMs); effDecay.store (p.decay);
    engine.setParams (p);
    updateEq();
    const bool eqPost = get ("eqPost") > 0.5f;

    trimSm.setTargetValue (bh::dbToLin (get ("trim")));
    mixSm.setTargetValue (get ("mix"));
    outSm.setTargetValue (bh::dbToLin (get ("output")));
    float peakIn = 0.f;
    for (int i = 0; i < n; ++i)
    {
        const float t = trimSm.getNextValue();
        L[i] *= t; R[i] *= t;
        peakIn = std::max (peakIn, std::max (std::abs (L[i]), std::abs (R[i])));
    }
    inPeakDb.store (20.f * std::log10 (peakIn + 1e-6f));

    std::copy (L, L + n, dryL.begin()); std::copy (R, R + n, dryR.begin());
    std::copy (L, L + n, wetL.begin()); std::copy (R, R + n, wetR.begin());

    // ---- ducking detector: input signal, or the sidechain bus when one is connected
    const bool duckOn = get ("duckOn") > 0.5f;
    const float *detL = dryL.data(), *detR = dryR.data();
    if (duckOn)
        if (auto* sb = getBus (true, 1))
            if (sb->isEnabled())
            {
                auto sc = getBusBuffer (buffer, true, 1);
                if (sc.getNumChannels() >= 1) { detL = sc.getReadPointer (0); detR = sc.getReadPointer (sc.getNumChannels() > 1 ? 1 : 0); }
            }

    if (! eqPost) applyEq (wetL.data(), wetR.data(), n, false);
    engine.process (wetL.data(), wetR.data(), n);
    if (eqPost) applyEq (wetL.data(), wetR.data(), n, true);

    // ---- ducking
    const float amountDb = get ("duckAmt") * 24.f, thr = -10.f - get ("duckSens") * 50.f, rel = std::max (20.f, get ("duckRel"));
    const float aEnvA = 1.f - std::exp (-1.f / (0.004f * (float) sr)), aEnvR = 1.f - std::exp (-1.f / (0.08f * (float) sr));
    const float aGrA = 1.f - std::exp (-1.f / (0.010f * (float) sr)), aGrR = 1.f - std::exp (-1.f / (rel * 0.001f * (float) sr));
    if (duckOn)
    {
        for (int i = 0; i < n; ++i)
        {
            const float x = std::max (std::abs (detL[i]), std::abs (detR[i]));
            envDet += (x - envDet) * (x > envDet ? aEnvA : aEnvR);
            const float envDb = 20.f * std::log10 (envDet + 1e-6f);
            const float target = amountDb * juce::jlimit (0.f, 1.f, (envDb - thr) / 10.f);
            grSmooth += (target - grSmooth) * (target > grSmooth ? aGrA : aGrR);
            const float g = bh::dbToLin (-grSmooth);
            wetL[(size_t) i] *= g; wetR[(size_t) i] *= g;
        }
    }
    else { grSmooth = 0.f; envDet = 0.f; }
    grDb.store (grSmooth);

    // ---- mix / output
    double sumSq = 0.0;
    for (int i = 0; i < n; ++i)
    {
        const float m = mixSm.getNextValue(), o = outSm.getNextValue();
        const float gd = std::cos (m * 1.5707963f), gw = std::sin (m * 1.5707963f);
        L[i] = (dryL[(size_t) i] * gd + softLimit (wetL[(size_t) i]) * gw) * o;
        R[i] = (dryR[(size_t) i] * gd + softLimit (wetR[(size_t) i]) * gw) * o;
        sumSq += 0.5 * ((double) L[i] * L[i] + (double) R[i] * R[i]);
    }
    pushScope (L, R, n);
    outRmsDb.store (10.f * std::log10 ((float) (sumSq / (double) n) + 1e-12f));
}

juce::AudioProcessorEditor* TempoReverbProcessor::createEditor() { return new TempoReverbEditor (*this); }

void TempoReverbProcessor::abSwitch (int slot)
{
    slot = juce::jlimit (0, 1, slot);
    if (slot == abCurrent) return;
    abState[abCurrent] = apvts.copyState();
    abCurrent = slot;
    apvts.replaceState (abState[slot].createCopy());
}

void TempoReverbProcessor::getStateInformation (juce::MemoryBlock& dest)
{
    if (auto xml = apvts.copyState().createXml()) copyXmlToBinary (*xml, dest);
}
void TempoReverbProcessor::setStateInformation (const void* data, int size)
{
    if (auto xml = getXmlFromBinary (data, size))
        if (xml->hasTagName (apvts.state.getType()))
        {
            apvts.replaceState (juce::ValueTree::fromXml (*xml));
            abState[0] = abState[1] = apvts.copyState(); abCurrent = 0;
        }
}

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter() { return new TempoReverbProcessor(); }
