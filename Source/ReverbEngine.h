// BoomHype Tech - Tempo Reverb MK I
// Reverb DSP engine. Pure C++17 (no JUCE), so it can be unit-tested on its own.
//
//  HALL      8-line feedback delay network (FDN), sparse early reflections, pre-bloom tail
//  PLATE     Dattorro plate topology (Dattorro, JAES 1997): instant dense build-up,
//            no early reflections, bright, modulated all-pass tank
//  ROOM      small FDN, dense/strong early reflections, short decay, light modulation
//  SPACE     very large FDN, deep modulation, wide, long diffuse bloom
//  SPRING    dispersive all-pass chain in a feedback loop (the "boing / drip" chirp)
//  SHIMMER   FDN with an octave-up pitch shifter inside the feedback path
//  CATHEDRAL huge sparse early reflections, long pre-tail, dark and slow
//  LO-FI     small FDN + sample-rate/bit reduction + tape-style wobble
#pragma once
#include <vector>
#include <cmath>
#include <complex>
#include <algorithm>
#include <cstdint>

namespace bh
{
constexpr float kPi = 3.14159265358979323846f;

inline float dbToLin (float db) { return std::pow (10.0f, db * 0.05f); }
inline float clampf (float x, float lo, float hi) { return x < lo ? lo : (x > hi ? hi : x); }

enum Type { Hall = 0, Plate, Room, Space, Spring, Shimmer, Cathedral, LoFi, NumTypes };

inline constexpr const char* kTypeNames[NumTypes] = { "HALL", "PLATE", "ROOM", "SPACE", "SPRING", "SHIMMER", "CATHEDRAL", "LO-FI" };

// Note values are fractions of a whole note (1/1 = one bar of 4/4)
inline constexpr const char* kNoteNames[9] = { "1/32", "1/16T", "1/16", "1/8T", "1/8", "1/4T", "1/4", "1/2", "1/1" };
inline constexpr float kNoteFrac[9] = { 0.03125f, 0.0416667f, 0.0625f, 0.0833333f, 0.125f, 0.1666667f, 0.25f, 0.5f, 1.0f };

struct TypeDefaults { float predelay, decay, size, diffusion, damping, mod, width, tone, character; };
inline constexpr TypeDefaults kDefaults[NumTypes] = {
    //  pre    decay  size  diff  damp  mod   width tone  char
    {  25.f,  2.6f, .75f, .75f, .45f, .35f, 1.0f, .50f, .50f },   // Hall
    {   0.f,  1.8f, .50f, .90f, .35f, .25f, 1.0f, .55f, .60f },   // Plate
    {   5.f,  0.55f,.35f, .60f, .55f, .10f, 0.8f, .50f, .50f },   // Room
    {  40.f,  7.0f, .90f, .85f, .30f, .60f, 1.2f, .50f, .60f },   // Space
    {   0.f,  2.2f, .50f, .50f, .50f, .30f, 0.8f, .50f, .50f },   // Spring
    {  30.f,  5.5f, .85f, .85f, .25f, .60f, 1.1f, .60f, .50f },   // Shimmer
    {  55.f,  8.5f, .95f, .80f, .40f, .40f, 1.1f, .40f, .50f },   // Cathedral
    {  10.f,  1.6f, .50f, .60f, .60f, .60f, 0.8f, .40f, .60f }    // Lo-Fi
};

// ------------------------------------------------------------------ biquad / EQ helpers
struct BiquadCoeffs { double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0; };

inline BiquadCoeffs normalise (double b0, double b1, double b2, double a0, double a1, double a2)
{
    BiquadCoeffs c; c.b0 = b0 / a0; c.b1 = b1 / a0; c.b2 = b2 / a0; c.a1 = a1 / a0; c.a2 = a2 / a0; return c;
}
inline BiquadCoeffs makePeak (double fs, double f, double q, double gainDb)
{
    f = std::min (f, fs * 0.45);
    const double A = std::pow (10.0, gainDb / 40.0), w = 2.0 * 3.14159265358979 * f / fs;
    const double s = std::sin (w), c = std::cos (w), al = s / (2.0 * q);
    return normalise (1 + al * A, -2 * c, 1 - al * A, 1 + al / A, -2 * c, 1 - al / A);
}
inline BiquadCoeffs makeHP (double fs, double f, double q = 0.7071)
{
    f = std::min (f, fs * 0.45);
    const double w = 2.0 * 3.14159265358979 * f / fs, s = std::sin (w), c = std::cos (w), al = s / (2.0 * q);
    return normalise ((1 + c) / 2, -(1 + c), (1 + c) / 2, 1 + al, -2 * c, 1 - al);
}
inline BiquadCoeffs makeLP (double fs, double f, double q = 0.7071)
{
    f = std::min (f, fs * 0.45);
    const double w = 2.0 * 3.14159265358979 * f / fs, s = std::sin (w), c = std::cos (w), al = s / (2.0 * q);
    return normalise ((1 - c) / 2, 1 - c, (1 - c) / 2, 1 + al, -2 * c, 1 - al);
}
inline double magnitudeDb (const BiquadCoeffs& k, double fs, double f)
{
    const double w = 2.0 * 3.14159265358979 * f / fs;
    const std::complex<double> z1 = std::polar (1.0, -w), z2 = std::polar (1.0, -2.0 * w);
    const auto num = k.b0 + k.b1 * z1 + k.b2 * z2;
    const auto den = 1.0 + k.a1 * z1 + k.a2 * z2;
    return 20.0 * std::log10 (std::max (1e-9, std::abs (num / den)));
}
struct Biquad
{
    BiquadCoeffs c; double z1[2] { 0, 0 }, z2[2] { 0, 0 };
    inline float process (int ch, float xf)
    {
        const double x = xf, y = c.b0 * x + z1[ch];
        z1[ch] = c.b1 * x - c.a1 * y + z2[ch];
        z2[ch] = c.b2 * x - c.a2 * y;
        return (float) y;
    }
    void reset() { z1[0] = z1[1] = z2[0] = z2[1] = 0; }
};

// ------------------------------------------------------------------ building blocks
struct Delay
{
    std::vector<float> buf; int mask = 0, w = 0;
    void init (int maxSamples) { int n = 1; while (n < maxSamples + 8) n <<= 1; buf.assign ((size_t) n, 0.f); mask = n - 1; w = 0; }
    void clear() { std::fill (buf.begin(), buf.end(), 0.f); w = 0; }
    inline void push (float x) { buf[(size_t) w] = x; w = (w + 1) & mask; }
    // d = 0 returns the most recently pushed sample
    inline float readInt (int d) const { return buf[(size_t) ((w - 1 - d) & mask)]; }
    inline float read (float d) const
    {
        const float p = (float) (w - 1) - d;
        const int i = (int) std::floor (p);
        const float f = p - (float) i;
        const float a = buf[(size_t) (i & mask)], b = buf[(size_t) ((i + 1) & mask)];
        return a + (b - a) * f;
    }
};

struct OnePole
{
    float a = 1.f, y = 0.f;
    void setCutoff (float fc, float sr) { a = 1.f - std::exp (-2.f * kPi * std::min (fc, 0.45f * sr) / sr); }
    inline float lp (float x) { y += a * (x - y); return y; }
    void reset() { y = 0.f; }
};

struct Allpass
{
    Delay d; int len = 1; float g = 0.5f;
    void init (int maxLen) { d.init (maxLen + 48); }
    void set (int length, float gain) { len = std::max (1, length); g = gain; }
    void clear() { d.clear(); }
    inline float process (float x)
    {
        const float zd = d.readInt (len - 1), v = x - g * zd;
        d.push (v); return zd + g * v;
    }
    inline float processMod (float x, float mod)
    {
        const float zd = d.read (std::max (0.f, (float) (len - 1) + mod)), v = x - g * zd;
        d.push (v); return zd + g * v;
    }
};

struct PitchShifter   // two cross-faded delay taps; ratio 2 = one octave up
{
    Delay d; float phase = 0.f; int win = 2048;
    void prepare (float sr) { win = (int) (0.06f * sr); d.init (win * 2 + 16); phase = 0.f; }
    void clear() { d.clear(); phase = 0.f; }
    inline float process (float x, float ratio)
    {
        d.push (x);
        phase += (ratio - 1.f) / (float) win;
        if (phase >= 1.f) phase -= 1.f;
        if (phase < 0.f) phase += 1.f;
        float p2 = phase + 0.5f; if (p2 >= 1.f) p2 -= 1.f;
        float w1 = std::sin (kPi * phase), w2 = std::sin (kPi * p2); w1 *= w1; w2 *= w2;
        return d.read ((1.f - phase) * (float) win) * w1 + d.read ((1.f - p2) * (float) win) * w2;
    }
};

// ------------------------------------------------------------------ 8-line FDN
class FDN
{
public:
    static constexpr int N = 8;
    void prepare (float sampleRate)
    {
        sr = sampleRate;
        for (int i = 0; i < N; ++i) { line[i].init ((int) (0.6f * sr) + 64); damp[i].reset(); ph[i] = 0.9f * (float) i; }
        static constexpr float apMs[2][4] = { { 4.7f, 7.9f, 11.3f, 16.9f }, { 5.3f, 8.7f, 12.7f, 17.3f } };
        for (int c = 0; c < 2; ++c)
            for (int k = 0; k < 4; ++k)
            {
                const int l = (int) (apMs[c][k] * 0.001f * sr);
                ap[c][k].init (l + 2); ap[c][k].set (l, 0.7f);
            }
        curMul = tgtMul = 1.f; curRt = tgtRt = 1.f; updateGains();
    }
    void clear()
    {
        for (int i = 0; i < N; ++i) { line[i].clear(); damp[i].reset(); }
        for (int c = 0; c < 2; ++c) for (int k = 0; k < 4; ++k) ap[c][k].clear();
    }
    void setTargets (float sizeMul, float rt60, float dampHz, float modDepthSamples, float diffG, bool freezeOn)
    {
        tgtMul = sizeMul; tgtRt = std::max (0.05f, rt60 * 1.25f); modDepth = modDepthSamples; freeze = freezeOn;
        for (int i = 0; i < N; ++i) damp[i].setCutoff (freeze ? 0.45f * sr : dampHz, sr);
        for (int c = 0; c < 2; ++c) for (int k = 0; k < 4; ++k) ap[c][k].g = diffG;
    }
    float inputNorm() const { return norm; }

