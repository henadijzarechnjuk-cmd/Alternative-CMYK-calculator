import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'cmyk_engine.dart';

void main() => runApp(const SmartCmykApp());

class SmartCmykApp extends StatelessWidget {
  const SmartCmykApp({super.key});

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
      ),
      home: const CalculatorScreen(),
    );
  }
}

class CalculatorScreen extends StatefulWidget {
  const CalculatorScreen({super.key});

  @override
  State<CalculatorScreen> createState() => _CalculatorScreenState();
}

class _CalculatorScreenState extends State<CalculatorScreen> {
  static const _magenta = Color(0xFFE91E8C);
  static const _grey = Color(0xFF595959);
  static const _names = ['C', 'M', 'Y', 'K'];

  final _cmykCtl = [
    for (final v in ['90', '80', '30', '50']) TextEditingController(text: v)
  ];
  final _deCtl = TextEditingController(text: '2.0');
  final List<double> _limits = [100, 100, 100, 100];

  final List<String> _profilePaths = [];
  String? _profilePath;
  CmykEngine? _engine;

  SearchResult? _result;
  String _status = 'Оберіть CMYK-профіль, задайте параметри й натисніть «Розрахувати».';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _scanSystemProfiles();
  }

  @override
  void dispose() {
    _engine?.close();
    for (final c in _cmykCtl) {
      c.dispose();
    }
    _deCtl.dispose();
    super.dispose();
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

Future<void> _browse() async {
  final files = await FilePicker.pickFiles(
    type: FileType.custom,
    allowedExtensions: ['icc', 'icm'],
  );
  if (files.isEmpty) return; // діалог закрито без вибору
  final p = files.first.path;
  if (p != null) _selectProfile(p);
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
        _status = _describe(r, cmyk, de);
      });
    } on EngineException catch (e) {
      if (mounted) setState(() => _status = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _fmt(List<double> v) =>
      'C ${v[0].toStringAsFixed(1)}%  M ${v[1].toStringAsFixed(1)}%  '
      'Y ${v[2].toStringAsFixed(1)}%  K ${v[3].toStringAsFixed(1)}%';

  String _describe(SearchResult r, List<double> src, double tol) {
    final srcInk = src.fold<double>(0, (a, b) => a + b);
    final limits = [
      for (var i = 0; i < 4; i++)
        if (_limits[i] < 100) '${_names[i]} ≤ ${_limits[i].round()}%'
    ];
    return '${r.withinTolerance ? "ΔE у межах допуску" : "УВАГА: у межах допуску вкластися не вдалося — це найближчий результат"}\n'
        'Вхід:      ${_fmt(src)}  (Σ ${srcInk.toStringAsFixed(0)}%)\n'
        'Результат: ${_fmt(r.cmyk)}  (Σ ${r.totalInk.toStringAsFixed(0)}%)\n'
        'ΔE2000 = ${r.deltaE.toStringAsFixed(2)}  (допуск ${tol.toStringAsFixed(2)})\n'
        'Обмеження: ${limits.isEmpty ? "немає" : limits.join(", ")}';
  }

  // ---------- Інтерфейс ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Smart CMYK Calculator'), centerTitle: true),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _profileCard(),
              const SizedBox(height: 16),
              _inputCard(),
              const SizedBox(height: 16),
              _limitsCard(),
              const SizedBox(height: 20),
              _previewBox(),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _busy ? null : _calculate,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
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
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
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
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
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
                  onChanged: _busy ? null : (v) => v == null ? null : _selectProfile(v),
                ),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _browse,
              icon: const Icon(Icons.folder_open),
              label: const Text('Файл…'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _inputCard() {
    const accents = [Colors.cyan, _magenta, Color(0xFFF9A825), Colors.grey];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
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
                          labelStyle: TextStyle(color: accents[i], fontWeight: FontWeight.bold),
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const Divider(height: 24),
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

  Widget _limitsCard() {
    const accents = [Colors.cyan, _magenta, Color(0xFFF9A825), Colors.grey];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
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
                        style: TextStyle(fontSize: 12, color: accents[i])),
                  ),
                  Expanded(
                    child: Slider(
                      value: _limits[i],
                      min: 0,
                      max: 100,
                      divisions: 100,
                      activeColor: accents[i],
                      onChanged: (v) => setState(() => _limits[i] = v),
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

  Color _rgb(List<int> v) => Color.fromARGB(255, v[0], v[1], v[2]);

  // Сіре тло + два концентричні квадрати: зовнішній — вхід, внутрішній — результат
  Widget _previewBox() {
    final r = _result;
    return Container(
      height: 180,
      decoration: BoxDecoration(
        color: _grey,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white24),
      ),
      child: Center(
        child: Container(
          width: 130,
          height: 130,
          color: r == null ? _grey : _rgb(r.rgbIn),
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 65,
              height: 65,
              color: r == null ? _grey : _rgb(r.rgbOut),
            ),
          ),
        ),
      ),
    );
  }
}
