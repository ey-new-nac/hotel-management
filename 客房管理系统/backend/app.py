# ============================================================
# 客房管理系统 - Flask 后端
# 说明：业务逻辑已迁移至 MySQL 触发器（sql/triggers.sql），
#       Flask 仅负责请求校验 + 简单 INSERT/UPDATE，
#       触发器自动完成房费/积分/押金/房间状态等所有业务处理。
# ============================================================
import os
import csv
import io
import hashlib
from datetime import datetime, date
from functools import wraps
from flask import Flask, request, jsonify, session, send_from_directory, send_file
from flask_cors import CORS
import pymysql
from openpyxl import Workbook

app = Flask(__name__, static_folder='../frontend', static_url_path='')
app.secret_key = 'hotel-management-secret-key-2026'
CORS(app, supports_credentials=True)

# ---- 数据库配置 ----
DB_CONFIG = {
    'host': 'localhost',
    'port': 3306,
    'user': 'root',
    'password': '@615820817Ml',
    'database': 'hotel_management',
    'charset': 'utf8mb4',
    'cursorclass': pymysql.cursors.DictCursor
}


def get_db():
    return pymysql.connect(**DB_CONFIG)


# ============================================================
# 工具函数
# ============================================================
def hash_password(pwd):
    return hashlib.sha256(pwd.encode()).hexdigest()


def login_required(f):
    """要求登录的装饰器"""
    @wraps(f)
    def decorated(*args, **kwargs):
        if 'user_id' not in session:
            return jsonify({'code': 401, 'msg': '请先登录'}), 401
        return f(*args, **kwargs)
    return decorated


def role_required(*roles):
    """要求特定角色的装饰器"""
    def decorator(f):
        @wraps(f)
        def decorated(*args, **kwargs):
            if 'user_id' not in session:
                return jsonify({'code': 401, 'msg': '请先登录'}), 401
            if session.get('role') not in roles:
                return jsonify({'code': 403, 'msg': '权限不足'}), 403
            return f(*args, **kwargs)
        return decorated
    return decorator


# ============================================================
# 前端页面路由
# ============================================================

@app.route('/')
def index():
    return send_from_directory('../frontend', 'index.html')


# ============================================================
# 认证相关 API
# ============================================================

@app.route('/api/login', methods=['POST'])
def api_login():
    """系统用户登录"""
    data = request.json
    username = data.get('username', '').strip()
    password = data.get('password', '')

    if not username or not password:
        return jsonify({'code': 400, 'msg': '用户名和密码不能为空'})

    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute(
                'SELECT user_id, username, role, status FROM sys_user '
                'WHERE username=%s AND password=SHA2(%s, 256)',
                (username, password))
            user = cur.fetchone()
        if not user:
            return jsonify({'code': 401, 'msg': '用户名或密码错误'})
        if user['status'] == 0:
            return jsonify({'code': 403, 'msg': '账号已被禁用'})

        session['user_id'] = user['user_id']
        session['username'] = user['username']
        session['role'] = user['role']
        session['user_type'] = 'staff'

        return jsonify({
            'code': 200,
            'msg': '登录成功',
            'data': {
                'user_id': user['user_id'],
                'username': user['username'],
                'role': user['role']
            }
        })
    finally:
        db.close()


@app.route('/api/customer/login', methods=['POST'])
def api_customer_login():
    """客户登录"""
    data = request.json
    phone = data.get('phone', '').strip()
    password = data.get('password', '')

    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute(
                'SELECT customer_id, name, phone FROM customer '
                'WHERE phone=%s AND password=SHA2(%s, 256)',
                (phone, password))
            customer = cur.fetchone()
        if not customer:
            return jsonify({'code': 401, 'msg': '手机号或密码错误'})

        session['user_id'] = customer['customer_id']
        session['username'] = customer['name']
        session['role'] = 'customer'
        session['user_type'] = 'customer'

        return jsonify({
            'code': 200,
            'msg': '登录成功',
            'data': {
                'user_id': customer['customer_id'],
                'name': customer['name'],
                'role': 'customer'
            }
        })
    finally:
        db.close()


@app.route('/api/customer/register', methods=['POST'])
def api_customer_register():
    """客户注册"""
    data = request.json
    name = data.get('name', '').strip()
    phone = data.get('phone', '').strip()
    password = data.get('password', '')
    gender = data.get('gender', '其他')
    id_card = data.get('id_card', '').strip()

    if not name or not phone or not password:
        return jsonify({'code': 400, 'msg': '姓名、手机号和密码不能为空'})

    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute('SELECT customer_id FROM customer WHERE phone=%s', (phone,))
            if cur.fetchone():
                return jsonify({'code': 409, 'msg': '该手机号已注册'})

            cur.execute(
                'INSERT INTO customer (name, gender, phone, id_card, password) '
                'VALUES (%s, %s, %s, %s, SHA2(%s, 256))',
                (name, gender, phone, id_card, password))
            db.commit()
        return jsonify({'code': 200, 'msg': '注册成功'})
    finally:
        db.close()


@app.route('/api/logout', methods=['POST'])
def api_logout():
    session.clear()
    return jsonify({'code': 200, 'msg': '已退出登录'})


@app.route('/api/session', methods=['GET'])
def api_session():
    """获取当前登录用户信息"""
    if 'user_id' in session:
        return jsonify({
            'code': 200,
            'data': {
                'user_id': session['user_id'],
                'username': session['username'],
                'role': session['role'],
                'user_type': session.get('user_type', 'staff')
            }
        })
    return jsonify({'code': 401, 'msg': '未登录'})


# ============================================================
# 客户管理 API
# ============================================================

@app.route('/api/customers', methods=['GET'])
@login_required
@role_required('admin', 'manager', 'front')
def api_get_customers():
    keyword = request.args.get('keyword', '')
    db = get_db()
    try:
        with db.cursor() as cur:
            if keyword:
                cur.execute(
                    'SELECT * FROM customer '
                    'WHERE name LIKE %s OR phone LIKE %s OR id_card LIKE %s '
                    'ORDER BY create_time DESC LIMIT 100',
                    (f'%{keyword}%', f'%{keyword}%', f'%{keyword}%'))
            else:
                cur.execute('SELECT * FROM customer ORDER BY create_time DESC LIMIT 100')
            customers = cur.fetchall()
        return jsonify({'code': 200, 'data': customers})
    finally:
        db.close()


@app.route('/api/customers/<int:cid>', methods=['GET'])
@login_required
@role_required('admin', 'manager', 'front')
def api_get_customer(cid):
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute('SELECT * FROM customer WHERE customer_id=%s', (cid,))
            customer = cur.fetchone()
        if not customer:
            return jsonify({'code': 404, 'msg': '客户不存在'})
        return jsonify({'code': 200, 'data': customer})
    finally:
        db.close()


# ============================================================
# 客房管理 API
# ============================================================

@app.route('/api/customers/<int:cid>', methods=['PUT'])
@login_required
@role_required('admin', 'manager')
def api_update_customer(cid):
    data = request.get_json()
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute('SELECT * FROM customer WHERE customer_id=%s', (cid,))
            customer = cur.fetchone()
            if not customer:
                return jsonify({'code': 404, 'msg': '客户不存在'})

        allowed = ['name', 'gender', 'phone', 'id_card', 'member_level', 'points']
        updates, values = [], []
        for f in allowed:
            if f in data and data[f] is not None:
                updates.append(f'{f}=%s')
                values.append(data[f])

        if not updates:
            return jsonify({'code': 400, 'msg': '没有需要更新的字段'})

        old_level = customer['member_level']
        values.append(cid)

        with db.cursor() as cur:
            cur.execute(f"UPDATE customer SET {', '.join(updates)} WHERE customer_id=%s", values)
            db.commit()
            cur.execute('SELECT member_level, points FROM customer WHERE customer_id=%s', (cid,))
            updated = cur.fetchone()

        msg = '更新成功'
        if old_level == '普通' and updated['member_level'] == '会员':
            msg = f'更新成功！客户已自动升级为 <b>会员</b> 🎉'

        return jsonify({'code': 200, 'msg': msg, 'data': {
            'customer_id': cid,
            'member_level': updated['member_level'],
            'points': updated['points']
        }})
    finally:
        db.close()


