import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

void main() {
  runApp(const SmartCmykApp());
}

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
      home: const SmartCmykCalculatorScreen(),
    );
  }
}

class SmartCmykCalculatorScreen extends StatefulWidget {
  const SmartCmykCalculatorScreen({super.key});

  @override
  State<SmartCmykCalculatorScreen> createState() => _SmartCmykCalculatorScreenState();
}

class _SmartCmykCalculatorScreenState extends State<SmartCmykCalculatorScreen> {
  // Профіль
  String _selectedProfile = 'PSO Coated v3 (FOGRA51)';
  final List<String> _profiles = [
    'PSO Coated v3 (FOGRA51)',
    'Coated FOGRA39',
    'PSO Uncoated v3 (FOGRA52)',
  ];

  // Вхідні значення CMYK
  double _srcC = 90.0, _srcM = 80.0, _srcY = 30.0, _srcK = 50.0;
  double _deltaE = 1.5;

  // Канальні ліміти (100% = нема ліміту)
  double _limitC = 100.0, _limitM = 100.0, _limitY = 100.0, _limitK = 100.0;

  // Результат розрахунку (за замовчуванням до розрахунку — null)
  Color _originalRgb = const Color(0xFF1B2A3D); // Приклад обчисленого початкового RGB
  Color? _resultRgb; // Внутрішній квадрат (сірий до розрахунку)
  
  String _statusMessage = 'Готовий до обчислень. Задайте параметри та натисніть «Розрахувати».';
  bool _isCalculating = false;

  void _onCalculate() async {
    setState(() {
      _isCalculating = true;
      _statusMessage = 'Виконується обчислення через LittleCMS...';
    });

    // Імітація FFI виклику (тут викликається виклики вашої cmyk_engine_c.h через Dart FFI)
    await Future.delayed(const Duration(milliseconds: 300));

    setState(() {
      _isCalculating = false;
      // Приклад знайденого результату із задіяним GCR
      _resultRgb = const Color(0xFF1E2838); 
      _statusMessage = 'Знайдено рішення: C:78% M:68% Y:22% K:64% (ΔE = 0.84, in Gamut)';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Smart CMYK Calculator'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildProfileDropdown(),
              const SizedBox(height: 16),
              _buildOriginalCmykInputs(),
              const SizedBox(height: 16),
              _buildChannelLimitsSection(),
              const SizedBox(height: 20),
              _buildColorPreviewBox(),
              const SizedBox(height: 20),
              _buildCalculateButton(),
              const SizedBox(height: 16),
              _buildStatusMessageBox(),
            ],
          ),
        ),
      ),
    );
  }

  // 1. Dropdown вибору профілю
  Widget _buildProfileDropdown() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _selectedProfile,
            isExpanded: true,
            icon: const Icon(Icons.palette_outlined),
            items: _profiles.map((p) => DropdownMenuItem(value: p, child: Text(p))).toList(),
            onChanged: (val) => setState(() => _selectedProfile = val!),
          ),
        ),
      ),
    );
  }

  // 2. Вхідні CMYK + Delta E
  Widget _buildOriginalCmykInputs() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Вхідний колір (CMYK %)', style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Row(
              children: [
                _cmykInputField('C', _srcC, (v) => _srcC = v, Colors.cyan),
                _cmykInputField('M', _srcM, (v) => _srcM = v, Colors.magenta),
                _cmykInputField('Y', _srcY, (v) => _srcY = v, Colors.yellow.shade700),
                _cmykInputField('K', _srcK, (v) => _srcK = v, Colors.grey),
              ],
            ),
            const Divider(height: 24),
            Row(
              children: [
                const Text('Допуск похибки (ΔE):'),
                const SizedBox(width: 12),
                SizedBox(
                  width: 70,
                  child: TextField(
                    controller: TextEditingController(text: _deltaE.toString()),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(isDense: true, border: OutlineInputBorder()),
                    onChanged: (v) => _deltaE = double.tryParse(v) ?? 1.5,
                  ),
                ),
              ],
            )
          ],
        ),
      ),
    );
  }

  Widget _cmykInputField(String label, double val, Function(double) onChanged, Color accent) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4.0),
        child: TextField(
          controller: TextEditingController(text: val.toInt().toString()),
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(
            labelText: label,
            labelStyle: TextStyle(color: accent, fontWeight: FontWeight.bold),
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (v) => onChanged(double.tryParse(v) ?? 0),
        ),
      ),
    );
  }

  // 3. Канальні ліміти
  Widget _buildChannelLimitsSection() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Канальні ліміти (100% = без обмежень)', style: TextStyle(fontWeight: FontWeight.bold)),
            _channelSlider('Limit C', _limitC, (v) => setState(() => _limitC = v), Colors.cyan),
            _channelSlider('Limit M', _limitM, (v) => setState(() => _limitM = v), Colors.magenta),
            _channelSlider('Limit Y', _limitY, (v) => setState(() => _limitY = v), Colors.yellow.shade700),
            _channelSlider('Limit K', _limitK, (v) => setState(() => _limitK = v), Colors.grey),
          ],
        ),
      ),
    );
  }

  Widget _channelSlider(String label, double val, Function(double) onChanged, Color accent) {
    return Row(
      children: [
        SizedBox(width: 60, child: Text(label, style: TextStyle(fontSize: 12, color: accent))),
        Expanded(
          child: Slider(
            value: val,
            min: 0,
            max: 100,
            activeColor: accent,
            onChanged: onChanged,
          ),
        ),
        SizedBox(width: 40, child: Text('${val.toInt()}%', textAlign: TextAlign.right)),
      ],
    );
  }

  // 4. Порівняльне вікно (Сіре тло 35% + Концентричні квадрати)
  Widget _buildColorPreviewBox() {
    return Container(
      height: 180,
      decoration: BoxDecoration(
        color: const Color(0xFF595959), // Нейтральне сіре тло ~35%
        borderRadius: BorderRadius.circular(8.0),
        border: Border.all(color: Colors.white24),
      ),
      child: Center(
        // Зовнішній квадрат: RGB початкового кольору
        child: Container(
          width: 130,
          height: 130,
          color: _originalRgb,
          child: Center(
            // Внутрішній квадрат: До розрахунку сірий, після — RGB результату
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 65,
              height: 65,
              color: _resultRgb ?? const Color(0xFF595959),
              child: _resultRgb == null
                  ? const Center(child: Text('Grey', style: TextStyle(fontSize: 10, color: Colors.white54)))
                  : null,
            ),
          ),
        ),
      ),
    );
  }

  // 5. Кнопка Розрахувати
  Widget _buildCalculateButton() {
    return ElevatedButton(
      onPressed: _isCalculating ? null : _onCalculate,
      style: ElevatedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16.0),
        backgroundColor: const Color(0xFF00ACC1),
        foregroundColor: Colors.white,
      ),
      child: _isCalculating
          ? const SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            )
          : const Text('РОЗРАХУВАТИ', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
    );
  }

  // 6. Поле повідомлень
  Widget _buildStatusMessageBox() {
    return Container(
      padding: const EdgeInsets.all(12.0),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(6.0),
        border: Border.all(color: Colors.white12),
      ),
      child: Text(
        _statusMessage,
        style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
      ),
    );
  }
}
