// BoomHype Tech - Tempo Reverb MK I  -  editor implementation
#include "PluginEditor.h"

using namespace juce;

const Skin kSkins[bh::NumTypes] = {
    { Colour (0xff2a2c31), Colour (0xff1a1b1f), Colour (0xff0d0e11), Colour (0xffe8b83a), false },  // Hall       black
    { Colour (0xff2fd27a), Colour (0xff14a355), Colour (0xff065c2c), Colour (0xff9dffc4), false },  // Plate      green
    { Colour (0xffff9a2e), Colour (0xffd9650a), Colour (0xff7a3300), Colour (0xffffc266), true  },  // Room       orange
    { Colour (0xff3a8bff), Colour (0xff1b5fe0), Colour (0xff0a2f85), Colour (0xff9cc9ff), false },  // Space      blue
    { Colour (0xffff5a4a), Colour (0xffd2281a), Colour (0xff7a0d06), Colour (0xffffb3a3), false },  // Spring     red
    { Colour (0xffc24dff), Colour (0xff8f1fe0), Colour (0xff4a0a85), Colour (0xffefb8ff), false },  // Shimmer    purple
    { Colour (0xffffd51f), Colour (0xfff2a300), Colour (0xffa85f00), Colour (0xffffb400), true  },  // Cathedral  yellow
    { Colour (0xff1fc7c7), Colour (0xff0e9a9a), Colour (0xff055656), Colour (0xff9ff7f2), true  }   // Lo-Fi      teal
};

static Colour inkOf (const Skin& s) { return s.darkInk ? Colour (0xff1c1200) : Colour (0xfff2f2f2); }

//==============================================================================
void BHLook::drawRotarySlider (Graphics& g, int x, int y, int w, int h, float pos, float sa, float ea, Slider& s)
{
    const auto b = Rectangle<float> ((float) x, (float) y, (float) w, (float) h);
    const float r = jmin (b.getWidth(), b.getHeight()) * 0.5f;
    const auto c = b.getCentre();
    const float kr = r * 0.62f, ringR = r * 0.80f, angle = sa + pos * (ea - sa);
    const auto accent = skin->accent.withAlpha (s.isEnabled() ? 1.f : 0.35f);

    g.setColour (inkOf (*skin).withAlpha (0.75f));                       // scale ticks
    for (int i = 0; i <= 10; ++i)
    {
        const float a = sa + (ea - sa) * (float) i / 10.f;
        g.drawLine (Line<float> (c.getPointOnCircumference (r * 0.90f, a), c.getPointOnCircumference (r * 0.99f, a)), jmax (1.f, r * 0.03f));
    }
    Path track, val;                                                       // value ring
    track.addCentredArc (c.x, c.y, ringR, ringR, 0.f, sa, ea, true);
    val.addCentredArc (c.x, c.y, ringR, ringR, 0.f, sa, angle, true);
    g.setColour (Colours::black.withAlpha (0.45f)); g.strokePath (track, PathStrokeType (r * 0.07f));
    g.setColour (accent);                          g.strokePath (val, PathStrokeType (r * 0.07f));

    g.setColour (Colours::black.withAlpha (0.5f));                         // drop shadow
    g.fillEllipse (c.x - kr, c.y - kr + r * 0.10f, kr * 2.f, kr * 2.f);
    g.setColour (Colour (0xff0e0e0e));                                     // knurled skirt
    g.fillEllipse (c.x - kr, c.y - kr, kr * 2.f, kr * 2.f);
    for (int i = 0; i < 48; ++i)
    {
        const float a = (float) i * MathConstants<float>::twoPi / 48.f;
        g.setColour (i % 2 ? Colour (0xff2b2b2b) : Colour (0xff6a6a6a));
        g.drawLine (Line<float> (c.getPointOnCircumference (kr * 0.84f, a), c.getPointOnCircumference (kr, a)), jmax (1.f, kr * 0.11f));
    }
    const float cr = kr * 0.84f;                                           // chrome cap
    g.setGradientFill (ColourGradient (Colour (0xfffbfbfb), c.x - cr * 0.4f, c.y - cr * 0.5f, Colour (0xff6d6d6d), c.x + cr * 0.7f, c.y + cr * 0.8f, true));
    g.fillEllipse (c.x - cr, c.y - cr, cr * 2.f, cr * 2.f);
    const float ir = cr * 0.62f;
    g.setGradientFill (ColourGradient (Colour (0xff8a8a8a), c.x - ir * 0.5f, c.y - ir * 0.6f, Colour (0xffeeeeee), c.x + ir * 0.6f, c.y + ir * 0.7f, true));
    g.fillEllipse (c.x - ir, c.y - ir, ir * 2.f, ir * 2.f);
    g.setColour (Colours::white.withAlpha (0.55f)); g.drawEllipse (c.x - cr, c.y - cr, cr * 2.f, cr * 2.f, 1.f);

    Path ptr;                                                              // pointer
    ptr.addRoundedRectangle (-kr * 0.045f, -kr * 0.86f, kr * 0.09f, kr * 0.46f, kr * 0.04f);
    g.setColour (Colour (0xff14100b));
    g.fillPath (ptr, AffineTransform::rotation (angle).translated (c.x, c.y));
}