@app.route('/api/rooms', methods=['GET'])
@login_required
@role_required('admin', 'manager', 'front', 'customer')
def api_get_rooms():
    type_id = request.args.get('type_id', '')
    status = request.args.get('status', '')
    db = get_db()
    try:
        with db.cursor() as cur:
            sql = 'SELECT r.*, rt.type_name, rt.default_price FROM room r JOIN room_type rt ON r.type_id = rt.type_id WHERE 1=1'
            params = []
            if type_id:
                sql += ' AND r.type_id=%s'; params.append(type_id)
            if status:
                sql += ' AND r.status=%s'; params.append(status)
            sql += ' ORDER BY r.room_id'
            cur.execute(sql, params)
            rooms = cur.fetchall()
        return jsonify({'code': 200, 'data': rooms})
    finally:
        db.close()


@app.route('/api/rooms/<room_id>', methods=['PUT'])
@login_required
@role_required('admin', 'manager')
def api_update_room(room_id):
    """经理修改房间价格/状态"""
    data = request.json
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute('SELECT * FROM room WHERE room_id=%s', (room_id,))
            if not cur.fetchone():
                return jsonify({'code': 404, 'msg': '房间不存在'})

            updates = []
            params = []
            for field in ['price', 'status', 'remark', 'area']:
                if field in data:
                    updates.append(f'{field}=%s')
                    params.append(data[field])
            if not updates:
                return jsonify({'code': 400, 'msg': '没有要更新的字段'})

            params.append(room_id)
            cur.execute(f'UPDATE room SET {", ".join(updates)} WHERE room_id=%s', params)
            db.commit()
        return jsonify({'code': 200, 'msg': '更新成功'})
    finally:
        db.close()


@app.route('/api/rooms/batch-update', methods=['POST'])
@login_required
@role_required('admin', 'manager')
def api_batch_update_rooms():
    """批量修改客房信息"""
    data = request.json
    room_ids = data.get('room_ids', [])
    if not room_ids or not isinstance(room_ids, list):
        return jsonify({'code': 400, 'msg': '请选择要修改的房间'})

    allowed = ['price', 'status', 'area', 'remark']
    updates = {}
    for f in allowed:
        if f in data and data[f] is not None and data[f] != '':
            updates[f] = data[f]
    if not updates:
        return jsonify({'code': 400, 'msg': '没有需要更新的字段'})

    db = get_db()
    try:
        with db.cursor() as cur:
            placeholders = ','.join(['%s'] * len(room_ids))
            cur.execute(f'SELECT room_id FROM room WHERE room_id IN ({placeholders})', room_ids)
            exist = [r['room_id'] for r in cur.fetchall()]
            if not exist:
                return jsonify({'code': 404, 'msg': '未找到匹配的房间'})

            set_clause = ', '.join(f'{k}=%s' for k in updates)
            values = list(updates.values()) + exist
            cur.execute(f'UPDATE room SET {set_clause} WHERE room_id IN ({','.join(['%s']*len(exist))})', values)
            db.commit()
            cnt = cur.rowcount

        return jsonify({'code': 200, 'msg': f'成功更新 {cnt} 个房间'})
    finally:
        db.close()


# ============================================================
# 房型管理 API
# ============================================================

@app.route('/api/room-types', methods=['GET'])
@login_required
@role_required('admin', 'manager', 'front', 'customer')
def api_get_room_types():
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute('SELECT * FROM room_type ORDER BY type_id')
            types = cur.fetchall()
        return jsonify({'code': 200, 'data': types})
    finally:
        db.close()


# ============================================================
# 预订管理 API
# ============================================================

@app.route('/api/bookings', methods=['GET'])
@login_required
@role_required('admin', 'manager', 'front', 'customer')
def api_get_bookings():
    status = request.args.get('status', '')
    db = get_db()
    try:
        with db.cursor() as cur:
            sql = '''
                SELECT b.*, cu.name AS customer_name, cu.phone,
                       rt.type_name, su.username AS operator_name
                FROM booking b
                JOIN customer cu ON b.customer_id = cu.customer_id
                JOIN room_type rt ON b.type_id = rt.type_id
                LEFT JOIN sys_user su ON b.operator_id = su.user_id
            '''
            if status:
                sql += ' WHERE b.status=%s'
                cur.execute(sql + ' ORDER BY b.booking_time DESC', (status,))
            else:
                cur.execute(sql + ' ORDER BY b.booking_time DESC')
            bookings = cur.fetchall()
        return jsonify({'code': 200, 'data': bookings})
    finally:
        db.close()


@app.route('/api/bookings', methods=['POST'])
@login_required
@role_required('admin', 'front', 'customer')
def api_create_booking():
    """创建预订（前台/管理员/客户）"""
    data = request.json
    customer_id = data.get('customer_id')
    type_id = data.get('type_id')
    expected_checkin = data.get('expected_checkin')
    expected_checkout = data.get('expected_checkout')
    room_count = data.get('room_count', 1)
    # 客户自助预订时使用 admin(1) 作为默认经办人
    operator_id = session['user_id'] if session.get('user_type') == 'staff' else 1

    if not all([customer_id, type_id, expected_checkin, expected_checkout]):
        return jsonify({'code': 400, 'msg': '请填写完整的预订信息'})

    db = get_db()
    try:
        with db.cursor() as cur:
            # 检查剩余房间数
            cur.execute('SELECT surplus_room FROM room_type WHERE type_id=%s', (type_id,))
            rt = cur.fetchone()
            if not rt or rt['surplus_room'] < int(room_count):
                return jsonify({'code': 400, 'msg': '该房型剩余房间不足'})

            cur.execute(
                'INSERT INTO booking (customer_id, type_id, expected_checkin, '
                'expected_checkout, room_count, operator_id) '
                'VALUES (%s, %s, %s, %s, %s, %s)',
                (customer_id, type_id, expected_checkin, expected_checkout, room_count, operator_id))
            # 扣减剩余房间数
            cur.execute('UPDATE room_type SET surplus_room = surplus_room - %s WHERE type_id=%s',
                        (room_count, type_id))
            db.commit()
        return jsonify({'code': 200, 'msg': '预订成功'})
    finally:
        db.close()


@app.route('/api/bookings/<int:bid>/cancel', methods=['POST'])
@login_required
@role_required('admin', 'front', 'customer')
def api_cancel_booking(bid):
    """取消预订"""
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute('SELECT * FROM booking WHERE booking_id=%s', (bid,))
            booking = cur.fetchone()
            if not booking:
                return jsonify({'code': 404, 'msg': '预订不存在'})
            if booking['status'] != '已预订':
                return jsonify({'code': 400, 'msg': '只能取消"已预订"状态的订单'})

            # 客户只能取消自己的预订
            if session.get('role') == 'customer' and booking['customer_id'] != session.get('user_id'):
                return jsonify({'code': 403, 'msg': '只能取消自己的预订'})

            # UPDATE 触发 trg_booking_update 自动恢复剩余房间数
            cur.execute("UPDATE booking SET status='已取消' WHERE booking_id=%s", (bid,))
            db.commit()
        return jsonify({'code': 200, 'msg': '取消成功'})
    finally:
        db.close()


