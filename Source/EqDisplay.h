// BoomHype Tech - Tempo Reverb MK I  -  spectral EQ display (smooth analyser + EQ curve + draggable bands)
#pragma once
#include "Ui.h"
#include "PluginProcessor.h"

class EqDisplay : public juce::Component
{
public:
    explicit EqDisplay (TempoReverbProcessor& p)
        : proc (p), fft (12), window ((size_t) N, juce::dsp::WindowingFunction<float>::hann)
    {
        db.fill (-100.f); fftData.fill (0.f);
        setMouseCursor (juce::MouseCursor::CrosshairCursor);
    }
    int skinType = 0, activeBand = 0;
    std::function<void (int)> onActiveBand;

    static constexpr int N = 4096, kCols = 480;

    // ---------------------------------------------------------------- analyser
    void tick()
    {
        const double sr = proc.getSampleRate() > 0.0 ? proc.getSampleRate() : 44100.0;
        const int w = proc.scopeWrite.load(), mask = TempoReverbProcessor::scopeSize - 1;
        for (int i = 0; i < N; ++i) fftData[(size_t) i] = proc.scope[(size_t) ((w - N + i) & mask)];
        std::fill (fftData.begin() + N, fftData.end(), 0.f);
        window.multiplyWithWindowingTable (fftData.data(), (size_t) N);
        fft.performFrequencyOnlyForwardTransform (fftData.data());
        std::array<float, N / 2> pwr {};
        const float norm = 1.f / ((float) N * 0.25f);
        for (int k = 0; k < N / 2; ++k) { const float a = fftData[(size_t) k] * norm; pwr[(size_t) k] = a * a; }

        const float binHz = (float) sr / (float) N;
        std::array<float, kCols> col {};
        for (int c = 0; c < kCols; ++c)                                  // log-spaced columns, ~1/12 octave wide integration
        {
            const float f = 20.f * std::pow (1000.f, (float) c / (float) (kCols - 1));
            const float lo = f * 0.9715f / binHz, hi = f * 1.0293f / binHz;
            if (hi - lo < 1.f)
            {
                const float pos = f / binHz; const int i0 = juce::jlimit (0, N / 2 - 2, (int) pos); const float fr = pos - (float) i0;
                col[(size_t) c] = pwr[(size_t) i0] * (1.f - fr) + pwr[(size_t) (i0 + 1)] * fr;
            }
            else
            {
                const int a = juce::jmax (1, (int) std::ceil (lo)), b = juce::jmin (N / 2 - 1, (int) std::floor (hi));
                float s = 0.f; int n = 0; for (int i = a; i <= b; ++i) { s += pwr[(size_t) i]; ++n; }
                col[(size_t) c] = n ? s / (float) n : 0.f;
            }
        }
        // gaussian smoothing across frequency (power domain) -> no jagged peaks
        std::array<float, kCols> sm {};
        const int R = 9; float kern[2 * R + 1]; float ks = 0.f;
        for (int i = -R; i <= R; ++i) { kern[i + R] = std::exp (-0.5f * (float) (i * i) / (3.2f * 3.2f)); ks += kern[i + R]; }
        for (int c = 0; c < kCols; ++c)
        {
            float s = 0.f, wsum = 0.f;
            for (int i = -R; i <= R; ++i) { const int j = c + i; if (j < 0 || j >= kCols) continue; s += col[(size_t) j] * kern[i + R]; wsum += kern[i + R]; }
            sm[(size_t) c] = s / wsum;
        }
        // temporal ballistics (fast attack, slow release) at the ~60 Hz timer rate
        const float aAtt = 1.f - std::exp (-1.f / (0.060f * 60.f)), aRel = 1.f - std::exp (-1.f / (0.280f * 60.f));
        for (int c = 0; c < kCols; ++c)
        {
            const float f = 20.f * std::pow (1000.f, (float) c / (float) (kCols - 1));
            const float d = 10.f * std::log10 (sm[(size_t) c] + 1e-12f) + 4.5f * std::log2 (f / 1000.f);   // +4.5 dB/oct tilt = flat for music
            float& cur = db[(size_t) c];
            cur += (d - cur) * (d > cur ? aAtt : aRel);
        }
        repaint();
    }

