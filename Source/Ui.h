// BoomHype Tech - Tempo Reverb MK I  -  UI building blocks (skins, fonts, 3D knob, buttons, LCD, VU)
#pragma once
#include <juce_gui_basics/juce_gui_basics.h>
#include <juce_audio_processors/juce_audio_processors.h>
#include <functional>
#include <array>
#include "ReverbEngine.h"
#if BH_HAS_FONTS
 #include <BinaryData.h>
#endif

namespace ui
{
using namespace juce;

//==============================================================================  skins
enum Cap { CapRed = 0, CapOrange, CapGreen, CapBlue, CapYellow, CapGray };

struct Skin
{
    Colour p1, p2, p3, accent, silk, dim, brand;
    float sheen = 0.1f; bool dark = false;
    Colour caps[6];
};

inline Skin mkSkin (uint32 a, uint32 b, uint32 c, uint32 acc, float sheen, bool dark, uint32 silk, uint32 dim, uint32 brand,
                    std::array<uint32, 6> caps)
{
    Skin s; s.p1 = Colour (a); s.p2 = Colour (b); s.p3 = Colour (c); s.accent = Colour (acc); s.sheen = sheen; s.dark = dark;
    s.silk = Colour (silk); s.dim = Colour (dim); s.brand = Colour (brand);
    for (int i = 0; i < 6; ++i) s.caps[i] = Colour (caps[(size_t) i]);
    return s;
}

inline const Skin& skinFor (int t)
{
    static const Skin skins[8] = {
        mkSkin (0xff2a2c31, 0xff1a1b1f, 0xff0d0e11, 0xffe8b83a, .11f, false, 0xffeceef2, 0xffa4aab5, 0xffe8b83a, { 0xffe03a2e, 0xfff08028, 0xff3fae4e, 0xff3a6fd9, 0xfff2c118, 0xffb9bec7 }),
        mkSkin (0xff2fd27a, 0xff14a355, 0xff065c2c, 0xff9dffc4, .16f, false, 0xffeceef2, 0xffa4aab5, 0xff9dffc4, { 0xffc8452d, 0xffe0952f, 0xff9aa63a, 0xff3f7f9a, 0xfff0c84a, 0xffcfc6b4 }),
        mkSkin (0xffff9a2e, 0xffd9650a, 0xff7a3300, 0xffffc266, .18f, true,  0xff2a1000, 0xff5a2a00, 0xff7a1d00, { 0xffd4553a, 0xffe39a3a, 0xff34b36b, 0xff2f8fa8, 0xffcfd848, 0xffbfc9c1 }),
        mkSkin (0xff3a8bff, 0xff1b5fe0, 0xff0a2f85, 0xff9cc9ff, .16f, false, 0xffeceef2, 0xffa4aab5, 0xff9cc9ff, { 0xffff5d73, 0xffffa24a, 0xff3cc7b0, 0xff4f8fd9, 0xffe5d85a, 0xffc3cad6 }),
        mkSkin (0xffff5a4a, 0xffd2281a, 0xff7a0d06, 0xffffb3a3, .16f, false, 0xffeceef2, 0xffa4aab5, 0xffffb3a3, { 0xffd94f33, 0xffe8803a, 0xff8aa83c, 0xff4a7fb0, 0xfff0b83a, 0xffd1c1b4 }),
        mkSkin (0xffc24dff, 0xff8f1fe0, 0xff4a0a85, 0xffefb8ff, .16f, false, 0xffeceef2, 0xffa4aab5, 0xffefb8ff, { 0xffe0457f, 0xffff9a5a, 0xff55c7a0, 0xff7a62e8, 0xfff0d25a, 0xffcbbfe0 }),
        mkSkin (0xffffd51f, 0xfff2a300, 0xffa85f00, 0xffffb400, .20f, true,  0xff1c1200, 0xff4d3300, 0xff8a1d00, { 0xffb83a30, 0xffd9962e, 0xff5c9a56, 0xff4a68b5, 0xffe8c63a, 0xffcfcbbd }),
        mkSkin (0xff1fc7c7, 0xff0e9a9a, 0xff055656, 0xff9ff7f2, .16f, true,  0xff002a2a, 0xff064a4a, 0xff7a1d00, { 0xffb5502f, 0xffc98a3a, 0xff7a8a3a, 0xff5f7f8a, 0xffd8b24a, 0xffbdb19a }) };
    return skins[jlimit (0, 7, t)];
}

//==============================================================================  fonts (Josefin Sans + Bevan embedded; falls back to system bold)
inline Typeface::Ptr bhTypeface (int which)   // 0 = Josefin 500, 1 = 600, 2 = 700, 3 = Bevan
{
    static Typeface::Ptr tf[4];
    static bool loaded = false;
    if (! loaded)
    {
        loaded = true;
#if BH_HAS_FONTS
        tf[0] = Typeface::createSystemTypefaceFor (BinaryData::Josefin500_ttf, (size_t) BinaryData::Josefin500_ttfSize);
        tf[1] = Typeface::createSystemTypefaceFor (BinaryData::Josefin600_ttf, (size_t) BinaryData::Josefin600_ttfSize);
        tf[2] = Typeface::createSystemTypefaceFor (BinaryData::Josefin700_ttf, (size_t) BinaryData::Josefin700_ttfSize);
        tf[3] = Typeface::createSystemTypefaceFor (BinaryData::Bevan400_ttf, (size_t) BinaryData::Bevan400_ttfSize);
#endif
    }
    return tf[which];
}
// px = CSS-style font size from the design; kern = letter spacing in em
inline Font bhFont (float px, int which = 2, float kern = 0.f)
{
    const float h = jmax (5.f, px * 1.18f);
    auto t = bhTypeface (which);
    if (t != nullptr) return Font (FontOptions (t).withHeight (h).withKerningFactor (kern));
    return Font (FontOptions (h, which == 3 ? Font::plain : Font::bold));
}

// draws text and shrinks the font if it would be wider than the rectangle (nothing is ever clipped)
inline void drawFit (Graphics& g, const String& t, Rectangle<float> r, Font f, Justification j)
{
    const float w = f.getStringWidthFloat (t);
    if (w > r.getWidth() && w > 0.f) f = f.withHeight (f.getHeight() * r.getWidth() / w * 0.97f);
    g.setFont (f); g.drawText (t, r, j, false);
}

inline Colour jewelRed() { return Colour (0xffff3b30); }

//==============================================================================  3D knob (port of the HTML SVG knob)
enum ScaleKind { ScPct, ScDb, ScMs, ScFreq, ScQ };

inline Point<float> polar (float r, float deg) { const float a = degreesToRadians (deg); return { 60.f + r * std::sin (a), 68.f - r * std::cos (a) }; }
inline float logPos (float f) { return std::log (f / 20.f) / std::log (1000.f); }
inline float qPos (float q) { return jlimit (0.f, 1.f, std::log (q / 0.3f) / std::log (8.f / 0.3f)); }

inline void drawScale (Graphics& g, ScaleKind kind, Colour ink, float k)
{
    auto dot = [&] (float r, float deg, float rad, float alpha)
    {
        auto p = polar (r, deg); g.setColour (ink.withAlpha (alpha)); g.fillEllipse (p.x - rad, p.y - rad, rad * 2.f, rad * 2.f);
    };
    auto label = [&] (const String& t, float deg, float px)
    {
        auto p = polar (63.f, deg); g.setColour (ink.withAlpha (0.95f)); g.setFont (bhFont (px, 2));
        g.drawText (t, Rectangle<float> (p.x - 20.f, p.y - 10.f, 40.f, 20.f), Justification::centred, false);
    };
    auto tick = [&] (float t, const String& txt) { const float a = -135.f + t * 270.f; dot (54.f, a, 2.4f, 0.95f); label (txt, a, 17.f); };
    auto minor = [&] (float t) { dot (54.f, -135.f + t * 270.f, 1.7f, 0.6f); };

    // everything below is in the 120-unit design box; text sizes were multiplied by k so they stay pixel-true
    if (kind == ScDb)
    {
        for (int i = 0; i <= 10; ++i) dot (54.f, -135.f + (float) i * 27.f, i % 5 == 0 ? 2.7f : 2.1f, 0.95f);
        label ("-", -135.f, 21.f); label ("+", 135.f, 21.f);
    }
    else if (kind == ScPct)
    {
        for (int i = 0; i <= 5; ++i) tick ((float) i / 5.f, String (i * 2));
        for (float t : { .1f, .3f, .5f, .7f, .9f }) minor (t);
    }
    else if (kind == ScMs)
    {
        for (int v = 0; v <= 500; v += 100) tick ((float) v / 500.f, String (v));
    }
    else if (kind == ScFreq)
    {
        tick (logPos (100.f), "100"); tick (logPos (1000.f), "1k"); tick (logPos (10000.f), "10k");
        for (float f : { 20.f, 50.f, 200.f, 500.f, 2000.f, 5000.f, 20000.f }) minor (logPos (f));
    }
    else
    {
        tick (qPos (.3f), ".3"); tick (qPos (1.f), "1"); tick (qPos (3.f), "3"); tick (qPos (8.f), "8");
        for (float q : { .5f, .7f, 1.5f, 2.f, 5.f }) minor (qPos (q));
    }
}

inline void drawKnob3D (Graphics& g, float norm, Colour c0, Colour c1, Colour c2, bool silver)
{
    const float KK = 0.7f;
    auto ep = [&] (float cx, float cy, float r, float u) { const float a = degreesToRadians (u); return Point<float> (cx + r * std::sin (a), cy + r * KK * std::cos (a)); };
    auto ell = [&] (float cx, float cy, float rx, float ry) { return Rectangle<float> (cx - rx, cy - ry, rx * 2.f, ry * 2.f); };

    Graphics::ScopedSaveState ss (g);
    g.addTransform (AffineTransform::translation (-60.f, -70.f).scaled (1.4f).translated (60.f, 70.f));

    for (int i = 0; i < 8; ++i)                                     // soft contact shadow
    {
        const float f = 1.f - (float) i * 0.07f;
        g.setColour (Colours::black.withAlpha (0.075f)); g.fillEllipse (ell (60.f, 90.f, 46.f * f, 27.f * f));
    }
    const Colour sideC = silver ? Colour (0xff868b94) : Colour (0xff4a4d54);
    g.setColour (sideC); g.fillEllipse (ell (60.f, 83.f, 31.f, 21.7f)); g.fillRect (29.f, 78.f, 62.f, 5.f);
    g.setColour (Colours::black.withAlpha (0.7f)); g.drawEllipse (ell (60.f, 83.f, 31.f, 21.7f), 0.9f);
    {
        auto r = ell (60.f, 78.f, 31.f, 21.7f);
        ColourGradient fl (silver ? Colour (0xfffafbfc) : Colour (0xffc1c5cc), r.getX(), r.getY(), silver ? Colour (0xff9aa0a9) : Colour (0xff666a72), r.getRight(), r.getBottom(), false);
        fl.addColour (0.55, silver ? Colour (0xffc4c9d0) : Colour (0xff8d9199));
        g.setGradientFill (fl); g.fillEllipse (r);
        g.setColour (Colours::black.withAlpha (0.65f)); g.drawEllipse (r, 0.9f);
    }
    g.setColour (Colours::black.withAlpha (0.55f));
    for (float u = -80.f; u <= 80.f; u += 20.f) { auto d = ep (60.f, 78.f, 28.9f, u); g.fillEllipse (d.x - 1.f, d.y - 1.f, 2.f, 2.f); }
    g.setColour (Colours::black.withAlpha (0.5f)); g.drawEllipse (ell (60.f, 77.f, 26.5f, 18.55f), 1.8f);

    // knurled skirt
    const auto lightC = silver ? Colour (0xfff0f2f5) : Colour (0xff62656c), darkC = silver ? Colour (0xff8a8f98) : Colour (0xff1b1c1f);
    int i = 0;
    for (float u = -90.f; u < 89.9f; u += 7.5f, ++i)
    {
        const float u2 = u + 7.5f, um = 0.5f * (u + u2), L = 0.5f - 0.5f * std::sin (degreesToRadians (um));
        Colour col = darkC.interpolatedWith (lightC, 0.1f + 0.9f * L);
        col = (i % 2) ? col.withMultipliedBrightness (0.5f) : col;
        auto T1 = ep (60.f, 52.f, 20.f, u), T2 = ep (60.f, 52.f, 20.f, u2), B2 = ep (60.f, 77.f, 26.5f, u2), B1 = ep (60.f, 77.f, 26.5f, u);
        Path pg; pg.startNewSubPath (T1); pg.lineTo (T2); pg.lineTo (B2); pg.lineTo (B1); pg.closeSubPath();
        g.setColour (col); g.fillPath (pg); g.strokePath (pg, PathStrokeType (0.5f));
    }
    {
        Path body;                                                  // shading over the skirt
        for (int s = 0; s <= 24; ++s) { const float t = (float) s / 24.f * MathConstants<float>::pi; Point<float> p (60.f - 20.f * std::cos (t), 52.f + 14.f * std::sin (t)); if (s == 0) body.startNewSubPath (p); else body.lineTo (p); }
        for (int s = 0; s <= 24; ++s) { const float t = (float) s / 24.f * MathConstants<float>::pi; body.lineTo (60.f + 26.5f * std::cos (t), 77.f + 18.55f * std::sin (t)); }
        body.closeSubPath();
        ColourGradient ov (Colours::white.withAlpha (0.14f), 0.f, 52.f, Colours::black.withAlpha (0.42f), 0.f, 95.5f, false);
        ov.addColour (0.45, Colours::transparentBlack);
        g.setGradientFill (ov); g.fillPath (body);
        Path rim; rim.addCentredArc (60.f, 77.f, 26.5f, 18.55f, 0.f, MathConstants<float>::halfPi, MathConstants<float>::halfPi * 3.f, true);
        g.setColour (Colours::black.withAlpha (0.7f)); g.strokePath (rim, PathStrokeType (1.f));
    }
    // top cap
    {
        auto r = ell (60.f, 52.f, 20.4f, 14.3f);
        if (silver)
        {
            ColourGradient cs (Colours::white, r.getX() + r.getWidth() * .1f, r.getY(), Colour (0xff8d929b), r.getX() + r.getWidth() * .9f, r.getBottom(), false);
            cs.addColour (0.4, Colour (0xffe0e3e8)); cs.addColour (0.75, Colour (0xffb2b7bf));
            g.setGradientFill (cs);
        }
        else
        {
            ColourGradient cp (c0, 54.3f, 45.7f, c2, 54.3f + 33.f, 45.7f, true); cp.addColour (0.5, c1);
            g.setGradientFill (cp);
        }
        g.fillEllipse (r);
        g.setColour (Colours::black.withAlpha (0.7f)); g.drawEllipse (r, 1.f);
        if (silver)
            for (int rr = 3; rr <= 18; rr += 3)
            {
                g.setColour (rr % 6 ? Colours::white.withAlpha (0.45f) : Colours::black.withAlpha (0.1f));
                g.drawEllipse (ell (60.f, 52.f, (float) rr, (float) rr * KK), 0.7f);
            }
        g.setColour (Colours::white.withAlpha (0.4f)); g.drawEllipse (ell (60.f, 52.f, 19.2f, 13.4f), 0.8f);
    }
    // pointer
    {
        Graphics::ScopedSaveState s2 (g);
        const float ang = degreesToRadians (-135.f + norm * 270.f);
        g.addTransform (AffineTransform::rotation (ang).scaled (1.f, KK).translated (60.f, 52.f));
        if (silver)
        {
            g.setColour (Colours::white.withAlpha (0.75f)); g.drawLine (1.f, -17.f, 1.f, -3.f, 4.2f);
            g.setColour (Colour (0xff14110d)); g.drawLine (0.f, -18.f, 0.f, -4.f, 3.8f);
        }
        else
        {
            g.setColour (Colours::black.withAlpha (0.5f)); g.drawLine (1.4f, -16.5f, 1.4f, -4.f, 5.4f);
            g.setColour (Colours::white); g.drawLine (0.f, -18.f, 0.f, -5.5f, 4.6f);
        }
    }
    for (int s = 0; s < 3; ++s)                                     // specular glint
    {
        Graphics::ScopedSaveState s3 (g);
        g.addTransform (AffineTransform::rotation (degreesToRadians (-16.f), 51.f, 46.5f));
        g.setColour (Colours::white.withAlpha (0.22f)); g.fillEllipse (ell (51.f, 46.5f, 9.f - (float) s * 2.5f, 3.6f - (float) s * 0.9f));
    }
}

//==============================================================================  KnobComp : Slider that paints the whole cell (label, scale, knob, value)
class KnobComp : public Slider
{
public:
    KnobComp (const String& labelText, ScaleKind kindIn, Cap capIn, float designSize, std::function<String (double)> fmtIn, const String& unitIn = {})
        : label (labelText), kind (kindIn), cap (capIn), S (designSize), fmt (std::move (fmtIn)), unit (unitIn)
    {
        setSliderStyle (Slider::RotaryVerticalDrag);
        setTextBoxStyle (Slider::NoTextBox, false, 0, 0);
        setRotaryParameters (MathConstants<float>::pi * 1.25f, MathConstants<float>::pi * 2.75f, true);
        setMouseDragSensitivity (220);
        setMouseCursor (MouseCursor::UpDownResizeCursor);
    }
    int skinType = 0; bool dimmed = false; String labelOverride;