# ============================================================
# 入住管理 API
# ============================================================

@app.route('/api/checkins', methods=['GET'])
@login_required
@role_required('admin', 'manager', 'front', 'customer')
def api_get_checkins():
    status = request.args.get('status', '')
    db = get_db()
    try:
        with db.cursor() as cur:
            sql = '''
                SELECT ci.*, cu.name AS customer_name, cu.phone, cu.id_card,
                       cu.member_level, cu.points,
                       r.room_id, r.price, rt.type_name,
                       su.username AS operator_name
                FROM check_in ci
                JOIN customer cu ON ci.customer_id = cu.customer_id
                JOIN room r ON ci.room_id = r.room_id
                JOIN room_type rt ON r.type_id = rt.type_id
                LEFT JOIN sys_user su ON ci.operator_id = su.user_id
            '''
            if status:
                sql += ' WHERE ci.status=%s'
                cur.execute(sql + ' ORDER BY ci.checkin_time DESC', (status,))
            else:
                cur.execute(sql + ' ORDER BY ci.checkin_time DESC')
            checkins = cur.fetchall()
        return jsonify({'code': 200, 'data': checkins})
    finally:
        db.close()


@app.route('/api/checkins', methods=['POST'])
@login_required
@role_required('admin', 'front')
def api_checkin():
    """办理入住 — 触发器 trg_checkin_insert 自动处理房费/积分/押金/房间状态"""
    data = request.json
    customer_id = data.get('customer_id')
    room_id = data.get('room_id')
    booking_id = data.get('booking_id')
    expected_checkout = data.get('expected_checkout')
    operator_id = session['user_id']

    if not all([customer_id, room_id]):
        return jsonify({'code': 400, 'msg': '请填写完整的入住信息'})

    db = get_db()
    try:
        with db.cursor() as cur:
            # 检查房间状态
            cur.execute('SELECT status FROM room WHERE room_id=%s', (room_id,))
            room = cur.fetchone()
            if not room:
                return jsonify({'code': 404, 'msg': '房间不存在'})
            if room['status'] not in ('空闲', '已预订'):
                return jsonify({'code': 400, 'msg': '该房间当前不可入住'})

            # 有预订时用预订的离店日期作为默认值
            if not expected_checkout and booking_id:
                cur.execute('SELECT expected_checkout FROM booking WHERE booking_id=%s', (booking_id,))
                bk = cur.fetchone()
                if bk and bk['expected_checkout']:
                    dt = bk['expected_checkout']
                    expected_checkout = dt.isoformat() if hasattr(dt, 'isoformat') else str(dt)

            if not expected_checkout:
                return jsonify({'code': 400, 'msg': '请选择预计离店日期'})

            # 仅执行 INSERT，触发器 trg_checkin_insert 自动完成所有业务逻辑
            cur.execute(
                'INSERT INTO check_in (booking_id, customer_id, room_id, '
                'expected_checkout, operator_id) VALUES (%s, %s, %s, %s, %s)',
                (booking_id, customer_id, room_id, expected_checkout, operator_id))
            checkin_id = cur.lastrowid
            db.commit()

            # 查询触发器生成的结果返回给前端
            cur.execute(
                "SELECT COALESCE(SUM(amount),0) AS val FROM consumption "
                "WHERE checkin_id=%s AND item_name='房费'", (checkin_id,))
            room_fee = float(cur.fetchone()['val'])
            cur.execute(
                "SELECT COALESCE(SUM(amount),0) AS val FROM consumption "
                "WHERE checkin_id=%s AND item_name='积分抵扣'", (checkin_id,))
            points_deduct = float(cur.fetchone()['val'])
            cur.execute(
                "SELECT COALESCE(SUM(amount),0) AS val FROM consumption "
                "WHERE checkin_id=%s AND item_name='入住押金'", (checkin_id,))
            deposit = float(cur.fetchone()['val'])
            cur.execute(
                "SELECT COALESCE(SUM(ABS(points_change)),0) AS val FROM points_record "
                "WHERE source_type='入住结算' AND source_id=%s", (checkin_id,))
            points_earned = int(cur.fetchone()['val'])

        return jsonify({
            'code': 200, 'msg': '入住办理成功',
            'data': {
                'checkin_id': checkin_id,
                'room_fee': room_fee,
                'points_deduct': points_deduct,
                'points_earned': points_earned,
                'deposit': deposit
            }
        })
    finally:
        db.close()


# ============================================================
# 退房管理 API
# ============================================================

@app.route('/api/checkout', methods=['POST'])
@login_required
@role_required('admin', 'front')
def api_checkout():
    """办理退房 — 触发器 trg_checkout_insert 自动处理押金/赔偿/房间状态"""
    data = request.json
    checkin_id = data.get('checkin_id')
    damage_fee = float(data.get('damage_fee', 0))
    operator_id = session['user_id']

    if not checkin_id:
        return jsonify({'code': 400, 'msg': '请提供入住编号'})

    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute('SELECT * FROM check_in WHERE checkin_id=%s AND status="入住中"', (checkin_id,))
            checkin = cur.fetchone()
            if not checkin:
                return jsonify({'code': 404, 'msg': '未找到该入住记录或已退房'})

            # 仅执行 INSERT，触发器 trg_checkout_insert (BEFORE) 自动回填 deposit_deduct/extra_pay
            cur.execute(
                'INSERT INTO check_out (checkin_id, damage_fee, operator_id) '
                'VALUES (%s, %s, %s)',
                (checkin_id, damage_fee, operator_id))
            checkout_id = cur.lastrowid
            db.commit()

            # 查询触发器生成的结果
            cur.execute('SELECT * FROM check_out WHERE checkout_id=%s', (checkout_id,))
            co = cur.fetchone()
            deposit_deduct = float(co['deposit_deduct'] or 0)
            cur.execute(
                "SELECT COALESCE(SUM(amount),0) AS val FROM consumption "
                "WHERE checkin_id=%s AND item_name='入住押金'", (checkin_id,))
            deposit = float(cur.fetchone()['val'])
            refund = round(deposit - deposit_deduct, 2)

        return jsonify({
            'code': 200, 'msg': '退房办理成功',
            'data': {
                'checkin_id': checkin_id,
                'total_fee': damage_fee,
                'deposit_deduct': deposit_deduct,
                'refund_fee': refund
            }
        })
    finally:
        db.close()


# ============================================================
# 换房 API
# ============================================================

@app.route('/api/room-change', methods=['POST'])
@login_required
@role_required('admin', 'front')
def api_room_change():
    """换房 — 触发器 trg_checkin_update 自动处理房间状态/换房记录/升级费用"""
    data = request.json
    checkin_id = data.get('checkin_id')
    new_room_id = data.get('new_room_id')
    operator_id = session['user_id']

    if not checkin_id or not new_room_id:
        return jsonify({'code': 400, 'msg': '请提供入住编号和新房间编号'})

    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute('SELECT room_id FROM check_in WHERE checkin_id=%s AND status="入住中"', (checkin_id,))
            checkin = cur.fetchone()
            if not checkin:
                return jsonify({'code': 404, 'msg': '未找到有效的入住记录'})

            cur.execute('SELECT status FROM room WHERE room_id=%s', (new_room_id,))
            room = cur.fetchone()
            if not room:
                return jsonify({'code': 404, 'msg': '新房间不存在'})
            if room['status'] != '空闲':
                return jsonify({'code': 400, 'msg': '新房间不可用'})

            reason = data.get('reason', '').strip()
            if reason:
                cur.execute('SET @room_change_reason = %s', (reason,))
            else:
                cur.execute('SET @room_change_reason = NULL')

            # UPDATE 触发 trg_checkin_update 自动完成：
            #   换房记录（含原因）、房间状态更新、故障房自动报修
            cur.execute(
                'UPDATE check_in SET room_id=%s, operator_id=%s WHERE checkin_id=%s',
                (new_room_id, operator_id, checkin_id))
            db.commit()
        return jsonify({'code': 200, 'msg': '换房成功'})
    finally:
        db.close()


