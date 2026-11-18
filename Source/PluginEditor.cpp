// BoomHype Tech - Tempo Reverb MK I  -  editor implementation
#include "PluginEditor.h"

using namespace juce;
using namespace ui;

//==============================================================================  presets (from the design)
namespace
{
struct Preset
{
    float size, diff, damp, width, mod, tone; int timeNote, pdNote; float timeMs, pdMs;
    float hpF; int hpS; float lpF; int lpS; float eq[5][3];
};
const Preset kPresets[8] = {
    /* HALL      */ { .78f, .65f, .45f, .85f, .40f, .55f, 8, 2, 2400, 125, 80.f, 2, 12000.f, 2, { { 60, .5f, 1.2f }, { 250, -.3f, 1.f }, { 1200, .2f, 1.4f }, { 4000, -.2f, 1.f }, { 10000, .3f, 1.1f } } },
    /* PLATE     */ { .45f, .90f, .30f, .75f, .50f, .65f, 7, 0, 1800, 60, 100.f, 2, 14000.f, 1, { { 80, .2f, 1.f }, { 300, -.1f, 1.2f }, { 1000, .4f, 1.6f }, { 3500, .3f, 1.2f }, { 9000, -.2f, 1.f } } },
    /* ROOM      */ { .30f, .55f, .55f, .60f, .30f, .50f, 6, 0, 550, 12, 120.f, 2, 11000.f, 2, { { 50, .3f, 1.f }, { 200, .1f, 1.f }, { 800, -.2f, 1.2f }, { 3000, .1f, 1.f }, { 12000, -.3f, 1.f } } },
    /* SPACE     */ { .95f, .70f, .25f, .95f, .60f, .70f, 8, 4, 5000, 250, 40.f, 1, 16000.f, 1, { { 40, .6f, 1.4f }, { 180, .2f, 1.f }, { 900, -.1f, 1.2f }, { 3800, .4f, 1.4f }, { 12000, .2f, 1.f } } },
    /* SPRING    */ { .20f, .40f, .60f, .45f, .80f, .40f, 7, 0, 1400, 12, 150.f, 3, 9000.f, 2, { { 100, .4f, 1.6f }, { 400, -.4f, 1.f }, { 1500, .5f, 2.f }, { 5000, -.3f, 1.f }, { 11000, .1f, 1.f } } },
    /* SHIMMER   */ { .88f, .75f, .20f, .90f, .70f, .80f, 8, 4, 4500, 250, 60.f, 2, 16000.f, 1, { { 50, .2f, 1.f }, { 250, .3f, 1.2f }, { 1200, .5f, 1.4f }, { 5000, .6f, 1.6f }, { 14000, .4f, 1.f } } },
    /* CATHEDRAL */ { .98f, .80f, .35f, .98f, .50f, .60f, 8, 3, 7000, 333, 35.f, 1, 13000.f, 2, { { 35, .7f, 1.4f }, { 150, .3f, 1.f }, { 700, -.2f, 1.2f }, { 2800, .2f, 1.2f }, { 10000, .5f, 1.f } } },
    /* LO-FI     */ { .55f, .50f, .75f, .50f, .60f, .25f, 6, 2, 800, 125, 180.f, 2, 6500.f, 3, { { 120, .2f, 1.f }, { 350, -.5f, 1.f }, { 900, .3f, 1.2f }, { 2500, -.6f, 1.f }, { 8000, -.4f, 1.f } } }
};

String fmtF (double f) { return f >= 1000.0 ? String (f / 1000.0, f >= 10000.0 ? 1 : 2) + "k" : String (roundToInt (f)) + "Hz"; }
String fmtG (double g) { return String (g >= 0.0 ? "+" : "") + String (g, 1) + "dB"; }
String fmtPct (double v) { return String (roundToInt (v * 100.0)) + "%"; }
String fmtMsS (double ms) { return ms >= 1000.0 ? String (ms / 1000.0, 2) + " s" : String (roundToInt (ms)) + " ms"; }
}