void BHLook::drawButtonBackground (Graphics& g, Button& b, const Colour&, bool, bool down)
{
    auto r = b.getLocalBounds().toFloat().reduced (1.f);
    const float cr = r.getHeight() * 0.18f;
    const bool on = b.getToggleState();
    g.setColour (Colours::black.withAlpha (0.4f)); g.fillRoundedRectangle (r.translated (0.f, 1.5f), cr);
    Colour top = on ? skin->accent.brighter (0.5f) : Colour (0xfff6f3ea), bot = on ? skin->accent.darker (0.15f) : Colour (0xffb7b4a6);
    if (down) { top = top.darker (0.1f); bot = bot.darker (0.1f); }
    g.setGradientFill (ColourGradient (top, 0.f, r.getY(), bot, 0.f, r.getBottom(), false));
    g.fillRoundedRectangle (r, cr);
    g.setColour (Colours::black.withAlpha (0.55f)); g.drawRoundedRectangle (r, cr, 1.f);
    if (on) { g.setColour (skin->accent.withAlpha (0.35f)); g.drawRoundedRectangle (r.expanded (1.5f), cr, 2.f); }
}

void BHLook::drawButtonText (Graphics& g, TextButton& b, bool, bool)
{
    g.setFont (getTextButtonFont (b, b.getHeight()));
    g.setColour (Colour (0xff241c0e).withAlpha (b.isEnabled() ? 1.f : 0.4f));
    g.drawText (b.getButtonText(), b.getLocalBounds(), Justification::centred, false);
}

//==============================================================================
float VuMeter::angleFor (float v) const
{
    static const float gv[] = { -20, -10, -7, -5, -3, -2, -1, 0 },              ga[] = { -55, -42, -30, -20, -11, -4, 6, 22 };
    static const float vv[] = { -20, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3 },     va[] = { -55, -42, -30, -20, -11, -4, 4, 14, 24, 33, 42 };
    const float* vals = isGR ? gv : vv; const float* angs = isGR ? ga : va; const int n = isGR ? 8 : 11;
    v = jlimit (vals[0], vals[n - 1], v);
    for (int i = 0; i < n - 1; ++i)
        if (v <= vals[i + 1]) return angs[i] + (v - vals[i]) / (vals[i + 1] - vals[i]) * (angs[i + 1] - angs[i]);
    return angs[n - 1];
}

void VuMeter::paint (Graphics& g)
{
    auto b = getLocalBounds().toFloat();
    const float h = b.getHeight();
    g.setColour (Colour (0xff0b0c0e)); g.fillRoundedRectangle (b, h * 0.05f);
    g.setColour (Colour (0xff3a3a3a)); g.drawRoundedRectangle (b.reduced (1.f), h * 0.05f, 1.f);
    auto face = b.reduced (h * 0.05f);
    g.setGradientFill (ColourGradient (Colour (0xfffbf7e6), face.getCentreX(), face.getBottom(), Colour (0xffcfc7ae), face.getX(), face.getY(), true));
    g.fillRect (face);
    g.setGradientFill (ColourGradient (Colours::black.withAlpha (0.28f), 0.f, face.getY(), Colours::transparentBlack, 0.f, face.getY() + h * 0.3f, false));
    g.fillRect (face);

    Graphics::ScopedSaveState ss (g);
    g.reduceClipRegion (face.toNearestInt());
    const float cx = face.getCentreX(), cy = face.getBottom() - h * 0.05f, R = face.getHeight() * 0.86f;
    auto pt = [&] (float deg, float rad) { const float a = degreesToRadians (deg); return Point<float> (cx + rad * std::sin (a), cy - rad * std::cos (a)); };

    static const float gv[] = { -20, -10, -7, -5, -3, -2, -1, 0 };
    static const float vv[] = { -20, -10, -7, -5, -3, -2, -1, 0, 1, 2, 3 };
    const float* vals = isGR ? gv : vv; const int n = isGR ? 8 : 11;
    const float aMin = angleFor (vals[0]), aMax = angleFor (vals[n - 1]);

    if (! isGR)
    {
        Path red; red.addCentredArc (cx, cy, R, R, 0.f, degreesToRadians (angleFor (0.f)), degreesToRadians (aMax), true);
        g.setColour (Colour (0xffd81414)); g.strokePath (red, PathStrokeType (h * 0.045f));
    }
    Path arc; arc.addCentredArc (cx, cy, R, R, 0.f, degreesToRadians (aMin), degreesToRadians (aMax), true);
    g.setColour (Colour (0xff111111)); g.strokePath (arc, PathStrokeType (h * 0.016f));

    g.setFont (bhFont (h * 0.105f));
    for (int i = 0; i < n; ++i)
    {
        const float a = angleFor (vals[i]);
        const bool red = ! isGR && vals[i] > 0.f;
        g.setColour (red ? Colour (0xffd81414) : Colour (0xff111111));
        g.drawLine (Line<float> (pt (a, R - h * 0.07f), pt (a, R + h * 0.02f)), h * 0.018f);
        const auto tp = pt (a, R + h * 0.13f);
        String t = isGR ? (vals[i] == 0.f ? "0" : String ((int) vals[i])) : String ((int) std::abs (vals[i]));
        g.drawText (t, Rectangle<float> (tp.x - h * 0.15f, tp.y - h * 0.07f, h * 0.3f, h * 0.14f), Justification::centred, false);
    }
    g.setColour (Colour (0xff111111)); g.setFont (bhFont (h * 0.22f));
    g.drawText (isGR ? "GR" : "VU", Rectangle<float> (cx - h * 0.4f, cy - R * 0.62f, h * 0.8f, h * 0.26f), Justification::centred, false);

    const float a = angleFor (needle);
    g.setColour (Colours::black.withAlpha (0.25f)); g.drawLine (Line<float> (cx + h * 0.02f, cy, pt (a, R * 0.98f).x + h * 0.025f, pt (a, R * 0.98f).y), h * 0.016f);
    g.setColour (Colour (0xff111111)); g.drawLine (Line<float> (Point<float> (cx, cy), pt (a, R * 0.98f)), h * 0.016f);
    g.setColour (Colour (0xff050505)); g.fillEllipse (cx - h * 0.1f, cy - h * 0.1f, h * 0.2f, h * 0.2f);
}

