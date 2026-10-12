#include "cmyk_engine_c.h"

#include <lcms2.h>

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <vector>

namespace {

struct Engine {
    cmsHPROFILE prof = nullptr, lab = nullptr, srgb = nullptr;
    cmsHTRANSFORM cmykToLab = nullptr, labToCmyk = nullptr, cmykToRgb = nullptr, cmykToRgbAbs = nullptr,
                   rgbToLab = nullptr;

    ~Engine() {
        if (cmykToLab) cmsDeleteTransform(cmykToLab);
        if (labToCmyk) cmsDeleteTransform(labToCmyk);
        if (cmykToRgb) cmsDeleteTransform(cmykToRgb);
        if (cmykToRgbAbs) cmsDeleteTransform(cmykToRgbAbs);
        if (rgbToLab) cmsDeleteTransform(rgbToLab);
        if (prof) cmsCloseProfile(prof);
        if (lab) cmsCloseProfile(lab);
        if (srgb) cmsCloseProfile(srgb);
    }
};

// Вільні змінні — лише канали з лімітом > 0; канали з лімітом 0 завжди дорівнюють 0.
struct Objective {
    const Engine* e = nullptr;
    cmsCIELab target{};
    int n = 0;
    int idx[4] = {0, 0, 0, 0};
    double hi[4] = {0, 0, 0, 0};

    void expand(const double* x, double* cmyk) const {
        cmyk[0] = cmyk[1] = cmyk[2] = cmyk[3] = 0.0;
        for (int i = 0; i < n; ++i) cmyk[idx[i]] = x[i];
    }