//==============================================================================
TempoReverbEditor::TempoReverbEditor (TempoReverbProcessor& p) : AudioProcessorEditor (&p), proc (p), eq (p)
{
    // ---- header
    place (tempoLcd, 1406, 12, 120, 44);
    addToggle ("SYNC", "sync", 1540, 16, 96, 36);
    abA = addToggle ("A", {}, 1650, 16, 62, 36, true, 15.5f); abB = addToggle ("B", {}, 1726, 16, 62, 36, true, 15.5f);
    abA->setClickingTogglesState (false); abB->setClickingTogglesState (false);
    abA->onClick = [this] { proc.abSwitch (0); }; abB->onClick = [this] { proc.abSwitch (1); };
    addToggle ("BYPASS", "bypass", 1802, 16, 122, 36);

    // ---- programs
    for (int i = 0; i < bh::NumTypes; ++i)
    {
        prog[(size_t) i] = addToggle (bh::kTypeNames[i], {}, 36.f + (float) i * 237.5f, 84, 225.5f, 44);
        prog[(size_t) i]->setClickingTogglesState (false);
        prog[(size_t) i]->onClick = [this, i] { selectProgram (i); };
    }

    // ---- spectrum
    place (eq, 40, 150, 1880, 196);
    eq.onActiveBand = [this] (int b) { activeBand = b; repaint(); };

    // ---- filters
    addKnob ("hpF", "HIGH PASS", ScFreq, CapGray, 78, [] (double v) { return fmtF (v); }, 40, 392);
    addKnob ("lpF", "LOW PASS", ScFreq, CapGray, 78, [] (double v) { return fmtF (v); }, 1842, 392);
    place (hpChips, 128, 424, 130, 30); place (lpChips, 1696, 424, 130, 30);
    hpChips.onSelect = [this] (int i) { setP ("hpS", (float) i); };
    lpChips.onSelect = [this] (int i) { setP ("lpS", (float) i); };

    static const char* bandName[5] = { "LF", "LMF", "MF", "HMF", "HF" };
    static const Cap bandCap[5] = { CapBlue, CapGreen, CapYellow, CapOrange, CapRed };
    for (int i = 0; i < 5; ++i)
    {
        const float x0 = 285.f + (float) i * 282.f; const String n (i);
        bandByp[(size_t) i] = addToggle ("BYP", "b" + n, x0 + 128.f, 364, 88, 30, true, 13.f);
        gainK[(size_t) i] = addKnob ("g" + n, "GAIN", ScDb, bandCap[i], 78, [] (double v) { return fmtG (v); }, x0, 398);
        freqK[(size_t) i] = addKnob ("f" + n, "FREQ", ScFreq, bandCap[i], 78, [] (double v) { return fmtF (v); }, x0 + 92.f, 398);
        qK[(size_t) i] = addKnob ("q" + n, "Q", ScQ, bandCap[i], 78, [] (double v) { return "Q" + String (v, 1); }, x0 + 184.f, 398);
        (void) bandName;
    }

    // ---- tempo panel
    for (int i = 0; i < bh::kNumTimeNotes; ++i)          // reverb time: 12 keys (1/32 ... 4 BAR)
    {
        const float cx = 49.f + (float) (i % 3) * 77.7f, ry = (float) (i / 3) * 45.f;
        keyStore[(size_t) i] = std::make_unique<NoteKey> (bh::kTimeNames[i]); timeKeys[(size_t) i] = keyStore[(size_t) i].get();
        place (*timeKeys[(size_t) i], cx, 630.f + ry, 72.7f, 38);
        timeKeys[(size_t) i]->onClick = [this, i] { setP ("timeNote", (float) i); };
    }
    for (int i = 0; i < 9; ++i)                           // pre-delay: 9 keys
    {
        const float cx = 49.f + (float) (i % 3) * 77.7f, ry = (float) (i / 3) * 45.f;
        keyStore[(size_t) (12 + i)] = std::make_unique<NoteKey> (bh::kNoteNames[i]); pdKeys[(size_t) i] = keyStore[(size_t) (12 + i)].get();
        place (*pdKeys[(size_t) i], cx, 903.f + ry, 72.7f, 38);
        pdKeys[(size_t) i]->onClick = [this, i] { setP ("preNote", (float) i); };
    }
    place (timeLcd, 49, 813, 228, 36); place (pdLcd, 49, 1041, 228, 36);

    // ---- character
    {
        const char* ids[6] = { "size", "diffusion", "damping", "width", "mod", "tone" };
        const char* lb[6] = { "SIZE", "DIFFUSION", "DAMPING", "WIDTH", "MOD", "TONE" };
        for (int i = 0; i < 6; ++i)
        {
            auto* k = addKnob (ids[i], lb[i], ScPct, CapGray, 108, [] (double v) { return fmtPct (v); }, 316.f + (float) (i % 3) * 124.f, 606.f + (float) (i / 3) * 150.f);
            if (i == 4) modK = k;
        }
    }

    // ---- centre panel
    place (prePost, 775, 650, 140, 30);
    prePost.onSelect = [this] (int i) { setP ("eqPost", i == 1 ? 1.f : 0.f); };
    addToggle ("MOD", "modOn", 722, 766, 120, 36); addToggle ("FREEZE", "freeze", 848, 766, 120, 36); addToggle ("DUCK", "duckOn", 785, 812, 120, 36);

    // ---- ducking
    place (grMeter, 1060, 626, 340, 176);
    duckAmtK = addKnob ("duckAmt", "AMOUNT", ScPct, CapGray, 96, [] (double v) { return fmtPct (v); }, 1064, 808);
    duckSensK = addKnob ("duckSens", "SENS", ScPct, CapGray, 96, [] (double v) { return fmtPct (v); }, 1182, 808);
    duckRelK = addKnob ("duckRel", "RELEASE", ScMs, CapGray, 96, [] (double v) { return String (roundToInt (v)) + "ms"; }, 1300, 808);

    // ---- output
    place (outMeter, 1526, 626, 340, 176);
    addKnob ("mix", "MIX", ScPct, CapGray, 124, [] (double v) { return fmtPct (v); }, 1564, 808);
    addKnob ("output", "OUTPUT", ScDb, CapGray, 124, [] (double v) { return fmtG (v); }, 1704, 808);
    addKnob ("trim", "INPUT", ScDb, CapGray, 84, [] (double v) { return fmtG (v); }, 1654, 972);

    // ---- LCD behaviour
    tempoLcd.getEditText = [this] { return String (roundToInt (proc.bpmEff.load())); };
    tempoLcd.onEdited = [this] (const String& t) { if (! proc.hostHasBpm.load()) setP ("bpm", jlimit (40.f, 240.f, t.getFloatValue())); };
    tempoLcd.onDragBegin = [this] { dragStartVal = proc.get ("bpm"); if (auto* pr = proc.apvts.getParameter ("bpm")) pr->beginChangeGesture(); };
    tempoLcd.onDragDelta = [this] (float d) { setP ("bpm", jlimit (40.f, 240.f, std::round (dragStartVal + d * 0.25f))); };
    tempoLcd.onDragEnd = [this] { if (auto* pr = proc.apvts.getParameter ("bpm")) pr->endChangeGesture(); };

    timeLcd.getEditText = [this] { return String (roundToInt (proc.get ("timeMs"))); };
    timeLcd.onEdited = [this] (const String& t) { setP ("timeMs", jlimit (100.f, 16000.f, t.getFloatValue())); };
    timeLcd.onDragBegin = [this] { dragStartVal = proc.get ("timeMs"); if (auto* pr = proc.apvts.getParameter ("timeMs")) pr->beginChangeGesture(); };
    timeLcd.onDragDelta = [this] (float d) { setP ("timeMs", jlimit (100.f, 16000.f, dragStartVal + d * 16.f)); };
    timeLcd.onDragEnd = [this] { if (auto* pr = proc.apvts.getParameter ("timeMs")) pr->endChangeGesture(); };
    pdLcd.getEditText = [this] { return String (roundToInt (proc.get ("preMs"))); };
    pdLcd.onEdited = [this] (const String& t) { setP ("preMs", jlimit (0.f, 250.f, t.getFloatValue())); };
    pdLcd.onDragBegin = [this] { dragStartVal = proc.get ("preMs"); if (auto* pr = proc.apvts.getParameter ("preMs")) pr->beginChangeGesture(); };
    pdLcd.onDragDelta = [this] (float d) { setP ("preMs", jlimit (0.f, 250.f, dragStartVal + d)); };
    pdLcd.onDragEnd = [this] { if (auto* pr = proc.apvts.getParameter ("preMs")) pr->endChangeGesture(); };

    setResizable (true, true);
    setResizeLimits (700, 418, 2800, 1672);
    if (auto* c = getConstrainer()) c->setFixedAspectRatio ((double) DW / (double) DH);
    setSize (1400, (int) (1400.f * DH / DW));
    startTimerHz (60);
}