    // ---------------------------------------------------------------- drawing
    void paint (juce::Graphics& g) override
    {
        using namespace juce;
        const auto& sk = ui::skinFor (skinType);
        const float w = (float) getWidth(), h = (float) getHeight(), s = h / 196.f;
        const double sr = proc.getSampleRate() > 0.0 ? proc.getSampleRate() : 44100.0;
        const bool bypassed = proc.get ("bypass") > 0.5f;
        const auto accent = sk.accent;

        ColourGradient bg (Colour (0xff0e1016), 0.f, 0.f, Colour (0xff06070b), 0.f, h, false);
        g.setGradientFill (bg); g.fillRect (0.f, 0.f, w, h);

        // analyser
        {
            Path sp; Point<float> prev, cur; bool first = true;
            std::array<Point<float>, kCols> pts;
            for (int c = 0; c < kCols; ++c)
            {
                const float a = db[(size_t) juce::jmax (0, c - 1)], b = db[(size_t) c], d = db[(size_t) juce::jmin (kCols - 1, c + 1)];
                const float v = 0.25f * a + 0.5f * b + 0.25f * d;
                pts[(size_t) c] = { w * (float) c / (float) (kCols - 1), h - jlimit (0.f, 1.f, (v + 100.f) / 70.f) * h * 0.80f };
            }
            sp.startNewSubPath (pts[0]);
            for (int c = 1; c < kCols - 1; ++c) { const auto mid = (pts[(size_t) c] + pts[(size_t) (c + 1)]) * 0.5f; sp.quadraticTo (pts[(size_t) c], mid); }
            sp.lineTo (pts[(size_t) (kCols - 1)]);
            Path fill (sp); fill.lineTo (w, h); fill.lineTo (0.f, h); fill.closeSubPath();
            Graphics::ScopedSaveState ss (g);
            if (bypassed) g.setOpacity (0.35f);
            g.setColour (Colour (0x21c8ceda)); g.fillPath (fill);
            g.setColour (Colour (0x66dce2ec)); g.strokePath (sp, PathStrokeType (1.2f * s, PathStrokeType::curved, PathStrokeType::rounded));
            (void) prev; (void) cur; (void) first;
        }
        // grid
        g.setFont (ui::bhFont (14.f * s, 1));
        for (float f : { 20.f, 50.f, 100.f, 200.f, 500.f, 1000.f, 2000.f, 5000.f, 10000.f, 20000.f })
        {
            const float x = fToX (f);
            g.setColour (Colours::white.withAlpha (0.05f)); g.drawVerticalLine ((int) x, 0.f, h);
            if (f == 100.f || f == 1000.f || f == 10000.f)
            { g.setColour (Colours::white.withAlpha (0.4f)); g.drawText (f >= 1000.f ? String ((int) (f / 1000.f)) + "k" : String ((int) f), Rectangle<float> (x - 30.f * s, 4.f * s, 60.f * s, 16.f * s), Justification::centred, false); }
        }
        for (int d : { 12, 6, 0, -6, -12 })
        {
            const float y = gToY ((float) d);
            g.setColour (Colours::white.withAlpha (d == 0 ? 0.13f : 0.045f)); g.drawHorizontalLine ((int) y, 0.f, w);
            g.setColour (Colours::white.withAlpha (0.35f)); g.drawText ((d > 0 ? "+" : "") + String (d), Rectangle<float> (4.f * s, y - 2.f * s, 40.f * s, 16.f * s), Justification::centredLeft, false);
        }
        // filter cut shading
        const int hpS = (int) proc.get ("hpS"), lpS = (int) proc.get ("lpS");
        const float hpF = proc.get ("hpF"), lpF = proc.get ("lpF");
        const float xhp = fToX (hpF), xlp = fToX (lpF);
        auto cut = [&] (float x0, float x1)
        {
            if (x1 <= x0) return;
            g.setColour (Colours::black.withAlpha (0.45f)); g.fillRect (x0, 0.f, x1 - x0, h);
            Graphics::ScopedSaveState ss (g); g.reduceClipRegion (Rectangle<int> ((int) x0, 0, (int) (x1 - x0) + 1, (int) h));
            g.setColour (accent.withAlpha (0.06f));
            for (float xx = x0 - h; xx < x1; xx += 9.f * s) g.drawLine (xx, h, xx + h, 0.f, 1.f);
        };
        if (hpS > 0) cut (0.f, xhp);
        if (lpS > 0) cut (xlp, w);

        // response curve
        bh::CutFilter hpc, lpc; hpc.set (sr, hpF, hpS, true); lpc.set (sr, lpF, lpS, false);
        bh::BiquadCoeffs bc[5]; bool bon[5];
        for (int i = 0; i < 5; ++i) { const String n (i); bon[i] = proc.get ("b" + n) < 0.5f; bc[i] = bh::makePeak (sr, proc.get ("f" + n), proc.get ("q" + n), proc.get ("g" + n)); }
        Path curve; Path area; bool first = true;
        for (float x = 0.f; x <= w + 0.1f; x += 2.f)
        {
            const double f = xToF (x); double d = hpc.magDb (sr, f) + lpc.magDb (sr, f);
            for (int i = 0; i < 5; ++i) if (bon[i]) d += bh::magnitudeDb (bc[i], sr, f);
            const float y = jlimit (2.f, h - 2.f, gToY ((float) d));
            if (first) { curve.startNewSubPath (x, y); first = false; } else curve.lineTo (x, y);
        }
        area = curve; area.lineTo (w, h); area.lineTo (0.f, h); area.closeSubPath();
        ColourGradient fg (accent.withAlpha (0.22f), 0.f, 0.f, accent.withAlpha (0.02f), 0.f, h, false);
        g.setGradientFill (fg); g.fillPath (area);
        g.setColour (accent.withAlpha (0.28f)); g.strokePath (curve, PathStrokeType (6.f * s, PathStrokeType::curved, PathStrokeType::rounded));
        g.setColour (accent); g.strokePath (curve, PathStrokeType (2.4f * s, PathStrokeType::curved, PathStrokeType::rounded));

        // HP / LP tabs
        auto tab = [&] (float tx, bool on)
        {
            if (! on) return;
            g.setColour (accent.withAlpha (0.55f));
            for (float y = 0.f; y < h; y += 6.f * s) g.drawLine (tx, y, tx, y + 3.f * s, 1.f);
            const float ty = h - 24.f * s;
            Rectangle<float> r (tx - 6.f * s, ty, 12.f * s, 16.f * s);
            g.setColour (Colour (0xff191c22)); g.fillRoundedRectangle (r, 2.f * s);
            g.setColour (accent); g.drawRoundedRectangle (r, 2.f * s, 1.2f);
            Path a1; a1.addTriangle (tx - 3.f * s, ty + 8.f * s, tx + 0.5f * s, ty + 4.5f * s, tx + 0.5f * s, ty + 11.5f * s);
            Path a2; a2.addTriangle (tx + 3.f * s, ty + 8.f * s, tx - 0.5f * s, ty + 4.5f * s, tx - 0.5f * s, ty + 11.5f * s);
            g.fillPath (a1); g.fillPath (a2);
        };
        tab (xhp, hpS > 0); tab (xlp, lpS > 0);

        // band handles
        static const ui::Cap capOf[5] = { ui::CapBlue, ui::CapGreen, ui::CapYellow, ui::CapOrange, ui::CapRed };
        for (int i = 0; i < 5; ++i)
        {
            const String n (i);
            const auto p = bandPos (i); const bool act = i == activeBand, byp = ! bon[i];
            const float r = (act ? 8.5f : 7.f) * s * 1.15f;
            if (act) { g.setColour (Colours::white.withAlpha (0.85f)); g.drawEllipse (p.x - r - 3.f * s, p.y - r - 3.f * s, (r + 3.f * s) * 2.f, (r + 3.f * s) * 2.f, 1.4f); }
            g.setColour (Colours::black.withAlpha (0.5f)); g.fillEllipse (p.x - r, p.y - r + 2.f * s, r * 2.f, r * 2.f);
            g.setColour (byp ? Colour (0xff4a4d54) : sk.caps[capOf[i]]); g.fillEllipse (p.x - r, p.y - r, r * 2.f, r * 2.f);
            g.setColour (Colours::black.withAlpha (0.55f)); g.drawEllipse (p.x - r, p.y - r, r * 2.f, r * 2.f, 1.f);
            g.setColour (byp ? Colour (0xff9aa0ab) : (i == 2 ? Colour (0xff1a1a1a) : Colours::white)); g.setFont (ui::bhFont (r * 1.2f, 2));
            g.drawText (String (i + 1), Rectangle<float> (p.x - r, p.y - r, r * 2.f, r * 2.f), Justification::centred, false);
        }
        g.setColour (Colours::white.withAlpha (0.28f)); g.setFont (ui::bhFont (13.f * s, 1, 0.08f));
        g.drawText ("LIVE SPECTRUM", Rectangle<float> (44.f * s, h - 22.f * s, 200.f * s, 16.f * s), Justification::centredLeft, false);
        // glass sheen
        ColourGradient gl (Colours::white.withAlpha (0.06f), 0.f, 0.f, Colours::transparentWhite, w * 0.25f, h, false);
        g.setGradientFill (gl); g.fillRect (0.f, 0.f, w, h);
    }