//==============================================================================
EqDisplay::EqDisplay (TempoReverbProcessor& p)
    : proc (p), fft (TempoReverbProcessor::fftOrder),
      window ((size_t) TempoReverbProcessor::fftSize, dsp::WindowingFunction<float>::hann)
{
    spec.fill (-120.f); fftData.fill (0.f);
}

void EqDisplay::setP (const String& id, float plain)
{
    if (auto* p = proc.apvts.getParameter (id)) p->setValueNotifyingHost (p->convertTo0to1 (plain));
}
void EqDisplay::gesture (const String& id, bool begin)
{
    if (auto* p = proc.apvts.getParameter (id)) { if (begin) p->beginChangeGesture(); else p->endChangeGesture(); }
}

Point<float> EqDisplay::nodePos (int i) const
{
    if (i < 5) return { fToX (proc.get ("f" + String (i))), gToY (proc.get ("g" + String (i))) };
    return { fToX (i == 5 ? proc.get ("hpFreq") : proc.get ("lpFreq")), gToY (0.f) };
}
int EqDisplay::nearestNode (Point<float> p, float maxDist) const
{
    int best = -1; float bd = maxDist;
    for (int i = 0; i < 7; ++i) { const float d = nodePos (i).getDistanceFrom (p); if (d < bd) { bd = d; best = i; } }
    return best;
}

void EqDisplay::tick()
{
    if (proc.fftReady.exchange (false))
    {
        std::copy (proc.fftSnapshot.begin(), proc.fftSnapshot.end(), fftData.begin());
        std::fill (fftData.begin() + TempoReverbProcessor::fftSize, fftData.end(), 0.f);
        window.multiplyWithWindowingTable (fftData.data(), (size_t) TempoReverbProcessor::fftSize);
        fft.performFrequencyOnlyForwardTransform (fftData.data());
        for (size_t i = 0; i < spec.size(); ++i)
        {
            const float db = Decibels::gainToDecibels (fftData[i] / ((float) TempoReverbProcessor::fftSize * 0.25f), -120.f);
            spec[i] += (db - spec[i]) * (db > spec[i] ? 0.45f : 0.10f);      // fast attack, slow fall = smooth
        }
    }
    repaint();
}

