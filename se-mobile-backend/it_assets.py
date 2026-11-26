"""Техника за сотрудником: какой ПК, принтер и телефон числятся за кем.

Сейчас это таблица на компьютере ОИТиС. Человек не знает инвентарный
номер своего ноутбука, когда пишет заявку, а при увольнении или переводе
технику ищут по кабинетам. Здесь ОИТиС ведёт учёт: что выдано, кому и где
стоит; сотрудник видит своё, и при выдаче ему приходит оповещение.

Ведут: ОИТиС, системный администратор и IT_ASSET_STAFF.
"""

import os
from datetime import datetime

from flask import g, jsonify, request

import demo
from it_requests import _norm, _utc, is_it_staff
from models import db

KINDS = ('pc', 'laptop', 'monitor', 'printer', 'phone', 'ups', 'other')
KIND_NAMES = {'pc': 'компьютер', 'laptop': 'ноутбук', 'monitor': 'монитор',
              'printer': 'принтер', 'phone': 'телефон', 'ups': 'ИБП',
              'other': 'техника'}

_MAX_FOUND = 100


class ItAsset(db.Model):
    __tablename__ = 'it_assets'
    id = db.Column(db.Integer, primary_key=True)
    kind = db.Column(db.String(10), nullable=False)
    model = db.Column(db.String(200), nullable=False)
    inventory_no = db.Column(db.String(50), unique=True)
    serial = db.Column(db.String(100))
    employee_id = db.Column(db.String(10), db.ForeignKey('employees.employee_id'),
                            index=True)
    room = db.Column(db.String(50))
    note = db.Column(db.String(300))
    written_off = db.Column(db.Boolean, nullable=False, default=False)
    updated_at = db.Column(db.DateTime, nullable=False, default=datetime.utcnow)


def _env_ids(name):
    return {p.strip() for p in os.environ.get(name, '').split(',') if p.strip()}


def is_asset_staff(employee, core):
    if employee is None:
        return False
    return (is_it_staff(employee) or core._is_system_admin(employee.job_title)
            or employee.employee_id in _env_ids('IT_ASSET_STAFF'))


