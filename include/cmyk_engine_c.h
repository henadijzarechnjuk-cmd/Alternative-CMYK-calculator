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

// Режими входу для engine_search_ex
#define CMYK_INPUT_CMYK 0  // in[0..3] = C, M, Y, K у відсотках 0..100
#define CMYK_INPUT_RGB 1   // in[0..2] = R, G, B у діапазоні 0..255 (sRGB), in[3] ігнорується

// Прапорці для engine_search_ex
#define CMYK_FLAG_ROUND_INT 1  // результат — цілі відсотки
#define CMYK_FLAG_MIN_INK 2    // з-поміж усіх варіантів у межах max_delta_e обрати з мінімальною сумою фарб

// Створює рушій із CMYK ICC-профілю (шлях у UTF-16, тож кирилиця в шляху працює).
// Повертає nullptr при помилці; код помилки пишеться в *error_code (може бути NULL).
//   -1 невалідні аргументи, -2 файл не відкрився, -3 не CMYK-профіль або пошкоджений,
//   -4 не вдалося створити трансформації, -9 внутрішній виняток
CMYK_ENGINE_API void* engine_create(const wchar_t* profile_path, int* error_code);

CMYK_ENGINE_API void engine_destroy(void* engine);

// Шукає CMYK при обмеженні 0 <= канал <= max_ink[канал].
//   За замовчуванням (flags = 0) мінімізує ΔE2000 до цільового кольору.
//   CMYK_FLAG_MIN_INK: серед варіантів з ΔE <= max_delta_e шукає найменшу суму фарб
//                      (якщо вкластися в допуск неможливо — повертається варіант з мінімальним ΔE).
//   CMYK_FLAG_ROUND_INT: результат округлюється до цілих відсотків, але не «сліпо»:
//                      перебираються цілі сусіди оптимуму й обирається найкращий.
//   input_mode: CMYK_INPUT_CMYK або CMYK_INPUT_RGB
//   in:         див. описи режимів вище
//   max_ink[4]: C, M, Y, K у відсотках 0..100
//   out[19]:
//     0..3   результат CMYK (%)
//     4..6   Lab цілі (вхідного кольору)
//     7..9   Lab результату
//     10     ΔE2000 (ціль vs результат)
//     11     1.0 якщо ΔE <= max_delta_e, інакше 0.0
//     12..14 sRGB вхідного кольору (0..255)
//     15..17 sRGB результату (0..255)
//     18     сума фарб результату (%)
// Повертає 0 або код помилки: -1 аргументи, -5 вхід поза діапазоном, -6 max_ink поза 0..100,
//   -7 max_delta_e < 0, -8 невідомий режим входу, -9 внутрішній виняток
CMYK_ENGINE_API int engine_search_ex(void* engine,
                                     int input_mode,
                                     const double* in,
                                     const double* max_ink,
                                     double max_delta_e,
                                     int flags,
                                     double* out);

// Сумісність з версією 1.0: вхід CMYK, без додаткових прапорців.
CMYK_ENGINE_API int engine_search(void* engine,
                                  const double* in_cmyk,
                                  const double* max_ink,
                                  double max_delta_e,
                                  double* out);

#ifdef __cplusplus
}
#endif