# ============================================================
# 房型升级 API
# ============================================================

@app.route('/api/room-upgrade', methods=['POST'])
@login_required
@role_required('admin', 'front')
def api_room_upgrade():
    """房型升级 — 触发器 trg_checkin_update 自动检测价格差异并处理升级费用"""
    data = request.json
    checkin_id = data.get('checkin_id')
    new_room_id = data.get('new_room_id')
    operator_id = session['user_id']

    if not checkin_id or not new_room_id:
        return jsonify({'code': 400, 'msg': '请提供入住编号和新房间编号'})

    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute(
                'SELECT ci.room_id, r.price AS old_price '
                'FROM check_in ci JOIN room r ON ci.room_id = r.room_id '
                'WHERE ci.checkin_id=%s AND ci.status="入住中"', (checkin_id,))
            checkin = cur.fetchone()
            if not checkin:
                return jsonify({'code': 404, 'msg': '未找到有效入住记录'})

            cur.execute('SELECT price, status FROM room WHERE room_id=%s', (new_room_id,))
            new_room = cur.fetchone()
            if not new_room:
                return jsonify({'code': 404, 'msg': '新房间不存在'})
            if new_room['status'] != '空闲':
                return jsonify({'code': 400, 'msg': '新房间不可用'})
            if float(new_room['price']) <= float(checkin['old_price']):
                return jsonify({'code': 400, 'msg': '升级房型只能选择价格更高的房间'})

            # UPDATE 触发 trg_checkin_update 自动完成升级业务
            cur.execute(
                'UPDATE check_in SET room_id=%s, operator_id=%s WHERE checkin_id=%s',
                (new_room_id, operator_id, checkin_id))
            db.commit()

            # 查询触发器生成的升级记录
            cur.execute(
                'SELECT * FROM room_upgrade WHERE checkin_id=%s ORDER BY upgrade_id DESC LIMIT 1',
                (checkin_id,))
            upg = cur.fetchone()
            if upg:
                daily_diff = round(float(upg['new_price']) - float(upg['old_price']), 2)
                remain_days = upg['remain_days']
                actual_pay = float(upg['paid_amount'])
                points_used = upg['points_used']
            else:
                daily_diff = remain_days = actual_pay = points_used = 0

            cur.execute(
                "SELECT COALESCE(SUM(ABS(points_change)),0) AS val FROM points_record "
                "WHERE source_type='房型升级' AND source_id=%s", (checkin_id,))
            points_earned = int(cur.fetchone()['val'])

        return jsonify({
            'code': 200, 'msg': '升级成功',
            'data': {
                'daily_diff': daily_diff,
                'remain_days': remain_days,
                'actual_pay': actual_pay,
                'points_used': points_used,
                'points_earned': points_earned
            }
        })
    finally:
        db.close()


# ============================================================
# 消费管理 API
# ============================================================

@app.route('/api/consumptions/<int:checkin_id>', methods=['GET'])
@login_required
@role_required('admin', 'manager', 'front')
def api_get_consumptions(checkin_id):
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute('SELECT * FROM consumption WHERE checkin_id=%s ORDER BY create_time', (checkin_id,))
            consumptions = cur.fetchall()
        return jsonify({'code': 200, 'data': consumptions})
    finally:
        db.close()


@app.route('/api/consumptions', methods=['POST'])
@login_required
@role_required('admin', 'front')
def api_add_consumption():
    """添加消费记录（杂费、续住房费等）"""
    data = request.json
    checkin_id = data.get('checkin_id')
    item_name = data.get('item_name')
    amount = data.get('amount')
    remark = data.get('remark', '')
    operator_id = session['user_id']

    if not checkin_id or not item_name or not amount:
        return jsonify({'code': 400, 'msg': '请填写完整的消费信息'})

    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute(
                'INSERT INTO consumption (checkin_id, item_name, amount, remark, operator_id) '
                'VALUES (%s, %s, %s, %s, %s)',
                (checkin_id, item_name, amount, remark, operator_id))
            db.commit()
        return jsonify({'code': 200, 'msg': '记录成功'})
    finally:
        db.close()


# ============================================================
# 续住 API
# ============================================================

@app.route('/api/extend-stay', methods=['POST'])
@login_required
@role_required('admin', 'front')
def api_extend_stay():
    """办理续住 — 触发器 trg_checkin_update 自动处理续住房费/积分"""
    data = request.json
    checkin_id = data.get('checkin_id')
    new_checkout = data.get('new_checkout')
    operator_id = session['user_id']

    if not checkin_id or not new_checkout:
        return jsonify({'code': 400, 'msg': '请提供入住编号和新的离店日期'})

    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute('SELECT * FROM check_in WHERE checkin_id=%s AND status="入住中"', (checkin_id,))
            if not cur.fetchone():
                return jsonify({'code': 404, 'msg': '未找到有效的入住记录'})

            # UPDATE 触发 trg_checkin_update 自动处理续住房费/积分
            cur.execute(
                'UPDATE check_in SET expected_checkout=%s, operator_id=%s WHERE checkin_id=%s',
                (new_checkout, operator_id, checkin_id))
            db.commit()

            # 查询触发器生成的续住费用
            cur.execute(
                "SELECT COALESCE(SUM(amount),0) AS val FROM consumption "
                "WHERE checkin_id=%s AND item_name='续住房费'", (checkin_id,))
            extra_fee = float(cur.fetchone()['val'])
            cur.execute(
                "SELECT COALESCE(SUM(amount),0) AS val FROM consumption "
                "WHERE checkin_id=%s AND item_name='积分抵扣'", (checkin_id,))
            points_deduct = float(cur.fetchone()['val'])
            cur.execute(
                "SELECT COALESCE(SUM(ABS(points_change)),0) AS val FROM points_record "
                "WHERE source_type='续住结算' AND source_id=%s", (checkin_id,))
            points_earned = int(cur.fetchone()['val'])

        return jsonify({
            'code': 200, 'msg': '续住成功',
            'data': {
                'checkin_id': checkin_id,
                'extra_fee': extra_fee,
                'points_deduct': points_deduct,
                'points_earned': points_earned
            }
        })
    finally:
        db.close()


# ============================================================
# 增值服务 API
# ============================================================

