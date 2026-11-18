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
