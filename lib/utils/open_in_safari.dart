import 'package:url_launcher/url_launcher.dart';

/// Открыть ссылку именно в Safari — из значка на экране «Домой».
///
/// Значок живёт отдельно от Safari, и обычная ссылка на свой же сайт
/// открылась бы в нём самом, а не там, где человек уже вошёл. Адрес вида
/// x-safari-https://… iPhone отдаёт Safari. Не вышло — открываем как есть:
/// хотя бы покажем страницу, а код можно набрать и руками.
Future<void> openInSafari(String httpsUrl) async {
  final forced =
      httpsUrl.replaceFirst(RegExp(r'^https://'), 'x-safari-https://');
  try {
    if (await launchUrl(Uri.parse(forced),
        mode: LaunchMode.externalApplication)) {
      return;
    }
  } catch (_) {}
  try {
    await launchUrl(Uri.parse(httpsUrl), mode: LaunchMode.externalApplication);
  } catch (_) {}
}
