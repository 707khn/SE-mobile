"""Откуда берутся новости: лента, а если её нет — страница раздела."""

import textwrap

import pytest

import app as app_module
from parser_news_feed import feed_links, looks_like_feed, parse_news_feed
from parser_news_html import parse_news_html

_FEED = textwrap.dedent("""\
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0"><channel>
      <title>Новости</title>
      <item>
        <title>Открытие нового цеха</title>
        <link>https://se-btrz.com/news/cex/</link>
        <guid>https://se-btrz.com/news/cex/</guid>
        <pubDate>Tue, 07 Jul 2026 10:00:00 +0600</pubDate>
        <description>&lt;p&gt;Цех запущен.&lt;/p&gt;</description>
      </item>
    </channel></rss>
""").encode('utf-8')

_PAGE = textwrap.dedent("""\
    <!DOCTYPE html><html><head>
      <link rel="alternate" type="application/rss+xml" href="/news/rss/">
    </head><body>
      <nav><a href="/news/">Новости</a><a href="/about/">О предприятии сегодня</a></nav>
      <div class="item">
        <a href="/news/otkrytie-cexa/"><img src="/img/1.jpg"></a>
        <a href="/news/otkrytie-cexa/">Открытие нового цеха металлоконструкций</a>
        <span>12.07.2026</span>
      </div>
      <div class="item">
        <a href="/news/subbotnik-2026">Субботник на территории предприятия</a>
        <time datetime="2026-06-30">30 июня 2026</time>
      </div>
      <a href="/news/page/2/">Ещё</a>
    </body></html>
""").encode('utf-8')

_PAGE_NO_FEED = _PAGE.replace(
    b'<link rel="alternate" type="application/rss+xml" href="/news/rss/">', b'')


def test_looks_like_feed():
    assert looks_like_feed(_FEED)
    assert not looks_like_feed(_PAGE)


def test_feed_links_found_in_page():
    assert feed_links(_PAGE, 'https://se-btrz.com/news/') == [
        'https://se-btrz.com/news/rss/']
    assert feed_links(_PAGE_NO_FEED, 'https://se-btrz.com/news/') == []


def test_page_gives_news_when_there_is_no_feed():
    items = parse_news_html(_PAGE_NO_FEED, 'https://se-btrz.com/news/')
    assert [i['title'] for i in items] == [
        'Открытие нового цеха металлоконструкций',
        'Субботник на территории предприятия',
    ]
    # Дата берётся ближайшая к ссылке, а не первая на странице.
    assert items[0]['published_at'].strftime('%d.%m.%Y') == '12.07.2026'
    assert items[1]['published_at'].strftime('%d.%m.%Y') == '30.06.2026'
    # Картинка вынесена в отдельную ссылку — забираем и её.
    assert items[0]['image_url'] == 'https://se-btrz.com/img/1.jpg'


def test_page_skips_navigation_and_paging():
    urls = [i['url'] for i in parse_news_html(_PAGE_NO_FEED,
                                              'https://se-btrz.com/news/')]
    assert 'https://se-btrz.com/news/page/2/' not in urls
    assert 'https://se-btrz.com/about/' not in urls


def test_page_without_news_is_an_error():
    with pytest.raises(ValueError, match='новост'):
        parse_news_html('<html><body><a href="/about/">Мы</a></body></html>'
                        .encode('utf-8'), 'https://se-btrz.com/news/')


@pytest.fixture(autouse=True)
def _forget_the_feed():
    """Найденный адрес ленты живёт в модуле — между проверками забываем."""
    app_module._news_feed_url = ''
    yield
    app_module._news_feed_url = ''


def _fetcher(pages):
    def fetch(url, timeout=8):
        if url not in pages:
            raise OSError(f'404 {url}')
        return pages[url], url
    return fetch


def test_feed_wins_when_the_page_announces_one(monkeypatch):
    monkeypatch.setattr(app_module, '_fetch', _fetcher({
        'https://se-btrz.com/news/': _PAGE,
        'https://se-btrz.com/news/rss/': _FEED,
    }))
    items, kind = app_module._load_site_news('https://se-btrz.com/news/')
    assert 'лента' in kind
    assert items[0]['title'] == 'Открытие нового цеха'


def test_guessed_feed_is_tried_when_the_page_is_silent(monkeypatch):
    monkeypatch.setattr(app_module, '_fetch', _fetcher({
        'https://se-btrz.com/news/': _PAGE_NO_FEED,
        'https://se-btrz.com/news/feed/': _FEED,
    }))
    items, kind = app_module._load_site_news('https://se-btrz.com/news/')
    assert kind == 'лента https://se-btrz.com/news/feed/'
    assert len(items) == 1


