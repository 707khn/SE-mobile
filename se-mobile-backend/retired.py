"""Таблицы снятых разделов: «Закупки» и «Первые дни».

Вкладки убраны из приложения давно, а сервер всё ещё отвечал на
/api/purchases и /api/onboarding — около 950 строк кода и 330 строк тестов
без единого пользователя. Код удалён; остались только описания таблиц.

Зачем они: на сотрудников из этих таблиц ссылаются внешние ключи, а склейка
и удаление сотрудника (_employee_referrers в app.py) находят ссылающиеся
таблицы по описаниям моделей. Без описаний PostgreSQL отказал бы в удалении
сотрудника, у которого когда-то была заявка. Когда таблицы будут не нужны
и данные из них не жалко, их можно удалить из базы (DROP TABLE
purchase_events, purchase_lines, purchases, onboarding_steps, onboardings) —
и этот файл вместе с ними.
"""

from datetime import datetime

from models import db

# Длины колонок — как были: таблица в базе уже такая.
_MAX_NAME = 200
_MAX_TEXT = 500
_MAX_NOTE = 500


class Purchase(db.Model):
    __tablename__ = 'purchases'
    __table_args__ = (
        db.Index('ix_purchases_author', 'employee_id', 'created_at'),
        db.Index('ix_purchases_status', 'status', 'updated_at'),
    )
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False)
    # Для чего: «ремонт пресса К-2130», «участок 3, заказ 112».
    purpose = db.Column(db.String(_MAX_TEXT), nullable=False)
    needed_by = db.Column(db.Date)
    urgent = db.Column(db.Boolean, nullable=False, default=False)
    status = db.Column(db.String(12), nullable=False, default='new')
    assignee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    supplier = db.Column(db.String(_MAX_NAME))
    # Когда обещают привезти — менеджер ставит на «в пути».
    eta = db.Column(db.Date)
    reason = db.Column(db.Text)
    stage_since = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    closed_at = db.Column(db.DateTime)


class PurchaseLine(db.Model):
    __tablename__ = 'purchase_lines'
    id = db.Column(db.Integer, primary_key=True)
    purchase_id = db.Column(db.Integer,
                            db.ForeignKey('purchases.id', ondelete='CASCADE'),
                            nullable=False, index=True)
    position = db.Column(db.Integer, nullable=False)
    name = db.Column(db.String(_MAX_NAME), nullable=False)
    quantity = db.Column(db.Float, nullable=False)
    unit = db.Column(db.String(10), nullable=False, default='шт')


class PurchaseEvent(db.Model):
    __tablename__ = 'purchase_events'
    id = db.Column(db.Integer, primary_key=True)
    purchase_id = db.Column(db.Integer,
                            db.ForeignKey('purchases.id', ondelete='CASCADE'),
                            nullable=False, index=True)
    actor_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    # created, take, assign, stage, reject, cancel, comment
    action = db.Column(db.String(10), nullable=False)
    # Для stage — на какой этап перешли.
    stage = db.Column(db.String(12))
    comment = db.Column(db.Text)
    at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class Onboarding(db.Model):
    __tablename__ = 'onboardings'
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False, index=True)
    start_date = db.Column(db.Date, nullable=False)
    mentor_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                          index=True)
    note = db.Column(db.String(_MAX_NOTE))
    # active, done, cancelled
    status = db.Column(db.String(10), nullable=False, default='active', index=True)
    created_by = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    completed_at = db.Column(db.DateTime)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class OnboardingStep(db.Model):
    __tablename__ = 'onboarding_steps'
    __table_args__ = (db.UniqueConstraint('onboarding_id', 'step',
                                          name='uq_onboarding_steps_step'),)
    id = db.Column(db.Integer, primary_key=True)
    onboarding_id = db.Column(db.Integer,
                              db.ForeignKey('onboardings.id', ondelete='CASCADE'),
                              nullable=False, index=True)
    step = db.Column(db.String(10), nullable=False)
    done_at = db.Column(db.DateTime)
    done_by = db.Column(db.String(10), db.ForeignKey('employees.employee_id'))
    note = db.Column(db.String(_MAX_NOTE))
