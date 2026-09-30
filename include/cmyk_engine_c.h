#pragma once
#include <wchar.h>

#ifdef _WIN32
#define CMYK_ENGINE_API __declspec(dllexport)
#else
#define CMYK_ENGINE_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

// Створює рушій із CMYK ICC-профілю (шлях у UTF-16, тож кирилиця в шляху працює).
// Повертає nullptr при помилці; код помилки пишеться в *error_code (може бути NULL).
//   -1 невалідні аргументи, -2 файл не відкрився, -3 не CMYK-профіль або пошкоджений,
//   -4 не вдалося створити трансформації, -9 внутрішній виняток
CMYK_ENGINE_API void* engine_create(const wchar_t* profile_path, int* error_code);

CMYK_ENGINE_API void engine_destroy(void* engine);

// Шукає CMYK з мінімальним ΔE2000 до кольору in_cmyk при обмеженні 0 <= канал <= max_ink[канал].
//   in_cmyk[4], max_ink[4]: відсотки 0..100 (порядок C, M, Y, K)
//   max_delta_e: допуск, лише для прапорця within_tolerance
//   out[19]:
//     0..3   результат CMYK (%)
//     4..6   Lab вхідного кольору
//     7..9   Lab результату
//     10     ΔE2000 (вхід vs результат)
//     11     1.0 якщо ΔE <= max_delta_e, інакше 0.0
//     12..14 sRGB вхідного кольору (0..255)
//     15..17 sRGB результату (0..255)
//     18     сума фарб результату (%)
// Повертає 0 або код помилки: -1 аргументи, -5 in_cmyk поза 0..100,
//   -6 max_ink поза 0..100, -7 max_delta_e < 0, -9 внутрішній виняток
CMYK_ENGINE_API int engine_search(void* engine,
                                  const double* in_cmyk,
                                  const double* max_ink,
                                  double max_delta_e,
                                  double* out);

#ifdef __cplusplus
}
#endif
