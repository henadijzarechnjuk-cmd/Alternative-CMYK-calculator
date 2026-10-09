import 'dart:io';
import 'dart:ui';

/// Налаштування між сеансами. Файл: %APPDATA%\AlternativeCmykCalculator\settings.ini
/// (якщо APPDATA недоступний — поруч з .exe). Формат — звичайний INI, його можна правити вручну.
class AppSettings {
  Offset? windowPos;
  Size? windowSize;
  String? profilePath;
  bool inputRgb = false; // остання вкладка входу: false = CMYK, true = RGB
  List<double> cmyk = [90, 80, 30, 50];
  List<double> rgb = [40, 60, 120];
  double deltaE = 2.0;
  List<double> limits = [100, 100, 100, 100];
  bool roundResult = false; // «Заокруглювати до цілих %»
  bool minInk = false; // «Мінімальна сума фарб»

  static File get _file {
    final appData = Platform.environment['APPDATA'];
    final dir = (appData != null && appData.isNotEmpty)
        ? '$appData\\AlternativeCmykCalculator'
        : File(Platform.resolvedExecutable).parent.path;
    return File('$dir\\settings.ini');
  }

  static List<double>? _nums(String? s, int count) {
    if (s == null) return null;
    final parts = s.split(',').map((e) => double.tryParse(e.trim())).toList();
    if (parts.length != count || parts.any((v) => v == null)) return null;
    return [for (final v in parts) v!];
  }

  static bool _inRange(List<double> v, double max) => v.every((x) => x >= 0 && x <= max);

  static Future<AppSettings> load() async {
    final s = AppSettings();
    try {
      final f = _file;
      if (!await f.exists()) return s;

      final map = <String, String>{};
      var section = '';
      for (final raw in await f.readAsLines()) {
        final line = raw.trim();
        if (line.isEmpty || line.startsWith(';') || line.startsWith('#')) continue;
        if (line.startsWith('[') && line.endsWith(']')) {
          section = line.substring(1, line.length - 1);
          continue;
        }
        final eq = line.indexOf('=');
        if (eq <= 0) continue;
        map['$section.${line.substring(0, eq).trim()}'] = line.substring(eq + 1).trim();
      }

      final pos = _nums(map['Window.LastMainWindowPosition'], 2);
      if (pos != null) s.windowPos = Offset(pos[0], pos[1]);

      final size = _nums(map['Window.LastMainWindowSize'], 2);
      if (size != null && size[0] >= 200 && size[1] >= 200) {
        s.windowSize = Size(size[0], size[1]);
      }

      final profile = map['Profile.LastChoosedColorProfile'];
      if (profile != null && profile.isNotEmpty) s.profilePath = profile;

      s.inputRgb = (map['Color.LastInputMode'] ?? '').toUpperCase() == 'RGB';

      final color = _nums(map['Color.LastUsedColor'], 4);
      if (color != null && _inRange(color, 100)) s.cmyk = color;

      final rgb = _nums(map['Color.LastUsedRgb'], 3);
      if (rgb != null && _inRange(rgb, 255)) s.rgb = rgb;

      final de = double.tryParse(map['Color.MaxDeltaE'] ?? '');
      if (de != null && de > 0) s.deltaE = de;

      final lim = _nums(map['Color.ChannelLimits'], 4);
      if (lim != null && _inRange(lim, 100)) s.limits = lim;

      s.roundResult = map['Options.RoundToWholePercent'] == '1';
      s.minInk = map['Options.MinimalInkSum'] == '1';
    } catch (_) {
      // пошкоджений файл не повинен заважати запуску — лишаються значення за замовчуванням
    }
    return s;
  }

  static String _i(double v) => v.round().toString();
  static String _n(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();
  static String _list(List<double> v) => v.map(_n).join(',');

  Future<void> save() async {
    try {
      final f = _file;
      await f.parent.create(recursive: true);
      final b = StringBuffer()
        ..writeln('; Alternative CMYK Calculator: налаштування (можна редагувати вручну)')
        ..writeln('[Window]');
      if (windowPos != null) {
        b.writeln('LastMainWindowPosition=${_i(windowPos!.dx)},${_i(windowPos!.dy)}');
      }
      if (windowSize != null) {
        b.writeln('LastMainWindowSize=${_i(windowSize!.width)},${_i(windowSize!.height)}');
      }
      b
        ..writeln()
        ..writeln('[Profile]');
      if (profilePath != null) b.writeln('LastChoosedColorProfile=$profilePath');
      b
        ..writeln()
        ..writeln('[Color]')
        ..writeln('LastInputMode=${inputRgb ? 'RGB' : 'CMYK'}')
        ..writeln('LastUsedColor=${_list(cmyk)}')
        ..writeln('LastUsedRgb=${_list(rgb)}')
        ..writeln('MaxDeltaE=${_n(deltaE)}')
        ..writeln('ChannelLimits=${_list(limits)}')
        ..writeln()
        ..writeln('[Options]')
        ..writeln('RoundToWholePercent=${roundResult ? 1 : 0}')
        ..writeln('MinimalInkSum=${minInk ? 1 : 0}');
      await f.writeAsString(b.toString());
    } catch (_) {
      // збій запису налаштувань не критичний
    }
  }
}
