"""Страница политики конфиденциальности (/privacy).

Ссылку на неё Google Play требует в карточке приложения и проверяет, что
она открывается: без входа, обычной страницей, а не файлом.
"""


def test_privacy_page_opens_without_a_pass(client):
    answer = client.get('/privacy')
    assert answer.status_code == 200
    assert answer.mimetype == 'text/html'
    text = answer.get_data(as_text=True)
    assert 'Политика конфиденциальности' in text
    assert 'Семей инжиниринг' in text
    # Контакт по умолчанию — отдел, а не пустое место.
    assert 'ОИТиС' in text


def test_contact_comes_from_the_server_settings(client, monkeypatch):
    monkeypatch.setenv('PRIVACY_CONTACT', 'privacy@se-btrz.com <b>')
    text = client.get('/privacy').get_data(as_text=True)
    assert 'privacy@se-btrz.com' in text
    # Что бы ни вписали в настройку — это текст, а не разметка.
    assert '<b>' not in text.split('Ваши права')[1]
