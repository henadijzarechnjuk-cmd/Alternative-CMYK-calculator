import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'cmyk_engine.dart';
import 'settings.dart';

// ---- Розміри інтерфейсу: усе, що впливає на висоту вікна, налаштовується тут ----
const _defaultSize = Size(560, 980); // розмір вікна при першому запуску
const _minSize = Size(480, 640);
const double _pagePad = 12; // зовнішній відступ сторінки
const double _gap = 8; // проміжок між картками
const double _cardPad = 10; // внутрішній відступ карток
const double _dividerH = 16; // висота роздільників у картках
const double _previewH = 150; // висота сірого вікна порівняння
const double _outerSq = 112; // зовнішній квадрат (вхід)
const double _innerSq = 56; // внутрішній квадрат (результат)

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  final settings = await AppSettings.load();

  final size = settings.windowSize ?? _defaultSize;
  final pos = settings.windowPos;
  final restorePos = pos != null && await _isOnScreen(pos);

  await windowManager.waitUntilReadyToShow(
    WindowOptions(
      size: size,
      minimumSize: _minSize,
      center: !restorePos,
      title: 'Alternative CMYK Calculator',
    ),
    () async {
      if (restorePos) await windowManager.setPosition(pos);
      await windowManager.show();
      await windowManager.focus();
    },
  );

  runApp(SmartCmykApp(settings: settings));
}

/// Чи потрапляє смуга заголовка збереженого вікна на якийсь із поточних моніторів
/// (щоб після відключення другого монітора вікно не «загубилося»).
Future<bool> _isOnScreen(Offset pos) async {
  try {
    final probe = Offset(pos.dx + 100, pos.dy + 20);
    for (final d in await screenRetriever.getAllDisplays()) {
      final o = d.visiblePosition ?? Offset.zero;
      final s = d.visibleSize ?? d.size;
      if (Rect.fromLTWH(o.dx, o.dy, s.width, s.height).contains(probe)) return true;
    }
  } catch (_) {}
  return false;
}

class SmartCmykApp extends StatelessWidget {
  final AppSettings settings;
  const SmartCmykApp({super.key, required this.settings});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Alternative CMYK Calculator',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00ACC1),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
        cardTheme: const CardThemeData(margin: EdgeInsets.zero),
      ),
      home: CalculatorScreen(settings: settings),
    );
  }
}

class CalculatorScreen extends StatefulWidget {
  final AppSettings settings;
  const CalculatorScreen({super.key, required this.settings});

  @override
  State<CalculatorScreen> createState() => _CalculatorScreenState();
}

class _CalculatorScreenState extends State<CalculatorScreen> with WindowListener {
  static const _magenta = Color(0xFFE91E8C);
  static const _grey = Color(0xFF595959);
  static const _names = ['C', 'M', 'Y', 'K'];
  static const _accents = [Colors.cyan, _magenta, Color(0xFFF9A825), Colors.grey];

  late final AppSettings _s = widget.settings;

  late final List<TextEditingController> _cmykCtl = [
    for (final v in _s.cmyk) TextEditingController(text: _fmtNum(v))
  ];
  late final TextEditingController _deCtl = TextEditingController(text: _fmtNum(_s.deltaE));
  late final List<double> _limits = List.of(_s.limits);

  final List<String> _profilePaths = [];
  String? _profilePath;
  CmykEngine? _engine;

