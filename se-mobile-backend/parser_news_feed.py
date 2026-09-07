"""
Разбор ленты новостей сайта — RSS 2.0 или Atom.

Берём именно ленту, а не саму страницу: вёрстку страницы меняют при каждом
обновлении сайта, и разбор ломается молча — новости просто перестают
приходить, и никто этого не замечает. Лента же описана стандартом и живёт
годами.

Работает на стандартной библиотеке: xml.etree есть в Python, ставить ничего
не нужно, а на сервере с двумя гигабайтами это довод.

Возвращает: [{'external_id', 'title', 'summary', 'url', 'image_url', 'published_at'}]
"""

import re
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from xml.etree import ElementTree

_ATOM = '{http://www.w3.org/2005/Atom}'
_MEDIA = '{http://search.yahoo.com/mrss/}'
_CONTENT = '{http://purl.org/rss/1.0/modules/content/}'

_TAG = re.compile(r'<[^>]+>')
_SPACES = re.compile(r'\s+')
_IMG = re.compile(r'<img[^>]+src=["\']([^"\']+)["\']', re.I)


def _clean(html: str, limit: int = 400) -> str:
    """Текст без разметки: в ленте описание приходит куском HTML."""
    if not html:
        return ''
    text = _SPACES.sub(' ', _TAG.sub(' ', html)).strip()
    text = (text.replace('&nbsp;', ' ').replace('&amp;', '&')
                .replace('&quot;', '"').replace('&#039;', "'")
                .replace('&laquo;', '«').replace('&raquo;', '»')
                .replace('&mdash;', '—').replace('&ndash;', '–'))
    text = _SPACES.sub(' ', text).strip()
    if len(text) <= limit:
        return text
    # Обрезаем по границе слова, чтобы не оборвать на полуслове.
    # limit - 1: многоточие тоже занимает место, а в базе поле не резиновое.
    cut = text[:limit - 1].rsplit(' ', 1)[0]
    return cut + '…'


def _date(value: str):
    """Дата из ленты. RSS пишет по одному стандарту, Atom по другому."""
    if not value:
        return None
    value = value.strip()
    try:
        parsed = parsedate_to_datetime(value)          # RSS: Tue, 07 Jul 2026 10:00:00 +0600
    except (TypeError, ValueError):
        try:
            parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))  # Atom
        except ValueError:
            return None
    if parsed is None:
        return None
    # Храним в UTC без часового пояса — как всё остальное в базе.
    if parsed.tzinfo is not None:
        parsed = parsed.astimezone(timezone.utc).replace(tzinfo=None)
    return parsed


def _text_of(node, *names):
    for name in names:
        found = node.find(name)
        if found is not None and (found.text or '').strip():
            return found.text.strip()
    return ''


def _image_of(node, description: str) -> str:
    """Картинка: сначала явные поля ленты, потом первая из описания."""
    for name in (f'{_MEDIA}content', f'{_MEDIA}thumbnail'):
        found = node.find(name)
        if found is not None and found.get('url'):
            return found.get('url')
    enclosure = node.find('enclosure')
    if enclosure is not None and (enclosure.get('type') or '').startswith('image'):
        return enclosure.get('url') or ''
    match = _IMG.search(description or '')
    return match.group(1) if match else ''


def parse_news_feed(data: bytes):
    """Разбирает ленту в список новостей.

    Бросает ValueError, если это не лента.
    """
    try:
        root = ElementTree.fromstring(data)
    except ElementTree.ParseError as exc:
        raise ValueError(f'Лента не разобралась: {exc}') from exc

    items = root.findall('./channel/item') or root.findall(f'{_ATOM}entry')
    if not items:
        raise ValueError('В ленте нет ни одной новости. Проверьте адрес.')

    news = []
    for item in items:
        title = _text_of(item, 'title', f'{_ATOM}title')
        if not title:
            continue

        link = _text_of(item, 'link')
        if not link:                                   # Atom держит ссылку в атрибуте
            atom_link = item.find(f'{_ATOM}link')
            if atom_link is not None:
                link = atom_link.get('href') or ''

        raw = (_text_of(item, 'description', f'{_CONTENT}encoded',
                        f'{_ATOM}summary', f'{_ATOM}content'))
        published = _date(_text_of(item, 'pubDate', f'{_ATOM}published',
                                   f'{_ATOM}updated'))

        # По чему узнаём уже загруженную новость. guid надёжнее ссылки, но
        # есть не везде; в крайнем случае — заголовок.
        external = _text_of(item, 'guid', f'{_ATOM}id') or link or title

        news.append({
            'external_id': external[:500],
            'title': _clean(title, 500),
            'summary': _clean(raw),
            'url': link[:500],
            'image_url': _image_of(item, raw)[:500],
            'published_at': published,
        })
    if not news:
        raise ValueError('В ленте нет ни одной новости с заголовком.')
    return news


_LINK = re.compile(r'<link\b([^>]*)>', re.I)
_ATTR = re.compile(r'''(\w[\w-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))''')


def looks_like_feed(data: bytes) -> bool:
    """Лента это или страница. Смотрим на начало: у ленты там корневой тег."""
    head = (data or b'')[:400].lstrip()
    if head.startswith(b'<?xml'):
        head = head.split(b'?>', 1)[-1].lstrip()
    lowered = head.lower()
    return lowered.startswith((b'<rss', b'<feed', b'<rdf:rdf'))


def feed_links(data: bytes, base_url: str):
    """Адреса лент, объявленных самой страницей.

    Любая система управления сайтом ставит в <head> строку
    <link rel="alternate" type="application/rss+xml" href="...">. Спросить у
    страницы, где её лента, надёжнее, чем угадывать адрес.
    """
    from urllib.parse import urljoin

    try:
        html = (data or b'').decode('utf-8', errors='replace')
    except Exception:
        return []

    links = []
    for tag in _LINK.finditer(html[:200_000]):
        attrs = {}
        for attr in _ATTR.finditer(tag.group(1)):
            name = attr.group(1).lower()
            attrs[name] = (attr.group(2) or attr.group(3) or attr.group(4) or '')
        if 'alternate' not in attrs.get('rel', '').lower():
            continue
        kind = attrs.get('type', '').lower()
        if 'rss' not in kind and 'atom' not in kind:
            continue
        href = attrs.get('href', '').strip()
        if href:
            url = urljoin(base_url, href)
            if url not in links:
                links.append(url)
    return links