    // The cell is wider than the dial by PAD on each side, so the scale numbers and long labels (HIGH PASS...) never clip.
    static constexpr float PAD = 22.f;
    static float cellH (float S, bool hasUnit = false) { return 15.f + S + 17.f + (hasUnit ? 14.f : 0.f); }

    bool hitTest (int x, int y) override               // only the dial itself takes the mouse (neighbouring cells overlap)
    {
        const float k = (float) getWidth() / (S + 2.f * PAD);
        return (float) x >= PAD * k && (float) x <= (PAD + S) * k && y >= 0 && y < getHeight();
    }

    void paint (Graphics& g) override
    {
        const auto& sk = skinFor (skinType);
        const float k = (float) getWidth() / (S + 2.f * PAD);          // pixels per design pixel
        Graphics::ScopedSaveState ss (g);
        if (dimmed) g.beginTransparencyLayer (0.36f);
        g.setColour (sk.silk);
        drawFit (g, (labelOverride.isNotEmpty() ? labelOverride : label).toUpperCase(), Rectangle<float> (0.f, 0.f, (float) getWidth(), 15.f * k), bhFont (15.f * k, 2, 0.07f), Justification::centred);
        {
            Graphics::ScopedSaveState s2 (g);
            g.addTransform (AffineTransform::scale (k * S / 120.f).translated (PAD * k, 15.f * k));   // 120-unit dial box == S design px
            const auto cc = sk.caps[cap];
            const bool silver = cap == CapGray;
            drawScale (g, kind, silver ? sk.silk : cc.interpolatedWith (Colours::white, 0.5f), k);
            drawKnob3D (g, (float) valueToProportionOfLength (getValue()), cc.interpolatedWith (Colours::white, 0.5f), cc, cc.interpolatedWith (Colours::black, 0.58f), silver);
        }
        g.setColour (isMouseButtonDown() ? sk.accent : sk.dim);
        drawFit (g, fmt ? fmt (getValue()) : String (getValue()), Rectangle<float> (0.f, (15.f + S) * k, (float) getWidth(), 17.f * k), bhFont (15.f * k, 1, 0.03f), Justification::centred);
        if (unit.isNotEmpty())
        {
            g.setColour (sk.dim);
            drawFit (g, unit, Rectangle<float> (0.f, (15.f + S + 15.f) * k, (float) getWidth(), 14.f * k), bhFont (14.f * k, 1, 0.07f), Justification::centred);
        }
        if (dimmed) g.endTransparencyLayer();
    }
    void mouseDown (const MouseEvent& e) override { Slider::mouseDown (e); repaint(); }
    void mouseUp (const MouseEvent& e) override { Slider::mouseUp (e); repaint(); }
    float designSize() const { return S; }

private:
    String label; ScaleKind kind; Cap cap; float S; std::function<String (double)> fmt; String unit;
};

//==============================================================================  3D push-button with jewel lamp
class BellButton : public Button
{
public:
    explicit BellButton (const String& text, bool jewel = true, float fontPx = 14.f) : Button (text), showJewel (jewel), fpx (fontPx) { setMouseCursor (MouseCursor::PointingHandCursor); }
    int skinType = 0;

