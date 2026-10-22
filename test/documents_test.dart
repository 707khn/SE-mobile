import 'package:flutter_test/flutter_test.dart';
import 'package:se_mobile/requests/documents_request.dart';

Map<String, dynamic> _doc(int id, String category,
        {bool requiresAck = false, bool acked = false}) =>
    {
      'id': id,
      'category': category,
      'category_name': category,
      'title': 'Документ $id',
      'number': '',
      'date': '2026-10-20',
      'filename': 'Приказ $id.PDF',
      'size': 2048,
      'requires_ack': requiresAck,
      'acked': acked,
      'acked_at': acked ? '2026-10-21T05:00:00Z' : null,
      'created_at': '2026-10-20T05:00:00Z',
    };

const _categories = [
  {'key': 'order', 'name': 'Приказы'},
  {'key': 'regulation', 'name': 'Положения'},
  {'key': 'template', 'name': 'Образцы заявлений'},
];

void main() {
  test('документ разбирается, отметка — только у отмеченных', () {
    final waiting =
        CompanyDocument.fromJson(_doc(1, 'order', requiresAck: true));
    expect(waiting.awaitingAck, isTrue);
    expect(waiting.ackedAt, isNull);
    expect(waiting.date, DateTime(2026, 10, 20));
    expect(waiting.extension, 'pdf');

    final done = CompanyDocument.fromJson(
        _doc(2, 'order', requiresAck: true, acked: true));
    expect(done.awaitingAck, isFalse);
    expect(done.ackedAt, DateTime.utc(2026, 10, 21, 5));

    // Отметка не нужна — и ждать её нечего.
    expect(CompanyDocument.fromJson(_doc(3, 'template')).awaitingAck, isFalse);
  });

  test('кривые поля не роняют разбор', () {
    final doc = CompanyDocument.fromJson({'id': 5});
    expect(doc.title, '');
    expect(doc.date, isNull);
    expect(doc.extension, '');
    expect(doc.awaitingAck, isFalse);
  });

  test('разделы — в порядке сервера, пустых нет, незнакомый — в конце', () {
    final docs = [
      _doc(1, 'template'),
      _doc(2, 'order'),
      _doc(3, 'order'),
      _doc(4, 'новый_раздел'),
    ].map(CompanyDocument.fromJson).toList();
    final sections = groupDocuments(docs, _categories);
    expect(sections.map((s) => s.key), ['order', 'template', 'other']);
    expect(sections.first.documents.map((d) => d.id), [2, 3]);
    expect(sections.last.documents.single.id, 4);
  });

  test('размер файла', () {
    expect(documentSize(340 * 1024), '340 КБ');
    expect(documentSize(1), '1 КБ');
    expect(documentSize((1.3 * 1024 * 1024).round()), '1,3 МБ');
  });
}
