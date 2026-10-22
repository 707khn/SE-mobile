import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../requests/it_request.dart' show ItPerson;
import '../requests/pre_trip_request.dart';
import '../utils/app_theme.dart';
import '../widgets/custom_text.dart';

String _errorText(String? code) {
  for (final key in ['pt_err_$code', 'it_err_$code']) {
    if (code != null && key.tr != key) return key.tr;
  }
  if (code != null && code.startsWith('bad_')) return 'pt_err_bad_value'.tr;
  return 'it_err_failed'.tr;
}

int? _int(TextEditingController c) => int.tryParse(c.text.trim());
double? _double(TextEditingController c) =>
    double.tryParse(c.text.trim().replaceAll(',', '.'));

/// Осмотр водителя медработником: показатели и решение о допуске.
class PreTripExamScreen extends StatefulWidget {
  const PreTripExamScreen(
      {Key? key, required this.driver, this.limits = const PreTripLimits()})
      : super(key: key);

  final ItPerson driver;
  final PreTripLimits limits;

  @override
  State<PreTripExamScreen> createState() => _PreTripExamScreenState();
}

class _PreTripExamScreenState extends State<PreTripExamScreen> {
  final _systolic = TextEditingController();
  final _diastolic = TextEditingController();
  final _pulse = TextEditingController();
  final _temperature = TextEditingController();
  final _alcohol = TextEditingController(text: '0');
  final _complaints = TextEditingController();
  final _reason = TextEditingController();
  String _kind = 'pre';
  bool _sending = false;
  String? _error;

  List<TextEditingController> get _all => [
        _systolic,
        _diastolic,
        _pulse,
        _temperature,
        _alcohol,
        _complaints,
        _reason
      ];

  @override
  void initState() {
    super.initState();
    for (final c in [_systolic, _diastolic, _pulse, _temperature, _alcohol]) {
      c.addListener(() => setState(() {}));
    }
  }

  @override
  void dispose() {
    for (final c in _all) {
      c.dispose();
    }
    super.dispose();
  }

  List<String> get _warnings => widget.limits.warnings(
        systolic: _int(_systolic),
        diastolic: _int(_diastolic),
        pulse: _int(_pulse),
        temperature: _double(_temperature),
        alcohol: _double(_alcohol),
      );

  Future<void> _send(bool admitted) async {
    final systolic = _int(_systolic), diastolic = _int(_diastolic);
    final alcohol = _double(_alcohol);
    if (systolic == null || diastolic == null) {
      setState(() => _error = 'pt_err_pressure_required'.tr);
      return;
    }
    if (alcohol == null) {
      setState(() => _error = 'pt_err_alcohol_required'.tr);
      return;
    }
    final reason = _reason.text.trim();
    if (!admitted && reason.isEmpty) {
      setState(() => _error = 'pt_err_reason_required'.tr);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await recordPreTripExam(
      driverId: widget.driver.id,
      kind: _kind,
      systolic: systolic,
      diastolic: diastolic,
      pulse: _int(_pulse),
      temperature: _double(_temperature),
      alcohol: alcohol,
      complaints: _complaints.text.trim(),
      admitted: admitted,
      reason: admitted ? '' : reason,
    );
    if (!mounted) return;
    if (result.ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _sending = false;
      _error = _errorText(result.error);
    });
  }

  Widget _field(TextEditingController c, String label, Key key,
      {bool decimal = false}) {
    return TextField(
      key: key,
      controller: c,
      keyboardType: TextInputType.numberWithOptions(decimal: decimal),
      inputFormatters: [
        FilteringTextInputFormatter.allow(
            RegExp(decimal ? r'[0-9.,]' : r'[0-9]'))
      ],
      decoration: InputDecoration(
          labelText: label, border: const OutlineInputBorder(), isDense: true),
    );
  }

