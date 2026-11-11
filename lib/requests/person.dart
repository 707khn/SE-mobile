/// Человек в записи: автор, исполнитель или тот, кто оставил отметку.
class ItPerson {
  const ItPerson({required this.id, required this.name, this.department = ''});

  final String id;
  final String name;
  final String department;

  static ItPerson? fromJson(Object? raw) {
    if (raw is! Map) return null;
    return ItPerson(
      id: '${raw['id'] ?? ''}',
      name: '${raw['name'] ?? ''}',
      department: '${raw['department'] ?? ''}',
    );
  }

  /// «Николаев Даниил Олегович» → «Николаев Д. О.»: в строке статуса
  /// полное ФИО не помещается.
  String get short {
    final parts = name.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) return name;
    final initials =
        parts.skip(1).where((p) => p.isNotEmpty).map((p) => '${p[0]}.');
    return '${parts.first} ${initials.join(' ')}';
  }
}

/// Строка истории.
class ItEvent {
  const ItEvent(
      {required this.action, required this.at, this.actor, this.comment = ''});

  final String action;
  final DateTime? at;
  final ItPerson? actor;
  final String comment;

  factory ItEvent.fromJson(Map<String, dynamic> json) => ItEvent(
        action: '${json['action'] ?? ''}',
        at: _time(json['at']),
        actor: ItPerson.fromJson(json['actor']),
        comment: '${json['comment'] ?? ''}',
      );
}

DateTime? _time(Object? raw) =>
    raw is String ? DateTime.tryParse(raw)?.toLocal() : null;