    void paintButton (Graphics& g, bool over, bool down) override
    {
        const auto& sk = skinFor (skinType);
        const auto b = getLocalBounds().toFloat();
        const float h = b.getHeight(), u = h / 36.f;
        const bool on = getToggleState(), pressed = on || down;
        const float lip = 3.f * u, jz = showJewel ? 20.f * u : 0.f;
        Rectangle<float> body (1.f, 1.f, b.getWidth() - jz - 2.f, h - lip - 4.f * u);
        body.translate (0.f, pressed ? lip * 0.8f : 0.f);
        const float cr = 3.f * u;
        g.setColour (Colours::black.withAlpha (0.45f)); g.fillRoundedRectangle (body.translated (0.f, lip + (pressed ? 1.f : 3.f) * u), cr);
        if (! pressed)
        {
            g.setColour (Colour (0xff6b6c66)); g.fillRoundedRectangle (body.translated (0.f, lip), cr);
            g.setColour (Colour (0xff0a0a0a)); g.drawRoundedRectangle (body.translated (0.f, lip), cr, 1.f);
        }
        if (on)
            for (int i = 1; i <= 3; ++i) { g.setColour (sk.accent.withAlpha (0.12f)); g.drawRoundedRectangle (body.expanded ((float) i * 2.f * u), cr + (float) i * 2.f * u, 2.f * u); }
        ColourGradient grad (Colours::white, 0.f, body.getY(), Colour (0xffb6b6ad), 0.f, body.getBottom(), false);
        if (on)
        {
            grad = ColourGradient (sk.accent.interpolatedWith (Colours::white, 0.22f), 0.f, body.getY(), sk.accent.interpolatedWith (Colours::white, 0.12f), 0.f, body.getBottom(), false);
            grad.addColour (0.55, sk.accent.interpolatedWith (Colours::white, 0.0f));
        }
        else { grad.addColour (0.16, Colour (0xffecece6)); grad.addColour (0.62, Colour (0xffd4d4cc)); }
        if (over && ! on) grad.multiplyOpacity (1.f);
        g.setGradientFill (grad); g.fillRoundedRectangle (body, cr);
        g.setColour (Colours::white.withAlpha (on ? 0.25f : 0.7f)); g.drawLine (body.getX() + cr, body.getY() + 0.5f, body.getRight() - cr, body.getY() + 0.5f, 1.f);
        g.setColour (Colour (0xff060607)); g.drawRoundedRectangle (body, cr, 1.f);
        g.setColour (on ? Colour (0xff1a1304) : Colour (0xff1b1c1f)); g.setFont (bhFont (fpx * u, 2, 0.09f));
        g.drawText (getButtonText(), body, Justification::centred, false);

        if (showJewel)
        {
            const float r = 6.f * u, cx = b.getWidth() - jz * 0.5f - 1.f * u, cy = h * 0.43f;
            g.setColour (Colours::black.withAlpha (0.5f)); g.fillEllipse (cx - r - 2.f * u, cy - r, (r + 2.f * u) * 2.f, (r + 2.f * u) * 2.f + 2.f * u);
            g.setColour (on ? Colour (0xffdfe2e8) : Colour (0xffa9adb5)); g.fillEllipse (cx - r - 2.f * u, cy - r - 2.f * u, (r + 2.f * u) * 2.f, (r + 2.f * u) * 2.f);
            g.setColour (Colour (0xff15161a)); g.fillEllipse (cx - r - 1.f * u, cy - r - 1.f * u, (r + 1.f * u) * 2.f, (r + 1.f * u) * 2.f);
            if (on)
            {
                for (int i = 4; i >= 1; --i) { g.setColour (jewelRed().withAlpha (0.10f)); g.fillEllipse (cx - r - (float) i * 3.f * u, cy - r - (float) i * 3.f * u, (r + (float) i * 3.f * u) * 2.f, (r + (float) i * 3.f * u) * 2.f); }
                ColourGradient lg (Colours::white, cx - r * 0.3f, cy - r * 0.4f, Colour (0xff8a1510), cx + r, cy + r, true);
                lg.addColour (0.16, Colour (0xffffc4bc)); lg.addColour (0.48, jewelRed());
                g.setGradientFill (lg);
            }
            else
            {
                ColourGradient lg (Colour (0xff7d2d26), cx - r * 0.3f, cy - r * 0.4f, Colour (0xff240806), cx + r, cy + r, true);
                lg.addColour (0.55, Colour (0xff4a1512)); g.setGradientFill (lg);
            }
            g.fillEllipse (cx - r, cy - r, r * 2.f, r * 2.f);
        }
    }
private:
    bool showJewel; float fpx;
};

//==============================================================================  note key (tempo grid)
class NoteKey : public Button
{
public:
    explicit NoteKey (const String& t) : Button (t) { setMouseCursor (MouseCursor::PointingHandCursor); }
    int skinType = 0;
    void paintButton (Graphics& g, bool, bool) override
    {
        const auto& sk = skinFor (skinType);
        const auto b = getLocalBounds().toFloat(); const float u = b.getHeight() / 36.f;
        const bool on = getToggleState(); const float lip = 3.f * u;
        Rectangle<float> body (1.f, 1.f, b.getWidth() - 2.f, b.getHeight() - lip - 4.f * u);
        if (on) body.translate (0.f, lip * 0.8f);
        const float cr = 3.f * u;
        g.setColour (Colours::black.withAlpha (0.5f)); g.fillRoundedRectangle (body.translated (0.f, lip + 2.f * u), cr);
        if (! on) { g.setColour (Colour (0xff66655f)); g.fillRoundedRectangle (body.translated (0.f, lip), cr); g.setColour (Colour (0xff0a0a0a)); g.drawRoundedRectangle (body.translated (0.f, lip), cr, 1.f); }
        if (on) { g.setColour (sk.accent.withAlpha (0.18f)); g.drawRoundedRectangle (body.expanded (3.f * u), cr + 3.f * u, 3.f * u); }
        ColourGradient grad (on ? sk.accent.interpolatedWith (Colours::white, 0.22f) : Colours::white, 0.f, body.getY(), on ? sk.accent : Colour (0xffb5b2a6), 0.f, body.getBottom(), false);
        if (! on) { grad.addColour (0.18, Colour (0xffecebe4)); grad.addColour (0.62, Colour (0xffd3d1c6)); }
        g.setGradientFill (grad); g.fillRoundedRectangle (body, cr);
        g.setColour (Colour (0xff060607)); g.drawRoundedRectangle (body, cr, 1.f);
        const float dr = 2.6f * u; const auto c = body.getCentre();
        const float tw = bhFont (15.f * u, 2).getStringWidthFloat (getButtonText());
        const float dx = c.x - tw * 0.5f - 8.f * u;
        g.setColour (on ? Colours::white : Colour (0xff7c7660)); g.fillEllipse (dx - dr, c.y - dr, dr * 2.f, dr * 2.f);
        g.setColour (Colour (0xff2b261c)); g.setFont (bhFont (15.f * u, 2, 0.02f));
        g.drawText (getButtonText(), body.withTrimmedLeft (8.f * u), Justification::centred, false);
        if (! isEnabled()) { g.setColour (Colours::black.withAlpha (0.35f)); g.fillRoundedRectangle (body, cr); }
    }
};

//==============================================================================  preset row (Tempo Helper style: label on the left, live ms/s value on the right)
class PresetRow : public Button
{
public:
    explicit PresetRow (const String& t) : Button (t) { setMouseCursor (MouseCursor::PointingHandCursor); }
    int skinType = 0; String value;
    void setValue (const String& v) { if (v != value) { value = v; repaint(); } }
    void paintButton (Graphics& g, bool, bool) override
    {
        const auto& sk = skinFor (skinType);
        const auto b = getLocalBounds().toFloat(); const float u = b.getHeight() / 36.f;
        const bool on = getToggleState(); const float lip = 3.f * u;
        Rectangle<float> body (1.f, 1.f, b.getWidth() - 2.f, b.getHeight() - lip - 4.f * u);
        if (on) body.translate (0.f, lip * 0.8f);
        const float cr = 3.f * u;
        g.setColour (Colours::black.withAlpha (0.5f)); g.fillRoundedRectangle (body.translated (0.f, lip + 2.f * u), cr);
        if (! on) { g.setColour (Colour (0xff66655f)); g.fillRoundedRectangle (body.translated (0.f, lip), cr); g.setColour (Colour (0xff0a0a0a)); g.drawRoundedRectangle (body.translated (0.f, lip), cr, 1.f); }
        if (on) { g.setColour (sk.accent.withAlpha (0.18f)); g.drawRoundedRectangle (body.expanded (3.f * u), cr + 3.f * u, 3.f * u); }
        ColourGradient grad (on ? sk.accent.interpolatedWith (Colours::white, 0.22f) : Colours::white, 0.f, body.getY(), on ? sk.accent : Colour (0xffb5b2a6), 0.f, body.getBottom(), false);
        if (! on) { grad.addColour (0.18, Colour (0xffecebe4)); grad.addColour (0.62, Colour (0xffd3d1c6)); }
        g.setGradientFill (grad); g.fillRoundedRectangle (body, cr);
        g.setColour (Colour (0xff060607)); g.drawRoundedRectangle (body, cr, 1.f);
        const float dr = 3.f * u, cy = body.getCentreY();
        g.setColour (on ? Colours::white : Colour (0xff7c7660)); g.fillEllipse (body.getX() + 13.f * u - dr, cy - dr, dr * 2.f, dr * 2.f);
        g.setColour (on ? Colour (0xff1a1304) : Colour (0xff2b261c));
        auto area = body.withTrimmedLeft (26.f * u).withTrimmedRight (12.f * u);
        const float vw = bhFont (15.f * u, 1, 0.02f).getStringWidthFloat (value) + 2.f * u;
        auto valArea = area.removeFromRight (vw);
        drawFit (g, getButtonText(), area.withTrimmedRight (6.f * u), bhFont (15.f * u, 2, 0.04f), Justification::centredLeft);
        drawFit (g, value, valArea, bhFont (15.f * u, 1, 0.02f), Justification::centredRight);
        if (! isEnabled()) { g.setColour (Colours::black.withAlpha (0.35f)); g.fillRoundedRectangle (body, cr); }
    }
};

//==============================================================================  segmented chips (slope, pre/post)
class ChipGroup : public Component
{
public:
    ChipGroup (StringArray names) : labels (std::move (names)) { setMouseCursor (MouseCursor::PointingHandCursor); }
    int skinType = 0; int selected = 0; std::function<void (int)> onSelect;
    void setSelected (int i) { if (i != selected) { selected = i; repaint(); } }
    void paint (Graphics& g) override
    {
        const auto& sk = skinFor (skinType);
        auto b = getLocalBounds().toFloat().reduced (1.f); b.removeFromBottom (3.f);
        const float u = b.getHeight() / 26.f;
        g.setColour (Colour (0xff4a4b47)); g.fillRoundedRectangle (b.translated (0.f, 2.f), 3.f);
        const int n = labels.size(); const float w = b.getWidth() / (float) n;
        Graphics::ScopedSaveState ss (g);
        { Path c; c.addRoundedRectangle (b, 3.f); g.reduceClipRegion (c); }
        for (int i = 0; i < n; ++i)
        {
            Rectangle<float> r (b.getX() + w * (float) i, b.getY(), w, b.getHeight());
            const bool on = i == selected;
            ColourGradient grad (on ? sk.accent.interpolatedWith (Colours::white, 0.35f) : Colour (0xfffdfdf9), 0.f, r.getY(), on ? sk.accent : Colour (0xffbdbcb2), 0.f, r.getBottom(), false);
            if (! on) grad.addColour (0.6, Colour (0xffd9d8d0));
            g.setGradientFill (grad); g.fillRect (r);
            if (on) { g.setColour (Colours::black.withAlpha (0.25f)); g.fillRect (r.removeFromTop (2.f)); }
            g.setColour (on ? Colour (0xff1a1304) : Colour (0xff24262b)); g.setFont (bhFont (13.5f * u, 2, 0.03f));
            g.drawText (labels[i], r, Justification::centred, false);
            if (i > 0) { g.setColour (Colours::black.withAlpha (0.4f)); g.drawVerticalLine ((int) r.getX(), b.getY(), b.getBottom()); }
        }
        g.setColour (Colours::black); g.drawRoundedRectangle (b, 3.f, 1.f);
    }
    void mouseDown (const MouseEvent& e) override
    {
        const int n = labels.size(); if (n == 0) return;
        const int i = jlimit (0, n - 1, (int) (e.position.x / ((float) getWidth() / (float) n)));
        setSelected (i); if (onSelect) onSelect (i);
    }
private:
    StringArray labels;
};

//==============================================================================  LCD readout (drag, double-click to type)
class LcdBox : public Component
{
public:
    LcdBox (bool stackedLayout) : stacked (stackedLayout)
    {
        addChildComponent (ed);
        ed.setJustification (Justification::centred); ed.setMultiLine (false);
        ed.setColour (TextEditor::backgroundColourId, Colours::black); ed.setColour (TextEditor::outlineColourId, Colours::transparentBlack);
        ed.setColour (TextEditor::focusedOutlineColourId, Colours::transparentBlack);
        ed.onReturnKey = [this] { finish (true); }; ed.onEscapeKey = [this] { finish (false); }; ed.onFocusLost = [this] { finish (true); };
    }
    int skinType = 0; String top, mainText, subText; bool draggable = false, editable = true; bool tempoNote = false;
    std::function<void()> onDragBegin, onDragEnd; std::function<void (float)> onDragDelta;   // delta in px, up = positive
    std::function<String()> getEditText; std::function<void (const String&)> onEdited;