@app.route('/api/services/<svc_type>', methods=['POST'])
@login_required
@role_required('admin', 'front')
def api_add_service(svc_type):
    """增值服务 — 对应触发器自动写入消费记录并赠送积分"""
    data = request.json
    checkin_id = data.get('checkin_id')
    customer_id = data.get('customer_id')
    operator_id = session['user_id']

    if not checkin_id or not customer_id:
        return jsonify({'code': 400, 'msg': '请提供入住编号和客户编号'})

    db = get_db()
    try:
        with db.cursor() as cur:
            if svc_type == 'pool':
                cur.execute(
                    'INSERT INTO pool_service (checkin_id, customer_id, use_num, cost, operator_id) '
                    'VALUES (%s, %s, %s, %s, %s)',
                    (checkin_id, customer_id, data.get('use_num', 1),
                     float(data.get('cost', 0)), operator_id))
            elif svc_type == 'gym':
                cur.execute(
                    'INSERT INTO gym_service (checkin_id, customer_id, use_num, cost, operator_id) '
                    'VALUES (%s, %s, %s, %s, %s)',
                    (checkin_id, customer_id, data.get('use_num', 1),
                     float(data.get('cost', 0)), operator_id))
            elif svc_type == 'dining':
                cur.execute(
                    'INSERT INTO dining_service (checkin_id, customer_id, diner_num, total_cost, operator_id) '
                    'VALUES (%s, %s, %s, %s, %s)',
                    (checkin_id, customer_id, data.get('diner_num', 1),
                     float(data.get('total_cost', 0)), operator_id))
            else:
                return jsonify({'code': 400, 'msg': '不支持的服务类型'})

            db.commit()

            # 查询触发器赠送的积分
            source_types = {'pool': '泳池消费', 'gym': '健身房消费', 'dining': '餐厅消费'}
            cur.execute(
                "SELECT COALESCE(SUM(ABS(points_change)),0) AS val FROM points_record "
                "WHERE source_type=%s AND source_id=%s",
                (source_types[svc_type], cur.lastrowid))
            points_earned = int(cur.fetchone()['val'])

        return jsonify({
            'code': 200, 'msg': '服务记录成功',
            'data': {'points_earned': points_earned}
        })
    finally:
        db.close()


@app.route('/api/services/<svc_type>', methods=['GET'])
@login_required
@role_required('admin', 'manager', 'front')
def api_get_services(svc_type):
    """查询增值服务记录"""
    table_map = {
        'pool': 'pool_service', 'gym': 'gym_service', 'dining': 'dining_service'
    }
    if svc_type not in table_map:
        return jsonify({'code': 400, 'msg': '不支持的服务类型'})

    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute(
                f'SELECT s.*, cu.name AS customer_name FROM {table_map[svc_type]} s '
                f'JOIN customer cu ON s.customer_id = cu.customer_id ORDER BY s.register_time DESC LIMIT 100'
                if svc_type != 'dining' else
                f'SELECT s.*, cu.name AS customer_name FROM {table_map[svc_type]} s '
                f'JOIN customer cu ON s.customer_id = cu.customer_id ORDER BY s.consume_time DESC LIMIT 100'
            )
            records = cur.fetchall()
        return jsonify({'code': 200, 'data': records})
    finally:
        db.close()


# ============================================================
# 统计查询 API
# ============================================================

@app.route('/api/stats/room-summary', methods=['GET'])
@login_required
@role_required('admin', 'manager')
def api_room_summary():
    """房间状态汇总"""
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute('SELECT * FROM v_room_summary')
            data = cur.fetchall()
        return jsonify({'code': 200, 'data': data})
    finally:
        db.close()


@app.route('/api/stats/revenue', methods=['GET'])
@login_required
@role_required('admin', 'manager')
def api_revenue():
    """营收统计（基于已完成退房的消费明细）"""
    days = request.args.get('days', '30')
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute(
                'SELECT DATE(co.checkout_time) AS day, '
                'COUNT(DISTINCT co.checkin_id) AS orders, '
                'COALESCE(SUM(c.amount), 0) AS revenue '
                'FROM check_out co '
                'JOIN consumption c ON co.checkin_id = c.checkin_id '
                "WHERE c.item_name NOT IN ('入住押金', '积分抵扣') "
                'AND co.checkout_time >= DATE_SUB(CURDATE(), INTERVAL %s DAY) '
                'GROUP BY DATE(co.checkout_time) ORDER BY day DESC',
                (int(days),))
            data = cur.fetchall()
        return jsonify({'code': 200, 'data': data})
    finally:
        db.close()


@app.route('/api/stats/current-guests', methods=['GET'])
@login_required
@role_required('admin', 'manager', 'front')
def api_current_guests():
    """当前在住客人"""
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute('SELECT * FROM v_current_guests')
            data = cur.fetchall()
        return jsonify({'code': 200, 'data': data})
    finally:
        db.close()


@app.route('/api/stats/front-desk', methods=['GET'])
@login_required
@role_required('admin', 'manager', 'front')
def api_front_desk_stats():
    """前台概览统计：空闲/占用/今日将到/今日将退"""
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute('SELECT COUNT(*) AS cnt FROM room WHERE status=%s', ('空闲',))
            vacant = cur.fetchone()['cnt']
            cur.execute('SELECT COUNT(*) AS cnt FROM check_in WHERE status=%s', ('入住中',))
            occupied = cur.fetchone()['cnt']
            cur.execute('SELECT COUNT(*) AS cnt FROM v_today_arrivals')
            arrivals = cur.fetchone()['cnt']
            cur.execute('SELECT COUNT(*) AS cnt FROM v_today_departures')
            departures = cur.fetchone()['cnt']
        return jsonify({'code': 200, 'data': {
            'vacant': vacant, 'occupied': occupied,
            'arrivals': arrivals, 'departures': departures
        }})
    finally:
        db.close()


# ============================================================
# 积分查询 API
# ============================================================

@app.route('/api/customer/points', methods=['GET'])
@login_required
@role_required('customer')
def api_customer_points():
    """客户查看自己的积分和流水"""
    customer_id = session['user_id']
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute('SELECT member_level, points FROM customer WHERE customer_id=%s',
                        (customer_id,))
            customer = cur.fetchone()
            if not customer:
                return jsonify({'code': 404, 'msg': '客户不存在'})
            cur.execute(
                'SELECT * FROM points_record WHERE customer_id=%s '
                'ORDER BY create_time DESC LIMIT 50', (customer_id,))
            records = cur.fetchall()
        return jsonify({'code': 200, 'data': {
            'member_level': customer['member_level'],
            'points': customer['points'],
            'records': records
        }})
    finally:
        db.close()


@app.route('/api/customers/<int:cid>/points', methods=['GET'])
@login_required
@role_required('admin', 'manager', 'front')
def api_customer_points_detail(cid):
    """员工查看指定客户的积分和流水"""
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute('SELECT customer_id, name, member_level, points FROM customer WHERE customer_id=%s',
                        (cid,))
            customer = cur.fetchone()
            if not customer:
                return jsonify({'code': 404, 'msg': '客户不存在'})
            cur.execute(
                'SELECT * FROM points_record WHERE customer_id=%s '
                'ORDER BY create_time DESC LIMIT 50', (cid,))
            records = cur.fetchall()
        return jsonify({'code': 200, 'data': {
            'customer_id': customer['customer_id'],
            'name': customer['name'],
            'member_level': customer['member_level'],
            'points': customer['points'],
            'records': records
        }})
    finally:
        db.close()