    inline void process (float inL, float inR, float extraIn, float& oL, float& oR)
    {
        curMul += (tgtMul - curMul) * 0.0006f;
        curRt += (tgtRt - curRt) * 0.0006f;
        if ((++cnt & 15) == 0) updateGains();

        float d[2] = { inL, inR };
        for (int c = 0; c < 2; ++c) for (int k = 0; k < 4; ++k) d[c] = ap[c][k].process (d[c]);

        float y[N], sum = 0.f;
        for (int i = 0; i < N; ++i)
        {
            ph[i] += rate[i] / sr * 2.f * kPi; if (ph[i] > 2.f * kPi) ph[i] -= 2.f * kPi;
            const float dl = std::max (2.f, baseMs[i] * 0.001f * sr * curMul + modDepth * std::sin (ph[i]));
            y[i] = damp[i].lp (line[i].read (dl)) * g[i];
            sum += y[i];
        }
        const float h = sum * (2.f / (float) N);
        oL = oR = 0.f;
        for (int i = 0; i < N; ++i)
        {
            const float inj = ((i & 1) ? d[1] : d[0]) * sgn[i] * norm * (freeze ? 0.f : 1.f) + extraIn * sgn[i] * 0.5f;
            line[i].push (y[i] - h + inj);
            oL += y[i] * sL[i]; oR += y[i] * sR[i];
        }
        oL *= 0.35f; oR *= 0.35f;
    }

private:
    void updateGains()
    {
        float gs = 0.f;
        for (int i = 0; i < N; ++i)
        {
            const float lenSec = baseMs[i] * 0.001f * curMul;
            g[i] = freeze ? 0.99995f : std::min (0.9995f, std::pow (10.f, -3.f * lenSec / curRt));
            gs += g[i];
        }
        const float ga = gs / (float) N;
        norm = 0.55f * std::pow (std::sqrt (std::max (0.02f, 1.f - ga * ga)), 0.6f);
    }

