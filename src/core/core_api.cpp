#include "cmyk_engine_c.h"
#include <lcms2.h>
#include <cmath>
#include <algorithm>

// Хелпер для створення преформованого профілю або завантаження з пам'яті/файлу
extern "C" {

CMYK_ENGINE_API int search_alternative_cmyk(
    const double* input_cmyk,
    const char* profile_path,
    double target_delta_e,
    double max_ink_limit,
    double* output_cmyk
) {
    if (!input_cmyk || !profile_path || !output_cmyk) {
        return -1; // Невалідні вказівники
    }

    // 1. Відкриваємо ICC профіль
    cmsHPROFILE hProfile = cmsOpenProfileFromFile(profile_path, "r");
    if (!hProfile) {
        return -2; // Помилка відкриття профілю
    }

    // 2. Створюємо Lab профіль для вимірювання Delta E
    cmsHPROFILE hLabProfile = cmsCreateLab4Profile(NULL);
    if (!hLabProfile) {
        cmsCloseProfile(hProfile);
        return -3;
    }

    // 3. Створюємо трансформацію CMYK -> Lab
    cmsHTRANSFORM hCmykToLab = cmsCreateTransform(
        hProfile,
        TYPE_CMYK_DBL,
        hLabProfile,
        TYPE_Lab_DBL,
        INTENT_RELATIVE_COLORIMETRIC,
        cmsFLAGS_NOCACHE
    );

    if (!hCmykToLab) {
        cmsCloseProfile(hProfile);
        cmsCloseProfile(hLabProfile);
        return -4;
    }

    // 4. Отримуємо цільовий Lab для вхідного CMYK
    cmsCIELab targetLab;
    cmsDoTransform(hCmykToLab, input_cmyk, &targetLab, 1);

    // 5. Перевірка Gamut (чи колір входить у колірне охоплення)
    cmsHTRANSFORM hGamutTransform = cmsCreateProofingTransform(
        hProfile,
        TYPE_CMYK_DBL,
        hLabProfile,
        TYPE_Lab_DBL,
        hProfile,
        INTENT_RELATIVE_COLORIMETRIC,
        INTENT_RELATIVE_COLORIMETRIC,
        cmsFLAGS_GAMUTCHECK
    );

    cmsUInt16Number inGamutFlag = 0; // Використовуємо cmsUInt16Number замість cmsWORD
    if (hGamutTransform) {
        cmsDoTransform(hGamutTransform, input_cmyk, &inGamutFlag, 1);
        cmsDeleteTransform(hGamutTransform);
    }

    // Приклад спрощеної віддачі результату (тут буде ваша алгоритміка пошуку альтернативного CMYK)
    output_cmyk[0] = input_cmyk[0];
    output_cmyk[1] = input_cmyk[1];
    output_cmyk[2] = input_cmyk[2];
    output_cmyk[3] = input_cmyk[3];

    // 6. Очищення ресурсів LittleCMS
    cmsDeleteTransform(hCmykToLab);
    cmsCloseProfile(hProfile);
    cmsCloseProfile(hLabProfile);

    return 0; // Успішно
}

} // extern "C"