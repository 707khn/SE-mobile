import os
import sys

# Ensure the backend package is importable when running pytest from any directory
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

os.environ['DATABASE_URL'] = 'sqlite:///:memory:'

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