    // ---------------------------------------------------------------- interaction
    void mouseDown (const juce::MouseEvent& e) override
    {
        const auto hit = hitTest (e.position);
        if (hit.type == None) return;
        if (hit.type == Band && ! hit.near) { activeBand = hit.idx; if (onActiveBand) onActiveBand (hit.idx); repaint(); return; }
        drag = hit; moved = false;
        if (hit.type == Band) { activeBand = hit.idx; if (onActiveBand) onActiveBand (hit.idx); const juce::String n (hit.idx); begin ("f" + n); begin ("g" + n); begin ("b" + n); setP ("b" + n, 0.f); }
        else begin (hit.type == Hp ? "hpF" : "lpF");
        repaint();
    }
    void mouseMove (const juce::MouseEvent& e) override
    {
        const auto hit = hitTest (e.position);
        setMouseCursor (hit.type == Hp || hit.type == Lp ? juce::MouseCursor::LeftRightResizeCursor : (hit.type == Band && hit.near ? juce::MouseCursor::DraggingHandCursor : juce::MouseCursor::CrosshairCursor));
    }
    void mouseDrag (const juce::MouseEvent& e) override
    {
        if (drag.type == None) return;
        const float f = juce::jlimit (20.f, 20000.f, xToF (e.position.x));
        if (drag.type == Band)
        {
            const juce::String n (drag.idx); float g = juce::jlimit (-12.f, 12.f, yToG (e.position.y));
            if (e.mods.isShiftDown()) g = std::round (g * 10.f) / 10.f;
            setP ("f" + n, f); setP ("g" + n, g);
        }
        else setP (drag.type == Hp ? "hpF" : "lpF", f);
    }
    void mouseUp (const juce::MouseEvent&) override
    {
        if (drag.type == Band) { const juce::String n (drag.idx); end ("f" + n); end ("g" + n); end ("b" + n); }
        else if (drag.type == Hp) end ("hpF"); else if (drag.type == Lp) end ("lpF");
        drag = {};
    }
    void mouseDoubleClick (const juce::MouseEvent& e) override
    {
        const auto hit = hitTest (e.position);
        if (hit.type == Band) setP ("g" + juce::String (hit.idx), 0.f);
        else if (hit.type == Hp || hit.type == Lp) { const juce::String id = hit.type == Hp ? "hpS" : "lpS"; setP (id, proc.get (id) > 0.5f ? 0.f : 2.f); }
    }
    void mouseWheelMove (const juce::MouseEvent& e, const juce::MouseWheelDetails& wh) override
    {
        const auto hit = hitTest (e.position);
        if (hit.type == Band)
        {
            const juce::String id = "q" + juce::String (hit.idx);
            activeBand = hit.idx; if (onActiveBand) onActiveBand (hit.idx);
            setP (id, juce::jlimit (0.3f, 8.f, proc.get (id) * std::exp (wh.deltaY * 0.8f)));
        }
        else if (hit.type == Hp || hit.type == Lp)
        {
            const juce::String id = hit.type == Hp ? "hpS" : "lpS";
            setP (id, (float) juce::jlimit (0, 3, (int) proc.get (id) + (wh.deltaY > 0 ? 1 : -1)));
        }
    }

private:
    enum HitType { None, Band, Hp, Lp };
    struct Hit { HitType type = None; int idx = -1; bool near = false; };