@app.route('/api/customers/<int:cid>/history', methods=['GET'])
@login_required
@role_required('admin', 'manager', 'front')
def api_customer_history(cid):
    """客户综合历史：预订+入住+退房+消费+积分+服务"""
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute('SELECT * FROM customer WHERE customer_id=%s', (cid,))
            customer = cur.fetchone()
            if not customer:
                return jsonify({'code': 404, 'msg': '客户不存在'})

            cur.execute(
                'SELECT b.*, rt.type_name FROM booking b '
                'LEFT JOIN room_type rt ON b.type_id = rt.type_id '
                'WHERE b.customer_id=%s ORDER BY b.booking_time DESC LIMIT 50', (cid,))
            bookings = cur.fetchall()

            cur.execute(
                'SELECT ci.*, rt.type_name, r.price '
                'FROM check_in ci '
                'JOIN room r ON ci.room_id = r.room_id '
                'JOIN room_type rt ON r.type_id = rt.type_id '
                'WHERE ci.customer_id=%s ORDER BY ci.checkin_time DESC LIMIT 50', (cid,))
            checkins = cur.fetchall()

            cur.execute(
                'SELECT co.* FROM check_out co '
                'JOIN check_in ci ON co.checkin_id = ci.checkin_id '
                'WHERE ci.customer_id=%s ORDER BY co.checkout_time DESC LIMIT 50', (cid,))
            checkouts = cur.fetchall()

            cur.execute(
                'SELECT c.* FROM consumption c '
                'JOIN check_in ci ON c.checkin_id = ci.checkin_id '
                'WHERE ci.customer_id=%s ORDER BY c.create_time DESC LIMIT 100', (cid,))
            consumptions = cur.fetchall()

            cur.execute(
                'SELECT * FROM points_record WHERE customer_id=%s '
                'ORDER BY create_time DESC LIMIT 50', (cid,))
            points_records = cur.fetchall()

            cur.execute(
                "SELECT '泳池' AS svc, pool_id AS id, customer_id, checkin_id, "
                "use_num AS qty, cost AS amount, register_time AS create_time FROM pool_service "
                "WHERE customer_id=%s "
                "UNION ALL SELECT '健身房', gym_id, customer_id, checkin_id, "
                "use_num, cost, register_time FROM gym_service "
                "WHERE customer_id=%s "
                "UNION ALL SELECT '餐厅', dining_id, customer_id, checkin_id, "
                "diner_num, total_cost, consume_time FROM dining_service "
                "WHERE customer_id=%s "
                "ORDER BY create_time DESC LIMIT 50", (cid, cid, cid))
            services = cur.fetchall()

        return jsonify({'code': 200, 'data': {
            'customer': customer,
            'bookings': bookings,
            'checkins': checkins,
            'checkouts': checkouts,
            'consumptions': consumptions,
            'points_records': points_records,
            'services': services
        }})
    finally:
        db.close()


@app.route('/api/rooms/search', methods=['GET'])
@login_required
@role_required('admin', 'manager', 'front')
def api_rooms_search():
    """多条件房间搜索：房号/房型/状态/入住时间/客户姓名"""
    room_id = request.args.get('room_id', '')
    type_id = request.args.get('type_id', '')
    status = request.args.get('status', '')
    date_from = request.args.get('date_from', '')
    date_to = request.args.get('date_to', '')
    customer_name = request.args.get('customer_name', '')

    db = get_db()
    try:
        with db.cursor() as cur:
            sql = ('SELECT r.*, rt.type_name, rt.default_price '
                   'FROM room r JOIN room_type rt ON r.type_id = rt.type_id WHERE 1=1')
            params = []
            if room_id:
                sql += ' AND r.room_id LIKE %s'; params.append(f'%{room_id}%')
            if type_id:
                sql += ' AND r.type_id=%s'; params.append(type_id)
            if status:
                sql += ' AND r.status=%s'; params.append(status)
            sql += ' ORDER BY r.room_id LIMIT 200'
            cur.execute(sql, params)
            rooms = cur.fetchall()

            ci_sql = (
                'SELECT ci.checkin_id, ci.customer_id, cu.name AS customer_name, '
                'cu.phone, ci.room_id, rt.type_name, r.price, ci.checkin_time, '
                'ci.expected_checkout, ci.status, co.checkout_time '
                'FROM check_in ci '
                'JOIN customer cu ON ci.customer_id = cu.customer_id '
                'JOIN room r ON ci.room_id = r.room_id '
                'JOIN room_type rt ON r.type_id = rt.type_id '
                'LEFT JOIN check_out co ON ci.checkin_id = co.checkin_id '
                'WHERE 1=1')
            ci_params = []
            if room_id:
                ci_sql += ' AND ci.room_id LIKE %s'; ci_params.append(f'%{room_id}%')
            if type_id:
                ci_sql += ' AND r.type_id=%s'; ci_params.append(type_id)
            if status:
                ci_sql += ' AND ci.status=%s'; ci_params.append(status)
            if date_from:
                ci_sql += ' AND ci.checkin_time >= %s'; ci_params.append(date_from)
            if date_to:
                ci_sql += ' AND ci.checkin_time <= %s'; ci_params.append(date_to + ' 23:59:59')
            if customer_name:
                ci_sql += ' AND cu.name LIKE %s'; ci_params.append(f'%{customer_name}%')
            ci_sql += ' ORDER BY ci.checkin_time DESC LIMIT 200'
            cur.execute(ci_sql, ci_params)
            stay_records = cur.fetchall()

        return jsonify({'code': 200, 'data': {
            'rooms': rooms,
            'stay_records': stay_records
        }})
    finally:
        db.close()


# ============================================================
# 员工管理 API
# ============================================================

@app.route('/api/staff', methods=['GET'])
@login_required
@role_required('admin', 'manager')
def api_get_staff():
    """查询员工列表"""
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute(
                'SELECT s.*, su.username, su.role, su.status AS user_status '
                'FROM staff s LEFT JOIN sys_user su ON s.user_id = su.user_id '
                'ORDER BY s.staff_id')
            staff = cur.fetchall()
        return jsonify({'code': 200, 'data': staff})
    finally:
        db.close()


@app.route('/api/staff', methods=['POST'])
@login_required
@role_required('admin')
def api_create_staff():
    """管理员创建员工，同时可创建系统账号"""
    data = request.json
    name = data.get('name', '').strip()
    gender = data.get('gender', '其他')
    phone = data.get('phone', '').strip()
    post = data.get('post', '').strip()
    entry_time = data.get('entry_time', date.today().isoformat())
    username = data.get('username', '').strip()
    password = data.get('password', '')
    role = data.get('role', '')

    if not name or not post:
        return jsonify({'code': 400, 'msg': '姓名和岗位不能为空'})

    db = get_db()
    try:
        with db.cursor() as cur:
            user_id = None
            if username and password and role:
                cur.execute('SELECT user_id FROM sys_user WHERE username=%s', (username,))
                if cur.fetchone():
                    return jsonify({'code': 400, 'msg': '用户名已存在'})
                hashed = hashlib.sha256(password.encode()).hexdigest()
                cur.execute(
                    'INSERT INTO sys_user (username, password, role) VALUES (%s, %s, %s)',
                    (username, hashed, role))
                user_id = cur.lastrowid

            cur.execute(
                'INSERT INTO staff (name, gender, phone, post, entry_time, user_id) '
                'VALUES (%s, %s, %s, %s, %s, %s)',
                (name, gender, phone, post, entry_time, user_id))
            db.commit()
        return jsonify({'code': 200, 'msg': '创建成功'})
    finally:
        db.close()


@app.route('/api/staff/<int:sid>', methods=['PUT'])
@login_required
@role_required('admin')
def api_update_staff(sid):
    """管理员修改员工信息，离职时自动禁用关联账号"""
    data = request.json
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute('SELECT * FROM staff WHERE staff_id=%s', (sid,))
            staff = cur.fetchone()
            if not staff:
                return jsonify({'code': 404, 'msg': '员工不存在'})

            updates = []
            params = []
            for field in ['name', 'gender', 'phone', 'post', 'entry_time', 'user_id', 'status']:
                if field in data:
                    updates.append(f'{field}=%s')
                    params.append(data[field])
            if updates:
                params.append(sid)
                cur.execute(f'UPDATE staff SET {", ".join(updates)} WHERE staff_id=%s', params)

            # 员工离职时自动禁用其系统账号
            if data.get('status') == '离职' and staff['user_id']:
                cur.execute('UPDATE sys_user SET status=0 WHERE user_id=%s', (staff['user_id'],))

            db.commit()
        return jsonify({'code': 200, 'msg': '更新成功'})
    finally:
        db.close()