    // ΔE2000 між цільовим Lab і Lab(CMYK)
    double deltaE(const double* x) const {
        double cmyk[4];
        expand(x, cmyk);
        cmsCIELab lab;
        cmsDoTransform(e->cmykToLab, cmyk, &lab, 1);
        return cmsCIE2000DeltaE(&target, &lab, 1.0, 1.0, 1.0);
    }
};

struct Vertex {
    std::vector<double> p;
    double f = 0.0;
};

void clampTo(const Objective& o, std::vector<double>& p) {
    for (int i = 0; i < o.n; ++i) p[i] = std::min(std::max(p[i], 0.0), o.hi[i]);
}

std::vector<double> toFree(const Objective& o, const double* full) {
    std::vector<double> x(o.n);
    for (int i = 0; i < o.n; ++i) x[i] = std::min(std::max(full[o.idx[i]], 0.0), o.hi[i]);
    return x;
}

// Nelder–Mead у прямокутнику [0, hi]. x — старт і результат. f(const double*) -> double.
template <class F>
double nelderMead(const Objective& o, F&& f, std::vector<double>& x, int maxIter) {
    const int n = o.n;
    std::vector<Vertex> s(n + 1);
    for (int j = 0; j <= n; ++j) {
        s[j].p = x;
        if (j > 0) {
            const int i = j - 1;
            const double step = std::min(15.0, 0.25 * o.hi[i]);
            s[j].p[i] = (x[i] + step <= o.hi[i]) ? x[i] + step : x[i] - step;
        }
        clampTo(o, s[j].p);
        s[j].f = f(s[j].p.data());
    }

    std::vector<double> c(n), xr(n), xt(n);
    // out = a + t * (b - a), із обрізанням до меж
    auto lerp = [&](std::vector<double>& out, const std::vector<double>& a,
                    const std::vector<double>& b, double t) {
        for (int i = 0; i < n; ++i) out[i] = a[i] + t * (b[i] - a[i]);
        clampTo(o, out);
    };
    auto byF = [](const Vertex& a, const Vertex& b) { return a.f < b.f; };

    for (int it = 0; it < maxIter; ++it) {
        std::sort(s.begin(), s.end(), byF);
        if (s[n].f - s[0].f < 1e-7) break;

        std::fill(c.begin(), c.end(), 0.0);
        for (int j = 0; j < n; ++j)
            for (int i = 0; i < n; ++i) c[i] += s[j].p[i] / n;

        lerp(xr, c, s[n].p, -1.0);  // віддзеркалення
        const double fr = f(xr.data());

        if (fr < s[0].f) {
            lerp(xt, c, s[n].p, -2.0);  // розтягування
            const double fe = f(xt.data());
            if (fe < fr) { s[n].p = xt; s[n].f = fe; }
            else         { s[n].p = xr; s[n].f = fr; }
        } else if (fr < s[n - 1].f) {
            s[n].p = xr; s[n].f = fr;
        } else {
            if (fr < s[n].f) lerp(xt, c, xr, 0.5);        // зовнішнє стиснення
            else             lerp(xt, c, s[n].p, 0.5);    // внутрішнє стиснення
            const double fc = f(xt.data());
            if (fc < std::min(fr, s[n].f)) {
                s[n].p = xt; s[n].f = fc;
            } else {  // стиснення всього симплекса до кращої вершини
                for (int j = 1; j <= n; ++j) {
                    lerp(s[j].p, s[0].p, s[j].p, 0.5);
                    s[j].f = f(s[j].p.data());
                }
            }
        }
    }
    std::sort(s.begin(), s.end(), byF);
    x = s[0].p;
    return s[0].f;
}

double sumOf(const std::vector<double>& x) {
    double s = 0.0;
    for (double v : x) s += v;
    return s;
}

// Безперервний мінімум ΔE2000 із кількох стартових точок.
std::vector<double> minimizeDeltaE(const Objective& o, const double* base, const double* seed) {
    std::vector<double> best;
    if (o.n == 0) return best;
    auto f = [&](const double* x) { return o.deltaE(x); };

    std::vector<std::vector<double>> starts;
    starts.push_back(toFree(o, seed));  // зворотна трансформація Lab -> CMYK
    starts.push_back(toFree(o, base));  // сам вхід (CMYK) або те саме, що seed (RGB)
    {
        std::vector<double> h(o.n);
        for (int i = 0; i < o.n; ++i) h[i] = 0.5 * o.hi[i];
        starts.push_back(h);
    }
    {
        const double t[4] = {base[0], base[1], base[2], 100.0};
        starts.push_back(toFree(o, t));
    }
    {
        const double t[4] = {base[0], base[1], base[2], 0.0};
        starts.push_back(toFree(o, t));
    }

    double bestF = 1e300;
    for (auto& st : starts) {
        std::vector<double> x = st;
        nelderMead(o, f, x, 400);
        const double v = nelderMead(o, f, x, 400);  // рестарт, щоб не застрягти на межі
        if (v < bestF) { bestF = v; best = x; }
        if (bestF < 1e-4) break;
    }
    return best;
}

// Мінімальна сума фарб при ΔE <= tol. x0 — розв'язок з ΔE <= tol (безперервний мінімум ΔE).
std::vector<double> minimizeInk(const Objective& o, const std::vector<double>& x0, double tol) {
    const int n = o.n;
    auto dE = [&](const std::vector<double>& x) { return o.deltaE(x.data()); };
    auto penal = [&](const double* p) {
        double s = 0.0;
        for (int i = 0; i < n; ++i) s += p[i];
        return s + 1000.0 * std::max(0.0, o.deltaE(p) - tol);
    };

    std::vector<double> best = x0;
    double bestInk = sumOf(x0);

    // Приймає кандидата; якщо він порушує допуск — зсуває його до x0 бісекцією
    auto consider = [&](std::vector<double> c) {
        if (dE(c) > tol) {
            double lo = 0.0, hi = 1.0;
            std::vector<double> p(n);
            for (int it = 0; it < 40; ++it) {
                const double mid = 0.5 * (lo + hi);
                for (int i = 0; i < n; ++i) p[i] = x0[i] + mid * (c[i] - x0[i]);
                if (dE(p) <= tol) lo = mid; else hi = mid;
            }
            for (int i = 0; i < n; ++i) c[i] = x0[i] + lo * (c[i] - x0[i]);
        }
        const double ink = sumOf(c);
        if (ink < bestInk && dE(c) <= tol) { bestInk = ink; best = c; }
    };

    const double scales[] = {1.0, 0.9, 0.75, 0.5};
    for (double sc : scales) {
        std::vector<double> x(n);
        for (int i = 0; i < n; ++i) x[i] = std::min(o.hi[i], x0[i] * sc);
        for (int pass = 0; pass < 3; ++pass) {
            nelderMead(o, penal, x, 300);
            consider(x);
        }
    }

    // Покоординатне «стиснення»: кожен канал опускаємо, доки допуск дотримано
    for (int round = 0; round < 5; ++round) {
        bool changed = false;
        for (int i = 0; i < n; ++i) {
            std::vector<double> p = best;
            const double cur = best[i];
            if (cur <= 1e-9) continue;
            p[i] = 0.0;
            if (dE(p) <= tol) { best = p; bestInk = sumOf(best); changed = true; continue; }
            double lo = 0.0, hi = cur;  // lo — порушує допуск, hi — дотримує
            for (int it = 0; it < 40; ++it) {
                const double mid = 0.5 * (lo + hi);
                p[i] = mid;
                if (dE(p) <= tol) hi = mid; else lo = mid;
            }
            if (hi < cur - 1e-6) { best[i] = hi; bestInk = sumOf(best); changed = true; }
        }
        if (!changed) break;
    }
    return best;
}

// Заокруглення до цілих %: перебір цілих сусідів безперервного розв'язку.
// minInk: оцінка = сума фарб (якщо ΔE <= tol), інакше — штраф + ΔE; без minInk оцінка = ΔE.
std::vector<double> roundToIntegers(const Objective& o, const std::vector<double>& xc,
                                    const std::vector<double>& x0, bool minInk, double tol) {
    const int n = o.n;
    std::vector<int> hiI(n);
    for (int i = 0; i < n; ++i) hiI[i] = static_cast<int>(std::floor(o.hi[i] + 1e-9));

    auto score = [&](const std::vector<int>& xi) {
        double p[4];
        double ink = 0.0;
        for (int i = 0; i < n; ++i) { p[i] = xi[i]; ink += xi[i]; }
        const double d = o.deltaE(p);
        if (minInk) return d <= tol ? ink : 1e6 + d;
        return d + 1e-9 * ink;
    };

    auto local = [&](std::vector<int> cur, int r) {
        double cs = score(cur);
        for (int iter = 0; iter < 60; ++iter) {
            std::vector<int> bestN = cur;
            double bs = cs;
            std::vector<int> d(n, -r);
            while (true) {
                bool zero = true;
                for (int i = 0; i < n; ++i) if (d[i] != 0) { zero = false; break; }
                if (!zero) {
                    std::vector<int> cand(n);
                    bool ok = true;
                    for (int i = 0; i < n; ++i) {
                        cand[i] = cur[i] + d[i];
                        if (cand[i] < 0 || cand[i] > hiI[i]) { ok = false; break; }
                    }
                    if (ok) {
                        const double sc = score(cand);
                        if (sc < bs - 1e-12) { bs = sc; bestN = cand; }
                    }
                }
                int k = 0;
                while (k < n && ++d[k] > r) { d[k] = -r; ++k; }
                if (k == n) break;
            }
            if (bestN == cur) break;
            cur = bestN;
            cs = bs;
        }
        return std::make_pair(cur, cs);
    };

    // Стартові точки: усі комбінації floor/ceil навколо безперервного розв'язку (і навколо x0)
    std::vector<std::vector<int>> starts;
    auto addCombos = [&](const std::vector<double>& x) {
        std::vector<int> fl(n), ce(n);
        for (int i = 0; i < n; ++i) {
            fl[i] = std::min(std::max(static_cast<int>(std::floor(x[i] + 1e-9)), 0), hiI[i]);
            ce[i] = std::min(std::max(static_cast<int>(std::ceil(x[i] - 1e-9)), 0), hiI[i]);
        }
        for (int mask = 0; mask < (1 << n); ++mask) {
            std::vector<int> c(n);
            for (int i = 0; i < n; ++i) c[i] = (mask >> i & 1) ? ce[i] : fl[i];
            starts.push_back(c);
        }
    };
    addCombos(xc);
    if (minInk) addCombos(x0);

    std::vector<int> best = starts.front();
    double bestS = 1e300;
    for (const auto& st : starts) {
        auto r = local(st, 1);
        if (r.second < bestS) { bestS = r.second; best = r.first; }
    }
    auto fin = local(best, 2);  // широкий пошук навколо найкращого
    std::vector<double> out(n);
    for (int i = 0; i < n; ++i) out[i] = fin.first[i];
    return out;
}

int searchImpl(void* engine, int input_mode, const double* in, const double* max_ink,
               double max_delta_e, int flags, double* out) {
    if (!engine || !in || !max_ink || !out) return -1;
    if (input_mode != CMYK_INPUT_CMYK && input_mode != CMYK_INPUT_RGB) return -8;

    const int inCount = (input_mode == CMYK_INPUT_CMYK) ? 4 : 3;
    const double inMax = (input_mode == CMYK_INPUT_CMYK) ? 100.0 : 255.0;
    for (int i = 0; i < inCount; ++i)
        if (!std::isfinite(in[i]) || in[i] < 0.0 || in[i] > inMax) return -5;
    for (int i = 0; i < 4; ++i)
        if (!std::isfinite(max_ink[i]) || max_ink[i] < 0.0 || max_ink[i] > 100.0) return -6;
    if (!std::isfinite(max_delta_e) || max_delta_e < 0.0) return -7;

    try {
        const Engine* e = static_cast<const Engine*>(engine);
        const bool wantRound = (flags & CMYK_FLAG_ROUND_INT) != 0;
        const bool wantMinInk = (flags & CMYK_FLAG_MIN_INK) != 0;

        Objective o;
        o.e = e;
        double base[4] = {0, 0, 0, 0};
        unsigned char rgbIn[3];

        if (input_mode == CMYK_INPUT_CMYK) {
            cmsDoTransform(e->cmykToLab, in, &o.target, 1);
            cmsDoTransform(e->cmykToRgb, in, rgbIn, 1);
            for (int i = 0; i < 4; ++i) base[i] = in[i];
        } else {
            const double rgb[3] = {in[0] / 255.0, in[1] / 255.0, in[2] / 255.0};
            cmsDoTransform(e->rgbToLab, rgb, &o.target, 1);
            for (int i = 0; i < 3; ++i) rgbIn[i] = static_cast<unsigned char>(std::lround(in[i]));
        }

        double seed[4];
        cmsDoTransform(e->labToCmyk, &o.target, seed, 1);
        if (input_mode == CMYK_INPUT_RGB) {
            for (int i = 0; i < 4; ++i) base[i] = seed[i];
        }

        for (int ch = 0; ch < 4; ++ch) {
            if (max_ink[ch] > 0.0) {
                o.idx[o.n] = ch;
                o.hi[o.n] = max_ink[ch];
                ++o.n;
            }
        }

        // 1) безперервний мінімум ΔE
        const std::vector<double> xMin = minimizeDeltaE(o, base, seed);
        std::vector<double> x = xMin;

        // 2) за потреби — мінімальна сума фарб у межах допуску
        if (wantMinInk && o.n > 0 && o.deltaE(xMin.data()) <= max_delta_e)
            x = minimizeInk(o, xMin, max_delta_e);

        // 3) за потреби — цілі відсотки
        if (wantRound && o.n > 0) x = roundToIntegers(o, x, xMin, wantMinInk, max_delta_e);

        double cmyk[4];
        o.expand(x.data(), cmyk);

        cmsCIELab labOut;
        cmsDoTransform(e->cmykToLab, cmyk, &labOut, 1);
        const double dE = cmsCIE2000DeltaE(&o.target, &labOut, 1.0, 1.0, 1.0);

        unsigned char rgbOut[3];
        cmsDoTransform(input_mode == CMYK_INPUT_CMYK ? e->cmykToRgb : e->cmykToRgbAbs, cmyk, rgbOut, 1);

        for (int i = 0; i < 4; ++i) out[i] = cmyk[i];
        out[4] = o.target.L; out[5] = o.target.a; out[6] = o.target.b;
        out[7] = labOut.L;   out[8] = labOut.a;   out[9] = labOut.b;
        out[10] = dE;
        out[11] = (dE <= max_delta_e) ? 1.0 : 0.0;
        for (int i = 0; i < 3; ++i) { out[12 + i] = rgbIn[i]; out[15 + i] = rgbOut[i]; }
        out[18] = cmyk[0] + cmyk[1] + cmyk[2] + cmyk[3];
        return 0;
    } catch (...) {
        return -9;
    }
}

}  // namespace

