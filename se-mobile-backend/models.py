import os
from datetime import datetime
from flask_sqlalchemy import SQLAlchemy

db = SQLAlchemy()


class Employee(db.Model):
    __tablename__ = 'employees'
    employee_id = db.Column(db.String(10), primary_key=True)
    full_name = db.Column(db.String(255), nullable=False)
    job_title = db.Column(db.String(100), nullable=False)
    iin = db.Column(db.String(12), unique=True, nullable=False)

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

    accruals = db.relationship('PayslipAccrual', backref='payslip', lazy='select', cascade='all, delete-orphan')
    deductions = db.relationship('PayslipDeduction', backref='payslip', lazy='select', cascade='all, delete-orphan')

    __table_args__ = (db.UniqueConstraint('employee_id', 'period_year', 'period_month'),)


class PayslipAccrual(db.Model):
    __tablename__ = 'payslip_accruals'
    id = db.Column(db.Integer, primary_key=True)
    payslip_id = db.Column(db.Integer, db.ForeignKey('payslips.id', ondelete='CASCADE'), nullable=False)
    name = db.Column(db.String(100), nullable=False)
    amount = db.Column(db.Float, nullable=False)


class PayslipDeduction(db.Model):
    __tablename__ = 'payslip_deductions'
    id = db.Column(db.Integer, primary_key=True)
    payslip_id = db.Column(db.Integer, db.ForeignKey('payslips.id', ondelete='CASCADE'), nullable=False)
    name = db.Column(db.String(100), nullable=False)
    amount = db.Column(db.Float, nullable=False)


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
