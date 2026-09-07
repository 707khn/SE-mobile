"""
Разбор страницы новостей — на случай, когда ленты нет.

Правильный источник — лента RSS или Atom, и берём мы её (parser_news_feed).
Но лента есть не у каждой системы управления сайтом, а новости в приложении
нужны сейчас. Поэтому здесь запасной путь: разбираем саму страницу списка.

Путь этот заведомо хрупкий — вёрстку меняют, и разбор ломается, — поэтому
он именно запасной: сначала ищется лента, и только если её нет, доходит
очередь сюда. Держимся не за вёрстку конкретного сайта, а за то общее, что
есть у любого списка новостей: ссылки вглубь того же раздела с заголовком
внутри.

Возвращает то же, что и разбор ленты:
[{'external_id', 'title', 'summary', 'url', 'image_url', 'published_at'}]
"""

import re
from datetime import datetime
from urllib.parse import urljoin, urlparse

_A = re.compile(r'<a\b([^>]*)>(.*?)</a>', re.I | re.S)
_HREF = re.compile(r'''href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''', re.I)
_IMG = re.compile(r'<img[^>]+src\s*=\s*["\']([^"\']+)["\']', re.I)
_SCRIPT = re.compile(r'<(script|style|noscript)\b.*?</\1>', re.I | re.S)
_TAG = re.compile(r'<[^>]+>')
_SPACES = re.compile(r'\s+')

# Заголовок новости — предложение, а не слово: «Главная», «Ещё», «Все новости»
# отсеиваем по длине и по этому списку.
_MIN_TITLE = 14
_MAX_TITLE = 300
_NOT_A_TITLE = {
    'новости', 'все новости', 'подробнее', 'читать далее', 'читать полностью',
    'далее', 'ещё', 'еще', 'главная', 'назад', 'вперёд', 'вперед', 'архив',
}

_MONTHS = {
    'янв': 1, 'фев': 2, 'мар': 3, 'апр': 4, 'ма': 5, 'июн': 6,
    'июл': 7, 'авг': 8, 'сен': 9, 'окт': 10, 'ноя': 11, 'дек': 12,
}

_DATE_DOTS = re.compile(r'\b(\d{1,2})[.\-/](\d{1,2})[.\-/](20\d{2})\b')
_DATE_ISO = re.compile(r'\b(20\d{2})-(\d{2})-(\d{2})\b')
_DATE_WORDS = re.compile(
    r'\b(\d{1,2})\s+([А-Яа-яЁё]{3,10})\s+(20\d{2})', re.U)

_ENTITIES = {
    '&nbsp;': ' ', '&amp;': '&', '&quot;': '"', '&#039;': "'", '&apos;': "'",
    '&laquo;': '«', '&raquo;': '»', '&mdash;': '—', '&ndash;': '–',
    '&hellip;': '…', '&lt;': '<', '&gt;': '>',
}


def _text(html: str, limit: int = 400) -> str:
    text = _SPACES.sub(' ', _TAG.sub(' ', html or '')).strip()
    for code, char in _ENTITIES.items():
        text = text.replace(code, char)
    text = _SPACES.sub(' ', text).strip()
    if len(text) <= limit:
        return text
    # limit - 1: многоточие тоже занимает место, а в базе поле не резиновое.
    return text[:limit - 1].rsplit(' ', 1)[0] + '…'


def _parse_date(match, kind):
    try:
        if kind == 'iso':
            year, month, day = (int(x) for x in match.groups())
        elif kind == 'dots':
            day, month, year = (int(x) for x in match.groups())
        else:
            day, year = int(match.group(1)), int(match.group(3))
            name = match.group(2).lower()
            month = next((number for prefix, number in _MONTHS.items()
                          if name.startswith(prefix)), 0)
        return datetime(year, month, day)
    except (ValueError, TypeError):
        return None