    float sr = 48000.f, curMul = 1.f, tgtMul = 1.f, curRt = 1.f, tgtRt = 1.f, modDepth = 0.f, norm = 0.3f;
    bool freeze = false; unsigned cnt = 0;
    Delay line[N]; OnePole damp[N]; Allpass ap[2][4];
    float ph[N] {}, g[N] {};
    static constexpr float baseMs[N] = { 29.7f, 37.1f, 41.1f, 43.7f, 53.3f, 59.9f, 67.7f, 73.3f };
    static constexpr float rate[N]   = { 0.21f, 0.33f, 0.47f, 0.59f, 0.71f, 0.83f, 1.07f, 1.31f };
    static constexpr float sgn[N]    = { 1.f, -1.f, 1.f, 1.f, -1.f, 1.f, -1.f, -1.f };
    static constexpr float sL[N]     = { 1.f, 1.f, -1.f, -1.f, 1.f, 1.f, -1.f, -1.f };
    static constexpr float sR[N]     = { 1.f, -1.f, -1.f, 1.f, 1.f, -1.f, -1.f, 1.f };
};

// ------------------------------------------------------------------ Dattorro plate
class PlateReverb
{
public:
    void prepare (float sampleRate)
    {
        sr = sampleRate; s = sr / 29761.f;
        auto L = [&] (float n) { return (int) std::lround (n * s); };
        const int ia[4] = { 142, 107, 379, 277 };
        for (int k = 0; k < 4; ++k) { inAP[k].init (L ((float) ia[k])); inAP[k].set (L ((float) ia[k]), k < 2 ? 0.75f : 0.625f); }
        lAP1.init (L (672) + 64);  lAP1.set (L (672), -0.7f);  lAP2.init (L (1800)); lAP2.set (L (1800), 0.5f);
        rAP1.init (L (908) + 64);  rAP1.set (L (908), -0.7f);  rAP2.init (L (2656)); rAP2.set (L (2656), 0.5f);
        lD1.init (L (4453 * 1.8f)); lD2.init (L (3720 * 1.8f)); rD1.init (L (4217 * 1.8f)); rD2.init (L (3163 * 1.8f));
        clear();
    }
    void clear()
    {
        for (auto& a : inAP) a.clear();
        lAP1.clear(); lAP2.clear(); rAP1.clear(); rAP2.clear(); lD1.clear(); lD2.clear(); rD1.clear(); rD2.clear();
        bw.reset(); lDamp.reset(); rDamp.reset(); t = 0.f;
    }
    void setTargets (float sizeMul, float rt60, float dampHz, float modAmount, float diffusion, float brightness, bool freezeOn)
    {
        mul = clampf (sizeMul, 0.4f, 1.75f); freeze = freezeOn;
        const float loopSec = 0.7254f * mul;
        decayG = freeze ? 0.99998f : std::min (0.9995f, std::pow (10.f, -1.5f * loopSec / std::max (0.05f, rt60 * 1.22f)));
        lDamp.setCutoff (freeze ? 0.45f * sr : dampHz, sr); rDamp.setCutoff (freeze ? 0.45f * sr : dampHz, sr);
        bw.setCutoff (3000.f * std::pow (6.f, brightness), sr);
        excursion = modAmount * 12.f * s;
        const float dd = 0.45f + 0.25f * diffusion;          // decay diffusion 1 (paper: 0.7)
        lAP1.g = rAP1.g = -dd; lAP2.g = rAP2.g = 0.25f + 0.25f * diffusion;   // paper: 0.5
        for (int k = 0; k < 4; ++k) inAP[k].g = (k < 2 ? 0.75f : 0.625f) * (0.6f + 0.4f * diffusion);
    }
    inline void process (float in, float& oL, float& oR)
    {
        t += 1.f / sr;
        float x = bw.lp (freeze ? 0.f : in);
        for (int k = 0; k < 4; ++k) x = inAP[k].process (x);
        const float lm = excursion * std::sin (2.f * kPi * 0.9f * t), rm = excursion * std::sin (2.f * kPi * 1.1f * t + 1.3f);

        const float lOut = lD2.read (3720.f * s * mul), rOut = rD2.read (3163.f * s * mul);
        float a = lAP1.processMod (x + rOut, lm); lD1.push (a);
        float b = lDamp.lp (lD1.read (4453.f * s * mul)) * decayG;
        lD2.push (lAP2.process (b));

        float c = rAP1.processMod (x + lOut, rm); rD1.push (c);
        float e = rDamp.lp (rD1.read (4217.f * s * mul)) * decayG;
        rD2.push (rAP2.process (e));

        auto T = [&] (const Delay& d, int idx) { return d.read (std::min ((float) idx * s * mul, (float) (d.mask - 8))); };
        auto TA = [&] (const Allpass& p, int idx) { return p.d.read ((float) idx * s); };
        oL = 0.6f * (T (rD1, 266) + T (rD1, 2974) - TA (rAP2, 1913) + T (rD2, 1996) - T (lD1, 1990) - TA (lAP2, 187) - T (lD2, 1066));
        oR = 0.6f * (T (lD1, 353) + T (lD1, 3627) - TA (lAP2, 1228) + T (lD2, 2673) - T (rD1, 2111) - TA (rAP2, 335) - T (rD2, 121));
    }
private:
    float sr = 48000.f, s = 1.6f, mul = 1.f, decayG = 0.8f, excursion = 4.f, t = 0.f; bool freeze = false;
    Allpass inAP[4], lAP1, lAP2, rAP1, rAP2; Delay lD1, lD2, rD1, rD2; OnePole bw, lDamp, rDamp;
};

// ------------------------------------------------------------------ Spring
class SpringReverb
{
public:
    static constexpr int Stages = 80;
    void prepare (float sampleRate)
    {
        sr = sampleRate;
        for (int k = 0; k < 2; ++k) { sp[k].loop.init ((int) (0.12f * sr)); }
        clear();
    }
    void clear() { for (auto& q : sp) { q.loop.clear(); for (auto& st : q.st) st = {}; q.lp.reset(); q.hp.reset(); q.inLp.reset(); } }
    void setTargets (float rt60, float dampHz, float character, float sizeNorm)
    {
        const float ms[2] = { 34.f + 14.f * sizeNorm, 41.f + 18.f * sizeNorm };
        for (int k = 0; k < 2; ++k)
        {
            sp[k].delay = ms[k] * 0.001f * sr;
            sp[k].fb = std::min (0.97f, std::pow (10.f, -3.f * ms[k] * 0.001f / std::max (0.1f, rt60 * 1.2f)));
            sp[k].lp.setCutoff (std::min (dampHz, 6500.f), sr); sp[k].hp.setCutoff (160.f, sr); sp[k].inLp.setCutoff (5500.f, sr);
        }
        a = -(0.45f + 0.3f * character); drive = 1.f + 3.f * character;
    }
    inline void process (float inL, float inR, float& oL, float& oR)
    {
        const float m = (inL + inR) * 0.5f;
        oL = sp[0].run (m, a, drive, Stages) ; oR = sp[1].run (m, a, drive, Stages);
    }
private:
    struct AP1 { float x1 = 0.f, y1 = 0.f; inline float p (float x, float a) { const float y = a * (x - y1) + x1; x1 = x; y1 = y; return y; } };
    struct Line
    {
        Delay loop; AP1 st[Stages]; OnePole lp, hp, inLp; float delay = 1500.f, fb = 0.8f;
        inline float run (float in, float a, float drive, int n)
        {
            float z = loop.read (delay);
            for (int k = 0; k < n; ++k) z = st[k].p (z, a);
            z = lp.lp (z); z -= hp.lp (z);
            z = std::tanh (z * drive) / drive;
            loop.push (inLp.lp (in) + fb * z);
            return z * 1.2f;
        }
    };
    float sr = 48000.f, a = -0.6f, drive = 2.f; Line sp[2];
};

// ------------------------------------------------------------------ main engine
struct Params
{
    int type = Hall; float predelayMs = 20.f, decay = 2.f, size = .6f, diffusion = .8f, damping = .5f,
        mod = .3f, width = 1.f, tone = .5f, character = .5f; bool freeze = false;
};

class Engine
{
public:
    void prepare (double sampleRate, int)
    {
        sr = (float) sampleRate;
        pdL.init ((int) (0.56f * sr)); pdR.init ((int) (0.56f * sr)); erD.init ((int) (0.5f * sr));
        tailL.init ((int) (0.12f * sr)); tailR.init ((int) (0.12f * sr));
        fdn.prepare (sr); plate.prepare (sr); spring.prepare (sr); ps.prepare (sr);
        initialised = false; resetAll();
    }
    void resetAll()
    {
        pdL.clear(); pdR.clear(); erD.clear(); tailL.clear(); tailR.clear();
        fdn.clear(); plate.clear(); spring.clear(); ps.clear();
        shimLp.reset(); lofiLp[0].reset(); lofiLp[1].reset(); tiltLp[0].reset(); tiltLp[1].reset();
        lastShim = 0.f; holdL = holdR = 0.f; holdCnt = 0; lofiPh = 0.f;
    }
    void setParams (const Params& p)
    {
        P = p;
        if (! initialised) { curType = pendingType = p.type; buildER (curType); initialised = true; pdCur = p.predelayMs * 0.001f * sr; sizeCur = 1.f; }
        pendingType = p.type;
        pdTgt = clampf (p.predelayMs, 0.f, 500.f) * 0.001f * sr;
        applyTargets (curType);
        tiltLo = dbToLin (-(P.tone - 0.5f) * 12.f); tiltHi = dbToLin ((P.tone - 0.5f) * 12.f);
        for (auto& f : tiltLp) f.setCutoff (1000.f, sr);
    }
    void process (float* l, float* r, int n)
    {
        const float fadeStep = 1.f / (0.03f * sr);
        for (int i = 0; i < n; ++i)
        {
            pdCur += (pdTgt - pdCur) * 0.003f;
            if (pendingType != curType)
            {
                fadeGain -= fadeStep;
                if (fadeGain <= 0.f) { fadeGain = 0.f; curType = pendingType; resetAll(); buildER (curType); applyTargets (curType); }
            }
            else if (fadeGain < 1.f) fadeGain = std::min (1.f, fadeGain + fadeStep);

            pdL.push (l[i]); pdR.push (r[i]);
            const float dl = pdL.read (pdCur), dr = pdR.read (pdCur);
            float wl = 0.f, wr = 0.f;

            switch (curType)
            {
                case Plate:
                {
                    plate.process (P.freeze ? 0.f : (dl + dr) * 0.5f, wl, wr);
                    wl *= 0.9f; wr *= 0.9f;
                    break;
                }
                case Spring:
                {
                    spring.process (dl, dr, wl, wr);
                    wl *= 0.8f; wr *= 0.8f;
                    break;
                }
                default:
                {
                    const float mono = P.freeze ? 0.f : (dl + dr) * 0.5f;
                    erD.push (mono);
                    float erL = 0.f, erR = 0.f;
                    for (int t = 0; t < kTaps; ++t)
                    {
                        const float v = erD.read (std::max (1.f, erMs[t] * 0.001f * sr * erScale));
                        erL += v * erGL[t]; erR += v * erGR[t];
                    }
                    tailL.push (P.freeze ? 0.f : dl); tailR.push (P.freeze ? 0.f : dr);
                    const float tdl = tailMs * 0.001f * sr;
                    float oL, oR;
                    fdn.process (tailL.read (tdl), tailR.read (tdl), lastShim, oL, oR);
                    if (curType == Shimmer)
                    {
                        const float shimmed = ps.process (shimLp.lp ((oL + oR) * 0.5f), 2.0f);
                        lastShim = shimmed * (0.05f + 0.5f * P.character);
                    }
                    wl = erL * erMul + oL; wr = erR * erMul + oR;
                    if (curType == LoFi)
                    {
                        lofiPh += 0.0f;
                        const int hold = 1 + (int) (P.character * 4.f);
                        if (++holdCnt >= hold) { holdCnt = 0; holdL = wl; holdR = wr; }
                        const float step = std::pow (2.f, 1.f - (15.f - 5.f * P.character));
                        wl = std::round (lofiLp[0].lp (holdL) / step) * step;
                        wr = std::round (lofiLp[1].lp (holdR) / step) * step;
                    }
                    break;
                }
            }
            wl *= kTrim[curType]; wr *= kTrim[curType];
            // tone tilt
            { const float lo = tiltLp[0].lp (wl); wl = lo * tiltLo + (wl - lo) * tiltHi; }
            { const float lo = tiltLp[1].lp (wr); wr = lo * tiltLo + (wr - lo) * tiltHi; }
            // width
            const float m = 0.5f * (wl + wr), sd = 0.5f * (wl - wr) * P.width;
            l[i] = (m + sd) * fadeGain; r[i] = (m - sd) * fadeGain;
        }
    }

private:
    static constexpr int kTaps = 12;
    static constexpr float kTrim[NumTypes] = { 1.25f, 0.7f, 0.55f, 1.2f, 1.1f, 1.2f, 1.45f, 1.9f };