TempoReverbEditor::~TempoReverbEditor() { stopTimer(); }

void TempoReverbEditor::place (Component& c, float x, float y, float w, float h)
{
    addAndMakeVisible (c); placed.push_back ({ &c, { x, y, w, h } });
}

KnobComp* TempoReverbEditor::addKnob (const String& id, const String& label, ScaleKind kind, Cap cap, float size, std::function<String (double)> fmt, float x, float y)
{
    auto k = std::make_unique<KnobComp> (label, kind, cap, size, std::move (fmt));
    sAtt.push_back (std::make_unique<SA> (proc.apvts, id, *k));
    if (auto* par = proc.apvts.getParameter (id)) k->setDoubleClickReturnValue (true, (double) par->convertFrom0to1 (par->getDefaultValue()));
    place (*k, x, y, size, KnobComp::cellH (size));
    knobs.push_back (std::move (k));
    return knobs.back().get();
}

BellButton* TempoReverbEditor::addToggle (const String& text, const String& paramId, float x, float y, float w, float h, bool jewel, float fpx)
{
    auto b = std::make_unique<BellButton> (text, jewel, fpx);
    b->setClickingTogglesState (true);
    if (paramId.isNotEmpty()) bAtt.push_back (std::make_unique<BA> (proc.apvts, paramId, *b));
    place (*b, x, y, w, h);
    bells.push_back (std::move (b));
    return bells.back().get();
}