# ============================================================
# 系统用户管理 API（管理员）
# ============================================================

@app.route('/api/system-users', methods=['GET'])
@login_required
@role_required('admin')
def api_get_sys_users():
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute(
                'SELECT u.user_id, u.username, u.role, u.status, s.name AS staff_name '
                'FROM sys_user u LEFT JOIN staff s ON u.user_id = s.user_id ORDER BY u.user_id')
            users = cur.fetchall()
        return jsonify({'code': 200, 'data': users})
    finally:
        db.close()


@app.route('/api/system-users', methods=['POST'])
@login_required
@role_required('admin')
def api_create_sys_user():
    """管理员创建系统用户，可关联员工"""
    data = request.json
    username = data.get('username', '').strip()
    password = data.get('password', '')
    role = data.get('role', 'front')
    staff_id = data.get('staff_id')

    if not username or not password:
        return jsonify({'code': 400, 'msg': '用户名和密码不能为空'})
    if role not in ('admin', 'manager', 'front'):
        return jsonify({'code': 400, 'msg': '无效的角色'})

    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute('SELECT user_id FROM sys_user WHERE username=%s', (username,))
            if cur.fetchone():
                return jsonify({'code': 409, 'msg': '用户名已存在'})
            cur.execute(
                'INSERT INTO sys_user (username, password, role) VALUES (%s, SHA2(%s, 256), %s)',
                (username, password, role))
            user_id = cur.lastrowid

            # 如果指定了员工，自动关联
            if staff_id:
                cur.execute('UPDATE staff SET user_id=%s WHERE staff_id=%s', (user_id, staff_id))

            db.commit()
        return jsonify({'code': 200, 'msg': '创建成功'})
    finally:
        db.close()


@app.route('/api/system-users/<int:uid>', methods=['PUT'])
@login_required
@role_required('admin')
def api_update_sys_user(uid):
    """管理员修改用户状态/角色"""
    data = request.json
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute('SELECT * FROM sys_user WHERE user_id=%s', (uid,))
            user = cur.fetchone()
            if not user:
                return jsonify({'code': 404, 'msg': '用户不存在'})
            new_status = data.get('status', user['status'])
            new_role = data.get('role', user['role'])
            cur.execute('UPDATE sys_user SET status=%s, role=%s WHERE user_id=%s',
                        (new_status, new_role, uid))
            db.commit()
        return jsonify({'code': 200, 'msg': '更新成功'})
    finally:
        db.close()


# ============================================================
# 维修清洁 API
# ============================================================

@app.route('/api/room-services', methods=['GET'])
@login_required
@role_required('admin', 'manager', 'front')
def api_get_room_services():
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute(
                'SELECT rs.*, su.username AS operator_name FROM room_service rs '
                'LEFT JOIN sys_user su ON rs.operator_id = su.user_id '
                'ORDER BY rs.service_time DESC LIMIT 100')
            records = cur.fetchall()
        return jsonify({'code': 200, 'data': records})
    finally:
        db.close()


@app.route('/api/room-services', methods=['POST'])
@login_required
@role_required('admin', 'manager', 'front')
def api_add_room_service():
    """添加维修/清洁记录"""
    data = request.json
    room_id = data.get('room_id')
    service_type = data.get('service_type')
    description = data.get('description', '')
    operator_id = session['user_id']

    if not room_id or not service_type:
        return jsonify({'code': 400, 'msg': '请填写完整信息'})

    db = get_db()
    try:
        with db.cursor() as cur:
            # INSERT 触发 trg_room_service_insert 自动更新房间状态
            cur.execute(
                'INSERT INTO room_service (room_id, service_type, description, operator_id) '
                'VALUES (%s, %s, %s, %s)',
                (room_id, service_type, description, operator_id))
            db.commit()
        return jsonify({'code': 200, 'msg': '记录成功'})
    finally:
        db.close()


# ============================================================
# 客房导入 / 删除 API
# ============================================================

@app.route('/api/rooms', methods=['POST'])
@login_required
@role_required('admin', 'manager')
def api_add_room():
    """新增客房（支持单个或批量）"""
    data = request.json
    room_ids = data.get('room_ids', [])  # 批量：数组
    room_id = data.get('room_id', '').strip()  # 单个：字符串
    type_id = data.get('type_id')
    price = data.get('price')
    area = data.get('area')
    remark = data.get('remark', '').strip()

    # 统一成列表
    if room_ids and isinstance(room_ids, list):
        ids = [r.strip() for r in room_ids if r and r.strip()]
    elif room_id:
        ids = [room_id]
    else:
        return jsonify({'code': 400, 'msg': '请输入房间号'})

    if not ids:
        return jsonify({'code': 400, 'msg': '请输入房间号'})
    if not type_id:
        return jsonify({'code': 400, 'msg': '请选择房型'})
    if not price:
        return jsonify({'code': 400, 'msg': '请输入价格'})

    try:
        price_val = float(price)
    except (TypeError, ValueError):
        return jsonify({'code': 400, 'msg': '价格格式错误'})

    area_val = float(area) if area else None

    db = get_db()
    success = []
    errors = []
    try:
        with db.cursor() as cur:
            cur.execute('SELECT type_id FROM room_type WHERE type_id=%s', (type_id,))
            if not cur.fetchone():
                return jsonify({'code': 400, 'msg': '所选房型不存在'})

            for rid in ids:
                cur.execute('SELECT room_id FROM room WHERE room_id=%s', (rid,))
                if cur.fetchone():
                    errors.append(f'{rid} 已存在')
                    continue
                cur.execute(
                    'INSERT INTO room (room_id, type_id, area, price, status, remark) VALUES (%s,%s,%s,%s,%s,%s)',
                    (rid, type_id, area_val, price_val, '空闲', remark or None))
                success.append(rid)
            db.commit()

        msg = f'成功新增 {len(success)} 间客房'
        if errors:
            msg += f'，{len(errors)} 间失败'
        return jsonify({'code': 200, 'msg': msg, 'data': {'success': success, 'errors': errors}})
    finally:
        db.close()


@app.route('/api/rooms/<room_id>', methods=['DELETE'])
@login_required
@role_required('admin', 'manager')
def api_delete_room(room_id):
    """删除客房（仅限无历史记录的空闲房间）"""
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute('SELECT * FROM room WHERE room_id=%s', (room_id,))
            room = cur.fetchone()
            if not room:
                return jsonify({'code': 404, 'msg': '房间不存在'})

            if room['status'] != '空闲':
                return jsonify({'code': 400, 'msg': '仅可删除空闲状态的房间'})

            # 检查 FK 约束
            cur.execute('SELECT COUNT(*) AS cnt FROM check_in WHERE room_id=%s', (room_id,))
            if cur.fetchone()['cnt'] > 0:
                return jsonify({'code': 400, 'msg': '该客房有入住记录，无法删除'})
            cur.execute('SELECT COUNT(*) AS cnt FROM room_change WHERE old_room_id=%s OR new_room_id=%s', (room_id, room_id))
            if cur.fetchone()['cnt'] > 0:
                return jsonify({'code': 400, 'msg': '该客房有换房记录，无法删除'})
            cur.execute('SELECT COUNT(*) AS cnt FROM room_service WHERE room_id=%s', (room_id,))
            if cur.fetchone()['cnt'] > 0:
                return jsonify({'code': 400, 'msg': '该客房有维修/清洁记录，无法删除'})
            cur.execute('SELECT COUNT(*) AS cnt FROM room_upgrade WHERE old_room_id=%s OR new_room_id=%s', (room_id, room_id))
            if cur.fetchone()['cnt'] > 0:
                return jsonify({'code': 400, 'msg': '该客房有升级记录，无法删除'})

            cur.execute('DELETE FROM room WHERE room_id=%s', (room_id,))
            db.commit()
        return jsonify({'code': 200, 'msg': '删除成功'})
    finally:
        db.close()