def test_page_is_the_fallback(monkeypatch):
    monkeypatch.setattr(app_module, '_fetch', _fetcher({
        'https://se-btrz.com/news/': _PAGE_NO_FEED,
    }))
    items, kind = app_module._load_site_news('https://se-btrz.com/news/')
    assert kind == 'страница'
    assert len(items) == 2


def test_feed_url_given_straight(monkeypatch):
    monkeypatch.setattr(app_module, '_fetch', _fetcher({
        'https://se-btrz.com/news/feed/': _FEED,
    }))
    items, kind = app_module._load_site_news('https://se-btrz.com/news/feed/')
    assert kind == 'лента'
    assert parse_news_feed(_FEED)[0]['url'] == items[0]['url']


def test_dead_feed_url_falls_back_to_the_news_page(monkeypatch):
    """В окружении может стоять адрес ленты, которой у сайта нет."""
    monkeypatch.setattr(app_module, '_fetch', _fetcher({
        'https://se-btrz.com/news/': _PAGE_NO_FEED,
    }))
    items, kind = app_module._load_site_news('https://se-btrz.com/news/feed/')
    assert kind == 'страница'
    assert len(items) == 2


def test_found_feed_is_remembered(monkeypatch):
    pages = {'https://se-btrz.com/news/': _PAGE,
             'https://se-btrz.com/news/rss/': _FEED}
    asked = []

    def fetch(url, timeout=8):
        asked.append(url)
        if url not in pages:
            raise OSError(f'404 {url}')
        return pages[url], url

    monkeypatch.setattr(app_module, '_fetch', fetch)
    app_module._load_site_news('https://se-btrz.com/news/')
    asked.clear()
    items, kind = app_module._load_site_news('https://se-btrz.com/news/')
    assert asked == ['https://se-btrz.com/news/rss/']
    assert len(items) == 1


def test_source_is_the_site_when_nothing_is_configured(monkeypatch):
    """Переменной в окружении может не быть — новости всё равно идут."""
    monkeypatch.delenv('NEWS_FEED_URL', raising=False)
    seen = {}

    def load(url):
        seen['url'] = url
        raise OSError('нет связи')

    monkeypatch.setattr(app_module, '_load_site_news', load)
    app_module._refresh_site_news(force=True)
    assert seen['url'] == 'https://se-btrz.com/news/'
    assert 'нет связи' in app_module._news_status['error']


def _wait_for_news_refresh(timeout=15):
    """Дождаться похода за новостями, который идёт отдельным потоком."""
    import threading
    for thread in threading.enumerate():
        if thread.name == 'news-refresh':
            thread.join(timeout=timeout)
            assert not thread.is_alive(), 'поход за новостями не завершился'


def test_news_endpoint_shows_what_came_from_the_site(client, monkeypatch):
    """Проверка целиком: страница сайта → лента в приложении.

    Ходит за новостями отдельный поток: срок на поход — двенадцать секунд, и
    ждать их должен не человек, открывший «Новости». Поэтому первый запрос
    отдаёт то, что уже в базе, а увиденное на сайте появляется следом.
    """
    monkeypatch.setattr(app_module, '_fetch', _fetcher({
        'https://se-btrz.com/news/': _PAGE_NO_FEED,
    }))
    # Уведомления в этой проверке ни к чему: почтальона подменяем.
    monkeypatch.setattr(app_module, '_push_to_everyone',
                        lambda *a, **k: None)
    app_module._news_checked_at = None

    first = client.get('/api/news')
    assert first.status_code == 200
    _wait_for_news_refresh()

    titles = [item['title'] for item in client.get('/api/news').get_json()['items']]
    assert 'Открытие нового цеха металлоконструкций' in titles
    assert 'Субботник на территории предприятия' in titles

    # Второй заход не задваивает: уже загруженное узнаём по адресу.
    app_module._news_checked_at = None
    client.get('/api/news')
    _wait_for_news_refresh()
    again = client.get('/api/news').get_json()['items']
    assert len(again) == len(titles)


def test_the_feed_does_not_make_anyone_wait(client, monkeypatch):
    """Медленный сайт не задерживает того, кто открыл ленту.

    Так и было: раз в четверть часа кому-то одному доставался вход в
    «Новости» длиной в двенадцать секунд — ровно столько отведено на поход к
    чужому сайту. Лента — едва ли не единственное, что в приложении
    обновляется само, и заставлять ждать как раз её хуже всего.
    """
    import time

    def _slow(url, timeout=None):
        time.sleep(3)
        raise OSError('сайт молчит')

    monkeypatch.setattr(app_module, '_fetch', _slow)
    app_module._news_checked_at = None

    started = time.monotonic()
    answer = client.get('/api/news')
    spent = time.monotonic() - started

    assert answer.status_code == 200
    assert spent < 1.5, f'человек ждал {spent:.1f} с чужого сайта'
    _wait_for_news_refresh()