void EqDisplay::paint (Graphics& g)
{
    const float sc = (float) getHeight() / 190.f;
    const auto accent = skin->accent;
    auto full = getLocalBounds().toFloat(); auto r = area();
    g.setColour (Colour (0xff060708)); g.fillRoundedRectangle (full, 22.f * sc);
    g.setColour (Colour (0xff2a2c30)); g.drawRoundedRectangle (full.reduced (1.f), 22.f * sc, 2.f);
    Graphics::ScopedSaveState ss (g);
    { Path clip; clip.addRoundedRectangle (full.reduced (3.f), 20.f * sc); g.reduceClipRegion (clip); }

    // grid
    g.setFont (bhFont (9.f * sc, false));
    for (float f : { 50.f, 100.f, 200.f, 500.f, 1000.f, 2000.f, 5000.f, 10000.f })
    {
        const float x = fToX (f);
        g.setColour (Colours::white.withAlpha (f == 100.f || f == 1000.f || f == 10000.f ? 0.14f : 0.06f));
        g.drawVerticalLine ((int) x, r.getY(), r.getBottom());
        g.setColour (Colours::white.withAlpha (0.35f));
        g.drawText (f >= 1000.f ? String ((int) (f / 1000.f)) + "k" : String ((int) f), Rectangle<float> (x + 2.f, r.getBottom() - 14.f * sc, 30.f * sc, 12.f * sc), Justification::left, false);
    }
    for (int db : { -12, -6, 0, 6, 12 })
    {
        const float y = gToY ((float) db);
        g.setColour (Colours::white.withAlpha (db == 0 ? 0.20f : 0.07f)); g.drawHorizontalLine ((int) y, r.getX(), r.getRight());
        g.setColour (Colours::white.withAlpha (0.35f)); g.drawText (db > 0 ? "+" + String (db) : String (db), Rectangle<float> (r.getX() + 4.f * sc, y - 12.f * sc, 30.f * sc, 11.f * sc), Justification::left, false);
    }

    // analyser (smoothed across frequency + time)
    double sr = proc.getSampleRate(); if (sr <= 0.0) sr = 44100.0;
    Path sp; bool first = true;
    for (float x = r.getX(); x <= r.getRight(); x += 2.f)
    {
        const float binF = xToF (x) / (float) (sr * 0.5) * (float) spec.size();
        const int i0 = jmax (1, (int) (binF * 0.93f)), i1 = jmin ((int) spec.size() - 1, (int) (binF * 1.07f) + 1);
        float sum = 0.f; int cnt = 0;
        for (int i = i0; i <= i1; ++i) { sum += spec[(size_t) i]; ++cnt; }
        const float db = cnt ? sum / (float) cnt : -120.f;
        const float y = r.getBottom() - jlimit (0.f, 1.f, (db + 90.f) / 80.f) * r.getHeight() * 0.9f;
        if (first) { sp.startNewSubPath (x, y); first = false; } else sp.lineTo (x, y);
    }
    Path fill (sp); fill.lineTo (r.getRight(), r.getBottom()); fill.lineTo (r.getX(), r.getBottom()); fill.closeSubPath();
    g.setGradientFill (ColourGradient (accent.withAlpha (0.45f), 0.f, r.getY(), accent.withAlpha (0.03f), 0.f, r.getBottom(), false));
    g.fillPath (fill);
    g.setColour (accent.withAlpha (0.55f)); g.strokePath (sp, PathStrokeType (1.2f * sc, PathStrokeType::curved));

    // response curve
    const auto hpC = bh::makeHP (sr, proc.get ("hpFreq")), lpC = bh::makeLP (sr, proc.get ("lpFreq"));
    const bool hpOn = proc.get ("hpOn") > 0.5f, lpOn = proc.get ("lpOn") > 0.5f;
    bh::BiquadCoeffs bc[5]; bool bon[5];
    for (int i = 0; i < 5; ++i)
    {
        const String n (i);
        bon[i] = proc.get ("b" + n) < 0.5f;
        bc[i] = bh::makePeak (sr, proc.get ("f" + n), proc.get ("q" + n), proc.get ("g" + n));
    }
    Path curve; first = true;
    for (float x = r.getX(); x <= r.getRight(); x += 2.f)
    {
        const double f = xToF (x); double db = 0.0;
        if (hpOn) db += bh::magnitudeDb (hpC, sr, f);
        if (lpOn) db += bh::magnitudeDb (lpC, sr, f);
        for (int i = 0; i < 5; ++i) if (bon[i]) db += bh::magnitudeDb (bc[i], sr, f);
        const float y = jlimit (r.getY(), r.getBottom(), gToY ((float) db));
        if (first) { curve.startNewSubPath (x, y); first = false; } else curve.lineTo (x, y);
    }
    g.setColour (accent.withAlpha (0.25f)); g.strokePath (curve, PathStrokeType (6.f * sc, PathStrokeType::curved));
    g.setColour (Colours::white);           g.strokePath (curve, PathStrokeType (2.2f * sc, PathStrokeType::curved));

    // nodes
    static const Colour bandCol[5] = { Colour (0xff4a8cff), Colour (0xff3fcf6a), Colour (0xffffd23a), Colour (0xffff8a2a), Colour (0xffff4a4a) };
    static const char* bandName[5] = { "1", "2", "3", "4", "5" };
    for (int i = 0; i < 7; ++i)
    {
        const auto p = nodePos (i);
        const bool active = i < 5 ? proc.get ("b" + String (i)) < 0.5f : proc.get (i == 5 ? "hpOn" : "lpOn") > 0.5f;
        const Colour c = i < 5 ? bandCol[i] : Colour (0xffd0d0d0);
        const float rad = 9.f * sc;
        g.setColour (Colours::black.withAlpha (0.5f)); g.fillEllipse (p.x - rad, p.y - rad + 2.f, rad * 2.f, rad * 2.f);
        g.setColour (active ? c : c.withAlpha (0.35f)); g.fillEllipse (p.x - rad, p.y - rad, rad * 2.f, rad * 2.f);
        g.setColour (i == selected ? Colours::white : Colours::black.withAlpha (0.8f)); g.drawEllipse (p.x - rad, p.y - rad, rad * 2.f, rad * 2.f, 1.5f * sc);
        g.setColour (Colours::black); g.setFont (bhFont (9.f * sc));
        g.drawText (i < 5 ? bandName[i] : (i == 5 ? "HP" : "LP"), Rectangle<float> (p.x - rad, p.y - rad, rad * 2.f, rad * 2.f), Justification::centred, false);
    }
}

