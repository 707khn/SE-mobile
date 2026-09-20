import os
from datetime import datetime
from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()


class Employee(db.Model):
    __tablename__ = 'employees'
    employee_id = db.Column(db.String(10), primary_key=True)
    full_name = db.Column(db.String(255), nullable=False)
    job_title = db.Column(db.String(100), nullable=False)
    iin = db.Column(db.String(12), unique=True, nullable=True)
    department = db.Column(db.String(200))

    access_records = db.relationship('AccessRecord', backref='employee', lazy='dynamic')
    payslips = db.relationship('Payslip', backref='employee', lazy='dynamic')
    leave_balances = db.relationship('LeaveBalance', backref='employee', lazy='dynamic')
    leave_history = db.relationship('LeaveHistory', backref='employee', lazy='dynamic')


class AccessRecord(db.Model):
    __tablename__ = 'access_records'
    # Самая большая таблица: примерно полмиллиона строк в год при 500
    # сотрудниках. Внешний ключ в PostgreSQL сам индекса не создаёт, а каждый
    # запрос «покажи мои проходы за период» фильтрует ровно по этой паре —
    # без индекса это полный перебор всей таблицы.
    __table_args__ = (
        db.Index('ix_access_records_emp_date', 'employee_id', 'access_date'),
    )
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'), nullable=False)
    access_date = db.Column(db.Date, nullable=False)
    access_time = db.Column(db.String(5), nullable=False)
    event_type = db.Column(db.String(50), nullable=False)
    door_location = db.Column(db.String(100), nullable=False)


class Payslip(db.Model):
    __tablename__ = 'payslips'
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'), nullable=False)
    period_month = db.Column(db.Integer, nullable=False)
    period_year = db.Column(db.Integer, nullable=False)
    period_display = db.Column(db.String(50), nullable=False)
    total_accruals = db.Column(db.Float, nullable=False)
    total_deductions = db.Column(db.Float, nullable=False)
    net_pay = db.Column(db.Float, nullable=False)
    # Extended fields from 1C ZUP
    position = db.Column(db.String(200))
    department = db.Column(db.String(200))
    salary_rate = db.Column(db.Float)
    debt_start = db.Column(db.Float, default=0.0)
    debt_end = db.Column(db.Float, default=0.0)
    total_paid = db.Column(db.Float, default=0.0)

    accruals = db.relationship('PayslipAccrual', backref='payslip', lazy='select', cascade='all, delete-orphan')
    deductions = db.relationship('PayslipDeduction', backref='payslip', lazy='select', cascade='all, delete-orphan')
    paid = db.relationship('PayslipPaid', backref='payslip', lazy='select', cascade='all, delete-orphan')
    benefits = db.relationship('PayslipBenefit', backref='payslip', lazy='select', cascade='all, delete-orphan')
    reference = db.relationship('PayslipReference', backref='payslip', lazy='select', cascade='all, delete-orphan')

    __table_args__ = (db.UniqueConstraint('employee_id', 'period_year', 'period_month'),)


class PayslipAccrual(db.Model):
    __tablename__ = 'payslip_accruals'
    id = db.Column(db.Integer, primary_key=True)
    payslip_id = db.Column(db.Integer, db.ForeignKey('payslips.id', ondelete='CASCADE'), nullable=False)
    name = db.Column(db.String(200), nullable=False)
    amount = db.Column(db.Float, nullable=False)
    period = db.Column(db.String(50))
    working_days = db.Column(db.Integer)
    working_hours = db.Column(db.Float)


class PayslipDeduction(db.Model):
    __tablename__ = 'payslip_deductions'
    id = db.Column(db.Integer, primary_key=True)
    payslip_id = db.Column(db.Integer, db.ForeignKey('payslips.id', ondelete='CASCADE'), nullable=False)
    name = db.Column(db.String(200), nullable=False)
    amount = db.Column(db.Float, nullable=False)
    period = db.Column(db.String(50))


class PayslipPaid(db.Model):
    __tablename__ = 'payslip_paid'
    id = db.Column(db.Integer, primary_key=True)
    payslip_id = db.Column(db.Integer, db.ForeignKey('payslips.id', ondelete='CASCADE'), nullable=False)
    payment_type = db.Column(db.String(200))
    period = db.Column(db.String(50))
    document = db.Column(db.String(200))
    date = db.Column(db.String(20))
    amount = db.Column(db.Float)


class PayslipBenefit(db.Model):
    __tablename__ = 'payslip_benefits'
    id = db.Column(db.Integer, primary_key=True)
    payslip_id = db.Column(db.Integer, db.ForeignKey('payslips.id', ondelete='CASCADE'), nullable=False)
    name = db.Column(db.String(200))
    amount = db.Column(db.Float)