void TempoReverbEditor::setP (const String& id, float plain)
{
    if (auto* p = proc.apvts.getParameter (id)) p->setValueNotifyingHost (p->convertTo0to1 (plain));
}

void TempoReverbEditor::selectProgram (int t)
{
    const auto& p = kPresets[jlimit (0, 7, t)];
    setP ("type", (float) t);
    setP ("size", p.size); setP ("diffusion", p.diff); setP ("damping", p.damp); setP ("width", p.width); setP ("mod", p.mod); setP ("tone", p.tone);
    setP ("timeNote", (float) p.timeNote); setP ("preNote", (float) p.pdNote); setP ("timeMs", p.timeMs); setP ("preMs", p.pdMs);
    setP ("hpF", p.hpF); setP ("hpS", (float) p.hpS); setP ("lpF", p.lpF); setP ("lpS", (float) p.lpS);
    for (int i = 0; i < 5; ++i)
    {
        const String n (i);
        setP ("f" + n, p.eq[i][0]); setP ("g" + n, p.eq[i][1]); setP ("q" + n, p.eq[i][2]); setP ("b" + n, 1.f);
    }
    activeBand = 0; eq.activeBand = 0;
}

void TempoReverbEditor::applySkin()
{
    for (auto& k : knobs) k->skinType = lastType;
    for (auto& b : bells) b->skinType = lastType;
    for (auto& k : keyStore) if (k) k->skinType = lastType;
    hpChips.skinType = lpChips.skinType = prePost.skinType = lastType;
    tempoLcd.skinType = timeLcd.skinType = pdLcd.skinType = lastType;
    grMeter.skinType = outMeter.skinType = lastType; eq.skinType = lastType;
    bg = Image();
    repaint();
}

//==============================================================================
void TempoReverbEditor::resized()
{
    sc = (float) getWidth() / DW;
    for (auto& p : placed)
        p.c->setBounds (Rectangle<int> (roundToInt (p.r.getX() * sc), roundToInt (p.r.getY() * sc), roundToInt (p.r.getWidth() * sc), roundToInt (p.r.getHeight() * sc)));
    bg = Image();
}

void TempoReverbEditor::timerCallback()
{
    const int t = jlimit (0, 7, (int) proc.get ("type"));
    if (t != lastType) { lastType = t; applySkin(); }
    for (int i = 0; i < 8; ++i) prog[(size_t) i]->setToggleState (i == t, dontSendNotification);
    abA->setToggleState (proc.abSlot() == 0, dontSendNotification); abB->setToggleState (proc.abSlot() == 1, dontSendNotification);

    const bool sync = proc.get ("sync") > 0.5f, host = proc.hostHasBpm.load();
    const int tn = (int) proc.get ("timeNote"), pn = (int) proc.get ("preNote");
    for (int i = 0; i < bh::kNumTimeNotes; ++i) { timeKeys[(size_t) i]->setToggleState (i == tn, dontSendNotification); timeKeys[(size_t) i]->setEnabled (sync); }
    for (int i = 0; i < 9; ++i) { pdKeys[(size_t) i]->setToggleState (i == pn, dontSendNotification); pdKeys[(size_t) i]->setEnabled (sync); }
    hpChips.setSelected ((int) proc.get ("hpS")); lpChips.setSelected ((int) proc.get ("lpS")); prePost.setSelected (proc.get ("eqPost") > 0.5f ? 1 : 0);

    // readouts
    const float bpm = proc.bpmEff.load();
    tempoLcd.set (host ? "HOST" : "TEMPO", String (roundToInt (bpm)), {}); tempoLcd.draggable = ! host; tempoLcd.editable = ! host;
    if (sync)
    {
        timeLcd.set ({}, bh::kTimeNames[tn], fmtMsS (proc.effDecay.load() * 1000.0)); pdLcd.set ({}, bh::kNoteNames[pn], fmtMsS (proc.effPre.load()));
    }
    else
    {
        timeLcd.set ({}, String (roundToInt (proc.get ("timeMs"))), "ms"); pdLcd.set ({}, String (roundToInt (proc.get ("preMs"))), "ms");
    }
    timeLcd.draggable = pdLcd.draggable = ! sync; timeLcd.editable = pdLcd.editable = ! sync;

    // dim states (greyed knobs when their section is off)
    auto setDim = [] (KnobComp* k, bool d) { if (k->dimmed != d) { k->dimmed = d; k->repaint(); } };
    setDim (modK, proc.get ("modOn") < 0.5f);
    const bool duck = proc.get ("duckOn") > 0.5f;
    setDim (duckAmtK, ! duck); setDim (duckSensK, ! duck); setDim (duckRelK, ! duck);
    for (int i = 0; i < 5; ++i) { const bool byp = proc.get ("b" + String (i)) > 0.5f; setDim (gainK[(size_t) i], byp); setDim (freqK[(size_t) i], byp); setDim (qK[(size_t) i], byp); }

    // meters
    grMeter.setLevel (proc.grDb.load());
    outMeter.setLevel (proc.outRmsDb.load() + 18.f);
    grMeter.tick(); outMeter.tick(); eq.tick();
    auto rr = [this] (float x, float y, float w, float h) { return Rectangle<int> (roundToInt (x * sc), roundToInt (y * sc), roundToInt (w * sc) + 1, roundToInt (h * sc) + 1); };
    repaint (rr (1240.f, 588.f, 680.f, 34.f));      // VU value tags
    repaint (rr (700.f, 690.f, 290.f, 60.f));        // band read-out
    repaint (rr (1060.f, 1048.f, 380.f, 20.f));      // duck activity bar
    repaint (rr (36.f, 1110.f, 1888.f, 58.f));       // footer LEDs + display
}