void EqDisplay::mouseDown (const MouseEvent& e)
{
    dragNode = nearestNode (e.position, 20.f * (float) getHeight() / 190.f);
    if (dragNode < 0) return;
    if (dragNode < 5) { selected = dragNode; const String n (dragNode); gesture ("f" + n, true); gesture ("g" + n, true); setP ("b" + n, 0.f); }
    else gesture (dragNode == 5 ? "hpFreq" : "lpFreq", true);
}
void EqDisplay::mouseDrag (const MouseEvent& e)
{
    if (dragNode < 0) return;
    const float f = xToF (e.position.x);
    if (dragNode < 5) { const String n (dragNode); setP ("f" + n, f); setP ("g" + n, yToG (e.position.y)); }
    else if (dragNode == 5) setP ("hpFreq", jlimit (20.f, 1000.f, f));
    else setP ("lpFreq", jlimit (2000.f, 20000.f, f));
}
void EqDisplay::mouseUp (const MouseEvent&)
{
    if (dragNode >= 0)
    {
        if (dragNode < 5) { const String n (dragNode); gesture ("f" + n, false); gesture ("g" + n, false); }
        else gesture (dragNode == 5 ? "hpFreq" : "lpFreq", false);
    }
    dragNode = -1;
}
void EqDisplay::mouseDoubleClick (const MouseEvent& e)
{
    const int n = nearestNode (e.position, 24.f * (float) getHeight() / 190.f);
    if (n < 0) return;
    if (n < 5) { const String id = "b" + String (n); setP (id, proc.get (id) > 0.5f ? 0.f : 1.f); }
    else { const String id = n == 5 ? "hpOn" : "lpOn"; setP (id, proc.get (id) > 0.5f ? 0.f : 1.f); }
}
void EqDisplay::mouseWheelMove (const MouseEvent& e, const MouseWheelDetails& w)
{
    int n = nearestNode (e.position, 60.f * (float) getHeight() / 190.f);
    if (n < 0 || n > 4) n = selected;
    const String id = "q" + String (n);
    setP (id, jlimit (0.3f, 8.f, proc.get (id) * std::exp (w.deltaY * 0.8f)));
}