  SearchResult? _result;
  double _srcInk = 0;
  String _status = 'Оберіть CMYK-профіль, задайте параметри й натисніть «Розрахувати».';
  bool _busy = false;
  bool _pickerOpen = false;
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    for (final c in _cmykCtl) {
      c.addListener(_scheduleSave);
    }
    _deCtl.addListener(_scheduleSave);
    _scanSystemProfiles();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreProfile());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _saveTimer?.cancel();
    _engine?.close();
    for (final c in _cmykCtl) {
      c.dispose();
    }
    _deCtl.dispose();
    super.dispose();
  }

  // ---------- Збереження налаштувань ----------

  String _fmtNum(double v) => v == v.roundToDouble() ? v.toInt().toString() : v.toString();

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 600), _saveNow);
  }

  Future<void> _saveNow() async {
    final cmyk = [for (final c in _cmykCtl) _num(c.text)];
    if (cmyk.every((v) => v != null && v >= 0 && v <= 100)) {
      _s.cmyk = [for (final v in cmyk) v!];
    }
    final de = _num(_deCtl.text);
    if (de != null && de > 0) _s.deltaE = de;
    _s.limits = List.of(_limits);
    _s.profilePath = _profilePath;
    await _s.save();
  }

  @override
  void onWindowMoved() => _captureGeometry();

  @override
  void onWindowResized() => _captureGeometry();

  Future<void> _captureGeometry() async {
    if (await windowManager.isMaximized() || await windowManager.isMinimized()) return;
    _s.windowPos = await windowManager.getPosition();
    _s.windowSize = await windowManager.getSize();
    _scheduleSave();
  }

  // ---------- Профілі ----------

  Future<bool> _isCmykProfile(File f) async {
    try {
      final raf = await f.open();
      try {
        final h = await raf.read(20);
        // байти 16..19 заголовка ICC — простір даних профілю
        return h.length == 20 && String.fromCharCodes(h.sublist(16, 20)) == 'CMYK';
      } finally {
        await raf.close();
      }
    } catch (_) {
      return false;
    }
  }

  Future<void> _scanSystemProfiles() async {
    final win = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final dir = Directory('$win\\System32\\spool\\drivers\\color');
    final found = <String>[];
    try {
      if (await dir.exists()) {
        await for (final e in dir.list()) {
          if (e is! File) continue;
          final l = e.path.toLowerCase();
          if ((l.endsWith('.icc') || l.endsWith('.icm')) && await _isCmykProfile(e)) {
            found.add(e.path);
          }
        }
      }
    } catch (_) {}
    found.sort();
    if (!mounted) return;
    setState(() {
      for (final p in found) {
        if (!_profilePaths.contains(p)) _profilePaths.add(p);
      }
    });
  }

  void _restoreProfile() {
    final p = _s.profilePath;
    if (p == null) return;
    if (File(p).existsSync()) {
      _selectProfile(p);
    } else {
      setState(() => _status = 'Профіль з минулого сеансу не знайдено: ${_baseName(p)}');
    }
  }

  Future<void> _browse() async {
    if (_pickerOpen) return;
    setState(() => _pickerOpen = true);
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['icc', 'icm'],
      );
      if (files.isEmpty) return; // діалог закрито без вибору
      final p = files.first.path;
      if (p != null) _selectProfile(p);
    } finally {
      if (mounted) setState(() => _pickerOpen = false);
    }
  }

  void _selectProfile(String path) {
    CmykEngine? eng;
    String msg;
    try {
      eng = CmykEngine.open(path);
      msg = 'Профіль завантажено: ${_baseName(path)}';
    } on EngineException catch (e) {
      msg = e.message;
    }
    setState(() {
      if (eng != null) {
        _engine?.close();
        _engine = eng;
        _profilePath = path;
        if (!_profilePaths.contains(path)) _profilePaths.add(path);
        _result = null;
      }
      _status = msg;
    });
    if (eng != null) _scheduleSave();
  }

  String _baseName(String p) => p.split(RegExp(r'[\\/]')).last;

  // ---------- Розрахунок ----------

  double? _num(String s) => double.tryParse(s.trim().replaceAll(',', '.'));

  Future<void> _calculate() async {
    final eng = _engine;
    if (eng == null) {
      setState(() => _status = 'Спершу оберіть CMYK-профіль.');
      return;
    }
    final cmyk = <double>[];
    for (var i = 0; i < 4; i++) {
      final v = _num(_cmykCtl[i].text);
      if (v == null || v < 0 || v > 100) {
        setState(() => _status = 'Канал ${_names[i]}: введіть число від 0 до 100.');
        return;
      }
      cmyk.add(v);
    }
    final de = _num(_deCtl.text);
    if (de == null || de <= 0) {
      setState(() => _status = 'Допуск ΔE: введіть додатне число.');
      return;
    }

    setState(() {
      _busy = true;
      _status = 'Виконується пошук…';
    });
    try {
      final r = await eng.search(cmyk: cmyk, maxInk: List.of(_limits), maxDeltaE: de);
      if (!mounted) return;
      setState(() {
        _result = r;
        _srcInk = cmyk.fold<double>(0, (a, b) => a + b);
        _status = _describe(r);
      });
      _saveNow();
    } on EngineException catch (e) {
      if (mounted) setState(() => _status = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _describe(SearchResult r) {
    final limits = [
      for (var i = 0; i < 4; i++)
        if (_limits[i] < 100) '${_names[i]} ≤ ${_limits[i].round()}%'
    ];
    final head = r.withinTolerance
        ? 'Готово: ΔE у межах допуску.'
        : 'УВАГА: у межах допуску вкластися не вдалося, показано найближчий результат.';
    return '$head\nОбмеження: ${limits.isEmpty ? "немає" : limits.join(", ")}';
  }

  // ---------- Інтерфейс ----------

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 60,
        centerTitle: true,
        title: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Smart CMYK Calculator'),
            Text(
              'алгоритм Нелдера-Міда',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(_pagePad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _profileCard(),
              const SizedBox(height: _gap),
              _inputCard(),
              const SizedBox(height: _gap),
              _limitsCard(),
              const SizedBox(height: _gap),
              _previewBox(),
              const SizedBox(height: _gap),
              ElevatedButton(
                onPressed: _busy ? null : _calculate,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  backgroundColor: const Color(0xFF00ACC1),
                  foregroundColor: Colors.white,
                ),
                child: _busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('РОЗРАХУВАТИ',
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              ),
              const SizedBox(height: _gap),
              _resultCard(),
              const SizedBox(height: _gap),
              Container(
                padding: const EdgeInsets.all(_cardPad),
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: Colors.white12),
                ),
                child: SelectableText(
                  _status,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _profileCard() {
    final locked = _busy || _pickerOpen;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: Row(
          children: [
            Expanded(
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _profilePath,
                  isExpanded: true,
                  hint: const Text('CMYK-профіль (системні)'),
                  icon: const Icon(Icons.palette_outlined),
                  items: [
                    for (final p in _profilePaths)
                      DropdownMenuItem(value: p, child: Text(_baseName(p))),
                  ],
                  onChanged: locked ? null : (v) => v == null ? null : _selectProfile(v),
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: locked ? null : _browse,
              icon: const Icon(Icons.folder_open),
              label: const Text('Профіль'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inputCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(_cardPad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Вхідний колір (CMYK %)', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                for (var i = 0; i < 4; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: TextField(
                        controller: _cmykCtl[i],
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                        decoration: InputDecoration(
                          labelText: _names[i],
                          labelStyle: TextStyle(color: _accents[i], fontWeight: FontWeight.bold),
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const Divider(height: _dividerH),
            Row(
              children: [
                const Text('Макс. допустима похибка (ΔE2000):'),
                const SizedBox(width: 12),
                SizedBox(
                  width: 80,
                  child: TextField(
                    controller: _deCtl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                    decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // Результат: та сама форма й розмір, що й у «Вхідний колір», але поля лише для читання
  Widget _resultCard() {
    final r = _result;
    final valueStyle = Theme.of(context).textTheme.bodyLarge;
    final ok = r?.withinTolerance ?? false;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(_cardPad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Результат (CMYK %)', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                for (var i = 0; i < 4; i++)
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: InputDecorator(
                        decoration: InputDecoration(
                          labelText: _names[i],
                          labelStyle: TextStyle(color: _accents[i], fontWeight: FontWeight.bold),
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        child: SelectableText(
                          r == null ? '—' : r.cmyk[i].toStringAsFixed(1),
                          style: valueStyle,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const Divider(height: _dividerH),
            Row(
              children: [
                const Text('Досягнута похибка (ΔE2000):'),
                const SizedBox(width: 12),
                SizedBox(
                  width: 80,
                  child: InputDecorator(
                    decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                    child: SelectableText(
                      r == null ? '—' : r.deltaE.toStringAsFixed(2),
                      style: valueStyle,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                if (r != null)
                  Tooltip(
                    message: ok
                        ? 'У межах допуску'
                        : 'Поза допуском: показано найближчий можливий результат',
                    child: Icon(
                      ok ? Icons.check_circle : Icons.warning_amber_rounded,
                      color: ok ? Colors.greenAccent : Colors.orangeAccent,
                      size: 22,
                    ),
                  ),
              ],
            ),
            if (r != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Σ фарб: ${r.totalInk.round()}% (вхід ${_srcInk.round()}%)',
                  style: const TextStyle(fontSize: 12, color: Colors.white70),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _limitsCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(_cardPad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Максимум фарби по каналах (100% = без обмежень)',
                style: TextStyle(fontWeight: FontWeight.bold)),
            for (var i = 0; i < 4; i++)
              Row(
                children: [
                  SizedBox(
                    width: 60,
                    child: Text('Макс. ${_names[i]}',
                        style: TextStyle(fontSize: 12, color: _accents[i])),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: _compactSliderTheme(context),
                      child: Slider(
                        value: _limits[i],
                        min: 0,
                        max: 100,
                        divisions: 100,
                        activeColor: _accents[i],
                        onChanged: (v) {
                          setState(() => _limits[i] = v);
                          _scheduleSave();
                        },
                      ),
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text('${_limits[i].round()}%', textAlign: TextAlign.right),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  // Менша «зона дотику» повзунка: рядок займає ~24 px замість 48
  SliderThemeData _compactSliderTheme(BuildContext context) =>
      SliderTheme.of(context).copyWith(
        trackHeight: 3,
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
      );

  Color _rgb(List<int> v) => Color.fromARGB(255, v[0], v[1], v[2]);

  // Сіре тло + два концентричні квадрати: зовнішній — вхід, внутрішній — результат
  Widget _previewBox() {
    final r = _result;
    return Container(
      height: _previewH,
      decoration: BoxDecoration(
        color: _grey,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      child: Center(
        child: Container(
          width: _outerSq,
          height: _outerSq,
          color: r == null ? _grey : _rgb(r.rgbIn),
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: _innerSq,
              height: _innerSq,
              color: r == null ? _grey : _rgb(r.rgbOut),
            ),
          ),
        ),
      ),
    );
  }
}
