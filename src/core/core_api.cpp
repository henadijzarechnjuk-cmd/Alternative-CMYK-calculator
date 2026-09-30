#include <iostream>
#include <vector>
#include <cmath>
#include <algorithm>
#include "lcms2.h"

// Структура для зберігання результату пошуку
struct CMYKCandidate {
    double c, m, y, k;
    double deltaE;
    bool inGamut;
};

// Розрахунок спрощеної колірної похибки Delta E76 (для ілюстрації)
// При потребі замінюється на cmsCIE94DeltaE() або cmsCIEDE2000() з LittleCMS
double calculateDeltaE76(const cmsCIELab* Lab1, const cmsCIELab* Lab2) {
    double dL = Lab1->L - Lab2->L;
    double da = Lab1->a - Lab2->a;
    double db = Lab1->b - Lab2->b;
    return std::sqrt(dL * dL + da * da + db * db);
}

// Головна функція пошуку альтернативних комбінацій CMYK
std::vector<CMYKCandidate> findAlternativeCMYK(
    cmsHPROFILE hProfile,       // Хендл ICC-профілю (наприклад, FOGRA39/51)
    double srcC, double srcM, double srcY, double srcK, // Вихідний CMYK (0..100)
    double maxChannelLimit,     // Обмеження на БУДЬ-ЯКУ компоненту (наприклад, 85.0%)
    double maxDeltaETolerance,  // Максимально припустиме ΔE (наприклад, 2.0)
    double kStep = 1.0          // Крок ітерації по K-каналу (%)
) {
    std::vector<CMYKCandidate> candidates;

    // 1. Створюємо пряме перетворення CMYK -> Lab (A2B)
    cmsHTRANSFORM hCMYK2Lab = cmsCreateTransform(
        hProfile, TYPE_CMYK_DBL,
        cmsCreateLab4Profile(NULL), TYPE_Lab_DBL,
        INTENT_RELATIVE_COLORIMETRIC, cmsFLAGS_NOCACHE
    );

    // 2. Створюємо зворотне перетворення Lab -> CMYK (B2A)
    cmsHTRANSFORM hLab2CMYK = cmsCreateTransform(
        cmsCreateLab4Profile(NULL), TYPE_Lab_DBL,
        hProfile, TYPE_CMYK_DBL,
        INTENT_RELATIVE_COLORIMETRIC, cmsFLAGS_NOCACHE
    );
    
// Замість cmsCreateTransformEx використовуйте cmsCreateTransform:
cmsHTRANSFORM hTransform = cmsCreateTransform(
    hInputProfile,
    TYPE_CMYK_FLT,     // Або ваш формат (наприклад, TYPE_CMYK_16)
    hOutputProfile,
    TYPE_Lab_FLT,      // Або TYPE_RGB_8 / TYPE_Lab_DBL
    INTENT_RELATIVE_COLORIMETRIC,
    cmsFLAGS_NOCACHE
);

    if (!hCMYK2Lab || !hLab2CMYK || !hGamutCheck) {
        std::cerr << "Помилка створення трансформацій LittleCMS!" << std::endl;
        return candidates;
    }

    // Розраховуємо еталонне значення Lab для вихідного CMYK
    double inputCMYK[4] = { srcC, srcM, srcY, srcK };
    cmsCIELab targetLab;
    cmsDoTransform(hCMYK2Lab, inputCMYK, &targetLab, 1);

    // 4. Ітераційний пошук із варіюванням каналу K (0%..100%)
    for (double testK = 0.0; testK <= 100.0; testK += kStep) {
        
        // Зворотне перетворення Lab -> CMYK
        double candidateCMYK[4] = { 0.0, 0.0, 0.0, testK };
        
        // Використовуємо B2A трансформацію під орієнтовний K
        cmsDoTransform(hLab2CMYK, &targetLab, candidateCMYK, 1);
        
        // Мамуально коригуємо або фіксуємо K для аналізу генерації чорного
        candidateCMYK[3] = testK; 

        // А. Перевірка ліміту фарби на кожну з компонент (Channel Limit)
        if (candidateCMYK[0] > maxChannelLimit ||
            candidateCMYK[1] > maxChannelLimit ||
            candidateCMYK[2] > maxChannelLimit ||
            candidateCMYK[3] > maxChannelLimit) 
        {
            continue; // Пропускаємо варіант, якщо хоч один канал перевищує ліміт
        }

        // Б. Перевірка на входження в колірне охоплення (Gamut Check)
        cmsUInt16Number inGamutFlag = 0;
        cmsDoTransform(hGamutCheck, &targetLab, &inGamutFlag, 1);
        bool isInGamut = (inGamutFlag == 0); // 0 означає, що точка в межах охоплення

        // В. Зворотна перевірка точності (CMYK' -> Lab' -> ΔE)
        cmsCIELab actualLab;
        cmsDoTransform(hCMYK2Lab, candidateCMYK, &actualLab, 1);
        
        double dE = calculateDeltaE76(&targetLab, &actualLab);

        // Г. Якщо похибка в межах допуску — додаємо кандидат
        if (dE <= maxDeltaETolerance) {
            candidates.push_back({
                candidateCMYK[0],
                candidateCMYK[1],
                candidateCMYK[2],
                candidateCMYK[3],
                dE,
                isInGamut
            });
        }
    }

    // Очищення ресурсів
    cmsDeleteTransform(hCMYK2Lab);
    cmsDeleteTransform(hLab2CMYK);
    cmsDeleteTransform(hGamutCheck);

    return candidates;
}

int main() {
    // Завантаження профілю FOGRA/PSO
    cmsHPROFILE hProfile = cmsOpenProfileFromFile("PSOcoated_v3.icc", "r");
    if (!hProfile) {
        std::cout << "Не вдалося відкрити ICC-профіль." << std::endl;
        return 1;
    }

    // Вхідний глибокий темний колір: C:90%, M:80%, Y:30%, K:50%
    // Задаємо обмеження: жоден канал не повинен перевищувати 80%, Delta E <= 1.5
    auto results = findAlternativeCMYK(hProfile, 90.0, 80.0, 30.0, 50.0, 80.0, 1.5);

    std::cout << "Знайдено " << results.size() << " альтернативних варіантів CMYK:\n";
    for (const auto& c : results) {
        std::cout << "C: " << c.c << "% | M: " << c.m 
                  << "% | Y: " << c.y << "% | K: " << c.k 
                  << "% | dE: " << c.deltaE 
                  << " | Gamut: " << (c.inGamut ? "OK" : "Out") << "\n";
    }

    cmsCloseProfile(hProfile);
    return 0;
}