def register(app, core):
    from models import Employee

    def _viewer():
        return getattr(g, 'employee', None)

    def _fail(error, status):
        return jsonify({'message': 'Failure', 'error': error}), status

    def _staff():
        viewer = _viewer()
        if viewer is None:
            return None, _fail('unauthorized', 401)
        if not is_asset_staff(viewer, core):
            return None, core._deny()
        return viewer, None

    def _json(asset, people=None):
        data = {
            'id': asset.id,
            'kind': asset.kind,
            'model': asset.model,
            'inventory_no': asset.inventory_no or '',
            'serial': asset.serial or '',
            'room': asset.room or '',
            'note': asset.note or '',
            'written_off': asset.written_off,
            'updated_at': _utc(asset.updated_at),
        }
        if people is not None:
            holder = people.get(asset.employee_id)
            data['holder'] = ({'id': holder.employee_id, 'name': holder.full_name,
                               'job_title': holder.job_title or '',
                               'department': holder.department or ''}
                              if holder else None)
        return data

    def _people(assets):
        ids = {a.employee_id for a in assets if a.employee_id}
        if not ids:
            return {}
        return {e.employee_id: e for e in
                Employee.query.filter(Employee.employee_id.in_(ids))}

    def _notify_holder(asset):
        if asset.employee_id:
            number = f', инв. № {asset.inventory_no}' if asset.inventory_no else ''
            core._record_notice(
                'itasset', f'За вами записан {KIND_NAMES[asset.kind]}',
                f'{asset.model}{number}'[:500], employee_ids=[asset.employee_id])

    def _ordered(query):
        return query.order_by(ItAsset.kind, ItAsset.model, ItAsset.id)

    @app.route('/api/it-assets/mine', methods=['GET'])
    @core.require_auth
    def it_assets_mine():
        viewer = _viewer()
        if viewer is None:
            return _fail('unauthorized', 401)
        items = _ordered(ItAsset.query.filter_by(employee_id=viewer.employee_id,
                                                 written_off=False)).all()
        return jsonify({'message': 'Success',
                        'staff': is_asset_staff(viewer, core),
                        'items': [_json(a) for a in items]})

    @app.route('/api/it-assets', methods=['GET'])
    @core.require_auth
    def it_assets_search():
        """`?q=` — модель, инвентарный, серийный номер, кабинет или ФИО."""
        viewer, denied = _staff()
        if denied:
            return denied
        query = ' '.join((request.args.get('q') or '').split())
        # Техника гостевого мира (demo.py) в учёт ОИТиС не входит.
        rows = _ordered(ItAsset.query.filter_by(written_off=False).filter(
            demo.world(ItAsset.employee_id, viewer))).all()
        if query:
            words = _norm(query).split()
            people = _people(rows)

            def text(asset):
                holder = people.get(asset.employee_id)
                return _norm(' '.join([
                    asset.model, asset.inventory_no or '', asset.serial or '',
                    asset.room or '', KIND_NAMES[asset.kind],
                    holder.full_name if holder else '']))
            rows = [a for a in rows if all(w in text(a) for w in words)]
        free = request.args.get('free') == '1'
        if free:
            rows = [a for a in rows if not a.employee_id]
        more = len(rows) > _MAX_FOUND
        rows = rows[:_MAX_FOUND]
        return jsonify({'message': 'Success', 'more': more,
                        'items': [_json(a, _people(rows)) for a in rows]})

    @app.route('/api/it-assets/people', methods=['GET'])
    @core.require_auth
    def it_assets_people():
        viewer, denied = _staff()
        if denied:
            return denied
        words = _norm(request.args.get('q') or '').split()
        found = [e for e in Employee.query.filter(
                     demo.world(Employee.employee_id, viewer))
                 .order_by(Employee.full_name).all()
                 if all(w in _norm(e.full_name) for w in words)][:30]
        return jsonify({'message': 'Success', 'people': [
            {'id': e.employee_id, 'name': e.full_name,
             'job_title': e.job_title or '', 'department': e.department or ''}
            for e in found]})

    @app.route('/api/it-assets/employees/<employee_id>', methods=['GET'])
    @core.require_auth
    def it_assets_of(employee_id):
        """Всё, что числится за человеком, — при увольнении и переводе."""
        viewer, denied = _staff()
        if denied:
            return denied
        employee = db.session.get(Employee, employee_id)
        if employee is None:
            return _fail('not_found', 404)
        items = _ordered(ItAsset.query.filter_by(employee_id=employee_id,
                                                 written_off=False)).all()
        return jsonify({'message': 'Success',
                        'items': [_json(a, _people(items)) for a in items]})

    def _fields(asset, data, creating):
        """Поля из запроса в [asset]; ошибка — строкой, иначе None."""
        if creating or 'kind' in data:
            if data.get('kind') not in KINDS:
                return 'bad_kind'
            asset.kind = data['kind']
        if creating or 'model' in data:
            model = ' '.join(core._text(data, 'model').split())[:200]
            if not model:
                return 'model_required'
            asset.model = model
        if creating or 'inventory_no' in data:
            number = core._text(data, 'inventory_no')[:50] or None
            if number:
                with db.session.no_autoflush:
                    taken = ItAsset.query.filter_by(inventory_no=number).first()
                if taken is not None and taken is not asset:
                    return 'inventory_taken'
            asset.inventory_no = number
        for name, size in (('serial', 100), ('room', 50), ('note', 300)):
            if creating or name in data:
                setattr(asset, name, core._text(data, name)[:size] or None)
        return None

    @app.route('/api/it-assets', methods=['POST'])
    @core.require_auth
    def it_assets_create():
        """{kind, model, inventory_no, serial, room, note, employee_id?}."""
        viewer, denied = _staff()
        if denied:
            return denied
        data = core._json_body()
        asset = ItAsset()
        error = _fields(asset, data, creating=True)
        if error:
            return _fail(error, 400)
        holder = core._text(data, 'employee_id')
        if holder and db.session.get(Employee, holder) is None:
            return _fail('no_employee', 400)
        asset.employee_id = holder or None
        db.session.add(asset)
        db.session.commit()
        _notify_holder(asset)
        return jsonify({'message': 'Success',
                        'item': _json(asset, _people([asset]))}), 201

    @app.route('/api/it-assets/<int:asset_id>', methods=['POST'])
    @core.require_auth
    def it_assets_action(asset_id):
        """{action: update | assign {employee_id} | release | writeoff}."""
        viewer, denied = _staff()
        if denied:
            return denied
        asset = db.session.get(ItAsset, asset_id)
        if asset is None or asset.written_off:
            return _fail('not_found', 404)
        data = core._json_body()
        action = data.get('action')
        if action == 'update':
            error = _fields(asset, data, creating=False)
            if error:
                db.session.rollback()
                return _fail(error, 400)
        elif action == 'assign':
            holder = core._text(data, 'employee_id')
            if db.session.get(Employee, holder) is None:
                return _fail('no_employee', 400)
            if holder == asset.employee_id:
                return _fail('same_holder', 409)
            asset.employee_id = holder
            if 'room' in data:
                asset.room = core._text(data, 'room')[:50] or None
        elif action == 'release':
            asset.employee_id = None
        elif action == 'writeoff':
            asset.employee_id = None
            asset.written_off = True
        else:
            return _fail('bad_action', 400)
        asset.updated_at = datetime.utcnow()
        db.session.commit()
        if action == 'assign':
            _notify_holder(asset)
        return jsonify({'message': 'Success',
                        'item': _json(asset, _people([asset]))})