    float fToX (float f) const { return (float) getWidth() * juce::jlimit (0.f, 1.f, std::log (f / 20.f) / std::log (1000.f)); }
    float xToF (float x) const { return 20.f * std::pow (1000.f, juce::jlimit (0.f, 1.f, x / (float) getWidth())); }
    float gToY (float g) const { const float h = (float) getHeight(), s = h / 196.f; return h * 0.5f - (g / 12.f) * (h * 0.5f - 16.f * s); }
    float yToG (float y) const { const float h = (float) getHeight(), s = h / 196.f; return (h * 0.5f - y) / (h * 0.5f - 16.f * s) * 12.f; }
    juce::Point<float> bandPos (int i) const
    {
        const juce::String n (i); const float h = (float) getHeight();
        return { fToX (proc.get ("f" + n)), juce::jlimit (9.f, h - 9.f, gToY (proc.get ("g" + n))) };
    }
    Hit hitTest (juce::Point<float> p) const
    {
        const float s = (float) getHeight() / 196.f;
        if (proc.get ("hpS") > 0.5f && std::abs (p.x - fToX (proc.get ("hpF"))) < 10.f * s) return { Hp, -1, true };
        if (proc.get ("lpS") > 0.5f && std::abs (p.x - fToX (proc.get ("lpF"))) < 10.f * s) return { Lp, -1, true };
        int best = 0; float bd = 1e9f;
        for (int i = 0; i < 5; ++i) { const float d = bandPos (i).getDistanceFrom (p); if (d < bd) { bd = d; best = i; } }
        return { Band, best, bd < 20.f * s };
    }
    void setP (const juce::String& id, float plain) { if (auto* p = proc.apvts.getParameter (id)) p->setValueNotifyingHost (p->convertTo0to1 (plain)); }
    void begin (const juce::String& id) { if (auto* p = proc.apvts.getParameter (id)) p->beginChangeGesture(); }
    void end (const juce::String& id) { if (auto* p = proc.apvts.getParameter (id)) p->endChangeGesture(); }

    TempoReverbProcessor& proc;
    juce::dsp::FFT fft; juce::dsp::WindowingFunction<float> window;
    std::array<float, 2 * N> fftData {};
    std::array<float, kCols> db {};
    Hit drag; bool moved = false;
};