//==============================================================================  static artwork
void TempoReverbEditor::drawStatic (Graphics& g)
{
    const auto& sk = skinFor (jmax (0, lastType));
    const float W = DW, H = DH;
    ColourGradient grad (sk.p1, 0.f, 0.f, sk.p3, 0.f, H, false); grad.addColour (0.55, sk.p2);
    g.setGradientFill (grad); g.fillRect (0.f, 0.f, W, H);

    Random rnd (11);                                                 // brushed grain
    for (float y = 0.f; y < H; y += 1.f)
        for (int s = 0; s < 4; ++s)
        {
            const float x0 = rnd.nextFloat() * W, len = 120.f + rnd.nextFloat() * 700.f;
            g.setColour ((rnd.nextBool() ? Colours::white : Colours::black).withAlpha (rnd.nextFloat() * 0.07f));
            g.fillRect (x0, y, len, 1.f);
        }
    ColourGradient sh (Colours::transparentWhite, W * 0.12f, 0.f, Colours::transparentWhite, W * 0.62f, 0.f, false);
    sh.addColour (0.5, Colours::white.withAlpha (sk.sheen * 0.8f)); g.setGradientFill (sh); g.fillRect (0.f, 0.f, W, H);
    ColourGradient vs (Colours::white.withAlpha (0.09f), 0.f, 0.f, Colours::black.withAlpha (0.28f), 0.f, H, false);
    vs.addColour (0.09, Colours::transparentBlack); vs.addColour (0.88, Colours::transparentBlack); g.setGradientFill (vs); g.fillRect (0.f, 0.f, W, H);
    g.setColour (Colours::white.withAlpha (0.34f)); g.drawHorizontalLine (1, 0.f, W);
    g.setColour (Colours::black.withAlpha (0.9f)); g.drawRect (0.f, 0.f, W, H, 1.5f);

    // screws
    auto screw = [&] (float cx, float cy, float rot)
    {
        const float r = 9.5f;
        g.setColour (Colours::black.withAlpha (0.55f)); g.fillEllipse (cx - r - 2.f, cy - r, (r + 2.f) * 2.f, (r + 2.f) * 2.f + 3.f);
        ColourGradient sg (Colour (0xfffbfcfd), cx - r * 0.3f, cy - r * 0.44f, Colour (0xff14161a), cx + r, cy + r, true);
        sg.addColour (0.22, Colour (0xffaeb3bb)); sg.addColour (0.52, Colour (0xff6e737b)); sg.addColour (0.82, Colour (0xff2c2f35));
        g.setGradientFill (sg); g.fillEllipse (cx - r, cy - r, r * 2.f, r * 2.f);
        g.setColour (Colours::white.withAlpha (0.13f)); g.drawEllipse (cx - r - 1.f, cy - r - 1.f, (r + 1.f) * 2.f, (r + 1.f) * 2.f, 1.f);
        Graphics::ScopedSaveState ss (g); g.addTransform (AffineTransform::rotation (degreesToRadians (rot), cx, cy));
        g.setColour (Colour (0xff0b0c10)); g.fillRoundedRectangle (cx - 5.5f, cy - 1.3f, 11.f, 2.6f, 1.f); g.fillRoundedRectangle (cx - 1.3f, cy - 5.5f, 2.6f, 11.f, 1.f);
    };
    screw (20.5f, 20.5f, 18.f); screw (W - 20.5f, 20.5f, 64.f); screw (20.5f, H - 20.5f, -32.f); screw (W - 20.5f, H - 20.5f, 41.f);
    screw (20.5f, H * 0.5f, 52.f); screw (W - 20.5f, H * 0.5f, -12.f); screw (W * 0.5f, 20.5f, 33.f);

    auto line = [&] (float y) { g.setColour (Colours::black.withAlpha (0.6f)); g.drawHorizontalLine ((int) y + 1, 36.f, W - 36.f); g.setColour (sk.silk.withAlpha (0.16f)); g.drawHorizontalLine ((int) y, 36.f, W - 36.f); };
    line (68.f); line (136.f); line (528.f); line (1108.f);

    // brand
    {
        g.setFont (bhFont (28.f, 3)); g.setColour (Colours::black.withAlpha (0.8f)); g.drawText ("Boom", Rectangle<float> (40.f, 15.f, 120.f, 40.f), Justification::centredLeft, false);
        g.setColour (sk.silk); g.drawText ("Boom", Rectangle<float> (40.f, 14.f, 120.f, 40.f), Justification::centredLeft, false);
        const float bw = bhFont (28.f, 3).getStringWidthFloat ("Boom");
        g.setColour (sk.brand); g.drawText ("Hype", Rectangle<float> (40.f + bw, 14.f, 120.f, 40.f), Justification::centredLeft, false);
        g.setFont (bhFont (14.f, 1, 0.15f)); g.setColour (sk.dim);
        g.drawText ("TECH  -  TEMPO REVERB  -  MK I", Rectangle<float> (40.f + bw + 124.f, 14.f, 520.f, 40.f), Justification::centredLeft, false);
    }

    // display bezel
    {
        Rectangle<float> r (40.f, 150.f, 1880.f, 196.f);
        g.setColour (Colour (0xff08090b)); g.drawRoundedRectangle (r.expanded (3.f), 6.f, 3.f);
        g.setColour (Colours::white.withAlpha (0.2f)); g.drawRoundedRectangle (r.expanded (4.5f), 7.f, 1.f);
        g.setColour (Colours::black); g.drawRoundedRectangle (r.expanded (5.5f), 8.f, 1.f);
    }

    // eq strip labels
    g.setFont (bhFont (13.f, 2, 0.12f)); g.setColour (sk.dim);
    g.drawText ("SLOPE", Rectangle<float> (128.f, 400.f, 100.f, 20.f), Justification::centredLeft, false);
    g.drawText ("SLOPE", Rectangle<float> (1726.f, 400.f, 100.f, 20.f), Justification::centredRight, false);
    static const char* bn[5] = { "LF", "LMF", "MF", "HMF", "HF" }; static const Cap bc[5] = { CapBlue, CapGreen, CapYellow, CapOrange, CapRed };
    for (int i = 0; i < 5; ++i)
    {
        const float x0 = 285.f + (float) i * 282.f;
        const auto c = sk.caps[bc[i]];
        g.setColour (Colours::black.withAlpha (0.5f)); g.fillEllipse (x0 + 48.f, 372.f, 16.f, 16.f);
        g.setColour (c); g.fillEllipse (x0 + 48.f, 371.f, 16.f, 16.f);
        g.setFont (bhFont (18.f, 2, 0.13f)); g.setColour (Colours::black.withAlpha (0.7f)); g.drawText (bn[i], Rectangle<float> (x0 + 71.f, 366.f, 60.f, 26.f), Justification::centredLeft, false);
        g.setColour (sk.silk); g.drawText (bn[i], Rectangle<float> (x0 + 71.f, 365.f, 60.f, 26.f), Justification::centredLeft, false);
    }

    // panels
    struct PanelDef { float x, w; const char* title; };
    static const PanelDef panels[5] = { { 38.f, 250.f, "Tempo" }, { 302.f, 384.f, "Character" }, { 700.f, 290.f, "" }, { 1004.f, 452.f, "Ducking" }, { 1470.f, 452.f, "Output" } };
    const float py = 546.f, ph = 554.f;
    for (auto& p : panels)
    {
        Rectangle<float> r (p.x, py, p.w, ph);
        ColourGradient pg (Colours::white.withAlpha (0.02f), 0.f, py, Colours::black.withAlpha (0.22f), 0.f, py + ph, false);
        g.setGradientFill (pg); g.fillRoundedRectangle (r, 4.f);
        g.setColour (Colours::black.withAlpha (0.4f)); g.drawRoundedRectangle (r, 4.f, 1.f);
        g.setColour (Colours::white.withAlpha (0.06f)); g.drawHorizontalLine ((int) py + 1, p.x + 4.f, p.x + p.w - 4.f);
        if (String (p.title).isNotEmpty())
        {
            g.setFont (bhFont (19.f, 2, 0.12f)); g.setColour (Colours::black.withAlpha (0.7f));
            g.drawText (String (p.title).toUpperCase(), Rectangle<float> (p.x, py + 11.f, p.w, 28.f), Justification::centred, false);
            g.setColour (sk.silk); g.drawText (String (p.title).toUpperCase(), Rectangle<float> (p.x, py + 10.f, p.w, 28.f), Justification::centred, false);
            g.setColour (sk.silk.withAlpha (0.7f)); g.fillRect (p.x + p.w * 0.5f - 15.f, py + 42.f, 30.f, 1.5f);
        }
    }
    // engraved curved dividers
    for (int i = 0; i < 4; ++i)
    {
        const float x = panels[i].x + panels[i].w + 7.f;
        auto curve = [&] (float dx, Colour c, float w) { Path p; p.startNewSubPath (x + dx, py + 4.f); p.cubicTo (x + dx + 26.f, py + ph * 0.28f, x + dx - 26.f, py + ph * 0.62f, x + dx, py + ph - 4.f); g.setColour (c); g.strokePath (p, PathStrokeType (w)); };
        curve (1.6f, Colours::black.withAlpha (0.75f), 2.2f); curve (0.f, sk.silk.withAlpha (0.78f), 1.5f);
    }
    g.setFont (bhFont (14.f, 2, 0.1f)); g.setColour (sk.silk);
    g.drawText ("REVERB TIME", Rectangle<float> (38.f, 588.f, 250.f, 22.f), Justification::centred, false);
    g.drawText ("PRE-DELAY", Rectangle<float> (38.f, 861.f, 250.f, 22.f), Justification::centred, false);
    g.setFont (bhFont (14.5f, 2, 0.1f));
    g.drawText ("GAIN REDUCTION", Rectangle<float> (1020.f, 594.f, 250.f, 22.f), Justification::centredLeft, false);
    g.drawText ("OUTPUT LEVEL", Rectangle<float> (1486.f, 594.f, 250.f, 22.f), Justification::centredLeft, false);

    // centre panel art
    {
        const float cx = 700.f + 145.f;
        g.setFont (bhFont (31.f, 3)); g.setColour (Colours::black.withAlpha (0.7f)); g.drawText ("BoomHype", Rectangle<float> (700.f, 562.f, 290.f, 46.f), Justification::centred, false);
        g.setColour (sk.silk); g.drawText ("BoomHype", Rectangle<float> (700.f, 560.f, 290.f, 46.f), Justification::centred, false);
        g.setFont (bhFont (13.f, 2, 0.14f)); g.setColour (sk.dim); g.drawText ("TECH  -  TEMPO REVERB  -  MK I", Rectangle<float> (700.f, 608.f, 290.f, 20.f), Justification::centred, false);
        for (float y : { 638.f, 746.f, 862.f }) { g.setColour (sk.silk.withAlpha (0.55f)); g.fillRect (cx - 113.f, y, 226.f, 1.5f); }
        g.setFont (bhFont (13.f, 2, 0.09f)); g.setColour (sk.dim);
        g.drawText ("DRAG BANDS - SCROLL = Q", Rectangle<float> (700.f, 876.f, 290.f, 20.f), Justification::centred, false);
        g.drawText ("DOUBLE-CLICK A BAND = RESET GAIN", Rectangle<float> (700.f, 896.f, 290.f, 20.f), Justification::centred, false);
    }
    // footer labels
    g.setFont (bhFont (14.f, 2, 0.09f)); g.setColour (sk.dim);
    g.drawText ("IN", Rectangle<float> (74.f, 1126.f, 50.f, 22.f), Justification::centredLeft, false);
    g.drawText ("OUT", Rectangle<float> (166.f, 1126.f, 50.f, 22.f), Justification::centredLeft, false);
    g.drawText ("SYNC", Rectangle<float> (270.f, 1126.f, 60.f, 22.f), Justification::centredLeft, false);
    g.drawText ("v1.0.0", Rectangle<float> (1600.f, 1126.f, 120.f, 22.f), Justification::centredRight, false);
    g.setColour (sk.accent); g.drawText ("BoomHype Tech", Rectangle<float> (1730.f, 1126.f, 190.f, 22.f), Justification::centredRight, false);
    g.setColour (sk.dim); g.drawText ("ACT", Rectangle<float> (1020.f, 1048.f, 50.f, 20.f), Justification::centredLeft, false);
}

