#include <iostream>
#include <vector>
#include <cmath>
#include "lcms2.h"

// Структура для збереження результатів
struct CMYKColor {
    double c, m, y, k;
};

class ColorEngine {
private:
    cmsHPROFILE hProfile;
    cmsHTRANSFORM hCmykToLab;
    cmsHTRANSFORM hLabToCmyk;
    cmsHTRANSFORM hCmykCheckGamut;

public:
    ColorEngine(const char* profilePath) {
        // Завантаження ICC-профілю (наприклад, Fogra39.icc)
        hProfile = cmsOpenProfileFromFile(profilePath, "r");
        cmsHPROFILE hLabProfile = cmsCreateLab4Profile(NULL);

        if (!hProfile || !hLabProfile) {
            std::cerr << "Помилка завантаження профілю!" << std::endl;
            return;
        }

        // 1. Трансформація CMYK -> Lab
        hCmykToLab = cmsCreateTransform(hProfile, TYPE_CMYK_DBL,
                                        hLabProfile, TYPE_Lab_DBL,
                                        INTENT_RELATIVE_COLORIMETRIC, 0);

        // 2. Зворотна трансформація Lab -> CMYK
        hLabToCmyk = cmsCreateTransform(hLabProfile, TYPE_Lab_DBL,
                                        hProfile, TYPE_CMYK_DBL,
                                        INTENT_RELATIVE_COLORIMETRIC, 0);

        // 3. Трансформація для перевірки Gamut (повертає 0 якщо в межах, >0 якщо поза)
        hCmykCheckGamut = cmsCreateProofingTransform(hProfile, TYPE_CMYK_DBL,
                                                     hLabProfile, TYPE_Lab_DBL,
                                                     hProfile, INTENT_RELATIVE_COLORIMETRIC,
                                                     INTENT_RELATIVE_COLORIMETRIC, 
                                                     cmsFLAGS_GAMUTCHECK);

        cmsCloseProfile(hLabProfile);
    }

    ~ColorEngine() {
        if (hCmykToLab) cmsDeleteTransform(hCmykToLab);
        if (hLabToCmyk) cmsDeleteTransform(hLabToCmyk);
        if (hCmykCheckGamut) cmsDeleteTransform(hCmykCheckGamut);
        if (hProfile) cmsCloseProfile(hProfile);
    }

    // Перевірка, чи лежить точка CMYK у межах охоплення профілю
    bool IsInGamut(const CMYKColor& cmyk) {
        cmsCIELab lab;
        cmsUInt16Number alarm;
        
        // Перевіряємо через масив прапорців Gamut Check
        cmsDoTransform(hCmykCheckGamut, &cmyk, &alarm, 1);
        return (alarm == 0);
    }

    // Розрахунок Delta E 2000 між двома кольорами Lab
    double CalculateDeltaE2000(const cmsCIELab& lab1, const cmsCIELab& lab2) {
        return cmsCIE2000DeltaE(&lab1, &lab2, 1.0, 1.0, 1.0);
    }

    // Перетворення CMYK -> Lab
    cmsCIELab ConvertCMYKtoLab(const CMYKColor& cmyk) {
        cmsCIELab lab;
        cmsDoTransform(hCmykToLab, &cmyk, &lab, 1);
        return lab;
    }
};