# ============================================================
# 退房记录查询 API
# ============================================================

@app.route('/api/checkouts', methods=['GET'])
@login_required
@role_required('admin', 'manager', 'front')
def api_get_checkouts():
    """查询退房记录列表"""
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute(
                'SELECT co.checkout_id, co.checkin_id, co.checkout_time, co.damage_fee, '
                'co.deposit_deduct, co.extra_pay, c.name AS customer_name, c.phone, '
                'r.room_id, rt.type_name, su.username AS operator_name '
                'FROM check_out co '
                'JOIN check_in ci ON co.checkin_id = ci.checkin_id '
                'JOIN customer c ON ci.customer_id = c.customer_id '
                'JOIN room r ON ci.room_id = r.room_id '
                'JOIN room_type rt ON r.type_id = rt.type_id '
                'LEFT JOIN sys_user su ON co.operator_id = su.user_id '
                'ORDER BY co.checkout_time DESC LIMIT 200')
            records = cur.fetchall()
        return jsonify({'code': 200, 'data': records})
    finally:
        db.close()


# ============================================================
# Excel 导出 API
# ============================================================

def _build_xlsx_response(wb, filename):
    """将 Workbook 写入内存并返回 Flask 下载响应"""
    output = io.BytesIO()
    wb.save(output)
    output.seek(0)
    return send_file(
        output,
        mimetype='application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        as_attachment=True,
        download_name=filename
    )


@app.route('/api/export/rooms', methods=['GET'])
@login_required
@role_required('admin', 'manager', 'front')
def api_export_rooms():
    """导出客房信息表"""
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute(
                'SELECT r.room_id, rt.type_name, r.area, r.price, r.status, r.remark '
                'FROM room r JOIN room_type rt ON r.type_id = rt.type_id ORDER BY r.room_id')
            rows = cur.fetchall()
    finally:
        db.close()

    wb = Workbook()
    ws = wb.active
    ws.title = '客房信息表'
    ws.append(['客房编号', '房型', '面积(㎡)', '价格(元)', '状态', '备注'])
    for r in rows:
        ws.append([r['room_id'], r['type_name'], r['area'], r['price'], r['status'], r['remark']])
    return _build_xlsx_response(wb, '客房信息表.xlsx')


@app.route('/api/export/bookings', methods=['GET'])
@login_required
@role_required('admin', 'manager', 'front')
def api_export_bookings():
    """导出订房记录"""
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute(
                'SELECT b.booking_id, c.customer_name, c.phone, rt.type_name, b.room_count, '
                'b.booking_time, b.expected_checkin, b.expected_checkout, b.status, su.username AS operator_name '
                'FROM booking b '
                'JOIN customer c ON b.customer_id = c.customer_id '
                'JOIN room_type rt ON b.type_id = rt.type_id '
                'LEFT JOIN sys_user su ON b.operator_id = su.user_id '
                'ORDER BY b.booking_id DESC')
            rows = cur.fetchall()
    finally:
        db.close()

    wb = Workbook()
    ws = wb.active
    ws.title = '订房记录'
    ws.append(['预订编号', '客户姓名', '手机号', '房型', '间数', '预订时间', '预计入住', '预计离店', '状态', '操作员'])
    for r in rows:
        ws.append([r['booking_id'], r['customer_name'], r['phone'], r['type_name'], r['room_count'],
                   str(r['booking_time']) if r['booking_time'] else '',
                   str(r['expected_checkin']) if r['expected_checkin'] else '',
                   str(r['expected_checkout']) if r['expected_checkout'] else '',
                   r['status'], r['operator_name']])
    return _build_xlsx_response(wb, '订房记录.xlsx')


@app.route('/api/export/checkins', methods=['GET'])
@login_required
@role_required('admin', 'manager', 'front')
def api_export_checkins():
    """导出入住登记表"""
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute(
                'SELECT ci.checkin_id, c.customer_name, c.phone, c.id_card, '
                'r.room_id, rt.type_name, ci.checkin_time, ci.expected_checkout, ci.status, '
                'su.username AS operator_name '
                'FROM check_in ci '
                'JOIN customer c ON ci.customer_id = c.customer_id '
                'JOIN room r ON ci.room_id = r.room_id '
                'JOIN room_type rt ON r.type_id = rt.type_id '
                'LEFT JOIN sys_user su ON ci.operator_id = su.user_id '
                'ORDER BY ci.checkin_id DESC')
            rows = cur.fetchall()
    finally:
        db.close()

    wb = Workbook()
    ws = wb.active
    ws.title = '入住登记表'
    ws.append(['入住编号', '客户姓名', '手机号', '身份证号', '客房编号', '房型', '入住时间', '预计离店', '状态', '操作员'])
    for r in rows:
        ws.append([r['checkin_id'], r['customer_name'], r['phone'], r.get('id_card', ''),
                   r['room_id'], r['type_name'],
                   str(r['checkin_time']) if r['checkin_time'] else '',
                   str(r['expected_checkout']) if r['expected_checkout'] else '',
                   r['status'], r['operator_name']])
    return _build_xlsx_response(wb, '入住登记表.xlsx')


@app.route('/api/export/checkouts', methods=['GET'])
@login_required
@role_required('admin', 'manager', 'front')
def api_export_checkouts():
    """导出退房信息表"""
    db = get_db()
    try:
        with db.cursor() as cur:
            cur.execute(
                'SELECT co.checkout_id, co.checkin_id, c.name AS customer_name, c.phone, '
                'r.room_id, rt.type_name, co.checkout_time, co.damage_fee, '
                'co.deposit_deduct, co.extra_pay, su.username AS operator_name '
                'FROM check_out co '
                'JOIN check_in ci ON co.checkin_id = ci.checkin_id '
                'JOIN customer c ON ci.customer_id = c.customer_id '
                'JOIN room r ON ci.room_id = r.room_id '
                'JOIN room_type rt ON r.type_id = rt.type_id '
                'LEFT JOIN sys_user su ON co.operator_id = su.user_id '
                'ORDER BY co.checkout_id DESC')
            rows = cur.fetchall()
    finally:
        db.close()

    wb = Workbook()
    ws = wb.active
    ws.title = '退房信息表'
    ws.append(['退房编号', '入住编号', '客户姓名', '手机号', '客房编号', '房型', '退房时间',
               '损坏赔偿', '押金抵扣', '补交金额', '操作员'])
    for r in rows:
        ws.append([r['checkout_id'], r['checkin_id'], r['customer_name'], r['phone'],
                   r['room_id'], r['type_name'],
                   str(r['checkout_time']) if r['checkout_time'] else '',
                   r['damage_fee'], r['deposit_deduct'], r['extra_pay'], r['operator_name']])
    return _build_xlsx_response(wb, '退房信息表.xlsx')


# ============================================================
# 启动
# ============================================================
if __name__ == '__main__':
    print('客房管理系统后端启动中...')
    print('访问地址: http://localhost:5000')
    print('测试账号: admin/admin123 | manager/manager123 | front/front123')
    app.run(host='0.0.0.0', port=5000, debug=True)
