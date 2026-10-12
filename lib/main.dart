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
const _defaultSize = Size(560, 1000); // розмір вікна при першому запуску
const _minSize = Size(480, 640);
const double _pagePad = 12; // зовнішній відступ сторінки
const double _gap = 8; // проміжок між картками
const double _cardPad = 10; // внутрішній відступ карток
const double _dividerH = 16; // висота роздільників у картках
const double _previewH = 140; // висота сірого вікна порівняння
const double _outerSq = 112; // зовнішній квадрат (вхід)
const double _innerSq = 56; // внутрішній квадрат (результат)
const double _tabH = 32; // висота вкладок CMYK / RGB
const double _btnW = 176; // ширина кнопки «Розрахувати» (фіксована)
const double _btnH = 48; // висота кнопки «Розрахувати»

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

  runApp(AlternativeCmykApp(settings: settings));
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

class AlternativeCmykApp extends StatelessWidget {
  final AppSettings settings;
  const AlternativeCmykApp({super.key, required this.settings});

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

class _CalculatorScreenState extends State<CalculatorScreen>
    with WindowListener, SingleTickerProviderStateMixin {
  static const _magenta = Color(0xFFE91E8C);
  static const _grey = Color(0xFF595959);
  static const _names = ['C', 'M', 'Y', 'K'];
  static const _rgbNames = ['R', 'G', 'B'];
  static const _accents = [Colors.cyan, _magenta, Color(0xFFF9A825), Colors.grey];
  static const _rgbAccents = [Colors.redAccent, Colors.greenAccent, Colors.lightBlueAccent];

  late final AppSettings _s = widget.settings;

  late final List<TextEditingController> _cmykCtl = [
    for (final v in _s.cmyk) TextEditingController(text: _fmtNum(v))
  ];
  late final List<TextEditingController> _rgbCtl = [
    for (final v in _s.rgb) TextEditingController(text: _fmtNum(v))
  ];
  late final TabController _tabs =
      TabController(length: 2, vsync: this, initialIndex: _s.inputRgb ? 1 : 0);
  late final TextEditingController _deCtl = TextEditingController(text: _fmtNum(_s.deltaE));
  late final List<double> _limits = List.of(_s.limits);

  final List<String> _profilePaths = [];
  String? _profilePath;
  CmykEngine? _engine;

  SearchResult? _result;
  String _srcLabel = ''; // підпис входу для рядка «Σ фарб»
  bool _lastRound = false; // чи був останній розрахунок із цілими відсотками
  late bool _round = _s.roundResult; // «Заокруглювати до цілих %»
  late bool _minInk = _s.minInk; // «Мінімальна сума фарб»
  String _status = 'Оберіть CMYK-профіль, задайте параметри й натисніть «Розрахувати».';
  bool _busy = false;
  bool _pickerOpen = false;
  Timer? _saveTimer;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    for (final c in [..._cmykCtl, ..._rgbCtl]) {
      c.addListener(_scheduleSave);
    }
    _deCtl.addListener(_scheduleSave);
    _tabs.addListener(() {
      if (!mounted) return;
      setState(() {}); // перемалювати поля вибраної вкладки
      _scheduleSave();
    });
    _scanSystemProfiles();
    WidgetsBinding.instance.addPostFrameCallback((_) => _restoreProfile());
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    _saveTimer?.cancel();
    _engine?.close();
    for (final c in [..._cmykCtl, ..._rgbCtl]) {
      c.dispose();
    }
    _deCtl.dispose();
    _tabs.dispose();
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
    final rgb = [for (final c in _rgbCtl) _num(c.text)];
    if (rgb.every((v) => v != null && v >= 0 && v <= 255)) {
      _s.rgb = [for (final v in rgb) v!];
    }
    _s.inputRgb = _tabs.index == 1;
    final de = _num(_deCtl.text);
    if (de != null && de > 0) _s.deltaE = de;
    _s.limits = List.of(_limits);
    _s.roundResult = _round;
    _s.minInk = _minInk;
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
    } catch (e) {
      msg = 'Не вдалося завантажити рушій (cmyk_engine.dll): $e';
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
    final rgbMode = _tabs.index == 1;
    final input = <double>[];
    if (rgbMode) {
      for (var i = 0; i < 3; i++) {
        final v = _num(_rgbCtl[i].text);
        if (v == null || v < 0 || v > 255) {
          setState(() => _status = 'Канал ${_rgbNames[i]}: введіть число від 0 до 255.');
          return;
        }
        input.add(v);
      }
    } else {
      for (var i = 0; i < 4; i++) {
        final v = _num(_cmykCtl[i].text);
        if (v == null || v < 0 || v > 100) {
          setState(() => _status = 'Канал ${_names[i]}: введіть число від 0 до 100.');
          return;
        }
        input.add(v);
      }
    }
    final de = _num(_deCtl.text);
    if (de == null || de <= 0) {
      setState(() => _status = 'Допуск ΔE: введіть додатне число.');
      return;
    }

    final roundInt = _round;
    final minInk = _minInk;
    setState(() {
      _busy = true;
      _status = 'Виконується пошук…';
    });
    try {
      final r = await eng.search(
        mode: rgbMode ? InputMode.rgb : InputMode.cmyk,
        input: input,
        maxInk: List.of(_limits),
        maxDeltaE: de,
        roundToInt: roundInt,
        minInk: minInk,
      );
      if (!mounted) return;
      setState(() {
        _result = r;
        _lastRound = roundInt;
        _srcLabel = rgbMode
            ? 'вхід RGB ${input.map((v) => v.round()).join(', ')}'
            : 'вхід ${input.fold<double>(0, (a, b) => a + b).round()}%';
        _status = _describe(r, rgbMode: rgbMode, minInk: minInk, roundInt: roundInt, tol: de);
      });
      _saveNow();
    } on EngineException catch (e) {
      if (mounted) setState(() => _status = e.message);
    } catch (e) {
      if (mounted) setState(() => _status = 'Неочікувана помилка під час розрахунку: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _describe(SearchResult r,
      {required bool rgbMode,
      required bool minInk,
      required bool roundInt,
      required double tol}) {
    final limits = [
      for (var i = 0; i < 4; i++)
        if (_limits[i] < 100) '${_names[i]} ≤ ${_limits[i].round()}%'
    ];
    final String head;
    if (r.withinTolerance) {
      head = minInk
          ? 'Готово: мінімальна сума фарб у межах ΔE ≤ ${_fmtNum(tol)}.'
          : 'Готово: ΔE у межах допуску.';
    } else if (rgbMode) {
      head = 'УВАГА: колір поза охопленням профілю (або обмежень), показано найближчий друкований результат.';
    } else {
      head = 'УВАГА: у межах допуску вкластися не вдалося, показано найближчий результат.';
    }
    return '$head\n'
        'Обмеження: ${limits.isEmpty ? "немає" : limits.join(", ")}'
        '${roundInt ? "\nЗаокруглено до цілих %." : ""}';
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
            const Text('Alternative CMYK Calculator'),
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
              _actionRow(),
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

  Widget _numField(TextEditingController ctl, String label, Color accent, {String? suffix}) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: TextField(
          controller: ctl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
          decoration: InputDecoration(
            labelText: label,
            labelStyle: TextStyle(color: accent, fontWeight: FontWeight.bold),
            suffixText: suffix,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      ),
    );
  }

  Widget _inputCard() {
    final rgbMode = _tabs.index == 1;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(_cardPad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text('Вхідний колір', style: TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                SizedBox(
                  width: 170,
                  child: TabBar(
                    controller: _tabs,
                    dividerHeight: 0,
                    indicatorSize: TabBarIndicatorSize.tab,
                    labelStyle: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    unselectedLabelStyle: const TextStyle(fontSize: 13),
                    tabs: const [
                      Tab(text: 'CMYK', height: _tabH),
                      Tab(text: 'RGB', height: _tabH),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: rgbMode
                  ? [
                      for (var i = 0; i < 3; i++)
                        _numField(_rgbCtl[i], _rgbNames[i], _rgbAccents[i]),
                    ]
                  : [
                      for (var i = 0; i < 4; i++)
                        _numField(_cmykCtl[i], _names[i], _accents[i], suffix: '%'),
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

  // Чекбокси зліва, кнопка фіксованого розміру справа
  Widget _actionRow() {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _check(
                'Заокруглювати до цілих %',
                'Результат — цілі відсотки. Не просте округлення: перебираються цілі сусіди оптимуму.',
                _round,
                (v) {
                  setState(() => _round = v);
                  _scheduleSave();
                },
              ),
              _check(
                'Мінімальна сума фарб',
                'Серед усіх варіантів у межах допуску ΔE обирається той, що має найменшу суму фарб.',
                _minInk,
                (v) {
                  setState(() => _minInk = v);
                  _scheduleSave();
                },
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: _btnW,
          height: _btnH,
          child: ElevatedButton(
            onPressed: _busy ? null : _calculate,
            style: ElevatedButton.styleFrom(
              padding: EdgeInsets.zero,
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
        ),
      ],
    );
  }

  Widget _check(String label, String tip, bool value, ValueChanged<bool> onChanged) {
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: _busy ? null : () => onChanged(!value),
        child: SizedBox(
          height: 26,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: value,
                  onChanged: _busy ? null : (v) => onChanged(v ?? false),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(label,
                    style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
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
                          r == null ? '—' : r.cmyk[i].toStringAsFixed(_lastRound ? 0 : 1),
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
                  'Σ фарб: ${r.totalInk.round()}% ($_srcLabel)',
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
