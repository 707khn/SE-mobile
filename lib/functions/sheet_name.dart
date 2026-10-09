/// Имя листа в книге Excel.
///
/// У листа Excel имя не длиннее 31 знака, в нём нельзя `: \ / ? * [ ]`, оно не
/// может быть пустым, начинаться или кончаться апострофом и называться
/// «History» — это имя занято самим Excel.
///
/// Отчёт по проходам называет лист фамилией, именем и отчеством, и из 123
/// человек справочника **у двенадцати ФИО длиннее 31 знака**: фамилия, имя и
/// отчество в 36 знаков — обычное дело. Файл с таким листом Excel открывать
/// отказывается: человек нажимает «выгрузить в Excel», получает файл и не
/// может его открыть, а почему — не написано нигде.
///
/// Обрезка порождает вторую беду: две длинные фамилии могут совпасть первыми
/// 31 знаками, и тогда данные второго молча лягут в лист первого. Поэтому
/// [taken] — уже занятые имена; совпадение разводится номером.
String excelSheetName(String raw, Set<String> taken) {
  var name = raw.replaceAll(RegExp(r'[:\\/?*\[\]]'), ' ').trim();

  // Апостроф по краям Excel тоже не принимает.
  while (name.startsWith("'")) {
    name = name.substring(1);
  }
  while (name.endsWith("'")) {
    name = name.substring(0, name.length - 1);
  }
  name = name.trim();

  if (name.isEmpty) name = 'Лист';
  if (name.toLowerCase() == 'history') name = 'History_';

  if (name.length > 31) name = name.substring(0, 31).trim();

  if (!taken.contains(name)) {
    taken.add(name);
    return name;
  }

  // Совпало — разводим номером, не вылезая за 31 знак.
  for (var n = 2; n < 1000; n++) {
    final suffix = ' $n';
    final head = name.length + suffix.length > 31
        ? name.substring(0, 31 - suffix.length).trim()
        : name;
    final candidate = '$head$suffix';
    if (!taken.contains(candidate)) {
      taken.add(candidate);
      return candidate;
    }
  }
  taken.add(name);
  return name;
}