    void set (const String& t, const String& m, const String& s) { if (t != top || m != mainText || s != subText) { top = t; mainText = m; subText = s; repaint(); } }
    void paint (Graphics& g) override
    {
        const auto& sk = skinFor (skinType);
        auto b = getLocalBounds().toFloat().reduced (1.f);
        ColourGradient bg (Colour (0xff08090c), 0.f, b.getY(), Colour (0xff040507), 0.f, b.getBottom(), false);
        g.setGradientFill (bg); g.fillRoundedRectangle (b, 3.f);
        g.setColour (Colours::black.withAlpha (0.9f)); g.drawLine (b.getX() + 3.f, b.getY() + 1.5f, b.getRight() - 3.f, b.getY() + 1.5f, 3.f);
        g.setColour (Colours::black); g.drawRoundedRectangle (b, 3.f, 1.f);
        g.setColour (Colours::white.withAlpha (0.18f)); g.drawLine (b.getX() + 3.f, b.getBottom() + 0.5f, b.getRight() - 3.f, b.getBottom() + 0.5f, 1.f);
        const float h = b.getHeight();
        if (stacked)
        {
            g.setColour (Colour (0xff5c6270)); g.setFont (bhFont (h * 0.27f, 2, 0.12f));
            g.drawText (top, b.removeFromTop (h * 0.36f), Justification::centred, false);
            drawGlow (g, mainText, b, bhFont (h * 0.46f, 1, 0.04f), sk.accent, Justification::centred);
            if (tempoNote) {}
        }
        else
        {
            g.setFont (bhFont (h * 0.56f, 1, 0.03f));
            const float wm = g.getCurrentFont().getStringWidthFloat (mainText);
            g.setFont (bhFont (h * 0.40f, 0, 0.02f));
            const float ws = g.getCurrentFont().getStringWidthFloat (subText);
            const float x0 = b.getCentreX() - (wm + 8.f + ws) * 0.5f;
            drawGlow (g, mainText, Rectangle<float> (x0, b.getY(), wm + 4.f, h), bhFont (h * 0.56f, 1, 0.03f), sk.accent, Justification::centredLeft);
            g.setColour (draggable ? Colour (0xff9aa0ab) : Colour (0xff5c6270)); g.setFont (bhFont (h * 0.40f, 0, 0.02f));
            g.drawText (subText, Rectangle<float> (x0 + wm + 8.f, b.getY(), ws + 6.f, h), Justification::centredLeft, false);
        }
    }
    void resized() override { ed.setBounds (getLocalBounds().reduced (3)); ed.setFont (bhFont ((float) getHeight() * 0.42f, 1)); }
    void mouseDown (const MouseEvent& e) override { if (draggable) { dragging = true; startY = e.position.y; if (onDragBegin) onDragBegin(); } }
    void mouseDrag (const MouseEvent& e) override { if (dragging && onDragDelta) onDragDelta ((startY - e.position.y) * (e.mods.isShiftDown() ? 0.2f : 1.f)); }
    void mouseUp (const MouseEvent&) override { if (dragging) { dragging = false; if (onDragEnd) onDragEnd(); } }
    void mouseDoubleClick (const MouseEvent&) override
    {
        if (! editable || ! getEditText) return;
        ed.setText (getEditText(), false); ed.setVisible (true); ed.grabKeyboardFocus(); ed.selectAll();
    }
private:
    static void drawGlow (Graphics& g, const String& t, Rectangle<float> r, Font f, Colour c, Justification j)
    {
        g.setFont (f);
        g.setColour (c.withAlpha (0.22f)); for (int dx = -1; dx <= 1; ++dx) for (int dy = -1; dy <= 1; ++dy) if (dx || dy) g.drawText (t, r.translated ((float) dx, (float) dy), j, false);
        g.setColour (c); g.drawText (t, r, j, false);
    }
    void finish (bool apply)
    {
        if (! ed.isVisible()) return;
        const String txt = ed.getText(); ed.setVisible (false);
        if (apply && onEdited) onEdited (txt);
    }
    bool stacked, dragging = false; float startY = 0.f; TextEditor ed;
};

//==============================================================================  needle VU meter (port of the HTML SVG meter)
class VuMeter : public Component
{
public:
    explicit VuMeter (bool gr) : isGR (gr) { needle = target = gr ? 22.f : -55.f; }
    int skinType = 0;
    void setLevel (float v) { target = isGR ? 22.f - jlimit (0.f, 20.f, v) / 20.f * 77.f : -55.f + (jlimit (-20.f, 3.f, v) + 20.f) / 23.f * 97.f; }
    void tick() { needle += (target - needle) * 0.2f; phase += 0.02f; repaint(); }
    static float designAspect() { return 150.f / 320.f; }