//==============================================================================
TempoReverbEditor::TempoReverbEditor (TempoReverbProcessor& p)
    : AudioProcessorEditor (&p), proc (p), eq (p)
{
    setLookAndFeel (&laf);

    for (int i = 0; i < bh::NumTypes; ++i)
    {
        typeBtn[(size_t) i].setButtonText (bh::kTypeNames[i]);
        typeBtn[(size_t) i].onClick = [this, i] { selectType (i); };
        addAndMakeVisible (typeBtn[(size_t) i]);
    }

    preKnob = addKnob ("predelay", "PRE-DELAY"); decayKnob = addKnob ("decay", "DECAY"); addKnob ("size", "SIZE");
    addKnob ("diffusion", "DIFFUSION"); addKnob ("damping", "DAMPING"); addKnob ("mod", "MOD");
    addKnob ("width", "WIDTH"); addKnob ("tone", "TONE"); characterKnob = addKnob ("character", "CHARACTER");
    addKnob ("duckAmt", "AMOUNT"); addKnob ("duckThr", "THRESH"); addKnob ("duckRel", "RELEASE");
    addKnob ("mix", "MIX"); addKnob ("output", "OUTPUT");

    addToggle (syncBtn, "TEMPO SYNC", "sync");
    addToggle (freezeBtn, "FREEZE", "freeze");
    addToggle (bypassBtn, "BYPASS", "bypass");
    addToggle (duckBtn, "DUCK ON", "duckOn");
    addToggle (hpBtn, "HIGH PASS", "hpOn");
    addToggle (lpBtn, "LOW PASS", "lpOn");
    addToggle (srcBtn, "INPUT", {});
    addToggle (eqPosBtn, "EQ POST", {});
    srcBtn.onClick = [this] { setP ("duckSrc", proc.get ("duckSrc") > 0.5f ? 0.f : 1.f); };
    eqPosBtn.onClick = [this] { setP ("eqPost", proc.get ("eqPost") > 0.5f ? 0.f : 1.f); };

    for (int i = 0; i < 9; ++i)
    {
        preBtn[(size_t) i].setButtonText (bh::kNoteNames[i]);  preBtn[(size_t) i].onClick  = [this, i] { setP ("preNote", (float) i); };
        timeBtn[(size_t) i].setButtonText (bh::kNoteNames[i]); timeBtn[(size_t) i].onClick = [this, i] { setP ("timeNote", (float) i); };
        addAndMakeVisible (preBtn[(size_t) i]); addAndMakeVisible (timeBtn[(size_t) i]);
    }
    static const char* bn[5] = { "LF", "LMF", "MF", "HMF", "HF" };
    for (int i = 0; i < 5; ++i)
    {
        bandBtn[(size_t) i].setButtonText (bn[i]);
        bandBtn[(size_t) i].onClick = [this, i] { const String id = "b" + String (i); setP (id, proc.get (id) > 0.5f ? 0.f : 1.f); };
        addAndMakeVisible (bandBtn[(size_t) i]);
    }
    addAndMakeVisible (grMeter); addAndMakeVisible (outMeter); addAndMakeVisible (eq);

    setResizable (true, true);
    setResizeLimits (600, 360, 2400, 1440);
    if (auto* c = getConstrainer()) c->setFixedAspectRatio (5.0 / 3.0);
    setSize (1200, 720);
    startTimerHz (30);
}

TempoReverbEditor::~TempoReverbEditor() { stopTimer(); setLookAndFeel (nullptr); }

TempoReverbEditor::Knob* TempoReverbEditor::addKnob (const String& id, const String& name)
{
    auto k = std::make_unique<Knob>();
    k->name = name;
    k->s.setSliderStyle (Slider::RotaryVerticalDrag);
    k->s.setRotaryParameters (MathConstants<float>::pi * 1.25f, MathConstants<float>::pi * 2.75f, true);
    k->s.setTextBoxStyle (Slider::TextBoxBelow, false, 80, 18);
    k->s.setMouseDragSensitivity (200);
    if (auto* par = proc.apvts.getParameter (id))
        k->s.setDoubleClickReturnValue (true, (double) par->convertFrom0to1 (par->getDefaultValue()));
    k->att = std::make_unique<AudioProcessorValueTreeState::SliderAttachment> (proc.apvts, id, k->s);
    addAndMakeVisible (k->s);
    knobs.push_back (std::move (k));
    return knobs.back().get();
}

void TempoReverbEditor::addToggle (TextButton& b, const String& text, const String& paramId)
{
    b.setButtonText (text);
    addAndMakeVisible (b);
    if (paramId.isNotEmpty()) btnAtts.push_back (std::make_unique<BtnAtt> (proc.apvts, paramId, b));
}

void TempoReverbEditor::setP (const String& id, float plain)
{
    if (auto* p = proc.apvts.getParameter (id)) p->setValueNotifyingHost (p->convertTo0to1 (plain));
}

void TempoReverbEditor::selectType (int i)
{
    setP ("type", (float) i);
    const auto& d = bh::kDefaults[i];
    setP ("predelay", d.predelay); setP ("decay", d.decay); setP ("size", d.size); setP ("diffusion", d.diffusion);
    setP ("damping", d.damping); setP ("mod", d.mod); setP ("width", d.width); setP ("tone", d.tone); setP ("character", d.character);
}

void TempoReverbEditor::applySkin()
{
    const auto& sk = kSkins[jlimit (0, bh::NumTypes - 1, lastType)];
    laf.skin = &sk; eq.skin = &sk;
    for (auto& k : knobs)
    {
        k->s.setColour (Slider::textBoxTextColourId, sk.accent);
        k->s.setColour (Slider::textBoxBackgroundColourId, Colour (0xff120b05));
        k->s.setColour (Slider::textBoxOutlineColourId, Colours::transparentBlack);
    }
    static const char* cn[bh::NumTypes] = { "BLOOM", "BRIGHT", "REFLECT", "BLOOM", "TENSION", "SHIMMER", "BLOOM", "CRUSH" };
    characterKnob->name = cn[lastType];
    repaint();
}