class PayslipReference(db.Model):
    __tablename__ = 'payslip_reference'
    id = db.Column(db.Integer, primary_key=True)
    payslip_id = db.Column(db.Integer, db.ForeignKey('payslips.id', ondelete='CASCADE'), nullable=False)
    name = db.Column(db.String(200))
    amount = db.Column(db.Float)


class LeaveBalance(db.Model):
    __tablename__ = 'leave_balances'
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'), nullable=False)
    leave_type = db.Column(db.String(100), nullable=False)
    total_days = db.Column(db.Integer, nullable=False)
    used_days = db.Column(db.Integer, nullable=False, default=0)
    remaining_days = db.Column(db.Integer, nullable=False)

    __table_args__ = (db.UniqueConstraint('employee_id', 'leave_type'),)


class LeaveHistory(db.Model):
    __tablename__ = 'leave_history'
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'), nullable=False)
    leave_type = db.Column(db.String(100), nullable=False)
    start_date = db.Column(db.Date, nullable=False)
    end_date = db.Column(db.Date, nullable=False)
    days = db.Column(db.Integer, nullable=False)
    status = db.Column(db.String(50), nullable=False)


class FcmToken(db.Model):
    __tablename__ = 'fcm_tokens'
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'), nullable=False)
    token = db.Column(db.String(512), nullable=False, unique=True)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)


