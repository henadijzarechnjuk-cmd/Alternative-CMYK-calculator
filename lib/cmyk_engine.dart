import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

const _dllName = 'cmyk_engine.dll';

/// Режим входу: збігається з CMYK_INPUT_* у cmyk_engine_c.h
enum InputMode { cmyk, rgb }

class EngineException implements Exception {
  final int code;
  const EngineException(this.code);

  String get message {
    switch (code) {
      case -1:
        return 'Внутрішня помилка: невалідні аргументи.';
      case -2:
        return 'Не вдалося відкрити файл профілю.';
      case -3:
        return 'Файл не є коректним CMYK ICC-профілем.';
      case -4:
        return 'Не вдалося створити колірні трансформації для цього профілю.';
      case -5:
        return 'Вхідні значення поза діапазоном (CMYK: 0–100%, RGB: 0–255).';
      case -6:
        return 'Ліміти каналів мають бути в межах 0–100%.';
      case -7:
        return 'Допуск ΔE не може бути від’ємним.';
      case -8:
        return 'Невідомий режим входу.';
      default:
        return 'Помилка рушія (код $code).';
    }
  }

  @override
  String toString() => message;
}

class SearchResult {
  final List<double> cmyk; // результат, %
  final List<double> labIn;
  final List<double> labOut;
  final double deltaE;
  final bool withinTolerance;
  final List<int> rgbIn;
  final List<int> rgbOut;
  final double totalInk;

  const SearchResult({
    required this.cmyk,
    required this.labIn,
    required this.labOut,
    required this.deltaE,
    required this.withinTolerance,
    required this.rgbIn,
    required this.rgbOut,
    required this.totalInk,
  });

  factory SearchResult.fromBuffer(List<double> o) => SearchResult(
        cmyk: o.sublist(0, 4),
        labIn: o.sublist(4, 7),
        labOut: o.sublist(7, 10),
        deltaE: o[10],
        withinTolerance: o[11] > 0.5,
        rgbIn: o.sublist(12, 15).map((v) => v.round()).toList(),
        rgbOut: o.sublist(15, 18).map((v) => v.round()).toList(),
        totalInk: o[18],
      );
}

typedef _CreateC = Pointer<Void> Function(Pointer<Utf16>, Pointer<Int32>);
typedef _CreateD = Pointer<Void> Function(Pointer<Utf16>, Pointer<Int32>);
typedef _DestroyC = Void Function(Pointer<Void>);
typedef _DestroyD = void Function(Pointer<Void>);
typedef _SearchExC = Int32 Function(Pointer<Void>, Int32, Pointer<Double>, Pointer<Double>,
    Double, Int32, Pointer<Double>);
typedef _SearchExD = int Function(
    Pointer<Void>, int, Pointer<Double>, Pointer<Double>, double, int, Pointer<Double>);

// Прапорці: збігаються з CMYK_FLAG_* у cmyk_engine_c.h
const int _flagRoundInt = 1;
const int _flagMinInk = 2;

class CmykEngine {
  final int _handle; // адреса рушія (щоб передати в isolate)
  CmykEngine._(this._handle);

  static final DynamicLibrary _lib = DynamicLibrary.open(_dllName);
  static final _CreateD _create = _lib.lookupFunction<_CreateC, _CreateD>('engine_create');
  static final _DestroyD _destroy = _lib.lookupFunction<_DestroyC, _DestroyD>('engine_destroy');

  static CmykEngine open(String profilePath) {
    final p = profilePath.toNativeUtf16();
    final err = calloc<Int32>();
    try {
      final h = _create(p, err);
      if (h == nullptr) throw EngineException(err.value);
      return CmykEngine._(h.address);
    } finally {
      calloc.free(p);
      calloc.free(err);
    }
  }

  void close() => _destroy(Pointer<Void>.fromAddress(_handle));

  /// Пошук виконується в окремому isolate, щоб не блокувати інтерфейс.
  ///   input: 4 числа (C, M, Y, K у %) для InputMode.cmyk або 3 числа (R, G, B, 0..255) для InputMode.rgb
  ///   roundToInt: результат — цілі відсотки
  ///   minInk: мінімальна сума фарб у межах maxDeltaE
  Future<SearchResult> search({
    required InputMode mode,
    required List<double> input,
    required List<double> maxInk,
    required double maxDeltaE,
    bool roundToInt = false,
    bool minInk = false,
  }) {
    final handle = _handle;
    final modeIndex = mode.index;
    final flags = (roundToInt ? _flagRoundInt : 0) | (minInk ? _flagMinInk : 0);
    return Isolate.run(() {
      final lib = DynamicLibrary.open(_dllName);
      final fn = lib.lookupFunction<_SearchExC, _SearchExD>('engine_search_ex');
      final inP = calloc<Double>(4);
      final limP = calloc<Double>(4);
      final outP = calloc<Double>(19);
      try {
        for (var i = 0; i < 4; i++) {
          inP[i] = i < input.length ? input[i] : 0.0;
          limP[i] = maxInk[i];
        }
        final rc = fn(Pointer<Void>.fromAddress(handle), modeIndex, inP, limP, maxDeltaE, flags, outP);
        if (rc != 0) throw EngineException(rc);
        return SearchResult.fromBuffer(List<double>.generate(19, (i) => outP[i]));
      } finally {
        calloc.free(inP);
        calloc.free(limP);
        calloc.free(outP);
      }
    });
  }
}
