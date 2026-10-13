import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:share_plus/share_plus.dart';

import '../utils/app_theme.dart';
import '../utils/app_update.dart';
import '../utils/app_version.dart';
import '../utils/colors.dart';
import '../utils/dimensions.dart';
import '../utils/error_log.dart';
import '../utils/open_external.dart';
import '../utils/variables.dart';

/// «О программе»: версия, адрес сервера и последние ошибки.
///
/// Последнее и есть смысл экрана. Когда приложение падает у человека в цехе,
/// к его телефону не подключишься: раньше причину искали, собирая сборку за
/// сборкой. Теперь она записана здесь, и её можно отправить одним касанием.
class AboutScreen extends StatefulWidget {
  const AboutScreen({Key? key}) : super(key: key);

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  List<ErrorEntry> _errors = [];
  bool _loading = true;

  /// Здесь про обновление говорим всегда, даже отложенное: человек пришёл
  /// сюда посмотреть, что у него за версия, — значит, спрашивает именно это.
  AppUpdate? _update;

  @override
  void initState() {
    super.initState();
    _load();
    AppUpdate.check().then((update) {
      if (mounted) setState(() => _update = update);
    });
  }

  Future<void> _load() async {
    final errors = await ErrorLog.read();
    if (!mounted) return;
    setState(() {
      _errors = errors;
      _loading = false;
    });
  }

  String get _report => [
        'SE Mobile ${appVersionLabel()}',
        'Сервер: ${AppValues.baseUrl}',
        '',
        if (_errors.isEmpty) 'Ошибок не записано.',
        for (final e in _errors) ...['${e.asText()}\n${'-' * 30}'],
      ].join('\n');

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('about_title'.tr),
        actions: [
          IconButton(
            tooltip: 'about_share'.tr,
            icon: const Icon(Icons.share_outlined),
            onPressed: () => Share.share(_report),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: EdgeInsets.all(Dimensions.width20),
              children: [
                _row('app_version'.tr, appVersionLabel()),
                _row('about_server'.tr, AppValues.baseUrl),
                if (_update != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      children: [
                        SizedBox(width: 110, child: Text('')),
                        Expanded(
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: ElevatedButton.icon(
                              onPressed: () =>
                                  openExternal(context, _update!.url),
                              icon: const Icon(Icons.system_update_outlined,
                                  size: 18),
                              label: Text(
                                  'update_available'
                                      .trParams({'version': _update!.label}),
                                  style: const TextStyle(fontSize: 13)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                SizedBox(height: Dimensions.height30 / 1.5),
                Row(
                  children: [
                    Expanded(
                      child: Text('about_errors'.tr,
                          style: const TextStyle(
                              fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                    if (_errors.isNotEmpty)
                      TextButton(
                        onPressed: () async {
                          await ErrorLog.clear();
                          await _load();
                        },
                        child: Text('about_clear'.tr),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                if (_errors.isEmpty)
                  Text('about_no_errors'.tr,
                      style: TextStyle(color: context.mutedColor, fontSize: 13))
                else
                  ..._errors.map(_errorCard),
              ],
            ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 110,
            child: Text(label,
                style: TextStyle(fontSize: 13, color: context.mutedColor)),
          ),
          Expanded(
            child: InkWell(
              onTap: () {
                Clipboard.setData(ClipboardData(text: value));
                HapticFeedback.selectionClick();
              },
              child: Text(value, style: const TextStyle(fontSize: 13.5)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _errorCard(ErrorEntry entry) {
    final when = entry.at.replaceFirst('T', ' ').split('.').first;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.cardSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.hairlineColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.error_outline, size: 16, color: Colors.red.shade700),
              const SizedBox(width: 6),
              Expanded(
                child: Text('$when · ${entry.version}',
                    style:
                        TextStyle(fontSize: 12, color: context.mutedColor)),
              ),
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: entry.asText()));
                  HapticFeedback.selectionClick();
                  Get.snackbar('about_copied'.tr, '',
                      snackPosition: SnackPosition.BOTTOM,
                      margin: const EdgeInsets.all(12));
                },
                child: Icon(Icons.copy, size: 16, color: AppColors.mainColor),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(entry.error, style: const TextStyle(fontSize: 13)),
          if (entry.stack.isNotEmpty) ...[
            const SizedBox(height: 6),
            // След в одну строку не влезает и переносить его нельзя — читать
            // становится нечего. Поэтому прокрутка вбок.
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(entry.stack,
                  style: TextStyle(
                      fontSize: 11,
                      height: 1.35,
                      fontFamily: 'monospace',
                      color: context.mutedColor)),
            ),
          ],
        ],
      ),
    );
  }
}