    void paint (Graphics& g) override
    {
        const auto full = getLocalBounds().toFloat();
        const float fr = full.getWidth() / 340.f;                        // frame scale (340 design px wide)
        g.setColour (Colour (0xff0b0c0e)); g.fillRoundedRectangle (full.reduced (1.f), 5.f * fr);
        g.setColour (Colours::white.withAlpha (0.14f)); g.drawRoundedRectangle (full.reduced (0.5f), 5.f * fr, 1.f);
        auto face = full.reduced (8.f * fr);
        Graphics::ScopedSaveState ss (g);
        { Path c; c.addRoundedRectangle (face, 2.f); g.reduceClipRegion (c); }
        const float s = face.getWidth() / 320.f;
        g.addTransform (AffineTransform::scale (s).translated (face.getX(), face.getY()));

        ColourGradient bgc (Colour (0xfff7f2e2), 160.f, 82.f, Colour (0xffcfc8b2), 160.f + 224.f, 82.f, true);
        bgc.addColour (0.65, Colour (0xffe9e2cf));
        g.setGradientFill (bgc); g.fillRect (0.f, 0.f, 320.f, 150.f);

        const float CX = 160.f, CY = 140.f, VR = 116.f;
        auto vp = [&] (float r, float deg) { const float a = degreesToRadians (deg - 90.f); return Point<float> (CX + r * std::cos (a), CY + r * std::sin (a)); };
        auto arc = [&] (float r, float a1, float a2) { Path p; p.addCentredArc (CX, CY, r, r, 0.f, degreesToRadians (a1), degreesToRadians (a2), true); return p; };
        g.setColour (Colour (0xff1a1a1a)); g.strokePath (arc (VR, -56.f, 43.f), PathStrokeType (1.4f));
        if (! isGR) { g.setColour (Colour (0xffc41a1a)); g.strokePath (arc (VR, 14.f, 42.f), PathStrokeType (4.5f, PathStrokeType::curved, PathStrokeType::rounded)); }
        struct M { const char* t; float a; bool red; };
        static const M om[] = { { "20", -55, 0 }, { "10", -42, 0 }, { "7", -30, 0 }, { "5", -20, 0 }, { "3", -11, 0 }, { "2", -4, 0 }, { "1", 4, 0 }, { "0", 14, 1 }, { "1", 24, 1 }, { "2", 33, 1 }, { "3", 42, 1 } };
        static const M gm[] = { { "20", -55, 0 }, { "10", -42, 0 }, { "7", -30, 0 }, { "5", -20, 0 }, { "3", -11, 0 }, { "2", -4, 0 }, { "1", 6, 0 }, { "0", 22, 0 } };
        const M* marks = isGR ? gm : om; const int nm = isGR ? 8 : 11;
        for (int i = 0; i < nm; ++i)
        {
            const auto p1 = vp (VR - 13.f, marks[i].a), p2 = vp (VR, marks[i].a), pl = vp (VR - 28.f, marks[i].a);
            g.setColour (marks[i].red ? Colour (0xffc41a1a) : Colour (0xff1a1a1a)); g.drawLine (Line<float> (p1, p2), 1.5f);
            g.setFont (bhFont (13.5f, 2)); g.setColour (marks[i].red ? Colour (0xffc41a1a) : Colour (0xff0a0a0a));
            g.drawText (marks[i].t, Rectangle<float> (pl.x - 16.f, pl.y - 9.f, 32.f, 18.f), Justification::centred, false);
        }
        g.setColour (Colour (0xff0a0a0a)); g.setFont (bhFont (20.f, 3, 0.05f));
        g.drawText (isGR ? "GR" : "VU", Rectangle<float> (CX - 40.f, CY - 44.f, 80.f, 24.f), Justification::centred, false);
        {
            Graphics::ScopedSaveState s2 (g);
            g.addTransform (AffineTransform::rotation (degreesToRadians (needle), CX, CY));
            g.setColour (Colours::black.withAlpha (0.22f)); g.drawLine (CX + 1.5f, CY + 1.5f, CX + 1.5f, CY - VR + 7.f, 1.5f);
            g.setColour (Colour (0xff0a0a0a)); g.drawLine (CX, CY, CX, CY - VR + 6.f, 1.5f);
            g.fillRoundedRectangle (CX - 2.f, CY, 4.f, 9.f, 2.f);
        }
        g.setColour (Colour (0xff1a1a1a)); g.fillEllipse (CX - 13.f, CY - 6.5f, 26.f, 13.f);
        g.setColour (Colour (0xff8a6d1f)); g.fillEllipse (CX - 8.f, CY - 5.1f, 16.f, 7.2f);
        // warm backlight + glass
        ColourGradient warm (Colour (0x26ffc46e).withMultipliedAlpha (0.8f + 0.2f * std::sin (phase)), CX, 90.f, Colours::transparentBlack, CX + 140.f, 90.f, true);
        g.setGradientFill (warm); g.fillRect (0.f, 0.f, 320.f, 150.f);
        ColourGradient glass (Colours::white.withAlpha (0.18f), 0.f, 0.f, Colours::transparentBlack, 80.f, 70.f, false);
        g.setGradientFill (glass); g.fillRect (0.f, 0.f, 320.f, 150.f);
        ColourGradient vig (Colours::transparentBlack, CX, 75.f, Colours::black.withAlpha (0.24f), CX + 190.f, 75.f, true); vig.addColour (0.58, Colours::transparentBlack);
        g.setGradientFill (vig); g.fillRect (0.f, 0.f, 320.f, 150.f);
    }
private:
    bool isGR; float needle = 0.f, target = 0.f, phase = 0.f;
};

} // namespace ui
