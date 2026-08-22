import os
import sys

# Ensure the backend package is importable when running pytest from any directory
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

os.environ['DATABASE_URL'] = 'sqlite:///:memory:'
# Выгрузка расчётных листков теперь отказывает при незаданном секрете, а не
# пропускает всех. На боевом сервере его ставит setup.sh; здесь — тоже, иначе
# тесты проверяли бы поведение, которого в работе не бывает.
os.environ.setdefault('ADMIN_TOKEN', 'test-admin-token')

import pytest
from app import create_app  # noqa: E402


@pytest.fixture(scope='session')
def app():
    application = create_app()
    application.config['TESTING'] = True
    return application


@pytest.fixture(scope='session')
def client(app):
    return app.test_client()