void TempoReverbEditor::rebuildBackground()
{
    const float ss = jlimit (1.f, 2.f, 2400.f / (float) jmax (1, getWidth()));
    const int w = roundToInt ((float) getWidth() * ss), h = roundToInt ((float) getHeight() * ss);
    if (w < 8 || h < 8) return;
    bg = Image (Image::ARGB, w, h, true);
    Graphics ig (bg);
    ig.addTransform (AffineTransform::scale ((float) w / DW, (float) h / DH));
    drawStatic (ig);
}

//==============================================================================  dynamic artwork
void TempoReverbEditor::paint (Graphics& g)
{
    if (lastType < 0) lastType = jlimit (0, 7, (int) proc.get ("type"));
    if (bg.isNull()) rebuildBackground();
    if (bg.isValid()) g.drawImage (bg, getLocalBounds().toFloat());
    const auto& sk = skinFor (lastType);
    Graphics::ScopedSaveState ss (g);
    g.addTransform (AffineTransform::scale (sc));

    // VU value tags
    g.setFont (bhFont (17.f, 1)); g.setColour (sk.accent);
    g.drawText (String ("-") + String (proc.grDb.load(), 1) + " dB", Rectangle<float> (1250.f, 592.f, 190.f, 26.f), Justification::centredRight, false);
    const float lv = proc.outRmsDb.load() + 18.f;
    g.drawText (lv < -19.9f ? String ("-inf dB") : String (lv >= 0.f ? "+" : "") + String (lv, 1) + " dB", Rectangle<float> (1716.f, 592.f, 190.f, 26.f), Justification::centredRight, false);

    // band read-out (centre panel)
    {
        static const char* bn[5] = { "LF", "LMF", "MF", "HMF", "HF" }; static const Cap bc[5] = { CapBlue, CapGreen, CapYellow, CapOrange, CapRed };
        const String n (jlimit (0, 4, activeBand));
        const bool byp = proc.get ("b" + n) > 0.5f;
        g.setColour (sk.caps[bc[jlimit (0, 4, activeBand)]]); g.fillEllipse (738.f, 713.f, 12.f, 12.f);
        g.setFont (bhFont (16.f, 1, 0.04f)); g.setColour (sk.silk);
        g.drawText (String (bn[jlimit (0, 4, activeBand)]) + "  " + fmtF (proc.get ("f" + n)) + (byp ? "  BYP" : ""), Rectangle<float> (758.f, 698.f, 222.f, 22.f), Justification::centredLeft, false);
        g.drawText (fmtG (proc.get ("g" + n)) + "  Q" + String (proc.get ("q" + n), 1), Rectangle<float> (758.f, 720.f, 222.f, 22.f), Justification::centredLeft, false);
    }
    // duck activity
    {
        Rectangle<float> r (1064.f, 1055.f, 372.f, 6.f);
        g.setGradientFill (ColourGradient (Colour (0xff08090c), 0.f, r.getY(), Colour (0xff14161b), 0.f, r.getBottom(), false)); g.fillRoundedRectangle (r, 3.f);
        const float a = proc.get ("duckOn") > 0.5f ? jlimit (0.f, 1.f, proc.grDb.load() / 18.f) : 0.f;
        if (a > 0.f) { g.setGradientFill (ColourGradient (Colour (0xffe07a20), r.getX(), 0.f, Colour (0xffffc46a), r.getRight(), 0.f, false)); g.fillRoundedRectangle (r.withWidth (r.getWidth() * a), 3.f); }
    }
    // LEDs + mini display
    auto led = [&] (float cx, float cy, bool lit)
    {
        g.setColour (Colour (0xff8e929a)); g.fillEllipse (cx - 7.f, cy - 7.f, 14.f, 14.f);
        g.setColour (Colour (0xff111111)); g.fillEllipse (cx - 6.f, cy - 6.f, 12.f, 12.f);
        if (lit) { g.setColour (Colour (0x2646e07e)); g.fillEllipse (cx - 11.f, cy - 11.f, 22.f, 22.f); }
        g.setColour (lit ? Colour (0xff46e07e) : Colour (0xff2a2d33)); g.fillEllipse (cx - 5.f, cy - 5.f, 10.f, 10.f);
    };
    const bool byp = proc.get ("bypass") > 0.5f;
    led (60.f, 1137.f, ! byp && proc.inPeakDb.load() > -50.f); led (152.f, 1137.f, ! byp && proc.get ("mix") > 0.02f); led (256.f, 1137.f, proc.get ("sync") > 0.5f);
    {
        Rectangle<float> r (780.f, 1120.f, 400.f, 34.f);
        g.setGradientFill (ColourGradient (Colour (0xff08090c), 0.f, r.getY(), Colour (0xff040507), 0.f, r.getBottom(), false)); g.fillRoundedRectangle (r, 3.f);
        g.setColour (Colours::black); g.drawRoundedRectangle (r, 3.f, 1.f);
        const int t = jlimit (0, 7, lastType); const bool sync = proc.get ("sync") > 0.5f;
        String txt = String (bh::kTypeNames[t]);
        if (byp) txt = "BYPASSED";
        else if (proc.get ("freeze") > 0.5f) txt += "  |  FREEZE";
        else txt += "  |  " + (sync ? String (bh::kTimeNames[(int) proc.get ("timeNote")]) : fmtMsS (proc.get ("timeMs"))) + "  |  " + String (roundToInt (proc.bpmEff.load())) + " BPM";
        g.setFont (bhFont (17.f, 1, 0.08f)); g.setColour (sk.accent.withAlpha (0.25f)); g.drawText (txt, r.translated (0.f, 1.f), Justification::centred, false);
        g.setColour (sk.accent); g.drawText (txt, r, Justification::centred, false);
    }
}
