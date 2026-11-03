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

/// Ширина колонки с содержимым на большом мониторе, пока человек не вошёл.
///
/// Экраны входа и кода свёрстаны под телефон в руке: растянутые на 1920
/// точек, поля формы уезжают к краям. Поэтому до входа содержимое стоит
/// колонкой посередине — чуть шире телефона.
const double kDesktopContentWidth = 800;

/// Наибольшая ширина содержимого справа от боковой панели.
///
/// Программа после входа занимает окно целиком: слева панель разделов, справа
/// — раздел. На 1920 точках раздел шириной во всё оставшееся место — это
/// строки таблицы проходов, у которых дата и время на разных концах экрана.
/// Поэтому шире этого раздел не растягивается, а по бокам от него зелёная
/// полоса шапки и фон страницы продолжаются до краёв окна.
const double kDesktopWideContentWidth = 1200;

/// С какой ширины окна разделы — постоянной панелью слева, а не выдвижным
/// меню. Уже — панель отнимала бы у раздела слишком много.
const double kDesktopSidebarBreakpoint = 1000;

/// Ширина постоянной боковой панели.
const double kDesktopSidebarWidth = 272;

/// Человек вошёл, и открыта оболочка с разделами (HomeShell).
///
/// Боковая панель стоит над навигатором и про экраны ничего не знает: о том,
/// что пора её показать, ей сообщает оболочка.
class DesktopSession {
  DesktopSession._();

  static final ValueNotifier<bool> active = ValueNotifier<bool>(false);
  static int _shells = 0;

  /// Оболочка открылась. Сообщаем после кадра: панель стоит выше по дереву,
  /// и перестраивать её посреди построения оболочки нельзя.
  static void enter() {
    _shells++;
    WidgetsBinding.instance
        .addPostFrameCallback((_) => active.value = _shells > 0);
  }

  /// Оболочка закрылась — человек вышел.
  static void leave() {
    _shells--;
    WidgetsBinding.instance
        .addPostFrameCallback((_) => active.value = _shells > 0);
  }
}

/// Сообщает экранам, что разделы уже на виду — постоянной панелью слева.
///
/// Тогда кнопка «≡» и выдвижное меню на экране лишние: они открывали бы то же
/// самое, что и так стоит рядом.
class DesktopSidebarScope extends InheritedWidget {
  const DesktopSidebarScope(
      {super.key, required this.shown, required super.child});

  final bool shown;

  @override
  bool updateShouldNotify(DesktopSidebarScope old) => old.shown != shown;
}

/// Слева стоит постоянная панель разделов: выдвижное меню не нужно.
bool sidebarShown(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<DesktopSidebarScope>()?.shown ??
    false;

/// Ставит содержимое колонкой посередине, когда места больше [maxWidth].
///
/// MediaQuery внутри колонки — её собственного размера: экраны, которые
/// смотрят на ширину, верстаются под колонку, а не под всё окно.
///
/// С [band] по бокам от колонки продолжаются шапка (зелёная полоса) и фон
/// страницы — колонка не выглядит телефоном посреди серого поля. Без него
/// поля по бокам — серые, как раньше на экранах входа.
///
/// Дерево одно и то же при любой ширине окна: если бы узкое окно отдавало
/// содержимое как есть, а широкое — обёрнутым, навигатор при переходе через
/// границу создавался бы заново, и открытые экраны пропадали.
class DesktopFrame extends StatelessWidget {
  const DesktopFrame({
    super.key,
    required this.child,
    this.maxWidth = kDesktopContentWidth,
    this.band = false,
  });

  final Widget child;
  final double maxWidth;
  final bool band;

  @override
  Widget build(BuildContext context) {
    // Размер — из MediaQuery, а не из LayoutBuilder: внутри навигатор,
    // и при переезде (см. DesktopLayout) он должен строиться вместе с
    // остальным деревом, а не во время раскладки.
    final media = MediaQuery.of(context);
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final width = media.size.width > maxWidth ? maxWidth : media.size.width;
    {
      final Widget background;
      if (band) {
        background = Column(children: [
          ColoredBox(
            color: theme.appBarTheme.backgroundColor ?? scheme.primary,
            child: SizedBox(
                height: theme.appBarTheme.toolbarHeight ?? kToolbarHeight,
                width: double.infinity),
          ),
          Expanded(
              child: ColoredBox(
                  color: theme.scaffoldBackgroundColor,
                  child: const SizedBox.expand())),
        ]);
      } else {
        background = ColoredBox(
          color: Color.alphaBlend(
              scheme.onSurface.withValues(alpha: 0.06), scheme.surface),
          child: const SizedBox.expand(),
        );
      }
      return Stack(children: [
        Positioned.fill(child: background),
        // Отступ — целым числом точек: на половине точки край колонки
        // размывается и проступает светлой чертой поперёк шапки.
        Positioned(
          left: ((media.size.width - width) / 2).floorToDouble(),
          top: 0,
          bottom: 0,
          width: width,
          child: MediaQuery(
            data: media.copyWith(size: Size(width, media.size.height)),
            child: ClipRect(child: child),
          ),
        ),
      ]);
    }
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
