import 'package:flutter_test/flutter_test.dart';
import 'package:se_mobile/utils/shell_tab.dart';

/// Переход на вкладку из бокового меню — когда меню открыли не с вкладки, а с
/// «Справочника» или «Новостей», — создавал оболочку заново. Вместе с ней
/// заново создавались все пять вкладок, уходило пять запросов к серверу, а
/// открытый расчётный лист и выбранный период пропадали.
void main() {
  setUp(() => ShellTab.selected.value = 0);

  test('переход слышен снаружи', () {
    final seen = <int>[];
    void listener() => seen.add(ShellTab.selected.value);
    ShellTab.selected.addListener(listener);

    ShellTab.open(2);
    ShellTab.open(4);

    ShellTab.selected.removeListener(listener);
    expect(seen, <int>[2, 4]);
  });

  test('повторный переход на ту же вкладку никого не будит', () {
    var calls = 0;
    void listener() => calls++;
    ShellTab.selected.addListener(listener);

    ShellTab.open(3);
    ShellTab.open(3);
    ShellTab.open(3);

    ShellTab.selected.removeListener(listener);
    expect(calls, 1, reason: 'оболочка перестраивалась бы на каждое нажатие');
  });

  test('значение доступно и без слушателей', () {
    ShellTab.open(1);
    expect(ShellTab.selected.value, 1);
  });
}
