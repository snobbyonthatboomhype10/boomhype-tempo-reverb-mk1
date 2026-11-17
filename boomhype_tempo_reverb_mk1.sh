#!/usr/bin/env bash
# =====================================================================================
#  BoomHype Tech  -  Tempo Reverb MK I   (VST3, resizable, JUCE 8)
#
#  Usage (GitHub Codespaces or any Ubuntu box):
#     bash boomhype_tempo_reverb_mk1.sh          -> write the project files, then build for Linux
#     bash boomhype_tempo_reverb_mk1.sh files    -> only write the project files
#     bash boomhype_tempo_reverb_mk1.sh build    -> build (files must exist) and zip the VST3
#
#  Windows + macOS builds come from the GitHub Actions workflow this script writes to
#  .github/workflows/build.yml  (push the repo, then Actions > latest run > Artifacts).
# =====================================================================================
set -euo pipefail
MODE="${1:-all}"

write_files() {
  mkdir -p Source .github/workflows
  echo '  writing CMakeLists.txt'
  cat > 'CMakeLists.txt' <<'BH_EOF'
cmake_minimum_required(VERSION 3.22)
project(BoomHypeTempoReverbMK1 VERSION 1.0.0)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

include(FetchContent)
FetchContent_Declare(JUCE
    GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
    GIT_TAG 8.0.6
    GIT_SHALLOW ON)
FetchContent_MakeAvailable(JUCE)

juce_add_plugin(TempoReverb
    COMPANY_NAME "BoomHype Tech"
    COMPANY_WEBSITE "https://boomhype.tech"
    BUNDLE_ID com.boomhypetech.temporeverbmk1
    PLUGIN_MANUFACTURER_CODE Bhtc
    PLUGIN_CODE Trv1
    FORMATS VST3
    PRODUCT_NAME "Tempo Reverb MK I"
    VST3_CATEGORIES Fx Reverb
    IS_SYNTH FALSE
    NEEDS_MIDI_INPUT FALSE
    NEEDS_MIDI_OUTPUT FALSE
    IS_MIDI_EFFECT FALSE
    COPY_PLUGIN_AFTER_BUILD FALSE)

target_sources(TempoReverb PRIVATE
    Source/PluginProcessor.cpp
    Source/PluginEditor.cpp)

target_compile_definitions(TempoReverb PUBLIC
    JUCE_WEB_BROWSER=0
    JUCE_USE_CURL=0
    JUCE_VST3_CAN_REPLACE_VST2=0
    JUCE_DISPLAY_SPLASH_SCREEN=1)

target_link_libraries(TempoReverb
    PRIVATE
        juce::juce_audio_utils
        juce::juce_dsp
    PUBLIC
        juce::juce_recommended_config_flags
        juce::juce_recommended_warning_flags)
BH_EOF
  echo '  writing Source/ReverbEngine.h'
  cat > 'Source/ReverbEngine.h' <<'BH_EOF'
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
BH_EOF
  echo '  writing Source/PluginProcessor.h'
  cat > 'Source/PluginProcessor.h' <<'BH_EOF'
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
BH_EOF
  echo '  writing Source/PluginProcessor.cpp'
  cat > 'Source/PluginProcessor.cpp' <<'BH_EOF'
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
BH_EOF
  echo '  writing Source/PluginEditor.h'
  cat > 'Source/PluginEditor.h' <<'BH_EOF'
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
BH_EOF
  echo '  writing Source/PluginEditor.cpp'
  cat > 'Source/PluginEditor.cpp' <<'BH_EOF'
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
BH_EOF
  echo '  writing .github/workflows/build.yml'
  cat > '.github/workflows/build.yml' <<'BH_EOF'
name: Build VST3 (Windows / macOS / Linux)

on:
  push:
  workflow_dispatch:

jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        include:
          - { os: windows-latest, name: Windows }
          - { os: macos-latest,   name: macOS }
          - { os: ubuntu-latest,  name: Linux }
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4

      - name: Linux dependencies
        if: runner.os == 'Linux'
        run: |
          sudo apt-get update
          sudo apt-get install -y libasound2-dev libjack-jackd2-dev ladspa-sdk libcurl4-openssl-dev \
            libfreetype-dev libfontconfig1-dev libx11-dev libxcomposite-dev libxcursor-dev libxext-dev \
            libxinerama-dev libxrandr-dev libxrender-dev libglu1-mesa-dev mesa-common-dev

      - name: Configure (macOS universal)
        if: runner.os == 'macOS'
        run: cmake -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES="arm64;x86_64"

      - name: Configure
        if: runner.os != 'macOS'
        run: cmake -B build -DCMAKE_BUILD_TYPE=Release

      - name: Build
        run: cmake --build build --config Release --parallel 4

      - name: Upload VST3
        uses: actions/upload-artifact@v4
        with:
          name: BoomHype-TempoReverb-MK1-${{ matrix.name }}-VST3
          path: build/TempoReverb_artefacts/Release/VST3/
BH_EOF
  cat > README.md <<'BH_EOF'
# BoomHype Tech - Tempo Reverb MK I

VST3 reverb with 8 reverb types (Hall, Plate, Room, Space, Spring, Shimmer, Cathedral, Lo-Fi),
a tempo helper (host-synced pre-delay and reverb time), 5-band spectral EQ with live analyser,
ducking (input or sidechain) and needle GR / output VU meters. The window is resizable.

## Get the plugin
* **Windows / macOS / Linux:** push this repo to GitHub, open the **Actions** tab, open the newest
  "Build VST3" run and download the artifact for your system.
* **Linux only, inside Codespaces:** run `bash boomhype_tempo_reverb_mk1.sh build`, then right-click the
  generated `.zip` in the file explorer and choose **Download**.

## Install
* Windows: copy `Tempo Reverb MK I.vst3` to `C:\Program Files\Common Files\VST3\`
* macOS: copy to `~/Library/Audio/Plug-Ins/VST3/` (if blocked: `xattr -cr "Tempo Reverb MK I.vst3"`)
* Linux: copy to `~/.vst3/`

JUCE is used under its AGPLv3/commercial licence. Selling or closed-source distribution needs a JUCE commercial licence.
BH_EOF
  printf '%s' 'build/
*.zip
.DS_Store
' > .gitignore
}

build_linux() {
  echo ">> installing build tools and JUCE Linux dependencies (needs sudo)"
  sudo apt-get update -y
  sudo apt-get install -y build-essential cmake git zip pkg-config libasound2-dev libjack-jackd2-dev ladspa-sdk \
    libcurl4-openssl-dev libfreetype-dev libfontconfig1-dev libx11-dev libxcomposite-dev libxcursor-dev \
    libxext-dev libxinerama-dev libxrandr-dev libxrender-dev libglu1-mesa-dev mesa-common-dev
  echo ">> configuring (downloads JUCE 8.0.6 the first time)"
  cmake -B build -DCMAKE_BUILD_TYPE=Release
  echo ">> building - first build takes several minutes"
  cmake --build build --config Release --parallel "$(nproc)"
  local VST_DIR="build/TempoReverb_artefacts/Release/VST3"
  if [ ! -d "$VST_DIR" ]; then echo "!! VST3 folder not found at $VST_DIR"; find build -name '*.vst3' -maxdepth 4; exit 1; fi
  local ZIP="BoomHype_TempoReverb_MK1_Linux_VST3.zip"
  rm -f "$ZIP"
  ( cd "$VST_DIR" && zip -qr "$OLDPWD/$ZIP" . )
  echo
  echo "=============================================================="
  echo " DONE:  $PWD/$ZIP"
  echo " In Codespaces: right-click that .zip in the Explorer -> Download."
  echo " NOTE: this is the LINUX build. For Windows / macOS use the GitHub Actions artifacts."
  echo "=============================================================="
}

case "$MODE" in
  files) write_files ;;
  build) build_linux ;;
  all)   write_files; build_linux ;;
  *) echo "usage: $0 [files|build|all]"; exit 1 ;;
esac