def _date_near(html: str, start: int, end: int):
    """Дата рядом со ссылкой — та, что ближе всех к ней.

    Ближе всех, а не первая попавшаяся: новости на странице идут вплотную, и
    первая найденная дата запросто окажется датой следующей новости.
    """
    left, right = max(0, start - 300), end + 300
    window = html[left:right]
    best, distance = None, None
    for pattern, kind in ((_DATE_ISO, 'iso'), (_DATE_DOTS, 'dots'),
                          (_DATE_WORDS, 'words')):
        for match in pattern.finditer(window):
            parsed = _parse_date(match, kind)
            if parsed is None:
                continue
            at = left + match.start()
            gap = 0 if start <= at <= end else min(abs(at - start), abs(at - end))
            if distance is None or gap < distance:
                best, distance = parsed, gap
    return best


def _href_of(attributes: str) -> str:
    match = _HREF.search(attributes or '')
    if not match:
        return ''
    return (match.group(1) or match.group(2) or match.group(3) or '').strip()


def parse_news_html(data: bytes, page_url: str, limit: int = 20):
    """Достаёт новости из страницы списка.

    Бросает ValueError, если ничего похожего на список новостей не нашлось —
    вызывающий тогда оставит в ленте то, что уже лежит в базе.
    """
    if isinstance(data, bytes):
        html = data.decode('utf-8', errors='replace')
    else:
        html = data or ''
    html = _SCRIPT.sub(' ', html)

    page = urlparse(page_url)
    # Раздел, вглубь которого должны вести ссылки: /news/ → /news/
    section = page.path if page.path.endswith('/') else page.path.rsplit('/', 1)[0] + '/'
    section = section or '/'

    found, images = {}, {}
    for match in _A.finditer(html):
        href = _href_of(match.group(1))
        if not href or href.startswith(('#', 'mailto:', 'tel:', 'javascript:')):
            continue
        url = urljoin(page_url, href)
        link = urlparse(url)
        if link.scheme not in ('http', 'https') or link.netloc != page.netloc:
            continue
        path = link.path
        # Вглубь раздела: сам раздел и страницы листания («/news/page/2/») — не новости.
        if not path.startswith(section) or len(path.rstrip('/')) <= len(section.rstrip('/')):
            continue
        tail = path[len(section):].strip('/')
        if not tail or tail.split('/')[0] in ('page', 'pages', 'tag', 'category'):
            continue

        inner = match.group(2)
        clean_url = url.split('#')[0]
        image = _IMG.search(inner)
        image_url = urljoin(page_url, image.group(1))[:500] if image else ''
        if image_url:
            images.setdefault(clean_url, image_url)

        title = _text(inner, _MAX_TITLE)
        # Ссылка-картинка без текста — не заголовок, но картинку из неё берём:
        # на странице списка снимок обычно вынесен в отдельную ссылку.
        if len(title) < _MIN_TITLE or title.lower() in _NOT_A_TITLE:
            continue

        # Одна новость — обычно две ссылки: картинка и заголовок. Оставляем ту,
        # где текста больше (у картинки его нет вовсе), но картинку забираем.
        previous = found.get(clean_url)
        if previous:
            if not previous['image_url'] and image_url:
                previous['image_url'] = image_url
            if len(previous['title']) >= len(title):
                continue
            image_url = image_url or previous['image_url']

        found[clean_url] = {
            'external_id': clean_url[:500],
            'title': title,
            'summary': '',
            'url': clean_url[:500],
            'image_url': image_url,
            'published_at': _date_near(html, match.start(), match.end()),
            '_at': previous['_at'] if previous else match.start(),
        }

    if not found:
        raise ValueError('На странице не нашлось ссылок на новости. Проверьте адрес.')

    ordered = sorted(found.items(), key=lambda pair: pair[1]['_at'])
    news = []
    for url, item in ordered:
        item.pop('_at', None)
        if not item['image_url']:
            # Ключ здесь полный, а item['url'] обрезан под поле базы.
            item['image_url'] = images.get(url, '')
        news.append(item)
    return news[:limit]