    void applyTargets (int type)
    {
        const float scaleOf[NumTypes] = { 1.0f, 1.0f, 0.45f, 1.3f, 1.0f, 1.0f, 1.5f, 0.9f };
        const float norm = 0.35f + 1.65f * P.size;
        const float sizeMul = scaleOf[type] * norm;
        float dampHz = 18000.f * std::pow (1200.f / 18000.f, P.damping);
        float modMul = 1.f, erLevelMul = 1.f;
        switch (type)
        {
            case Cathedral: dampHz *= 0.8f; break;
            case LoFi:      dampHz *= 0.5f; modMul = 3.f; break;
            case Room:      modMul = 0.2f; break;
            case Space: case Shimmer: modMul = 1.5f; break;
            default: break;
        }
        const float modSamples = P.mod * sr * 0.0004f * modMul;
        const float diffG = 0.35f + 0.4f * P.diffusion;
        erScale = norm;
        erLevelMul = (type == Room || type == LoFi) ? (0.5f + P.character) : (1.4f - 1.2f * P.character);
        erMul = erLevelMul;
        const float tails[NumTypes] = { 15.f, 0.f, 0.f, 20.f, 0.f, 15.f, 30.f, 0.f };
        tailMs = tails[type];
        fdn.setTargets (sizeMul, P.decay * (type == Room ? 1.45f : 1.f), dampHz, modSamples, diffG, P.freeze);
        plate.setTargets (norm, P.decay, std::min (dampHz, 14000.f), P.mod, P.diffusion, P.character, P.freeze);
        spring.setTargets (P.decay, dampHz, P.character, P.size);
        shimLp.setCutoff (7000.f, sr);
        lofiLp[0].setCutoff (7000.f - 4500.f * P.character, sr); lofiLp[1].setCutoff (7000.f - 4500.f * P.character, sr);
    }