extern "C" {

CMYK_ENGINE_API void* engine_create(const wchar_t* profile_path, int* error_code) {
    auto fail = [&](int code) -> void* {
        if (error_code) *error_code = code;
        return nullptr;
    };
    if (!profile_path) return fail(-1);
    try {
        std::ifstream f(std::filesystem::path(profile_path), std::ios::binary);
        if (!f) return fail(-2);
        std::vector<char> buf((std::istreambuf_iterator<char>(f)),
                              std::istreambuf_iterator<char>());
        if (buf.empty()) return fail(-2);

        auto e = std::make_unique<Engine>();
        e->prof = cmsOpenProfileFromMem(buf.data(), static_cast<cmsUInt32Number>(buf.size()));
        if (!e->prof || cmsGetColorSpace(e->prof) != cmsSigCmykData) return fail(-3);

        e->lab = cmsCreateLab4Profile(nullptr);
        e->srgb = cmsCreate_sRGBProfile();
        if (!e->lab || !e->srgb) return fail(-4);

        e->cmykToLab = cmsCreateTransform(e->prof, TYPE_CMYK_DBL, e->lab, TYPE_Lab_DBL,
                                          INTENT_RELATIVE_COLORIMETRIC, 0);
        e->labToCmyk = cmsCreateTransform(e->lab, TYPE_Lab_DBL, e->prof, TYPE_CMYK_DBL,
                                          INTENT_RELATIVE_COLORIMETRIC, 0);
        // Симуляція на екрані: CMYK -> sRGB з компенсацією чорної точки
        e->cmykToRgb = cmsCreateTransform(e->prof, TYPE_CMYK_DBL, e->srgb, TYPE_RGB_8,
                                          INTENT_RELATIVE_COLORIMETRIC,
                                          cmsFLAGS_BLACKPOINTCOMPENSATION);
        // Симуляція результату для входу RGB: без компенсації чорної точки, щоб зображення
        // відповідало тому ж Lab, за яким рахується ΔE (інакше темні кольори «підтягуються» до входу)
        e->cmykToRgbAbs = cmsCreateTransform(e->prof, TYPE_CMYK_DBL, e->srgb, TYPE_RGB_8,
                                             INTENT_RELATIVE_COLORIMETRIC, 0);
        // Вхід RGB: sRGB (0..1) -> Lab
        e->rgbToLab = cmsCreateTransform(e->srgb, TYPE_RGB_DBL, e->lab, TYPE_Lab_DBL,
                                         INTENT_RELATIVE_COLORIMETRIC, 0);
        if (!e->cmykToLab || !e->labToCmyk || !e->cmykToRgb || !e->cmykToRgbAbs || !e->rgbToLab)
            return fail(-4);

        if (error_code) *error_code = 0;
        return e.release();
    } catch (...) {
        return fail(-9);
    }
}

CMYK_ENGINE_API void engine_destroy(void* engine) {
    delete static_cast<Engine*>(engine);
}

CMYK_ENGINE_API int engine_search_ex(void* engine, int input_mode, const double* in,
                                     const double* max_ink, double max_delta_e, int flags,
                                     double* out) {
    return searchImpl(engine, input_mode, in, max_ink, max_delta_e, flags, out);
}

CMYK_ENGINE_API int engine_search(void* engine, const double* in_cmyk, const double* max_ink,
                                  double max_delta_e, double* out) {
    return searchImpl(engine, CMYK_INPUT_CMYK, in_cmyk, max_ink, max_delta_e, 0, out);
}

}  // extern "C"
