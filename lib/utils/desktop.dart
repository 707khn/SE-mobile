import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

/// Приложение запущено на компьютере, а не на телефоне.
///
/// На компьютере нет того, на чём держится часть телефонного: камеры для
/// снимка к заявке, отпечатка пальца, уведомлений Firebase, «Поделиться» с
/// мессенджерами, установки apk. Каждое такое место спрашивает здесь и
/// делает по-компьютерному: файл ложится в «Загрузки», текст —
/// в буфер обмена.
///
/// Подменяется в тестах: сами тесты идут на Linux, то есть «на компьютере», а
/// проверять нужно и телефонное поведение.
bool get isDesktop =>
    debugDesktopOverride ??
    (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS));

/// Для тестов: `true` или `false` — притвориться, `null` — как на самом деле.
bool? debugDesktopOverride;

/// Ширина колонки с содержимым на большом мониторе.
///
/// Все экраны свёрстаны под телефон в руке. Растянутые на 1920 точек, строки
/// таблицы проходов и поля формы уезжают к краям, и глазу между ними далеко.
/// Поэтому на широком окне содержимое стоит колонкой посередине — чуть шире
/// телефона, чтобы помещались длинные ФИО и должности, и с местом слева
/// под вкладки (см. HomeShell).
const double kDesktopContentWidth = 800;

/// Ставит содержимое колонкой посередине, когда окно шире [kDesktopContentWidth].
///
/// MediaQuery внутри колонки — её собственного размера: экраны, которые
/// смотрят на ширину, верстаются под колонку, а не под всё окно.
class DesktopFrame extends StatelessWidget {
  const DesktopFrame({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    if (media.size.width <= kDesktopContentWidth) return child;
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: Color.alphaBlend(
          scheme.onSurface.withValues(alpha: 0.06), scheme.surface),
      child: Center(
        child: SizedBox(
          width: kDesktopContentWidth,
          child: MediaQuery(
            data: media.copyWith(
                size: Size(kDesktopContentWidth, media.size.height)),
            child: ClipRect(child: child),
          ),
        ),
      ),
    );
  }
}

/// Прокрутка перетаскиванием и мышью.
///
/// Колесо прокручивает и так, но листать вбок — вкладки, карточки, страницы
/// знакомства с приложением — Flutter на компьютере мышью не даёт: только
/// пальцем. Человек тянет страницу, а она стоит.
class DesktopScrollBehavior extends MaterialScrollBehavior {
  const DesktopScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        ...super.dragDevices,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
      };
}

/// Esc на компьютере — «назад», как кнопка «назад» на телефоне.
///
/// В поле ввода первый Esc только выводит из поля: иначе человек, набравший
/// половину заявки, одним нажатием терял бы весь текст. Открытое окно или
/// меню — тоже маршрут, и «назад» закрывает сначала его.
///
/// Своё намерение, а не DismissIntent: тот на обычной странице перехватывает
/// сам маршрут — и, раз «закрыть по фону» у страницы нет, ничего не делает.
class DesktopBackIntent extends Intent {
  const DesktopBackIntent();
}

class DesktopBackAction extends Action<DesktopBackIntent> {
  DesktopBackAction(this.navigator);

  final NavigatorState? Function() navigator;

  @override
  Object? invoke(DesktopBackIntent intent) {
    final focused = FocusManager.instance.primaryFocus;
    final editing = focused?.context
            ?.findAncestorWidgetOfExactType<EditableText>() !=
        null;
    if (editing) {
      focused!.unfocus();
      return null;
    }
    navigator()?.maybePop();
    return null;
  }
}

/// Клавиши приложения на компьютере: Esc — «назад».
///
/// Ставится над навигатором (в builder приложения), так что клавиша доходит
/// сюда с любой страницы и из любого окна.
class DesktopKeys extends StatelessWidget {
  const DesktopKeys({super.key, required this.navigator, required this.child});

  final NavigatorState? Function() navigator;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): DesktopBackIntent(),
      },
      child: Actions(
        actions: {DesktopBackIntent: DesktopBackAction(navigator)},
        child: child,
      ),
    );
  }
}