void TempoReverbEditor::timerCallback()
{
    const int t = (int) proc.get ("type");
    if (t != lastType) { lastType = t; applySkin(); }
    for (int i = 0; i < bh::NumTypes; ++i) typeBtn[(size_t) i].setToggleState (i == t, dontSendNotification);
    const int pn = (int) proc.get ("preNote"), tn = (int) proc.get ("timeNote");
    const bool sync = proc.get ("sync") > 0.5f;
    for (int i = 0; i < 9; ++i)
    {
        preBtn[(size_t) i].setToggleState (sync && i == pn, dontSendNotification);
        timeBtn[(size_t) i].setToggleState (sync && i == tn, dontSendNotification);
        preBtn[(size_t) i].setEnabled (sync); timeBtn[(size_t) i].setEnabled (sync);
    }
    preKnob->s.setEnabled (! sync); decayKnob->s.setEnabled (! sync);
    for (int i = 0; i < 5; ++i) bandBtn[(size_t) i].setToggleState (proc.get ("b" + String (i)) < 0.5f, dontSendNotification);
    srcBtn.setButtonText (proc.get ("duckSrc") > 0.5f ? "SIDECHAIN" : "INPUT");
    eqPosBtn.setToggleState (proc.get ("eqPost") > 0.5f, dontSendNotification);
    eqPosBtn.setButtonText (proc.get ("eqPost") > 0.5f ? "EQ: POST" : "EQ: PRE");

    grMeter.setValue (-proc.grDb.load());
    outMeter.setValue (jlimit (-20.f, 3.f, proc.outRmsDb.load() + 18.f));
    grMeter.tick(); outMeter.tick(); eq.tick();
    repaint (lcdHead); repaint (lcdBpm); repaint (lcdPre); repaint (lcdTime);
}

void TempoReverbEditor::resized()
{
    scale = (float) getWidth() / 1200.f;
    auto R = [this] (float x, float y, float w, float h) { return Rectangle<int> (roundToInt (x * scale), roundToInt (y * scale), roundToInt (w * scale), roundToInt (h * scale)); };

    rHeader = R (20, 12, 1160, 46);
    lcdHead = R (600, 18, 376, 34); freezeBtn.setBounds (R (986, 18, 94, 34)); bypassBtn.setBounds (R (1086, 18, 94, 34));
    for (int i = 0; i < bh::NumTypes; ++i) typeBtn[(size_t) i].setBounds (R (20.f + (float) i * 146.f, 64, 138, 30));
    eq.setBounds (R (20, 102, 1160, 190));

    hpBtn.setBounds (R (20, 296, 90, 26)); lpBtn.setBounds (R (1000, 296, 80, 26)); eqPosBtn.setBounds (R (1090, 296, 90, 26));
    for (int i = 0; i < 5; ++i) bandBtn[(size_t) i].setBounds (R (405.f + (float) i * 80.f, 296, 70, 26));

    pTempo = R (20, 330, 262, 374); pReverb = R (292, 330, 450, 374); pDuck = R (752, 330, 230, 374); pOut = R (992, 330, 188, 374);

    lcdBpm = R (30, 356, 140, 34); syncBtn.setBounds (R (180, 356, 92, 34));
    rLabelTime = R (30, 398, 240, 16); rLabelPre = R (30, 542, 240, 16);
    for (int i = 0; i < 9; ++i)
    {
        const float cx = 30.f + (float) (i % 3) * 82.f, ry = (float) (i / 3) * 30.f;
        timeBtn[(size_t) i].setBounds (R (cx, 416.f + ry, 76, 26)); preBtn[(size_t) i].setBounds (R (cx, 560.f + ry, 76, 26));
    }
    lcdTime = R (30, 508, 240, 24); lcdPre = R (30, 652, 240, 24);

    for (int i = 0; i < 9; ++i) knobs[(size_t) i]->cell = R (300.f + (float) (i % 3) * 144.f, 356.f + (float) (i / 3) * 116.f, 144, 112);
    duckBtn.setBounds (R (760, 356, 100, 26)); srcBtn.setBounds (R (868, 356, 106, 26));
    grMeter.setBounds (R (762, 390, 210, 132));
    for (int i = 0; i < 3; ++i) knobs[(size_t) (9 + i)]->cell = R (758.f + (float) i * 74.f, 530, 74, 124);
    outMeter.setBounds (R (1000, 356, 172, 118));
    knobs[12]->cell = R (1000, 484, 86, 124); knobs[13]->cell = R (1090, 484, 86, 124);

    for (auto& k : knobs)
    {
        const int labelH = roundToInt (15.f * scale);
        k->s.setTextBoxStyle (Slider::TextBoxBelow, false, roundToInt ((float) k->cell.getWidth() * 0.82f), roundToInt (18.f * scale));
        k->s.setBounds (k->cell.withTrimmedTop (labelH));
    }
}

