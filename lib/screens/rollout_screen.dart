import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../requests/admin_request.dart';
import '../utils/app_theme.dart';
import '../utils/colors.dart';
import '../utils/dimensions.dart';

/// «Обновление»: дошла ли новая сборка до всех.
///
/// Экран отвечает на один вопрос — можно ли включать обязательную проверку
/// пропуска. Включить её раньше времени значит выключить приложение всем,
/// кто ещё на старой сборке, поэтому смотреть надо не на ощущения, а на
/// число запросов без пропуска: пока оно не ноль, кто-то ещё не обновился.
class RolloutScreen extends StatefulWidget {
  const RolloutScreen({Key? key}) : super(key: key);

  @override
  State<RolloutScreen> createState() => _RolloutScreenState();
}

class _RolloutScreenState extends State<RolloutScreen> {
  RolloutReport? _report;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final report = await fetchRollout();
      if (!mounted) return;
      setState(() {
        _report = report;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.pageColor,
      appBar: AppBar(
        title: Text('rollout_title'.tr),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'refresh'.tr,
            onPressed: _loading ? null : _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error || _report == null
              ? Center(child: Text('connection_error'.tr))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: EdgeInsets.all(Dimensions.width20),
                    children: _body(_report!),
                  ),
                ),
    );
  }

  List<Widget> _body(RolloutReport r) {
    final today = r.withoutPass.isEmpty ? 0 : r.withoutPass.first.value;
    final ready = today == 0 && !r.requireAuth;
    return [
      _verdict(r, ready, today),
      SizedBox(height: Dimensions.height30 / 1.5),
      _section('rollout_versions'.tr),
      ...(r.byVersion.entries.toList()
            ..sort((a, b) => b.value.compareTo(a.value)))
          .map((e) => _line(e.key, '${e.value}')),
      _line('rollout_not_seen'.tr, '${r.notSeenForAWeek}',
          muted: true),
      SizedBox(height: Dimensions.height30 / 1.5),
      _section('rollout_without_pass'.tr),
      if (r.withoutPass.isEmpty)
        _line('rollout_no_data'.tr, '', muted: true)
      else
        ...r.withoutPass.map((e) => _line(e.key, '${e.value}')),
      SizedBox(height: Dimensions.height30 / 1.5),
      _section('rollout_in_code'.tr),
      if (r.inCodePasswords.isEmpty)
        _line('rollout_no_data'.tr, '', muted: true)
      else
        ...r.inCodePasswords.map((e) => _line(e.key, '${e.value}')),
      SizedBox(height: Dimensions.height30 / 2),
      Text('rollout_in_code_why'.tr,
          style: TextStyle(fontSize: 12, color: context.mutedColor, height: 1.4)),
    ];
  }

  Widget _verdict(RolloutReport r, bool ready, int today) {
    final color = r.requireAuth
        ? Colors.green.shade700
        : (ready ? Colors.green.shade700 : Colors.orange.shade800);
    final text = r.requireAuth
        ? 'rollout_on'.tr
        : (ready ? 'rollout_ready'.tr : 'rollout_waiting'.trParams({'count': '$today'}));
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(r.requireAuth || ready ? Icons.check_circle_outline : Icons.hourglass_empty,
              color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text,
                    style: TextStyle(
                        fontSize: 14.5,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                        color: color)),
                const SizedBox(height: 4),
                Text('rollout_accounts'.trParams({'count': '${r.accounts}'}),
                    style:
                        TextStyle(fontSize: 12.5, color: context.mutedColor)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _section(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
      );

  Widget _line(String label, String value, {bool muted = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(
                    fontSize: 13.5,
                    color: muted ? context.mutedColor : context.inkColor)),
          ),
          Text(value,
              style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: value == '0' ? Colors.green.shade700 : AppColors.mainColor)),
        ],
      ),
    );
  }
}