  @override
  Widget build(BuildContext context) {
    final warnings = _warnings;
    final alcohol = warnings.contains('alcohol');
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: widget.driver.short, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(widget.driver.name,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final kind in ['pre', 'post'])
                ChoiceChip(
                  label: Text('pt_kind_$kind'.tr),
                  selected: _kind == kind,
                  onSelected: (_) => setState(() => _kind = kind),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text('pt_pressure'.tr,
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                  child: _field(
                      _systolic, 'pt_systolic'.tr, const Key('pt_systolic'))),
              const SizedBox(width: 8),
              Expanded(
                  child: _field(_diastolic, 'pt_diastolic'.tr,
                      const Key('pt_diastolic'))),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                  child: _field(_pulse, 'pt_pulse'.tr, const Key('pt_pulse'))),
              const SizedBox(width: 8),
              Expanded(
                  child: _field(_temperature, 'pt_temperature'.tr,
                      const Key('pt_temperature'),
                      decimal: true)),
            ],
          ),
          const SizedBox(height: 12),
          _field(_alcohol, 'pt_alcohol'.tr, const Key('pt_alcohol'),
              decimal: true),
          const SizedBox(height: 12),
          TextField(
            key: const Key('pt_complaints'),
            controller: _complaints,
            maxLength: 500,
            decoration: InputDecoration(
              labelText: 'pt_complaints'.tr,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          for (final w in warnings)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Icon(Icons.warning_amber,
                      size: 18,
                      color: context.readable(const Color(0xFFE65100))),
                  const SizedBox(width: 6),
                  Expanded(
                      child: Text('pt_warn_$w'.tr,
                          key: Key('pt_warn_$w'),
                          style: const TextStyle(fontSize: 13))),
                ],
              ),
            ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('pt_reason'),
            controller: _reason,
            maxLength: 500,
            decoration: InputDecoration(
              labelText: 'pt_reason'.tr,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                key: const Key('pt_error'),
                style: TextStyle(color: Colors.red.shade700)),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: ElevatedButton.icon(
                    key: const Key('pt_admit'),
                    // С положительной пробой допустить нельзя — и сервер не
                    // даст.
                    onPressed: _sending || alcohol ? null : () => _send(true),
                    icon: const Icon(Icons.check),
                    label: Text('pt_admit'.tr),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: OutlinedButton.icon(
                    key: const Key('pt_not_admit'),
                    onPressed: _sending ? null : () => _send(false),
                    icon: const Icon(Icons.block),
                    label: Text('pt_not_admit'.tr),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Выпуск машины механиком: госномер, пробег, исправна или нет.
class VehicleCheckScreen extends StatefulWidget {
  const VehicleCheckScreen(
      {Key? key, required this.driver, this.lastPlate = ''})
      : super(key: key);

  final ItPerson driver;
  final String lastPlate;

  @override
  State<VehicleCheckScreen> createState() => _VehicleCheckScreenState();
}

class _VehicleCheckScreenState extends State<VehicleCheckScreen> {
  late final _plate = TextEditingController(text: widget.lastPlate);
  final _odometer = TextEditingController();
  final _reason = TextEditingController();
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _plate.dispose();
    _odometer.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _send(bool ok) async {
    final plate = _plate.text.trim();
    if (plate.isEmpty) {
      setState(() => _error = 'pt_err_plate_required'.tr);
      return;
    }
    final reason = _reason.text.trim();
    if (!ok && reason.isEmpty) {
      setState(() => _error = 'pt_err_reason_required'.tr);
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    final result = await recordVehicleCheck(
      driverId: widget.driver.id,
      plate: plate,
      odometer: _int(_odometer),
      ok: ok,
      reason: ok ? '' : reason,
    );
    if (!mounted) return;
    if (result.ok) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _sending = false;
      _error = _errorText(result.error);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: BigText(content: widget.driver.short, color: Colors.white),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Text(widget.driver.name,
              style:
                  const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          TextField(
            key: const Key('pt_plate'),
            controller: _plate,
            maxLength: 20,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              labelText: 'pt_plate'.tr,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('pt_odometer'),
            controller: _odometer,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            decoration: InputDecoration(
              labelText: 'pt_odometer'.tr,
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('pt_vehicle_reason'),
            controller: _reason,
            maxLength: 500,
            decoration: InputDecoration(
              labelText: 'pt_vehicle_reason'.tr,
              border: const OutlineInputBorder(),
              counterText: '',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                key: const Key('pt_error'),
                style: TextStyle(color: Colors.red.shade700)),
          ],
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: ElevatedButton.icon(
                    key: const Key('pt_vehicle_ok'),
                    onPressed: _sending ? null : () => _send(true),
                    icon: const Icon(Icons.check),
                    label: Text('pt_vehicle_ok'.tr),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: OutlinedButton.icon(
                    key: const Key('pt_vehicle_fail'),
                    onPressed: _sending ? null : () => _send(false),
                    icon: const Icon(Icons.block),
                    label: Text('pt_vehicle_fail'.tr),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