void TempoReverbEditor::drawPanel (Graphics& g, Rectangle<int> r, const String& title, float sc)
{
    const auto& sk = kSkins[jlimit (0, bh::NumTypes - 1, lastType)];
    g.setColour (Colours::black.withAlpha (0.12f)); g.fillRoundedRectangle (r.toFloat(), 8.f * sc);
    g.setColour (Colours::black.withAlpha (0.38f)); g.drawRoundedRectangle (r.toFloat().reduced (0.5f), 8.f * sc, 1.5f);
    g.setColour (inkOf (sk)); g.setFont (bhFont (12.f * sc));
    g.drawText (title, r.withHeight (roundToInt (22.f * sc)), Justification::centred, false);
}

void TempoReverbEditor::drawLcd (Graphics& g, Rectangle<int> r, const String& text)
{
    const auto& sk = kSkins[jlimit (0, bh::NumTypes - 1, lastType)];
    g.setColour (Colour (0xff120b05)); g.fillRoundedRectangle (r.toFloat(), 4.f * scale);
    g.setColour (Colours::black); g.drawRoundedRectangle (r.toFloat(), 4.f * scale, 1.f);
    g.setColour (sk.accent); g.setFont (bhFont ((float) r.getHeight() * 0.58f));
    g.drawText (text, r, Justification::centred, false);
}

void TempoReverbEditor::paint (Graphics& g)
{
    const float sc = scale;
    const auto& sk = kSkins[jlimit (0, bh::NumTypes - 1, lastType < 0 ? 0 : lastType)];
    const auto W = (float) getWidth(), H = (float) getHeight();

    ColourGradient grad (sk.p1, 0.f, 0.f, sk.p3, 0.f, H, false);
    grad.addColour (0.5, sk.p2);
    g.setGradientFill (grad); g.fillAll();
    Random rnd (7);                                                         // brushed-metal grain
    for (float y = 0.f; y < H; y += jmax (1.f, 2.f * sc))
    {
        g.setColour ((rnd.nextBool() ? Colours::white : Colours::black).withAlpha (rnd.nextFloat() * 0.05f));
        g.fillRect (0.f, y, W, jmax (1.f, sc));
    }
    g.setColour (Colours::white.withAlpha (0.3f)); g.drawRect (getLocalBounds(), 1);
    g.setColour (Colours::black.withAlpha (0.6f)); g.drawRect (getLocalBounds().reduced (1), 1);
    const float m = 9.f * sc;
    for (auto p : { Point<float> (m, m), Point<float> (W - m, m), Point<float> (m, H - m), Point<float> (W - m, H - m) })   // rack screws
    {
        const float r = 5.f * sc;
        g.setGradientFill (ColourGradient (Colour (0xfff0f0f0), p.x - r * 0.4f, p.y - r * 0.4f, Colour (0xff3a3a3a), p.x + r, p.y + r, true));
        g.fillEllipse (p.x - r, p.y - r, r * 2.f, r * 2.f);
    }

    // logo
    AttributedString as;
    as.append ("Boom", bhFont (30.f * sc), inkOf (sk)); as.append ("Hype", bhFont (30.f * sc), sk.darkInk ? Colour (0xff8a1d00) : sk.accent);
    as.draw (g, Rectangle<float> (30.f * sc, 14.f * sc, 260.f * sc, 40.f * sc));
    g.setColour (inkOf (sk).withAlpha (0.85f)); g.setFont (bhFont (11.f * sc));
    g.drawText ("TECH  -  TEMPO REVERB  MK I", Rectangle<float> (250.f * sc, 24.f * sc, 330.f * sc, 24.f * sc), Justification::centredLeft, false);

    drawLcd (g, lcdHead, String (bh::kTypeNames[jmax (0, lastType)]) + "  |  " + String (proc.effDecay.load(), 2) + " s  |  PRE " + String (proc.effPre.load(), 0) + " ms");

    drawPanel (g, pTempo, "TEMPO HELPER", sc); drawPanel (g, pReverb, "REVERB", sc);
    drawPanel (g, pDuck, "DUCKING", sc);       drawPanel (g, pOut, "OUTPUT", sc);

    drawLcd (g, lcdBpm, "BPM  " + String (proc.hostBpm.load(), 1));
    g.setColour (inkOf (sk)); g.setFont (bhFont (10.f * sc));
    g.drawText ("REVERB TIME", rLabelTime, Justification::centred, false);
    g.drawText ("PRE-DELAY", rLabelPre, Justification::centred, false);
    drawLcd (g, lcdTime, "TIME  " + String (proc.effDecay.load(), 2) + " s");
    drawLcd (g, lcdPre, "PRE  " + String (proc.effPre.load(), 1) + " ms");

    g.setColour (inkOf (sk)); g.setFont (bhFont (11.f * sc));
    for (auto& k : knobs)
        g.drawText (k->name, k->cell.withHeight (roundToInt (15.f * sc)), Justification::centred, false);
}