    void buildER (int type)
    {
        //                     level  start span  curve
        const float cfg[NumTypes][4] = { { .45f, 12.f, 70.f, 1.2f }, { 0, 0, 0, 1 }, { .8f, 2.5f, 35.f, .9f }, { .2f, 20.f, 110.f, 1.3f },
                                         { 0, 0, 0, 1 }, { .15f, 15.f, 90.f, 1.2f }, { .35f, 30.f, 170.f, 1.4f }, { .4f, 6.f, 50.f, 1.f } };
        uint32_t seed = 12345u + (uint32_t) type * 7919u;
        auto rnd = [&] { seed = seed * 1664525u + 1013904223u; return (float) (seed >> 8) / 16777216.f; };
        for (int t = 0; t < kTaps; ++t)
        {
            const float u = ((float) t + 0.3f + 0.4f * rnd()) / (float) kTaps;
            erMs[t] = cfg[type][1] + cfg[type][2] * std::pow (u, cfg[type][3]);
            const float gain = cfg[type][0] * (1.f - 0.8f * u) * (0.6f + 0.4f * rnd()) * ((t & 1) ? -1.f : 1.f);
            const float pan = rnd() * 2.f - 1.f;
            erGL[t] = gain * std::sqrt ((1.f - pan) * 0.5f); erGR[t] = gain * std::sqrt ((1.f + pan) * 0.5f);
        }
    }

    float sr = 48000.f, pdCur = 0.f, pdTgt = 0.f, sizeCur = 1.f, fadeGain = 1.f, tailMs = 0.f, erScale = 1.f, erMul = 1.f;
    float tiltLo = 1.f, tiltHi = 1.f, lastShim = 0.f, holdL = 0.f, holdR = 0.f, lofiPh = 0.f; int holdCnt = 0;
    bool initialised = false; int curType = Hall, pendingType = Hall; Params P;
    Delay pdL, pdR, erD, tailL, tailR; FDN fdn; PlateReverb plate; SpringReverb spring; PitchShifter ps;
    OnePole shimLp, lofiLp[2], tiltLp[2];
    float erMs[kTaps] {}, erGL[kTaps] {}, erGR[kTaps] {};
};

} // namespace bh
