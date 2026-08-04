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
