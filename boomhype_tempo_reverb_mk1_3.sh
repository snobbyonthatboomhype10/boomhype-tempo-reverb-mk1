#!/usr/bin/env bash
# =====================================================================================
#  BoomHype Tech  -  Tempo Reverb MK I   (VST3, resizable, JUCE 8)
#
#  Usage (GitHub Codespaces or any Ubuntu box):
#     bash boomhype_tempo_reverb_mk1_2.sh          -> write the project files, then build for Linux
#     bash boomhype_tempo_reverb_mk1.sh files    -> only write the project files
#     bash boomhype_tempo_reverb_mk1.sh build    -> build (files must exist) and zip the VST3
#
#  Windows + macOS builds come from the GitHub Actions workflow this script writes to
#  .github/workflows/build.yml  (push the repo, then Actions > latest run > Artifacts).
# =====================================================================================
set -euo pipefail
MODE="${1:-all}"

write_files() {
  mkdir -p Source .github/workflows tools test assets/fonts
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

# ---- fonts: Josefin Sans + Bevan (SIL OFL) are stored as .woff2 and converted to .ttf at configure time
set(BH_FONTS_OK OFF)
find_package(Python3 COMPONENTS Interpreter)
if(Python3_FOUND)
    execute_process(COMMAND ${Python3_EXECUTABLE} ${CMAKE_CURRENT_SOURCE_DIR}/tools/woff2ttf.py
                            ${CMAKE_CURRENT_SOURCE_DIR}/assets/fonts ${CMAKE_BINARY_DIR}/fonts
                    RESULT_VARIABLE BH_FONT_RC)
    if(BH_FONT_RC EQUAL 0)
        set(BH_FONTS_OK ON)
    endif()
endif()
if(BH_FONTS_OK)
    juce_add_binary_data(BHAssets SOURCES
        ${CMAKE_BINARY_DIR}/fonts/Josefin500.ttf
        ${CMAKE_BINARY_DIR}/fonts/Josefin600.ttf
        ${CMAKE_BINARY_DIR}/fonts/Josefin700.ttf
        ${CMAKE_BINARY_DIR}/fonts/Bevan400.ttf)
    target_link_libraries(TempoReverb PRIVATE BHAssets)
    target_compile_definitions(TempoReverb PUBLIC BH_HAS_FONTS=1)
else()
    message(WARNING "Font conversion failed - building with system fonts (plugin still works)")
    target_compile_definitions(TempoReverb PUBLIC BH_HAS_FONTS=0)
endif()

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
// Reverb DSP engine. Pure C++17 (no JUCE) so it can be unit-tested on its own.
//
//  HALL      concert hall: image-source early reflections of a 34 x 22 x 15 m shoebox,
//            8-line FDN tail, bass-rich decay, gentle modulation
//  PLATE     Dattorro plate (JAES 1997): instant dense build-up, no early reflections, bright
//  ROOM      4.6 x 3.7 x 2.7 m live room: strong, close early reflections, short tight tail
//  SPACE     huge ambient hall, wide + deeply modulated slow bloom
//  SPRING    dispersive all-pass chains in feedback loops (the "boing / drip" chirp)
//  SHIMMER   FDN with an octave-up pitch shifter in the feedback path
//  CATHEDRAL 62 x 30 x 32 m stone nave: sparse late early-reflections, very long dark tail
//  LO-FI     small room + sample-rate / bit reduction + tape wow & flutter
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
// ---- Tempo Helper logic, vocal sets only. Fractions are of ONE BAR (= 4 beats): ms = frac * 240000 / BPM
//      pre-delay  : Tight 1/64, Medium 1/32, Wide 1/16
//      reverb time: tail ends on the beat -> 1 beat, 2 beats, 1 bar, 2 bars, 4 bars
inline constexpr int kNumPre = 3, kNumTime = 5;
inline constexpr const char* kPreNames[3]  = { "TIGHT 1/64", "MEDIUM 1/32", "WIDE 1/16" };
inline constexpr float kPreFrac[3]         = { 0.015625f, 0.03125f, 0.0625f };
inline constexpr const char* kTimeNames[5] = { "1 BEAT", "2 BEATS", "1 BAR", "2 BARS", "4 BARS" };
inline constexpr float kTimeFrac[5]        = { 0.25f, 0.5f, 1.0f, 2.0f, 4.0f };

// Tempo-synced reverb time is the note length times this factor, so big spaces get big times at normal tempos
inline constexpr float kTimeMul[NumTypes] = { 1.0f, 1.0f, 1.0f, 2.0f, 1.0f, 1.5f, 3.0f, 1.0f };

// Defaults used for the "character" amount (not shown on the face) per type
inline constexpr float kCharacter[NumTypes] = { .50f, .60f, .55f, .60f, .50f, .50f, .50f, .60f };

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
// first-order (6 dB/oct) filters expressed as biquads (bilinear transform)
inline BiquadCoeffs makeHP1 (double fs, double f)
{
    f = std::min (f, fs * 0.45);
    const double k = std::tan (3.14159265358979 * f / fs), n = 1.0 / (1.0 + k);
    BiquadCoeffs c; c.b0 = n; c.b1 = -n; c.b2 = 0; c.a1 = (k - 1.0) * n; c.a2 = 0; return c;
}
inline BiquadCoeffs makeLP1 (double fs, double f)
{
    f = std::min (f, fs * 0.45);
    const double k = std::tan (3.14159265358979 * f / fs), n = 1.0 / (1.0 + k);
    BiquadCoeffs c; c.b0 = k * n; c.b1 = k * n; c.b2 = 0; c.a1 = (k - 1.0) * n; c.a2 = 0; return c;
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

// High-pass / low-pass with selectable slope: 0 = off, 1 = 6 dB/oct, 2 = 12 dB/oct, 3 = 24 dB/oct
struct CutFilter
{
    int slope = 0, n = 0; bool hp = true; BiquadCoeffs c[2]; Biquad b[2];
    void set (double fs, double f, int s, bool isHP)
    {
        slope = s; hp = isHP; n = (s == 0) ? 0 : (s == 3 ? 2 : 1);
        if (s == 1) c[0] = isHP ? makeHP1 (fs, f) : makeLP1 (fs, f);
        else if (s == 2) c[0] = isHP ? makeHP (fs, f, 0.70710678) : makeLP (fs, f, 0.70710678);
        else if (s == 3) { c[0] = isHP ? makeHP (fs, f, 0.5411961) : makeLP (fs, f, 0.5411961); c[1] = isHP ? makeHP (fs, f, 1.3065630) : makeLP (fs, f, 1.3065630); }
        for (int i = 0; i < n; ++i) b[i].c = c[i];
    }
    inline float process (int ch, float x) { for (int i = 0; i < n; ++i) x = b[i].process (ch, x); return x; }
    double magDb (double fs, double f) const { double d = 0; for (int i = 0; i < n; ++i) d += magnitudeDb (c[i], fs, f); return d; }
    void reset() { b[0].reset(); b[1].reset(); }
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

// ------------------------------------------------------------------ 8-line FDN with 2-band decay
class FDN
{
public:
    static constexpr int N = 8;
    void prepare (float sampleRate)
    {
        sr = sampleRate;
        for (int i = 0; i < N; ++i) { line[i].init ((int) (0.55f * sr) + 64); damp[i].reset(); split[i].reset(); ph[i] = 0.9f * (float) i; }
        static constexpr float apMs[2][4] = { { 4.7f, 7.9f, 11.3f, 16.9f }, { 5.3f, 8.7f, 12.7f, 17.3f } };
        for (int c = 0; c < 2; ++c)
            for (int k = 0; k < 4; ++k)
            {
                const int l = (int) (apMs[c][k] * 0.001f * sr);
                ap[c][k].init (l + 2); ap[c][k].set (l, 0.7f);
            }
        curMul = tgtMul = 1.f; curRt = tgtRt = 1.f; curLow = tgtLow = 1.f; updateGains();
    }
    void clear()
    {
        for (int i = 0; i < N; ++i) { line[i].clear(); damp[i].reset(); split[i].reset(); }
        for (int c = 0; c < 2; ++c) for (int k = 0; k < 4; ++k) ap[c][k].clear();
    }
    // rt60: seconds at mid frequencies.  lowMul: RT of the bass band relative to mid (1.3 = 30 % longer)
    void setTargets (float sizeMul, float rt60, float lowMul, float dampHz, float modDepthSamples, float diffG, bool freezeOn)
    {
        tgtMul = sizeMul; tgtRt = std::max (0.05f, rt60); tgtLow = lowMul; modDepth = modDepthSamples; freeze = freezeOn;
        for (int i = 0; i < N; ++i) { damp[i].setCutoff (freeze ? 0.45f * sr : dampHz, sr); split[i].setCutoff (320.f, sr); }
        for (int c = 0; c < 2; ++c) for (int k = 0; k < 4; ++k) ap[c][k].g = diffG;
    }

    inline void process (float inL, float inR, float extraIn, float& oL, float& oR)
    {
        curMul += (tgtMul - curMul) * 0.0006f;
        curRt += (tgtRt - curRt) * 0.0006f;
        curLow += (tgtLow - curLow) * 0.0006f;
        if ((++cnt & 15) == 0) updateGains();

        float d[2] = { inL, inR };
        for (int c = 0; c < 2; ++c) for (int k = 0; k < 4; ++k) d[c] = ap[c][k].process (d[c]);

        float y[N], sum = 0.f;
        for (int i = 0; i < N; ++i)
        {
            ph[i] += rate[i] / sr * 2.f * kPi; if (ph[i] > 2.f * kPi) ph[i] -= 2.f * kPi;
            const float dl = std::max (2.f, baseMs[i] * 0.001f * sr * curMul + modDepth * std::sin (ph[i]));
            const float hf = damp[i].lp (line[i].read (dl));          // air / wall absorption
            const float lo = split[i].lp (hf);                         // bass band
            y[i] = lo * gLow[i] + (hf - lo) * g[i];
            sum += y[i];
        }
        const float h = sum * (2.f / (float) N);                       // Householder feedback matrix
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
            g[i]    = freeze ? 0.99995f : std::min (0.9996f, std::pow (10.f, -3.f * lenSec / curRt));
            gLow[i] = freeze ? 0.99995f : std::min (0.9996f, std::pow (10.f, -3.f * lenSec / (curRt * curLow)));
            gs += g[i];
        }
        const float ga = gs / (float) N;
        norm = 0.55f * std::pow (std::sqrt (std::max (0.02f, 1.f - ga * ga)), 0.6f);
    }

    float sr = 48000.f, curMul = 1.f, tgtMul = 1.f, curRt = 1.f, tgtRt = 1.f, curLow = 1.f, tgtLow = 1.f, modDepth = 0.f, norm = 0.3f;
    bool freeze = false; unsigned cnt = 0;
    Delay line[N]; OnePole damp[N], split[N]; Allpass ap[2][4];
    float ph[N] {}, g[N] {}, gLow[N] {};
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
        decayG = freeze ? 0.99998f : std::min (0.9995f, std::pow (10.f, -1.5f * loopSec / std::max (0.05f, rt60 * 1.32f)));
        lDamp.setCutoff (freeze ? 0.45f * sr : dampHz, sr); rDamp.setCutoff (freeze ? 0.45f * sr : dampHz, sr);
        bw.setCutoff (3000.f * std::pow (6.f, brightness), sr);
        excursion = modAmount * 12.f * s;
        const float dd = 0.45f + 0.25f * diffusion;
        lAP1.g = rAP1.g = -dd; lAP2.g = rAP2.g = 0.25f + 0.25f * diffusion;
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
    void setTargets (float rt60, float dampHz, float character, float sizeNorm, bool freezeOn)
    {
        const float ms[2] = { 34.f + 14.f * sizeNorm, 41.f + 18.f * sizeNorm };
        for (int k = 0; k < 2; ++k)
        {
            sp[k].delay = ms[k] * 0.001f * sr;
            sp[k].fb = freezeOn ? 0.9997f : std::min (0.97f, std::pow (10.f, -3.f * ms[k] * 0.001f / std::max (0.1f, rt60 * 1.38f)));
            sp[k].lp.setCutoff (freezeOn ? 0.45f * sr : std::min (dampHz, 6500.f), sr); sp[k].hp.setCutoff (freezeOn ? 25.f : 160.f, sr); sp[k].inLp.setCutoff (5500.f, sr);
        }
        a = -(0.45f + 0.3f * character); drive = 1.f + 3.f * character;
    }
    inline void process (float inL, float inR, float& oL, float& oR)
    {
        const float m = (inL + inR) * 0.5f;
        oL = sp[0].run (m, a, drive, Stages); oR = sp[1].run (m, a, drive, Stages);
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

// shoebox geometry (metres) used to compute the early reflections of each room type
struct RoomGeo { float lx, ly, lz, beta; int maxRefl; float earSep; };

class Engine
{
public:
    void prepare (double sampleRate, int)
    {
        sr = (float) sampleRate;
        pdL.init ((int) (0.56f * sr)); pdR.init ((int) (0.56f * sr)); erD.init ((int) (0.62f * sr));
        tailL.init ((int) (0.2f * sr)); tailR.init ((int) (0.2f * sr)); wobD[0].init ((int) (0.02f * sr)); wobD[1].init ((int) (0.02f * sr));
        fdn.prepare (sr); plate.prepare (sr); spring.prepare (sr); ps.prepare (sr);
        initialised = false; resetAll();
    }
    void resetAll()
    {
        pdL.clear(); pdR.clear(); erD.clear(); tailL.clear(); tailR.clear(); wobD[0].clear(); wobD[1].clear();
        fdn.clear(); plate.clear(); spring.clear(); ps.clear();
        shimLp.reset(); lofiLp[0].reset(); lofiLp[1].reset(); tiltLp[0].reset(); tiltLp[1].reset(); erLp[0].reset(); erLp[1].reset();
        lastShim = 0.f; holdL = holdR = 0.f; holdCnt = 0; lofiPh = 0.f; wobPh = 0.f;
    }
    void setParams (const Params& p)
    {
        P = p;
        if (! initialised) { curType = pendingType = p.type; buildER (curType); initialised = true; pdCur = p.predelayMs * 0.001f * sr; erScaleCur = 1.f; }
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
            erScaleCur += (erScale - erScaleCur) * 0.0008f;
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
                    spring.process (P.freeze ? 0.f : dl, P.freeze ? 0.f : dr, wl, wr);
                    wl *= 0.8f; wr *= 0.8f;
                    break;
                }
                default:
                {
                    const float mono = P.freeze ? 0.f : (dl + dr) * 0.5f;
                    erD.push (mono);
                    float erL = 0.f, erR = 0.f;
                    const float tsc = 0.001f * sr * erScaleCur, maxD = (float) erD.mask - 4.f;
                    for (int t = 0; t < nTaps; ++t)
                    {
                        erL += erD.read (std::min (maxD, std::max (1.f, erMsL[t] * tsc))) * erGainL[t];
                        erR += erD.read (std::min (maxD, std::max (1.f, erMsR[t] * tsc))) * erGainR[t];
                    }
                    erL = erLp[0].lp (erL); erR = erLp[1].lp (erR);
                    tailL.push (P.freeze ? 0.f : dl); tailR.push (P.freeze ? 0.f : dr);
                    const float tdl = std::min (tailMs * erScaleCur * 0.001f * sr, 0.19f * sr);
                    float oL, oR;
                    fdn.process (tailL.read (tdl), tailR.read (tdl), lastShim, oL, oR);
                    if (curType == Shimmer)
                    {
                        const float shimmed = ps.process (shimLp.lp ((oL + oR) * 0.5f), 2.0f);
                        lastShim = shimmed * (0.05f + 0.5f * P.character) * (P.freeze ? 0.35f : 1.f);
                    }
                    wl = erL * erMul + oL * lateMul; wr = erR * erMul + oR * lateMul;
                    if (curType == LoFi)
                    {
                        // tape wow & flutter on the wet signal
                        wobPh += (0.7f + 5.5f * 0.02f) / sr; if (wobPh > 1.f) wobPh -= 1.f;
                        const float wob = (0.0006f * std::sin (2.f * kPi * wobPh) + 0.00012f * std::sin (2.f * kPi * 6.3f * wobPh * 1.f)) * sr * (0.3f + P.mod);
                        wobD[0].push (wl); wobD[1].push (wr);
                        wl = wobD[0].read (0.004f * sr + wob); wr = wobD[1].read (0.004f * sr + wob * 0.8f);
                        const int hold = 1 + (int) (P.character * 4.f);
                        if (++holdCnt >= hold) { holdCnt = 0; holdL = wl; holdR = wr; }
                        const float step = std::pow (2.f, 1.f - (15.f - 5.f * P.character));
                        wl = std::round (lofiLp[0].lp (holdL) / step) * step;
                        wr = std::round (lofiLp[1].lp (holdR) / step) * step;
                    }
                    break;
                }
            }
            wl *= trimOf (curType); wr *= trimOf (curType);
            { const float lo = tiltLp[0].lp (wl); wl = lo * tiltLo + (wl - lo) * tiltHi; }
            { const float lo = tiltLp[1].lp (wr); wr = lo * tiltLo + (wr - lo) * tiltHi; }
            const float m = 0.5f * (wl + wr), sd = 0.5f * (wl - wr) * P.width;
            l[i] = (m + sd) * fadeGain; r[i] = (m - sd) * fadeGain;
        }
    }

    // exposed for the offline test bench
    static float trimOf (int t) { return kTrim[t]; }

private:
    static constexpr int kMaxTaps = 64;
    // level match of every type (measured with pink noise by test/engine_test.cpp)
    static constexpr float kTrim[NumTypes] = { 1.46f, 1.40f, 0.39f, 1.51f, 1.59f, 1.40f, 1.33f, 0.45f };

    static constexpr RoomGeo kGeo[NumTypes] = {
        /* Hall      */ { 34.f, 22.f, 15.f, 0.86f, 5, 1.40f },
        /* Plate     */ {  0.f,  0.f,  0.f, 0.00f, 0, 0.00f },
        /* Room      */ { 4.6f, 3.7f, 2.7f, 0.74f, 7, 0.55f },
        /* Space     */ { 80.f, 55.f, 40.f, 0.90f, 4, 2.50f },
        /* Spring    */ {  0.f,  0.f,  0.f, 0.00f, 0, 0.00f },
        /* Shimmer   */ { 38.f, 26.f, 17.f, 0.88f, 4, 1.80f },
        /* Cathedral */ { 62.f, 30.f, 32.f, 0.93f, 4, 2.50f },
        /* Lo-Fi     */ { 5.2f, 4.0f, 2.8f, 0.70f, 6, 0.45f } };

    void applyTargets (int type)
    {
        //                                        Hall  Plate Room  Space Spring Shim  Cath  LoFi
        static const float scaleOf[NumTypes]  = { 1.00f, 1.0f, 0.34f, 0.90f, 1.0f, 1.10f, 0.95f, 0.40f };
        static const float lowOf[NumTypes]    = { 1.25f, 1.0f, 0.90f, 1.20f, 1.0f, 1.15f, 1.40f, 0.80f };
        static const float tailOf[NumTypes]   = { 14.f,  0.f,  4.f,   22.f,  0.f,  16.f,  34.f,  5.f };
        static const float rtMulOf[NumTypes]  = { 1.17f, 1.0f, 1.19f, 1.11f, 1.0f, 1.07f, 1.03f, 1.54f };  // so the displayed time == measured RT60
        static const float lateOf[NumTypes]   = { 1.0f,  1.0f, 1.8f,  1.0f,  1.0f, 1.0f,  1.0f,  1.5f };
        const float norm = 0.35f + 1.65f * P.size;
        const float sizeMul = scaleOf[type] * norm;
        float dampHz = 18000.f * std::pow (1200.f / 18000.f, P.damping);
        float modMul = 1.f;
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
        // early reflections: dominant in small rooms, a supporting cue in big ones. "character" balances them.
        const bool small = (type == Room || type == LoFi);
        erMul = small ? (0.85f + 1.3f * P.character) : (type == Cathedral ? 0.55f : 0.65f) * (1.5f - 1.1f * P.character);
        erLp[0].setCutoff (std::min (16000.f, dampHz * 1.4f), sr); erLp[1].setCutoff (std::min (16000.f, dampHz * 1.4f), sr);
        tailMs = tailOf[type]; lateMul = lateOf[type];
        fdn.setTargets (sizeMul, P.decay * rtMulOf[type], lowOf[type], dampHz, modSamples, diffG, P.freeze);
        plate.setTargets (norm, P.decay, std::min (dampHz, 14000.f), P.mod, P.diffusion, P.character, P.freeze);
        spring.setTargets (P.decay, dampHz, P.character, P.size, P.freeze);
        shimLp.setCutoff (7000.f, sr);
        lofiLp[0].setCutoff (7000.f - 4500.f * P.character, sr); lofiLp[1].setCutoff (7000.f - 4500.f * P.character, sr);
    }

    // image-source model of a shoebox: each tap is one wall reflection path (delay + 1/r level + wall loss)
    void buildER (int type)
    {
        nTaps = 0;
        const RoomGeo& G = kGeo[type];
        if (G.lx <= 0.f) return;
        const float c = 343.f;
        const float sx = 0.28f * G.lx, sy = 0.5f * G.ly, sz = std::min (1.7f, 0.55f * G.lz);
        const float lx0 = 0.72f * G.lx, ly0 = 0.5f * G.ly, lz0 = std::min (1.5f, 0.5f * G.lz);
        const float es = G.earSep * 0.5f;
        struct Img { float dL, dR, dM, g; };
        std::vector<Img> v;
        const float dDirL = std::sqrt ((lx0 - sx) * (lx0 - sx) + (ly0 - es - sy) * (ly0 - es - sy) + (lz0 - sz) * (lz0 - sz));
        const float dDirR = std::sqrt ((lx0 - sx) * (lx0 - sx) + (ly0 + es - sy) * (ly0 + es - sy) + (lz0 - sz) * (lz0 - sz));
        uint32_t seed = 9001u + (uint32_t) type * 7919u;
        auto rnd = [&] { seed = seed * 1664525u + 1013904223u; return (float) (seed >> 8) / 16777216.f; };
        for (int nx = -2; nx <= 2; ++nx) for (int qx = 0; qx < 2; ++qx)
        for (int ny = -2; ny <= 2; ++ny) for (int qy = 0; qy < 2; ++qy)
        for (int nz = -2; nz <= 2; ++nz) for (int qz = 0; qz < 2; ++qz)
        {
            const int k = std::abs (nx - qx) + std::abs (nx) + std::abs (ny - qy) + std::abs (ny) + std::abs (nz - qz) + std::abs (nz);
            if (k == 0 || k > G.maxRefl) continue;
            const float ix = (1 - 2 * qx) * sx + 2.f * (float) nx * G.lx;
            const float iy = (1 - 2 * qy) * sy + 2.f * (float) ny * G.ly;
            const float iz = (1 - 2 * qz) * sz + 2.f * (float) nz * G.lz;
            auto dist = [&] (float px, float py, float pz) { return std::sqrt ((ix - px) * (ix - px) + (iy - py) * (iy - py) + (iz - pz) * (iz - pz)); };
            Img im;
            im.dL = dist (lx0, ly0 - es, lz0); im.dR = dist (lx0, ly0 + es, lz0); im.dM = 0.5f * (im.dL + im.dR);
            im.g = std::pow (G.beta, (float) k) * (0.5f * (dDirL + dDirR) / im.dM) * (0.85f + 0.3f * rnd());
            v.push_back (im);
        }
        std::sort (v.begin(), v.end(), [] (const Img& a, const Img& b) { return a.dM < b.dM; });
        // the discrete reflections only run for a limited time, then the FDN diffuse field takes over
        static const float limitMs[NumTypes] = { 110.f, 0.f, 60.f, 150.f, 0.f, 120.f, 170.f, 50.f };
        const float lim = limitMs[type];
        nTaps = 0;
        for (size_t q = 0; q < v.size() && nTaps < kMaxTaps; ++q)
        {
            const float tms = 1000.f * (v[q].dM - 0.5f * (dDirL + dDirR)) / c;
            if (tms > lim) break;
            const int t = nTaps++;
            v[(size_t) t].g = v[q].g * (1.f - 0.65f * tms / lim); v[(size_t) t].dL = v[q].dL; v[(size_t) t].dR = v[q].dR;
        }
        for (int t = 0; t < nTaps; ++t)
        {
            erMsL[t] = std::max (0.3f, 1000.f * (v[(size_t) t].dL - dDirL) / c + 0.3f);
            erMsR[t] = std::max (0.3f, 1000.f * (v[(size_t) t].dR - dDirR) / c + 0.3f);
            const float pan = 0.45f * (rnd() * 2.f - 1.f);          // each wall bounce lands slightly left or right
            erGainL[t] = v[(size_t) t].g * 0.55f * (1.f + pan);
            erGainR[t] = v[(size_t) t].g * 0.55f * (1.f - pan);
        }
    }

    float sr = 48000.f, pdCur = 0.f, pdTgt = 0.f, fadeGain = 1.f, tailMs = 0.f, erScale = 1.f, erScaleCur = 1.f, erMul = 1.f, lateMul = 1.f;
    float tiltLo = 1.f, tiltHi = 1.f, lastShim = 0.f, holdL = 0.f, holdR = 0.f, lofiPh = 0.f, wobPh = 0.f; int holdCnt = 0;
    bool initialised = false; int curType = Hall, pendingType = Hall; Params P; int nTaps = 0;
    Delay pdL, pdR, erD, tailL, tailR, wobD[2]; FDN fdn; PlateReverb plate; SpringReverb spring; PitchShifter ps;
    OnePole shimLp, lofiLp[2], tiltLp[2], erLp[2];
    float erMsL[kMaxTaps] {}, erMsR[kMaxTaps] {}, erGainL[kMaxTaps] {}, erGainR[kMaxTaps] {};
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
    double getTailLengthSeconds() const override { return 32.0; }

    int getNumPrograms() override { return 1; }
    int getCurrentProgram() override { return 0; }
    void setCurrentProgram (int) override {}
    const juce::String getProgramName (int) override { return {}; }
    void changeProgramName (int, const juce::String&) override {}

    void getStateInformation (juce::MemoryBlock& destData) override;
    void setStateInformation (const void* data, int sizeInBytes) override;

    static juce::AudioProcessorValueTreeState::ParameterLayout createLayout();
    float get (const juce::String& id) const { return apvts.getRawParameterValue (id)->load(); }

    // A/B compare (message thread only)
    void abSwitch (int slot);
    int abSlot() const { return abCurrent; }

    juce::AudioProcessorValueTreeState apvts;

    // shared with the editor (meters, read-outs, analyser)
    std::atomic<float> grDb { 0.f }, outRmsDb { -90.f }, inPeakDb { -90.f }, bpmEff { 120.f }, effDecay { 2.f }, effPre { 20.f };
    std::atomic<bool> hostHasBpm { false };
    static constexpr int scopeSize = 16384;
    std::array<float, scopeSize> scope {};
    std::atomic<int> scopeWrite { 0 };

private:

    bh::Engine engine;
    bh::CutFilter hp, lp;
    bh::Biquad band[5];
    bool bandOn[5] {};
    std::vector<float> dryL, dryR, wetL, wetR;
    double sr = 44100.0;
    float envDet = 0.f, grSmooth = 0.f;
    juce::SmoothedValue<float> mixSm, outSm, trimSm;

    juce::ValueTree abState[2];
    int abCurrent = 0;

    void updateEq();
    void applyEq (float* l, float* r, int n, bool post);

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
BH_EOF
  echo '  writing Source/Ui.h'
  cat > 'Source/Ui.h' <<'BH_EOF'
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
BH_EOF
  echo '  writing Source/EqDisplay.h'
  cat > 'Source/EqDisplay.h' <<'BH_EOF'
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
BH_EOF
  echo '  writing Source/PluginEditor.h'
  cat > 'Source/PluginEditor.h' <<'BH_EOF'
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
    std::array<ui::PresetRow*, 5> timeKeys {};
    std::array<ui::PresetRow*, 3> pdKeys {};
    std::array<std::unique_ptr<ui::PresetRow>, 8> keyStore;
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
BH_EOF
  echo '  writing Source/PluginEditor.cpp'
  cat > 'Source/PluginEditor.cpp' <<'BH_EOF'
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
    /* HALL      */ { .78f, .65f, .45f, .85f, .40f, .55f, 2, 1, 2400, 125, 80.f, 2, 12000.f, 2, { { 60, .5f, 1.2f }, { 250, -.3f, 1.f }, { 1200, .2f, 1.4f }, { 4000, -.2f, 1.f }, { 10000, .3f, 1.1f } } },
    /* PLATE     */ { .45f, .90f, .30f, .75f, .50f, .65f, 1, 0, 1800, 60, 100.f, 2, 14000.f, 1, { { 80, .2f, 1.f }, { 300, -.1f, 1.2f }, { 1000, .4f, 1.6f }, { 3500, .3f, 1.2f }, { 9000, -.2f, 1.f } } },
    /* ROOM      */ { .30f, .55f, .55f, .60f, .30f, .50f, 0, 0, 550, 12, 120.f, 2, 11000.f, 2, { { 50, .3f, 1.f }, { 200, .1f, 1.f }, { 800, -.2f, 1.2f }, { 3000, .1f, 1.f }, { 12000, -.3f, 1.f } } },
    /* SPACE     */ { .95f, .70f, .25f, .95f, .60f, .70f, 3, 2, 5000, 250, 40.f, 1, 16000.f, 1, { { 40, .6f, 1.4f }, { 180, .2f, 1.f }, { 900, -.1f, 1.2f }, { 3800, .4f, 1.4f }, { 12000, .2f, 1.f } } },
    /* SPRING    */ { .20f, .40f, .60f, .45f, .80f, .40f, 1, 0, 1400, 12, 150.f, 3, 9000.f, 2, { { 100, .4f, 1.6f }, { 400, -.4f, 1.f }, { 1500, .5f, 2.f }, { 5000, -.3f, 1.f }, { 11000, .1f, 1.f } } },
    /* SHIMMER   */ { .88f, .75f, .20f, .90f, .70f, .80f, 3, 2, 4500, 250, 60.f, 2, 16000.f, 1, { { 50, .2f, 1.f }, { 250, .3f, 1.2f }, { 1200, .5f, 1.4f }, { 5000, .6f, 1.6f }, { 14000, .4f, 1.f } } },
    /* CATHEDRAL */ { .98f, .80f, .35f, .98f, .50f, .60f, 4, 2, 7000, 333, 35.f, 1, 13000.f, 2, { { 35, .7f, 1.4f }, { 150, .3f, 1.f }, { 700, -.2f, 1.2f }, { 2800, .2f, 1.2f }, { 10000, .5f, 1.f } } },
    /* LO-FI     */ { .55f, .50f, .75f, .50f, .60f, .25f, 0, 1, 800, 125, 180.f, 2, 6500.f, 3, { { 120, .2f, 1.f }, { 350, -.5f, 1.f }, { 900, .3f, 1.2f }, { 2500, -.6f, 1.f }, { 8000, -.4f, 1.f } } }
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
    for (int i = 0; i < bh::kNumTime; ++i)               // reverb time: tail ends on the beat (Tempo Helper)
    {
        keyStore[(size_t) i] = std::make_unique<PresetRow> (bh::kTimeNames[i]); timeKeys[(size_t) i] = keyStore[(size_t) i].get();
        place (*timeKeys[(size_t) i], 49, 624.f + (float) i * 40.f, 228, 38);
        timeKeys[(size_t) i]->onClick = [this, i] { setP ("timeNote", (float) i); };
    }
    for (int i = 0; i < bh::kNumPre; ++i)                // pre-delay: tight / medium / wide
    {
        keyStore[(size_t) (5 + i)] = std::make_unique<PresetRow> (bh::kPreNames[i]); pdKeys[(size_t) i] = keyStore[(size_t) (5 + i)].get();
        place (*pdKeys[(size_t) i], 49, 902.f + (float) i * 40.f, 228, 38);
        pdKeys[(size_t) i]->onClick = [this, i] { setP ("preNote", (float) i); };
    }
    place (timeLcd, 49, 826, 228, 34); place (pdLcd, 49, 1026, 228, 34);

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
    place (*k, x - KnobComp::PAD, y, size + 2.f * KnobComp::PAD, KnobComp::cellH (size));
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
    const int tn = jlimit (0, bh::kNumTime - 1, (int) proc.get ("timeNote")), pn = jlimit (0, bh::kNumPre - 1, (int) proc.get ("preNote"));
    const double barMs = 240000.0 / jmax (20.0, (double) proc.bpmEff.load());
    for (int i = 0; i < bh::kNumTime; ++i)
    {
        timeKeys[(size_t) i]->setToggleState (i == tn, dontSendNotification); timeKeys[(size_t) i]->setEnabled (sync);
        timeKeys[(size_t) i]->setValue (String (bh::kTimeFrac[i] * barMs / 1000.0, 2) + " s");
    }
    for (int i = 0; i < bh::kNumPre; ++i)
    {
        pdKeys[(size_t) i]->setToggleState (i == pn, dontSendNotification); pdKeys[(size_t) i]->setEnabled (sync);
        pdKeys[(size_t) i]->setValue (String (bh::kPreFrac[i] * barMs, 1) + " ms");
    }
    hpChips.setSelected ((int) proc.get ("hpS")); lpChips.setSelected ((int) proc.get ("lpS")); prePost.setSelected (proc.get ("eqPost") > 0.5f ? 1 : 0);

    // readouts
    const float bpm = proc.bpmEff.load();
    tempoLcd.set (host ? "HOST" : "TEMPO", String (roundToInt (bpm)), {}); tempoLcd.draggable = ! host; tempoLcd.editable = ! host;
    if (sync)
    {
        timeLcd.set ({}, bh::kTimeNames[tn], fmtMsS (proc.effDecay.load() * 1000.0)); pdLcd.set ({}, bh::kPreNames[pn], fmtMsS (proc.effPre.load()));
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
    g.drawText ("REVERB TIME", Rectangle<float> (38.f, 596.f, 250.f, 22.f), Justification::centred, false);
    g.drawText ("PRE-DELAY", Rectangle<float> (38.f, 872.f, 250.f, 22.f), Justification::centred, false);
    g.setFont (bhFont (14.5f, 2, 0.1f));
    g.drawText ("GAIN REDUCTION", Rectangle<float> (1020.f, 594.f, 250.f, 22.f), Justification::centredLeft, false);
    g.drawText ("OUTPUT LEVEL", Rectangle<float> (1486.f, 594.f, 250.f, 22.f), Justification::centredLeft, false);

    // centre panel art
    {
        const float cx = 700.f + 145.f;
        g.setFont (bhFont (31.f, 3)); g.setColour (Colours::black.withAlpha (0.7f)); g.drawText ("BoomHype", Rectangle<float> (700.f, 562.f, 290.f, 46.f), Justification::centred, false);
        g.setColour (sk.silk); g.drawText ("BoomHype", Rectangle<float> (700.f, 560.f, 290.f, 46.f), Justification::centred, false);
        g.setColour (sk.dim); drawFit (g, "TECH  -  TEMPO REVERB  -  MK I", Rectangle<float> (712.f, 608.f, 266.f, 20.f), bhFont (13.f, 2, 0.10f), Justification::centred);
        for (float y : { 638.f, 746.f, 862.f }) { g.setColour (sk.silk.withAlpha (0.55f)); g.fillRect (cx - 113.f, y, 226.f, 1.5f); }
        g.setColour (sk.dim);
        drawFit (g, "DRAG BANDS - SCROLL = Q", Rectangle<float> (712.f, 876.f, 266.f, 20.f), bhFont (13.f, 2, 0.06f), Justification::centred);
        drawFit (g, "DOUBLE-CLICK = RESET GAIN", Rectangle<float> (712.f, 896.f, 266.f, 20.f), bhFont (13.f, 2, 0.06f), Justification::centred);
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
        else txt += "  |  " + (sync ? String (bh::kTimeNames[jlimit (0, bh::kNumTime - 1, (int) proc.get ("timeNote"))]) : fmtMsS (proc.get ("timeMs"))) + "  |  " + String (roundToInt (proc.bpmEff.load())) + " BPM";
        g.setFont (bhFont (17.f, 1, 0.08f)); g.setColour (sk.accent.withAlpha (0.25f)); g.drawText (txt, r.translated (0.f, 1.f), Justification::centred, false);
        g.setColour (sk.accent); g.drawText (txt, r, Justification::centred, false);
    }
}
BH_EOF
  echo '  writing tools/woff2ttf.py'
  cat > 'tools/woff2ttf.py' <<'BH_EOF'
#!/usr/bin/env python3
# Converts the embedded .woff2 fonts (Josefin Sans, Bevan - SIL OFL) to .ttf so JUCE can load them.
import os, subprocess, sys

def ensure():
    try:
        import fontTools, brotli  # noqa
        return
    except ImportError:
        pass
    for extra in ([], ["--break-system-packages"], ["--user"]):
        r = subprocess.run([sys.executable, "-m", "pip", "install", "--quiet", "fonttools", "brotli"] + extra)
        if r.returncode == 0:
            break
    import fontTools, brotli  # noqa

def main():
    src, dst = sys.argv[1], sys.argv[2]
    ensure()
    from fontTools.ttLib import TTFont
    os.makedirs(dst, exist_ok=True)
    for f in sorted(os.listdir(src)):
        if f.endswith(".woff2"):
            t = TTFont(os.path.join(src, f)); t.flavor = None
            t.save(os.path.join(dst, f[:-6] + ".ttf")); print("font:", f)

if __name__ == "__main__":
    main()
BH_EOF
  echo '  writing test/engine_test.cpp'
  cat > 'test/engine_test.cpp' <<'BH_EOF'
#include "../Source/ReverbEngine.h"
#include <cstdio>
#include <random>
using namespace bh;

static const double SR = 48000.0;
struct Res { std::vector<float> L, R; };

static Params mk (int type, float decay, float pre = 0.f)
{
    Params p; p.type = type; p.decay = decay; p.predelayMs = pre; p.size = 0.6f; p.diffusion = 0.75f; p.damping = 0.45f;
    p.mod = 0.35f; p.width = 1.f; p.tone = 0.5f; p.character = kCharacter[type]; p.freeze = false; return p;
}
static Res render (const Params& p, const std::vector<float>& in)
{
    Engine e; e.prepare (SR, 512); e.setParams (p);
    std::vector<float> l (in), r (in);
    for (size_t i = 0; i < in.size(); i += 256)
    {
        int n = (int) std::min<size_t> (256, in.size() - i);
        e.setParams (p);
        e.process (l.data() + i, r.data() + i, n);
    }
    return { l, r };
}
static double rt60 (const std::vector<float>& x, double lo = -5, double hi = -25)
{
    // Schroeder backward integration, fit slope between lo and hi dB, extrapolate to 60 dB
    size_t n = x.size(); std::vector<double> e (n);
    double acc = 0; for (size_t i = n; i-- > 0;) { acc += (double) x[i] * x[i]; e[i] = acc; }
    double e0 = e[0]; std::vector<double> db (n); for (size_t i = 0; i < n; ++i) db[i] = 10 * std::log10 (e[i] / e0 + 1e-30);
    size_t i1 = 0, i2 = 0; for (size_t i = 0; i < n; ++i) { if (!i1 && db[i] <= lo) i1 = i; if (!i2 && db[i] <= hi) { i2 = i; break; } }
    if (!i1 || !i2 || i2 <= i1) return -1;
    return (double) (i2 - i1) / SR * (60.0 / (lo - hi));
}
static double echoDensity (const std::vector<float>& x, double t0, double win)
{
    // fraction of samples in window above 1/10 of the window's rms-peak-detect (Abel & Huang style simplified)
    size_t a = (size_t) (t0 * SR), b = std::min (x.size(), (size_t) ((t0 + win) * SR)); if (b <= a) return 0;
    double s = 0; for (size_t i = a; i < b; ++i) s += (double) x[i] * x[i]; double rms = std::sqrt (s / (b - a));
    size_t c = 0; for (size_t i = a; i < b; ++i) if (std::fabs (x[i]) > rms) ++c; return (double) c / (b - a) / 0.3173;
}
static double energyDb (const std::vector<float>& x, double t0, double t1)
{
    size_t a = (size_t) (t0 * SR), b = std::min (x.size(), (size_t) (t1 * SR)); double s = 0; for (size_t i = a; i < b; ++i) s += (double) x[i] * x[i];
    return 10 * std::log10 (s + 1e-30);
}
static double corr (const std::vector<float>& a, const std::vector<float>& b, size_t from, size_t to)
{
    double sab = 0, saa = 0, sbb = 0; for (size_t i = from; i < to && i < a.size(); ++i) { sab += a[i] * b[i]; saa += a[i] * a[i]; sbb += b[i] * b[i]; }
    return sab / std::sqrt (saa * sbb + 1e-30);
}
// std-dev (dB) of log-magnitude of the IR spectrum between f1..f2 after 1/6-oct smoothing removed => colouration measure
static double colourationDb (const std::vector<float>& x, double f1, double f2)
{
    int N = 1 << 17; std::vector<std::complex<double>> X (N);
    for (int i = 0; i < N; ++i) X[(size_t) i] = i < (int) x.size() ? x[(size_t) i] : 0.f;
    // naive FFT (radix-2)
    int j = 0; for (int i = 1; i < N; ++i) { int bit = N >> 1; for (; j & bit; bit >>= 1) j ^= bit; j ^= bit; if (i < j) std::swap (X[(size_t) i], X[(size_t) j]); }
    for (int len = 2; len <= N; len <<= 1) { double ang = -2 * M_PI / len; std::complex<double> wl (std::cos (ang), std::sin (ang));
        for (int i = 0; i < N; i += len) { std::complex<double> w (1); for (int k = 0; k < len / 2; ++k) { auto u = X[(size_t) (i + k)], v = X[(size_t) (i + k + len / 2)] * w; X[(size_t) (i + k)] = u + v; X[(size_t) (i + k + len / 2)] = u - v; w *= wl; } } }
    std::vector<double> db; for (int k = (int) (f1 / SR * N); k < (int) (f2 / SR * N); ++k) db.push_back (20 * std::log10 (std::abs (X[(size_t) k]) + 1e-12));
    // remove local trend (moving average of 64 bins)
    double s2 = 0; int cnt = 0; for (size_t k = 32; k + 32 < db.size(); ++k) { double m = 0; for (int q = -32; q <= 32; ++q) m += db[(size_t) ((int) k + q)]; m /= 65; s2 += (db[k] - m) * (db[k] - m); ++cnt; }
    return std::sqrt (s2 / cnt);
}

int main()
{
    const int NS = (int) (12 * SR);
    std::vector<float> imp (NS, 0.f); imp[10] = 1.f;
    struct Case { int type; float decay; const char* name; };
    Case cases[] = { { Hall, 2.6f, "HALL 2.6s" }, { Plate, 1.8f, "PLATE 1.8s" }, { Room, 0.55f, "ROOM 0.55s" }, { Space, 7.0f, "SPACE 7s" },
                     { Spring, 2.2f, "SPRING 2.2s" }, { Shimmer, 5.5f, "SHIMMER 5.5s" }, { Cathedral, 8.5f, "CATHEDRAL 8.5s" }, { LoFi, 1.6f, "LOFI 1.6s" } };
    printf ("%-15s %7s %7s %8s %8s %8s %8s %8s %6s %7s\n", "type", "RT60", "target", "dens50", "dens250", "ER dB", "tail dB", "colour", "L/R", "peak");
    for (auto& c : cases)
    {
        Params p = mk (c.type, c.decay);
        Res r = render (p, imp);
        double rt = rt60 (r.L);
        double peak = 0; for (float v : r.L) peak = std::max (peak, (double) std::fabs (v));
        double er = energyDb (r.L, 0.0, 0.03), tl = energyDb (r.L, 0.03, 1.0);
        printf ("%-15s %7.2f %7.2f %8.2f %8.2f %8.1f %8.1f %8.2f %6.2f %7.3f\n", c.name, rt, c.decay, echoDensity (r.L, 0.05, 0.05), echoDensity (r.L, 0.25, 0.05), er, tl,
                colourationDb (r.L, 300, 10000), corr (r.L, r.R, (size_t) (0.05 * SR), (size_t) (2.0 * SR)), peak);
    }
    // level match with pink-ish noise
    printf ("\n-- level (pink noise, RMS of wet output dBFS, input -20 dBFS) --\n");
    std::mt19937 rng (5); std::normal_distribution<float> nd (0.f, 1.f);
    std::vector<float> pn ((size_t) (8 * SR)); float b0 = 0, b1 = 0, b2 = 0;
    for (auto& v : pn) { float w = nd (rng); b0 = 0.99765f * b0 + w * 0.0990460f; b1 = 0.96300f * b1 + w * 0.2965164f; b2 = 0.57000f * b2 + w * 1.0526913f; v = (b0 + b1 + b2 + w * 0.1848f); }
    double ss = 0; for (float v : pn) ss += v * v; float g = (float) (0.1 / std::sqrt (ss / pn.size())); for (auto& v : pn) v *= g;
    for (auto& c : cases)
    {
        Res r = render (mk (c.type, c.decay), pn); double s = 0; size_t from = (size_t) (3 * SR); for (size_t i = from; i < r.L.size(); ++i) s += r.L[i] * r.L[i];
        printf ("%-15s %7.2f dB\n", c.name, 10 * std::log10 (s / (r.L.size() - from)));
    }
    // stability stress
    printf ("\n-- stress --\n");
    for (int t = 0; t < NumTypes; ++t)
    {
        Params p = mk (t, 20.f); p.size = 1.f; p.diffusion = 1.f; p.damping = 0.f; p.mod = 1.f;
        std::vector<float> in ((size_t) (14 * SR)); for (size_t i = 0; i < in.size(); ++i) in[i] = (i < 24000) ? nd (rng) * 0.5f : 0.f;
        Engine e; e.prepare (SR, 512); std::vector<float> l (in), rr (in); bool bad = false; double pk = 0, e1 = 0, e2 = 0;
        for (size_t i = 0; i < in.size(); i += 256) { Params q2 = p; q2.freeze = i >= (size_t) (1.0 * SR); e.setParams (q2); e.process (l.data() + i, rr.data() + i, 256); }
        for (size_t i = 0; i < l.size(); ++i) { if (!std::isfinite (l[i])) bad = true; pk = std::max (pk, (double) std::fabs (l[i])); if (i > 3 * SR && i < 4 * SR) e1 += l[i] * l[i]; if (i > 12 * SR && i < 13 * SR) e2 += l[i] * l[i]; }
        printf ("   freeze hold %s: energy @3s %.1f dB -> @12s %.1f dB   ", kTypeNames[t], 10 * std::log10 (e1 + 1e-30), 10 * std::log10 (e2 + 1e-30));
        Params q = mk (t, 20.f); q.size = 0.f; q.damping = 1.f; Res r2 = render (q, in); double pk2 = 0; for (float v : r2.L) { if (!std::isfinite (v)) bad = true; pk2 = std::max (pk2, (double) std::fabs (v)); }
        printf ("%-10s freeze-peak %.3f  min-size peak %.3f  %s\n", kTypeNames[t], pk, pk2, bad ? "NAN/INF!" : "ok");
    }
    return 0;
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

      - uses: actions/setup-python@v5
        with:
          python-version: '3.11'

      - name: Font tools
        run: python -m pip install fonttools brotli

      - name: Linux dependencies
        if: runner.os == 'Linux'
        run: |
          sudo apt-get update
          sudo apt-get install -y libasound2-dev libjack-jackd2-dev ladspa-sdk libcurl4-openssl-dev \
            libfreetype-dev libfontconfig1-dev libx11-dev libxcomposite-dev libxcursor-dev libxext-dev \
            libxinerama-dev libxrandr-dev libxrender-dev libglu1-mesa-dev mesa-common-dev

      - name: Reverb DSP self-test (Linux only)
        if: runner.os == 'Linux'
        run: |
          g++ -O2 -std=c++17 -o engine_test test/engine_test.cpp
          ./engine_test

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
  echo '  writing README.md'
  cat > 'README.md' <<'BH_EOF'
# BoomHype Tech - Tempo Reverb MK I

Vocal reverb VST3 by **BoomHype Tech**. 8 reverb rooms (Hall, Plate, Room, Space, Spring, Shimmer, Cathedral, Lo-Fi),
tempo-synced pre-delay and reverb time, 5-band spectral EQ with HP/LP (0/6/12/24 dB slopes) and a smooth live analyser,
ducking (input or sidechain), freeze, A/B compare, needle GR + output VU meters. Resizable window.

## Get the plugin
* **Windows / macOS / Linux:** push this repo to GitHub, open **Actions**, open the newest "Build VST3" run, download the artifact.
* **Linux inside Codespaces:** `bash boomhype_tempo_reverb_mk1.sh build`, then right-click the .zip -> Download.

## Install
* Windows: copy `Tempo Reverb MK I.vst3` to `C:\Program Files\Common Files\VST3\`
* macOS: `~/Library/Audio/Plug-Ins/VST3/` (if blocked: `xattr -cr "Tempo Reverb MK I.vst3"`)
* Linux: `~/.vst3/`

Fonts: Josefin Sans and Bevan (SIL Open Font License). JUCE is used under its AGPLv3/commercial licence.
BH_EOF
  echo '  writing assets/fonts/Bevan400.woff2'
  base64 -d > 'assets/fonts/Bevan400.woff2' <<'BH_EOF'
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
BH_EOF
  echo '  writing assets/fonts/Josefin500.woff2'
  base64 -d > 'assets/fonts/Josefin500.woff2' <<'BH_EOF'
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
phaNRq4EAAA=
BH_EOF
  echo '  writing assets/fonts/Josefin600.woff2'
  base64 -d > 'assets/fonts/Josefin600.woff2' <<'BH_EOF'
d09GMgABAAAAADAsABAAAAAAbNwAAC/MAAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAGoFeG7goHIYc
BmA/U1RBVEQAhQgRCAr3BNw6C4NuAAE2AiQDh1gEIAWGKgeGfAwHG45cRQdi2DgA/IaealGUUVJW
FCWM85Xk/1sClSHr+ptugKJwSVwKtTO0Fns0rUPrTOtL1OR3oxYmOwXqYPlnfil37CImikPEZJlh
L39f2PmU89YWDt0aHdEK2SWKeAYvBTs8Du6MIqhHaOyTXB4Cu69eVff8WRCZhEhiupvvIboMYgQi
AvsHfpu9/1FUxCYUEIkWFZG2aBPFKlTKKGauXDld9p3rW5eLvFrfbjvXt13UMm9S//6Ad7PnNrWt
QZJ85XAYgSOEYCBBWYQTlfyX/v30VNTC9expGZmKScViUdHgoArhDEZ+/wM8Rbw+5+uu/GFm1y4a
MMSo955tTaLPdqoySC3Lp5C/Q2wMAV577dxRC92W1PMVM0xvZ2VwrZGtZGImh1dlZ+KTAvj34cdZ
iHUlL4NIdAP1vjbf6TFsLPeG+v919tbq6uqdSHbAL8QKzfwkC9wCQZl6T//0nsay9Kwhz8+XrHhH
dsgaf7In6Al5Z0Neh7Ff5FHYE/QsIp6ee6637tMl1VLRNtsuAf1+qc0Gf+LiLjLyjAvJSHFA735A
A1nAEgdBFml8xwPLVMtKVfuqXDXWUBMQulHbbtkJByKPz9Zhpgwq3J5OOUWIMeo5LvFRC6Eo9/+X
ecmvghEaNRvM3coUUIEAPApFg0Ag/PhDBAiACBIEQUCGoGFAsLAg+PgQQhIIORWERiKEnhHCzAyR
Lh3CIg+iTCWEjQ3CwQHh4oao1wjRrAWiXRfEaKMhxuuFOOMMxGWXIe54CON3/8JAoEAXoAkU6o4H
wJf+gYVAPfQvBGhEwAqd9mt2IQTu/L2zFQJ5AarngIDC7PizvRVYhy8G2j9NaRkgAGmjIgSYQcu6
r3xxDg5WMAQOArGGJqIV/kNXqZhVJqMUKlJiPAwUiK17BDG0HRAvihUQzfsMMWW/Qvy73WjtngAz
ep4NMbTIPkj/M/PhQV0ClP/K/93Ab+4PgE/gPXgDXocXuz6tjyMegAoIgO6i9LAtMK6y2qirHDsc
H1ukKHh9IgRfSDn1xkKLz/BSr/7sV3nFZ73MM17KqU564uMd4yhHuECMLwZFP+/tnu+//bH7u6lP
xWu7uO92akPbv53bvHUb3NLN38xN3YSNXvvx1jz3ala+wuXsj6VPv6QpJplonNEXvtDhUSwKyN+9
7mn/hG/Yb93tl652vnOd6DCIe9vextb0VYvrpcxtelM63Pi684DYnpMqxneFrdLyy868/9KmSVZs
guPFihap4HCIF7+Fmi+FHdcCiZbdbKkBcm9i0+Yx+N5Phk9c8iyHz2RBEkdwJIwAoJQOyX0I7yp9
CzdiFw7gUPlrEIhY+sGGJMDtZERS9NjADYctTDsUigKoqG48z4kY+q1FHWyh7/iVpSAQYso/AhCF
EJ8jdrjkn5z8Ug7jZBwOV8qVMUZLjTDpBureTayhbfsLK2RFDj/RT3uATcWOwNg/G3KAQJdZ7z0Y
uytlCNyP+8thAIQtawCIGP/H/3EH7oDtFkRp3CiX5fC6d92WrCyERrUpY/OkX41uNQ8EDmfL2RYn
4gqUSZnFAllAwT5U4SI6a/+hXtVnMiqbS9CWs+1dSer6THH8BwlCQERCRhOJLgoj9ecTEokmFiNW
HAkaCkoqT/UMaWbpLHLkspIls1yFSulYlWm9Bu5YMjt06uKOJXn57ALOrzoJHI5hr7kdwgmrzVXA
EpgHMxqTIDTrO0D0zfzXQjXQyD1UuNCNjowKejoK0P3zomtbI7d0r9wbwJ8RCj1DQPjQ+ED5Qks8
4KDp4QWKy+NyfYUJBgAAI20AMPIEI2IVAIw0EitgOK0RGnl85AxNI9e/XZ03yl158rDh0Ru5Yugd
HGhEVlTGfjQ8vgYl7wHdfhGdXoZeFozdf8ntVcWcPqLLjBQ5k3Dgu2IYsa1dC0bKgF/g5/l9+m6G
x3RkzZY9NXKJeUXid7n+naSJkZ18lu661eCp5z4OiE4wJrGmdP1e8JEAKjF0QnYFer/sImvMs1Tw
/VJrBMdXgEB+CAj8RaLDY+EJJCAQRiQaQQwFEhU1BgsLlkpObG51xBo0iNWuQ5wuPeKhIiF8YfjD
QxERodyAJkIo8Q9Fxd2hLwkZL3KKp6B+lDKg5OGxEukgjBfQIJvmyDErVPEBO3Vy0Xr1XFDoozHQ
QC3URzv11kFxOmWQ0EN7W2Y5f4No+EMRREtUGYnXBAJYoIHoMkgN8GegWLHH9akAMSSYS5feWkHI
3Co4Nk6IYohgKHoxQxGrnj3AoMxhvxwPPrhg8ON37amCXt76+W9+GFbfbXfLfAHjHaq3Q52rvbVZ
H/VAA7JKJNqZcPB+b//xeS0LM+f7ZrlvfIl/onzv35m8yiHu503byjX8iuP9mqucZK+t0QpNv70V
OIy92IwBTMJY1ECxEJkFhbn6vZzvmj4W6AUI9+3CxsHFwydY2aXa+1qfB/cZuPM/QPx2XPjVd3jD
/vSZZobZBp2BM+VBX2Lqmv46Gbgww7rHveTEgdNyr/uDYMXNkFdS1FHVUIMthgJyYJ7W+TYHDPyY
QZsHJv1/8vN/XX8bakqiz+EkNtfMkgggSZNIliKVlo6RiVm6DJmyZMtRoVIVm2o1atk5udRr0KhF
uy7detZ6SQwGshi93zsZbLXRZdHJZ15SpNLSFQjBGJiCmdJlyJQlW8564YlnHmrUsnNyqT9Kg+he
vutrM3p4EDXw69F5LTiuoQ2nbWnFAR3VFQXGIRJ30g5YWgZguY4NPi/NGYgFxA92IToRqE/R2hiH
kU6ba/evQ7p066nR0f6JYRiGtTAsB2bpMmTKki2HTbUateycXOo3lvxuAVC0P25OF2j8JwmbvL7B
x2AL/ZtXqoM6BAVvtKzvqSFy4UJO3GYxndqamrGLhLq6Hv26qFNE0ClHSd6pBbF+hY8/xZIkGXzi
oy+StMV2+9WKZfiVm04zhgapgQqGF29YPnwLxDn/GXggYmHj4OIREBJfHXspsa3QRCNXsV+1CGtX
xOd/Ak9ELGwcXDwCQuLSRQjIQYpUWjpGJmbpMmTKki2HTbUateycXOqL3ZTgeeg5D4bfONoDqyc/
SLNLezORWMqQ7MXNPlp4OMYCIBMBFQwv3rB86r7kDlDtXx2/IkGW+W3wv4YnIhY2Di4eASHxVGKV
jPMw7WI6BIwWsWzGchgcxZYctSxnyDE7mv8zPCIWNg4uHgEh8YePy6k22vBkhrTi8Sxpx4OOtKS6
nv+mM5R8nmKNF78RmgtfvDC9NgwyChUML96wfPgWSBOqe+K6Fgy3sMwta7ZcBrN9IQdQGF68Yfnw
/XPxkB1+8+KuKU+oZmge+KstjivyAruWEHIAAAAAAMDdIYpuqpZatJygcJm2B56TFKm0dKUewXNg
li5DpizZcthUq1HLzsml/vp2DR3mumzohp7j+S69eKMukkywKHrl/9xSf6/9aUdnzCGTUMHw4g3L
h+/X/KrRdiSurx7XebISSjDXiGh5RstTdOtnsqPYBVpanE0DhlFcNsgH6xDVni9zB+Zk3OQi7Hgg
ZPXLC4YXb1g+fN/3e6A5W6lbyFmesCT3qZozZYU6g/mXzmDGOsSYiFsmTMhrSFW+s/hFQP10z5Ii
ak4Fq53R7ypsWfrR8Xwn/2ZigOemKzSdzlt+pvSuK89kP3Kzu2Y/b6m/EBntKz9rWHbXYsHt9Y17
+vTE9vTu6eXeBDMKWeFxr7rfhj9aPFD/2V7rAPu7oa4WKt9tjmYoDtCKmWjElN2qgOCPOPRDPGIx
AIMgMC2BQnDjy/nJkfK9G7johN3Wnc2NdedgiSIcxBsPXbhQeL1Q5cYHajXGtBgHE5UbC6YVAnF4
3iRiKBIchJcFMNaZChUIa16iMsX8zBERqMn6IPSLRQ5v8/g4godIQmD5CIERYnFJwFbokK0EDJTb
cHZQz7bRZr7LJhocDHDkclMBda1zBwShESi3/M6KMWCiKJKbN3jN//Cnv/ztH/9CoayswIcetmZu
qYaZSGAxCCWxZkIh0xqQJ6EYnMkHSQdWQBGIyYCwYDtJo3Y4eMBR6VZeGb5S3iCv243B3Gcdq0n9
brjLs2ALMAf/mkZvMpwCvX5Cnz4sKD/I+AHIDUAc3wmgh3BbkQi0CZQ+c478Vd+JAHj+yipCglB6
oU00yMCPsSway3G6NQJtsB6QPiWzExiDwQsFaCqO2gQjDYmvYMf23W7v7iEYL4wfhv1BYFAYdAaL
wWNoGEbGdiaLFcoijoyAphgkNNbQ18k3AVNgfHcMY4QzaPeo/pP6wy5gEaDqMcD/AwhECP/u/3fA
f0+Cz24BfHbgQfuDMQ8yHxB+3X9fuc8DAjACWOI2IG4aVsT1cR74Q/9RK6z2tZOu+MkaW22z0DnL
7DRonaXWOu8HP1rpKuTuxKctuiPxm7/ZIlvctt4LiXcp3n3J/OZ/yTa6aZOLjvrKcaedcMYtP3vm
ugl2u2SXG14adsEssz1y2TWLPTHTRHvMN88Cq2ChvPjy5sMPXphgIUJRhYtAEYiJh41DgOs7fDLx
pBKoRWuSKkkynRRaeibZMmTKUixfgUJpqthVq+FU63sOo7Rq49GtTg8hlzse2GG7Aw7aD4FUI74B
/A6In4C/QfOHQJv/AMoeIF8GIKuh5mA4eG59cd7TgKRG0A6dJ8QxYJ4iyUfZZdBRVEMfEEZk8lsH
esCUdvwjRyCACHt/6qT46NgFw6I7O8pjHKITCtOhS6c+RzEOmz3YvwEzUuYoAhwZrjcRIzExog6j
TXVS8zTIqZAXfoMfnaCG0LAGEZobQVt1GYYIw462eDyt7QhueqJ9FKSYReJ1fhd5dU5x0aWjF8ME
gjV2PUbWY5eY2pzTi4luY4j9FMzjsTO+ptBV18lSxtzTGk9y5/bLgYDKix6ILqGAsha/uowsBZWs
Hes4X/8EQQBiuLBhot48/QYMOKBqEuUiY6Cp7MZq4bIsiP+qAu7vNqHLFsuA6N5ubFCISr2C3+hL
Cgcl7Si2eA2tVlmDhdfygRcYCOyraG7YQpasJIPXyiGw4XV9xIsbmwWeE9Wncgvi9JsCTc1JdPy7
uemDDeX1OS8/OXRIgReb1HoZ49xbDNZ91oxJNNcbh8mVLvtMoLNUJjLLj4z5eFKjac/5nNzNOfbX
321SCj4S8hd15Fm5jHrWfB6T66h11osjvhrGejbisQy3tVN62U7WI/aBl0/VNXMsXkzp3kYdI7X3
Ph+duhB81iedpbE/R6qYg1R7dCSLWTwjvvhUfvEh/hxW/j3zS/yKvepJm9Z6j9GAH3TnYHvgg2bX
jjx5Pqiz1T/uT5vlDN6T2/EM+YDB2zEre7f599QkUpS2zs62t2B7L+Qn0CUv+OIJqlRFu+2Nh4qT
+HIV16FySG36gOqongy7XA09rP2ni7tVr22ukiZn31F9VR9DJL+UFGuZJq8hb8EIQbK1w1dGtbYB
cWcyPCzpWijidfUyIoO9Yl826AMxoXRO5Bsm9CvWCCMbwOnbxbnmZAw3+3dxbnsK7OjSrHIGl0Av
2z1dLfa3OGecCyFDsb2u0PFPMhLIQ4qdDSA1fXNR04jWXpv7K97uCVlZy+krTsPavT02BtTIWpcK
UujSLHPDWXTi+fbyWBg2eXccRa2cmZ5Nz9dTKcZR/v1Njol7uIEwUoUVjDYj+XaHTyYmpFVliXrg
M85X2efLMj6/pAfVulTNGiT+HkKeYrGccfV4bHYBGEi7Xbs8QJXcOnkWJeqCu2TuRi9Nq+OlwY2s
Ra8uZmrk6RTGxPg6gIF9SciK8625RRuMFEldKvENN5AhgkQXq45H/MQqv2ccFgAjqJ3MGYtKKScU
A2VL5ahX8fRk2lZkmtC4D72uIHA+RfTQM5sM66HozvU8nZXht8Obk2HMJqeRKD7XDRE9tKRIPwl1
sW7GsTNLVbzS/wo69Mk+d39BJwnULWre/mcLdaL3PqvGl+eiwuzonq4rqhOTbvWapDa+ohrEd2Uk
Kxbb+LPkQtDIzSWTXSuW7wDhYpaHtU0c54ZhRNZIBgru89o0p6TByUyql5lIJ98DjVEjDMW6oA5O
6aSExVnZe7Lh+gmoJwecL6/RP5S4/4PVThBiD2w39uSjimiQbuaIr3DOOrye9xgCLBr/Fc8+f+k2
VzIdynwG3Tmk82UdVI9aF5zksLPc1KybUDtpMiSV+Bn05fjyyaswi1vBlvrr+2P/2a9fz6Q5PrCS
svOfT8HdaGxqjDtz6qv6g2o0oUKLNQaCc10PMoqrmkg4hZWrKlXk8QFBtNMQkL+f8aul4vnn7PE+
xwLLwf25HAOwpTtNWTJHe1E55Oe+5VjOSijYFwScnVR30o7J8TEnv2MwbM/joMwt6CuejobBIvnq
E3btfZgGQeAhzw/lH02OlX3NCpEjt/VTDF48MNybAh8jM2zEXGz1zTmxbpP79Dst/QlZlwZmqtMz
GfBGDWqtffUuX2TJGuS71I/70eHA5l6zV54OHnD67rf7dB5C+6zeyPYRmuHGXeDtYgk3AH+xBt8k
Ml8MBL28LY1IODkacXYK1FZenDoMJXSMJIzc6Y2feXy4gvm3RHA9qf9f/jLbra2QxjtIFE93W7iG
qXAMW55LI+dlt1seMd5yiVnwUqiW1ynLYRQ6yqWBlSRdD2pWw3KL8ky7F3msX9E9DKBLVM2ALfZm
QrC5M4E/JyYK4uPrdPPrMGcHVoJjiEqAIJxt7oQMQp7Yy86r8oV92q3nfZ1e3VGqzUh1n1sBbLHq
38gdOQ122scM5OZDRxGd+0VCPBDsyZehnLvlzyBy/zs+a4dCefrU3PN+IuRcdgR/Tq3UG2EvqFKd
OH29n5gMVCezmZDruS/3mirOp2Y4Wb94jGdsZ69J8tKtDaaoC48GGD7wDtZyrDqdR58f1bkQbACn
i/6N1IVSAOR2/EHefojgbBBayhnWVc6fJqjX+cjvVeuvfXN+EUbq2x+XzAUVQlebxMscg+tIVfY3
JFP7sI/h/pPy6+DpT1fvg/2mDNx8RnQusXZtav8DRpe3Lw6crDs1HwzfRUF4hnpYG6aZHRe/Kre7
TuB7ffe+GfBiDY3i9Xwu7FcFDexjwR/kHIOo6pbzt3FeZFfnmfuqJ4s0MuoKBUKOkJKpBANLXv+i
289U9bI/oLJgDU6nVEnqSe9WX4fXQN+nUhKbmzCjC2hpNXmoyZrbi/KZfu+tEbm9VAT9N1Km/bAj
KnbBi4YPmZe3SxMaeUocRLpVQGAgbelsZ7XTw645Bnk/IyutytL5zjir/6Xr8MLoFdmTwe1XxyMj
OVnY7Ss516JY2N15D7LE6YaXbgio2swzcICfCHI/q7Ejzx9tHiK93Ne8ttOmgO6Wx6rALLqtFeJw
zB3s1VjmpDTM89U1punWKSdyIy9DE9W3u7Jrln9XsR9fLh/R6PhdsuLPobHIWaxwzSLY3h35PnQJ
vseLtyzcIO/mxbDN3eEeaE5+UITmm1e0UjsT0PPhYsft6R2YrLrrktstc8XdVqD46ZB4CwlI5Tbo
7IlACJJWf10OBPIIUhp1vMWmI9wLk1YtszDO1HtR5DonduadUp1NbiBRjWBpmTxdDm4ART8dInFY
QzEZ1+7TeVwWKERoOznJOat3GLVekLfBY2YD5u4v7OmfwCUJBcJxzgHY5tOz49yzmCB9j3PU2WWd
lFPKPXjT9SzAHIrxTnhRbNSSdJRcTPWPUEIf0PkfunUDbLd3q4oysu/d88fCrEsdhzWTBQEp85VF
mZRx9ZxrU2yHODz978bfW8a/LlJXjPV8oV77n++YBX++Wvth4vobz5vrhw93/KyIfKXpg37Fw389
+r+SBgNetdl/q6aMl21DZmJiGXznTJeklyarBTmm+BKS5PebN+VyvFB6T17yXb2cuz+JxVvxgl37
HUxUfXxWTNIWwjRNlVM6JbMgYUa1s0+ZY2rmmGOa9xZw5ZISns7Mq1KqWdVaYzlPrSpkLQHnzSvN
y3VVTaKphnz1ZGflFEnG+LZ6TTXDnMKrSjKKa9KTimiiseAY/t3TesbsMX833vMCHMNDHtMlahtV
3AUb9fcaDMQ0PKN0ttxhk0/Ork6cX2cfiM/SeyK7uU2i/XciUu0sk4FTk6LiVZh0taxE1qfmMTM8
X2Dv8M1OhVvRdbMrwZ0AjuHTOwtIsyvMk8YZc1H4yIgpLaxK74JbpzhvQzhLxcnKFYvf5zLp3Te7
Mf5xt97tuQPOl8g0EaU/Cn3Z+WisTyfq3yn/C36PiI2MRN90v8ByIzchnztfgqIxW93vqhvQWLIH
NO46TX+2RTPgdg2osnP6VS6neqDHouBVmcwVfIWsnG8w86oUSn6VIa2CL5dX8I1pXBu821JyNENf
dnT0ZHrJv66z64IuDDOa+VVyec5krjwEbUNUY9GN8OznbJdLNWDJVnH6e2d2xNui6982W37gtnK/
r2j7GeKHC7qUKXWZ0ZQilckmNDX833XzXiNP/f2FkJChg+H85k+QVpRUTj9KL1ZFhxfJTRVCU+u4
0ddHT6ht5Hi/fkymL58qcXyCPM/zUTMm2+bu5WAC+TrmJVWBZDjJQTcl8opV0RFFGmO1KE2pBe82
8lXfng8LHfougrf9p/dP4xH+tOMceGhwlNAEimci+nYjw+avZaRGmmVqla1JaYktDrOwvBPKR93T
hURGnZvDi4qeT6OZoi5zDdIkZYk9QYtYmjkrIG74b8+x+s76Q3DRO1qcliGMlWQJo9Oir3XcyM0a
PVGfCzkT9Zmjc290wq7hP9R6/A3xDNMH0wfg/Dx9H4Y/yy1f9f1p7ZvO7987Nrzupb4C/vDi28NL
fx+Zr2jfGLl9aANtzpuJwH6EfzTv4jTmjzPmBT963AmShtmaMmNThsfUqCkdX/+rlDBvB6GgOTDs
55DNa7tadnngf1xiTbzSnpGucdco1cmZktxqnKVuk6duK3fm6n5sRRSRPK5yjIIbxZ4czecl74Mr
OHUGU8wVReRFxcSWUB0h2usPOaTMNAKllR02W7FDHuPWrDMEV95RsL0Hg/m/qJTmFzapXpbPiNNK
KZOIWfVqlUufmupuTtKXeJyhFYXtq3C28StpYnbefwIRbT6X8iJHmu+VEw4lOHWeeN12uwffdgw7
p4yjUlfKFXZzWmKdU5Fn46yL4fOi13MYZvPMqhVKOWzlHbRShOYGhcZuMqU43DK1Io/2gyL9M4/J
HPWRx6Gu41NW4eF/XKJNKa8zpakdTllqbAFrEvFYG95Ts+1FiZhoY3HTZ5WPSStmsNclmvx3F39c
qluR6DJrlW6bRiM2cPGUtNDJSDarV1tfXjUnL/2QuyNrpnBphjTKlpxdLpZWcB2PubzHDi7b+YnH
/dxxNefzICfj89dAwmU1qJXmr/vQdqul3ZTuSN9YWuosCl9pi7Wu6PFn9SrWT3VMNQH9WkIGeWCq
Lvu8lh0jOs9iNzixZUqDplajdmn1yW6HRq0q5ldV++vrtiSm2FoVl7bxYs7ymEUlMytnuosYvNPR
YMG3ngkuLZIlJVlMvhpPaBBJyyqjm2OOQfZGzyYPVFzQGg8xDHHrPVsy4u1gwXvw9dRT1L5pd7SV
uMaRm79E8PoZ78F7YM9G3yJeb36Ckl2UZtF9lSeNTckw+yS2BQeMRjjZVDP2hCc4YDnCTqKa+Sc8
m0guWR6dVSJcKZ2IPTa+JuGwNsndpDGl1WtUbq1W32dDYpqpUZHk8hi5nztY1v0uA48GpxzJm3hw
+iuid7QFJ87jTtIJ28bWBtaufFgqViVVKeVus1njqJOXlHIfVvIE4nUcplz1dVEjRZF+MLrn/l/e
MW3DnuObFYU6Ii/x6Y541yp4/OR17P8rXNwo5MFbnKpSrnSY0pLcTmWiyhq9bofdM7YtRji7nBta
ynRrGotmpXNZrL3JfF7iXtiz0a9H4v2nPpLo1fbKLOSb+QfbNsEFX0kx89TTofqIsH/YIYSDJwby
5NpoJs3El0vMxL9FhhBUEjwUFkD4/l7dP8+OMXlcfRYfGs/r1JU10vm6Et6vfCHLFB+po1nURmlF
SaxGvPlCtOHRD8HMhRmc6MEghjc0M+yR5Hg9TRVjzdzgydNV6KCrxjPUWtqa68nNKM2A6yGaLDNZ
4wmlv2MzBZFpMUc9m1y+lTEXPmnDAcG93NO/PNmIztD0/r0H6je2gc6Jtp46OS1yXOSZk63dQUUl
5y/Dh9DKRZ5v/jh0epph48yC0LpFo765D23nw0e5g0fB95e2TNjggYlZzE8CSWFg6PvQwDf2NN/K
ZR+boqI/U4ef6XR0mo6E57feK4UyKZxcQ6HUkMMnpYqNUfJfH6JfMKs2cdYwDfESlnEJi/fpXIrT
yijWtnK/WoIaQ1cK4+WlORGR47nh3LcQmSLmG9L4cXEmPt8gjuaZzHxJbBqXbyiOIbJ/JxAxYUQS
+zWR8CYUVEiSU5RZJByfV8qfkJHn4qQkelD4X+cCYW9mgVOY2Ko0qhluvZZhN6pqrCZ1lEOnjXKZ
1JCw6NDiLo4eFPc7uipaZXUSWsSnOeGRCwavhjD1oWbtKk2oLkKpqm5OytHVaOS1agmrPLE0vSgr
NcQDxxZtoOkYBw4EaE2hvUyLJk3ralSkSpz8B5pqLy2bE5VN4suOyiMVr1mz/on9wwP+K2A5gm7N
L8tf0fWV95e+bddnH4BXPiq34F5SOVdPYzCop1ncTdU85towxK3z3Js3/IoTaqxKlDgStWq3IxFI
PqYWrXZscWrcqAJ3Q8kiS4GV3ehQ1InPbinSpknLFKqqVJPB2SjX1bEq33DZL5uYzPIAKoH+qg2G
F8GiKb9KW9UeIP0k46bP37FILhbHGvN40gQrT6ITSUzfnJjES09Qpzqak0ympqRkh7rbi+Wbx2RP
DmexfPKCYZKAo6BTl1Ap/dTIHip1WST89XN8mVxVnZylb2hSJZlbkrRNplz15Oq6juIllsI83phy
Y5Xm4fn81MhamSEllsB4bWUxW9/xeNhK4Cze1F/PTAVNN8XKXqOFXFOKKDrDkGySLQnKumxjaXuL
A15RuFdp5B/XwPpI0epnUdoZKfMpcUxOFTXY6cjIn+yZnfe47lh62PmocFp9Pp/P0Rq4UH1Mm0y7
EGieUxvR0bP+b/Dds3RPw9I9sGhawtB4lz7OQ9zYNKfmDRrwoiRQJtDnCjhCijyi93MvxSQsMZFw
JKFR5NzkCJMGRDLhhMi5EXIRwZeog5ZHppNzJmj7UeaTsyekgFMi4Gq1PJ5QOa1AsLmWK+AXuPVN
gIg8Sj6ZmE+hWYlkK40YUbCvWxDxA8COkkJRXWG5jFsng8FD7+CzYtC0GxrIpJtKImtpIPng1Dhl
Z+g1VIqDHllAoWrb2vXNaylU++L5VIoOAmbbcJWtxTb/yhz34hA1fIayhpvFS21WQY0FV2ZxfeWK
LP4T7iqml6qs5FJeFrdUKeGXLK5t01OJFbxitwtRut8sGDyeGL9ynP7mATHtyDIy487dFRWigjcG
C1OmLhPK81MTaLpdXUwCS8BUnFLzKqwgrUyUrBpb8AOpfm/55o4/C7KX8VQIZAUpT2y3U4q5Ii2s
ux2IjA+q/vzfuATTtxo1nyFRYxudQp0hWWmO3y6TVsh4U/MfeaboGn98gKtmae1SoCwktMyMaY0u
u3rz8AM7Z6J4ZitBZDdTQvu6EtZGvk2gQc3uhLeR6yWjOlgUswMccmLrLHG3wPXg0OGRgpVhMTNa
iCJHH3TKZMla4njiOytUW98dpcG4f8We/uZOg/u4u+4O4JbeqS9K/TWX89yS3VkzBstiKlPHcr+q
qtJaqWMqy2JX+mxUd4GW5/obZM7c3lzelHKG2UITCtv9t69klxucfv/b/weXX7w9HuQBR+1HgfuS
JRbOEUWzXAm3cs8nJJzX3k5woWf3jdW9GuW2evtkEH0+82P1g2U9Pz/j8wTDy/c/wp0PlhdHmGtL
sAWfq6EofoYhIs1egq2IkrXCk/+MccZjjQ3gB+n7I51i8q09R0e6+25FDHmcH9wfObr2NhnI369x
X3SPlEW9ZPIcCmwdeWmRe9zh4e4eckT39GdsdwS8N+w/0G9cvmbp+mmPBD8Uxd3RFaOxPRU9fQc/
PishSR6BH3GKMnczvZmbUalvTtbOGaUfpVscp8i2i/TpTuWkAvXspavY3DcVDBYxmLnjyPurUftI
PCekUe9APHeRJ4ZYsZQPm6WjK0Z79VT0jPkHv3HeRT3rR9O84I3xnXB7jXtgqn1qv7u/z94H+dBi
b4EI7+KtbsOgzLjNXLiju7S46I5bfsFYuMXo3uquKC8ugTPLKQYyMdkOSiRrqWKKHnRqWlrvOSZN
rnmIHXGoDqrpj/70osYMfRkaAXjUvbLYbYN72tTaqQPugb7avil4wtdPsoMforuwLjhQ3o81gjgi
q0VAvxL//3fBQe+KfZpKzS+JEJJkrZe6qj7A9RCV2Who8ud4lOqmxcTV6u88OuQPxHh9DCNXJhPD
skm8VBfDrBkZ+zr3xPRTqF0x0olUytyjQdJJzepKlwRkrfocldJfmDT/T6d5s7ceG9+CDI2F4/fy
F8R5alIWOFJ50/Mn9rkOJ42tXqBw2WWTs1K4rfqiKolK9D3V1Mv6+3QWU6gsjo0vCUhL7mw1pIv7
ZQcCGjn+wUn0YNIJPjFTnGkaOy3D3bRc7bSpm8JdXKukvSSjg2PQeDiBMdqWWr4jDGLpxLqj+Ar1
W+8ogU7INQiY3+bCHpw4jgl5p+ds40WKhFnW+CStXfq7OvvJIppgNSP4949h2K+pXgVVFI7pKY8j
T1iSkbrAYyoytqhS7akSkTU9sYz9/FlTj6RAChe2x2aKo7Ni4qIzM8WxuI/O5frlTuiZseVhFidG
J1GpKpxKnSgvOIPxj7r6294cCh29QaFK+rHv9eE94QKFzGilr12h08ZTtRwmWSu3RqkSnVxbfGG2
jgyca7awCMlBwTst2eUXrc6s5E7yMRTvC7lFp74d825BGAfST3dbBJL4Qll8iUwjKS1JSCIMn7or
LhoZH1JmVVAo5WNppD2oW5Q5WeaoVk7KtignO6rrYZmZU2T26oEt2YpJ9urJsqyyzG6jqTvbYuru
NmZm9mysfw2Gnm4DoCGp9ZoUl04nZiup2jrLsMDn2EyRKDNOIsqwXqzZPkMSJ8r8eGCTq4QDbFo1
n5OVYh0TfBLvvzuIoEpn8EvTokrg+55vSsaUjlm71hg4sBw3bXmgeSV6SKc8k3FGCXQV/QqNTv98
Rfqpz4emnaK3xIYOhYVF+KoPAcq+c+9zQ/J3LqfrMZYAUX/JK5rl8uwmueleUvk9eLL5ZJReYm6n
D1UHBqATMRoFSfeWRakIvNsXGHYhSpNB0O6Drwti6kODfg8OtDbPQHIjaTxvIuf5K+oGUjSB4E8i
+RMI0cCZxqnnQPJL5vaoI1Y+3Wu+qlUDNjrPmP8l8L55Wr/J2g9X7oq1An7uzCxLKiWc8jHKkj2L
b30LdQu3BhLInYSgGexg8lmCMbEIzShoXL/+lDVNHMNeqSXyBCUAxCfFJcMl1XXbdyG7doGKQMkn
kfIp1DwSKY966jyJ1WBgWAjiMimTw8PzKBSrGXxDdzKE/T3e2G9O/fEh93+Kj+g+cfSi6OjFj7fl
cFAXGlYSRiwKC3UB2g8C1HsUeCQuMfTY3JKGnpqZcuiZvnRDL3yTbOiVc1Fk/qVZGvqbT9wCEJDU
/PYLMflB5acRJMoMPTUxwdAzY4o3X/gqbpFMzbJo5Gx1QSNnq281crba+gxpdCOBzxJAyyMTFr0Z
DMKiP4WQsKZfRqQx/zIkzpcwSaYcTZK1WpNkLdckWUd8laH06MVE2Ndp/ok1NU93+rmNn20MFiwn
m86seWUREjZzf7k0WvpkIOKns9Ov4bV0YyZOS1cnkHR0QN6amucdgs0eNf202dOHP5z3s7uBQl+8
rViaU3tiJb0/0te3yaKD/DWbMctPs6mTiA2c+e3m9wcHAxrN9BjAb2HEtVqLOk9rUaeRFqz3u2jR
nOtTQmBzgwDQsp8lFcD+PIzyNgOxR89z7XvNBmb5zgI6c+hlzOru5zCsuT+Ozg6iuTaikzmd+/zT
7jQIfLkixqYirJ3c5mHw3wVGmMgYHdIvNXPoyMNx4/BvaD3aPX0U19UimzdBxJlHo6Ze/tiLUZDZ
WbU0825mwD4WH1RWBf/NtskyuFSP35MXm1N/mfkcNnv0z40+6f34zv4LyCz4CNR+B+j68wNfgA4g
77xBIJfIDbKIrCXXBzlP+cibtAdCQT6zm5x2k+U3m3xH+mBhADFjRn//6TFLf1/0GK6/jxnvX8/1
1/6+bZTv/TGuH8gJMo7MzO1Tts3m3GzyHem7/oXIIO+6WUTvzXzRMSHZROyklyyF1pnwdrbXlHpN
5YZsJva3foJ04KUcSw2ihja8YRDDt+z9C6Ln8g1PpXhiLahP5uoKWKKf5i7pI9IIQhBAbKu2phyh
IZbraX8EOySbiP0uewVV8p6t4Y7ziUA+ff7rFYvSzx4e+O/9GbeXlG4fDKf43cIqjRLH9sNNVdju
RQRC5DsQSxHqdHH2cNMnndi10eu723pWIe9JC/ZYejebtHyE/nYjWzhpFL82t2vRx5wx5lTuG0v9
SvoOJuNdzUM0k5WwPgVLCIs+JXlldl1X+cRJhzefoB/bsVEQIOn/e1k+1d+SfvhiMP8A3vwm3ArA
x4PGvt97Yff33QBqUIAAT7MotHzqny4d0jm8rH8PMcjHhI+Xe8fhsptzhyhH+p5zj0O3kBPy7vo1
5YVzlmy8/+BL+8fG8co9nJwTZxNI9iMvofTLw+Qj7Rxr4EjGUm5V/c02Ey2NZH8qG7f/Bffe3skO
oO8U8pPqIsmKiCYuCdtXsfQTB2NVEH0viBMtBDhd9UqIg3SCRVEbI8Py3zQPy6GoZnLeGAb9pK83
9SOPJiqG2amTy6mujAU5UQM/1DYRzEFUl5jFs4zD+iIoNxrx391/ucO/Rews0S1SLq278mHNQq/n
ZmejsMslmwRvASAZHT79QDk+ds+wFwTkRWIXhtsSiU0S3yzMpfArJuNfKv6VkpaL1tL32XaU/uKy
F8XF6v8RUZzHdAFzRuG2onRJUBxFzUZrC66L1dPmCVktNweH1DqxmkhTG6cGlbRERUtp9z3XvMFd
PMVKRavxgtJarVFdc6LIZKi440hDwp0QuW1aINpsfmCbsvUV5abT9omQEQqUol/BcODuM9OucE/r
L5YmfkSl7RfR35J1bzrhZF9C+Jlwh2xq/KWQXiXzsECbiSi6qKKUuy2le9qBWUAbYCMwBegLLAXG
xHkMFDCfjOk/yEU+wSFuNWkDTPZ3Gb2t1H4jiY1QC02plF0hAAjgdzbeTLyWvp26vmZ2wkBKP4Do
VXm8M0IWb2dUYITvjGF27bheuJ29URzeGUtiuhK4nsKdg7FIZchWwIEQgCZI9rj+OSAR3CBkOGCJ
Ni1qtcrQae+wWQOHEq7mOvU6FdBtya5+OmnmlBmSDi5uNFoxFDC0dmAoVJ8WRJabPTTixA1Dh/YU
enSSxupwm+03r027OnFymWUzjzjHdY8R4hZ7sp1PtpkXLRVLQiI+ShLlyJVrwjFaAvLDOl31Ba3V
Xnd3Bkto0IbpMdrV5EKpRLxNPb8uDPbQqn0MjdJBD3W6rKzXjmPGBFr7HT6q04AKu9gpHc2VccXs
NsuOgpFDk+slThdpVtXthE2TnWofWEiMoaeIZGgkO7Jut5l2YlApQ45sqbA3ll/DEgt9+UOQzjO8
734H+vgxUPie3Q4OO83HxePE9y8Blx+cd+FFOA9+0SWXXXka3esez03qqp/U+dkCu+yW4AnZE+wO
fN0N9X55YTczySPJjNA0t1GrFmuY6pud5j/pPA3wRz157cazDevUrScMdLHk9TKf77vR8o0xznhj
rdVrjwJPFSpSbIYSpSaYZLKJT+BjfF2GVOWNYBEfOOW0lVYJe6Kg/SS7W25UtHwRPwSH+MMxr73x
VoBUZ00TKcg2XtbDCsGyjjcculD68EgA2NRIoeUPb5+9gguELbY64aRv7XfAQYecg4kgJNhUx/lE
iH5LCxXomecOY2CKskitbwrji83PdANmmWm2PtX+oYsQMVLkwouIEjVakdGLihEzVmxz3HHfTXPd
ZXDbPbeC8zWRzt7u6nb5NcQ2tzmaC/OzfLpaGyTSBCXGXe32Vqm6wcvmXEWiV4dEqiaslEqUMupL
evuO53IXU5YNusKv7NYDKW9Ps1xntDMS1JDv9X4UxLQVabx8P7a5ZIJE5feV647v+gRwK/1qHV2d
fqvOhmbnCPKwsoD6tramWnsbem+8s63zxcSP8qeSIMdPKmY4Fshs/82e3gFRwoERMsrGQos5mNGQ
fTpJW9Oy3uD1rXO0HkZG+nd7zQE=
BH_EOF
  echo '  writing assets/fonts/Josefin700.woff2'
  base64 -d > 'assets/fonts/Josefin700.woff2' <<'BH_EOF'
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
BH_EOF
  printf '%s' 'build/
*.zip
.DS_Store
' > .gitignore
}

build_linux() {
  echo ">> installing build tools and JUCE Linux dependencies (needs sudo)"
  sudo apt-get update -y
  sudo apt-get install -y build-essential cmake git zip pkg-config python3 python3-pip libasound2-dev libjack-jackd2-dev ladspa-sdk \
    libcurl4-openssl-dev libfreetype-dev libfontconfig1-dev libx11-dev libxcomposite-dev libxcursor-dev \
    libxext-dev libxinerama-dev libxrandr-dev libxrender-dev libglu1-mesa-dev mesa-common-dev
  echo ">> font tools (for the Josefin Sans / Bevan face-plate fonts)"
  python3 -m pip install --quiet fonttools brotli || python3 -m pip install --quiet --break-system-packages fonttools brotli || true
  echo ">> reverb DSP self-test"
  g++ -O2 -std=c++17 -o /tmp/bh_engine_test test/engine_test.cpp && /tmp/bh_engine_test | head -12 || true
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
