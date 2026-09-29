class SmartCmykCalculatorScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Smart CMYK Calculator')),
      body: SafeArea(
        child: SingleChildScrollView( // Забезпечує вертикальний скрол на смартфонах
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
              _buildColorPreviewBox(), // Сіре тло 30-40% + концентричні квадрати
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
}