class TurnstileEvent(db.Model):
    __tablename__ = 'turnstile_events'
    # Табель выбирает события за сутки или за месяц — то есть диапазоном по
    # времени; проходы одного сотрудника ищутся по employee_id.
    __table_args__ = (
        db.Index('ix_turnstile_events_ts', 'timestamp'),
        db.Index('ix_turnstile_events_emp', 'employee_id'),
    )
    id = db.Column(db.Integer, primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'), nullable=False)
    direction = db.Column(db.String(10), nullable=False)  # 'in' | 'out'
    timestamp = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


class MenuDate(db.Model):
    __tablename__ = 'menu_dates'
    id = db.Column(db.Integer, primary_key=True)
    date = db.Column(db.Date, nullable=False, unique=True)
    items = db.relationship('MenuItem', backref='menu_date', lazy=True, cascade='all, delete-orphan')


class MenuItem(db.Model):
    __tablename__ = 'menu_items'
    id = db.Column(db.Integer, primary_key=True)
    menu_date_id = db.Column(db.Integer, db.ForeignKey('menu_dates.id'), nullable=False)
    category = db.Column(db.String(50), nullable=False)
    name = db.Column(db.String(255), nullable=False)
    price = db.Column(db.Numeric(10, 2))
    # Portion as printed in the 1C export ("100", "56.25"). Kept as text: the
    # unit is grams for food and millilitres for drinks, and the sheet does not
    # say which.
    portion = db.Column(db.String(50))


class DirectoryEntry(db.Model):
    """Строка телефонного справочника предприятия.

    Отдельно от employees намеренно: справочник — свой документ. В нём есть
    посты без человека («КПП», «Электроцех»), один человек может стоять
    дважды в разных ролях, а у половины предприятия внутреннего номера нет
    вовсе, и в справочник они не попадают.

    Загружается целиком: при импорте таблица заменяется, поэтому уволенные
    исчезают сами, а не остаются висеть.
    """
    __tablename__ = 'directory_entries'
    id = db.Column(db.Integer, primary_key=True)
    # Порядок из файла: справочник печатают по отделам, и алфавит внутри
    # отдела там не соблюдается — начальник стоит первым.
    sort_order = db.Column(db.Integer, nullable=False, default=0)
    department = db.Column(db.String(200))
    name = db.Column(db.String(255), nullable=False)
    position = db.Column(db.String(200))
    # С запасом: в столбце внутреннего номера у представительства стоят два
    # городских телефона, а мобильных у некоторых тоже два.
    extension = db.Column(db.String(100))
    email = db.Column(db.String(200))
    mobile = db.Column(db.String(100))
    updated_at = db.Column(db.DateTime, default=datetime.utcnow)


class NewsItem(db.Model):
    """Лента: новости с сайта и объявления по предприятию.

    Одна таблица на оба вида намеренно — в приложении это один список, и
    сортировка у них общая. Различает `source`.

    Новости с сайта публикуются сразу: их уже отредактировали на сайте.
    Объявления ждут одобрения — то, что рассылают по почте, писалось для
    сотрудников отдела, а не для пятисот экранов, и попадать в ленту без
    просмотра не должно.
    """
    __tablename__ = 'news_items'
    __table_args__ = (
        db.Index('ix_news_items_published', 'is_published', 'published_at'),
    )
    id = db.Column(db.Integer, primary_key=True)

    # 'site' — с сайта, 'announcement' — объявление.
    source = db.Column(db.String(20), nullable=False, default='announcement')

    # По чему узнаём уже загруженную новость: guid или ссылка из ленты.
    # У объявлений пусто — они приходят по одному.
    external_id = db.Column(db.String(500), unique=True)

    title = db.Column(db.String(500), nullable=False)
    summary = db.Column(db.Text)
    url = db.Column(db.String(500))
    image_url = db.Column(db.String(500))

    # Кто прислал объявление: отправитель письма или имя администратора.
    author = db.Column(db.String(255))

    published_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    is_published = db.Column(db.Boolean, nullable=False, default=False)
    created_at = db.Column(db.DateTime, default=datetime.utcnow)


class AppliedSeed(db.Model):
    """Журнал отработавших сидеров.

    Сидеры идемпотентны, но каждый из них — десятки запросов к базе, и они
    выполняются при каждом старте процесса. На бесплатном Render сервер
    засыпает и просыпается по нескольку раз в день, поэтому отработавший
    сидер отмечается здесь и больше не запускается. Чтобы прогнать сидер
    заново после изменения данных, у него повышается version.
    """
    __tablename__ = 'applied_seeds'
    name = db.Column(db.String(100), primary_key=True)
    version = db.Column(db.String(20), nullable=False, default='1')
    applied_at = db.Column(db.DateTime, default=datetime.utcnow)


class UserAccount(db.Model):
    """Учётная запись для входа в приложение.

    До этого логины и пароли лежали прямо в исходном коде: нового сотрудника
    нельзя было завести без правки кода и передеплоя, а пароль хранился
    открытым текстом. Здесь пароль лежит хешем (scrypt) — из хеша исходный
    пароль не восстанавливается, поэтому забытый пароль только сбрасывают.
    """
    __tablename__ = 'user_accounts'
    login = db.Column(db.String(50), primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False, index=True)
    password_hash = db.Column(db.String(255), nullable=False)

    # Просить сменить пароль при следующем входе. У перенесённых из кода
    # записей пока False: пароли им не меняли, экрана смены ещё нет.
    must_change_password = db.Column(db.Boolean, nullable=False, default=True)
    is_active = db.Column(db.Boolean, nullable=False, default=True)

    # Неудачные попытки подряд. Обнуляются удачным входом и сбросом пароля.
    failed_attempts = db.Column(db.Integer, nullable=False, default=0)

    # До какого времени вход закрыт после череды неудач. Замок временный и
    # отпирается сам: пароль забывают вечером, а администратор приходит утром,
    # и глухая блокировка означала бы ночь без расчётного листка. Перебору
    # хватает и этого — четырёхзначный номер так не подобрать.
    locked_until = db.Column(db.DateTime)

    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    last_login_at = db.Column(db.DateTime)

    # Какая сборка приложения стоит у человека и когда он последний раз
    # заходил. Нужно ровно для одного решения: можно ли уже включить
    # обязательную проверку пропуска, или кто-то ещё сидит на старой сборке
    # и назавтра останется без приложения.
    app_version = db.Column(db.String(20))
    last_seen_at = db.Column(db.DateTime)


class AuthToken(db.Model):
    """Пропуск, который приложение получает при входе и предъявляет дальше.

    Токен непрозрачный и лежит в базе, а не подписан ключом: так его можно
    отозвать — при выходе, при смене пароля, при отключении учётной записи.
    Одна строка на устройство, поэтому вход с телефона не выбрасывает
    человека с планшета.
    """
    __tablename__ = 'auth_tokens'
    token = db.Column(db.String(64), primary_key=True)
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            nullable=False, index=True)
    created_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    last_used_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)
    # Срок сдвигается при каждом обращении: пока человек пользуется
    # приложением, его не выбрасывает.
    expires_at = db.Column(db.DateTime, nullable=False, index=True)


class AuthMiss(db.Model):
    """Сколько за день пришло запросов без пропуска.

    Считаем по дням, а не по устройствам: устройство без пропуска ничем себя
    не называет, а вот скорость, с которой их число падает, показывает, как
    идёт раздача новой сборки. Ноль несколько дней подряд — можно включать
    REQUIRE_AUTH=1.
    """
    __tablename__ = 'auth_misses'
    day = db.Column(db.Date, primary_key=True)
    count = db.Column(db.Integer, nullable=False, default=0)
