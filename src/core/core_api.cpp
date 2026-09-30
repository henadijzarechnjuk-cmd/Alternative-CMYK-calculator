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
    cmsHTRANSFORM cmykToLab = nullptr, labToCmyk = nullptr, cmykToRgb = nullptr;

    ~Engine() {
        if (cmykToLab) cmsDeleteTransform(cmykToLab);
        if (labToCmyk) cmsDeleteTransform(labToCmyk);
        if (cmykToRgb) cmsDeleteTransform(cmykToRgb);
        if (prof) cmsCloseProfile(prof);
        if (lab) cmsCloseProfile(lab);
        if (srgb) cmsCloseProfile(srgb);
    }
};

// Цільова функція: ΔE2000 між цільовим Lab і Lab(cmyk).
// Вільні змінні — лише канали з ліміт > 0; канали з лімітом 0 завжди рівні 0.
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

    double operator()(const double* x) const {
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

// Nelder–Mead у прямокутнику [0, hi]. x — старт і результат. Повертає мінімум.
double nelderMead(const Objective& o, std::vector<double>& x, int maxIter) {
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
        s[j].f = o(s[j].p.data());
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
        const double fr = o(xr.data());

        if (fr < s[0].f) {
            lerp(xt, c, s[n].p, -2.0);  // розтягування
            const double fe = o(xt.data());
            if (fe < fr) { s[n].p = xt; s[n].f = fe; }
            else         { s[n].p = xr; s[n].f = fr; }
        } else if (fr < s[n - 1].f) {
            s[n].p = xr; s[n].f = fr;
        } else {
            if (fr < s[n].f) lerp(xt, c, xr, 0.5);        // зовнішнє стиснення
            else             lerp(xt, c, s[n].p, 0.5);    // внутрішнє стиснення
            const double fc = o(xt.data());
            if (fc < std::min(fr, s[n].f)) {
                s[n].p = xt; s[n].f = fc;
            } else {  // стиснення всього симплекса до кращої вершини
                for (int j = 1; j <= n; ++j) {
                    lerp(s[j].p, s[0].p, s[j].p, 0.5);
                    s[j].f = o(s[j].p.data());
                }
            }
        }
    }
    std::sort(s.begin(), s.end(), byF);
    x = s[0].p;
    return s[0].f;
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
        if (!e->cmykToLab || !e->labToCmyk || !e->cmykToRgb) return fail(-4);

        if (error_code) *error_code = 0;
        return e.release();
    } catch (...) {
        return fail(-9);
    }
}

CMYK_ENGINE_API void engine_destroy(void* engine) {
    delete static_cast<Engine*>(engine);
}

CMYK_ENGINE_API int engine_search(void* engine, const double* in_cmyk, const double* max_ink,
                                  double max_delta_e, double* out) {
    if (!engine || !in_cmyk || !max_ink || !out) return -1;
    for (int i = 0; i < 4; ++i) {
        if (!std::isfinite(in_cmyk[i]) || in_cmyk[i] < 0.0 || in_cmyk[i] > 100.0) return -5;
        if (!std::isfinite(max_ink[i]) || max_ink[i] < 0.0 || max_ink[i] > 100.0) return -6;
    }
    if (!std::isfinite(max_delta_e) || max_delta_e < 0.0) return -7;

    try {
        const Engine* e = static_cast<const Engine*>(engine);

        Objective o;
        o.e = e;
        cmsDoTransform(e->cmykToLab, in_cmyk, &o.target, 1);
        for (int ch = 0; ch < 4; ++ch) {
            if (max_ink[ch] > 0.0) {
                o.idx[o.n] = ch;
                o.hi[o.n] = max_ink[ch];
                ++o.n;
            }
        }

        auto toFree = [&](const double* full) {
            std::vector<double> x(o.n);
            for (int i = 0; i < o.n; ++i)
                x[i] = std::min(std::max(full[o.idx[i]], 0.0), o.hi[i]);
            return x;
        };

        std::vector<double> best;
        double bestF = 0.0;

        if (o.n == 0) {
            bestF = o(nullptr);  // усі канали = 0, змінних немає
        } else {
            // Стартові точки: зворотна трансформація Lab->CMYK, сам вхід, середина
            // допустимого діапазону, варіанти з максимальним/нульовим K.
            double seed[4];
            cmsDoTransform(e->labToCmyk, &o.target, seed, 1);
            std::vector<std::vector<double>> starts;
            starts.push_back(toFree(seed));
            starts.push_back(toFree(in_cmyk));
            {
                std::vector<double> h(o.n);
                for (int i = 0; i < o.n; ++i) h[i] = 0.5 * o.hi[i];
                starts.push_back(h);
            }
            {
                const double t[4] = {in_cmyk[0], in_cmyk[1], in_cmyk[2], 100.0};
                starts.push_back(toFree(t));
            }
            {
                const double t[4] = {in_cmyk[0], in_cmyk[1], in_cmyk[2], 0.0};
                starts.push_back(toFree(t));
            }

            bestF = 1e300;
            for (auto& st : starts) {
                std::vector<double> x = st;
                nelderMead(o, x, 400);
                const double f = nelderMead(o, x, 400);  // рестарт, щоб не застрягти на межі
                if (f < bestF) { bestF = f; best = x; }
                if (bestF < 1e-4) break;
            }
        }

        double cmyk[4];
        o.expand(best.data(), cmyk);

        cmsCIELab labOut;
        cmsDoTransform(e->cmykToLab, cmyk, &labOut, 1);
        const double dE = cmsCIE2000DeltaE(&o.target, &labOut, 1.0, 1.0, 1.0);

        unsigned char rgbIn[3], rgbOut[3];
        cmsDoTransform(e->cmykToRgb, in_cmyk, rgbIn, 1);
        cmsDoTransform(e->cmykToRgb, cmyk, rgbOut, 1);

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

}  // extern "C"
