"""B 正式交易服务。调用方使用公共 transaction(connection) 控制整笔提交和回滚。"""
from __future__ import annotations

from datetime import datetime, timedelta
from decimal import Decimal, InvalidOperation

from .charging_billing import ChargingError, _calculate
from .coupon_service import (
    lock_coupon_for_order, release_coupon_from_order, redeem_coupon_for_order,
)
from .reservation_service import consume_admission


def _one(cursor, statement, parameters=()):
    cursor.execute(statement, parameters)
    return cursor.fetchone()


def _number(raw, precision='0.01'):
    try:
        value = Decimal(str(raw))
        if not value.is_finite() or value < 0 or value != value.quantize(Decimal(precision)):
            raise ChargingError('数值必须非负且满足允许精度')
        return value
    except (InvalidOperation, TypeError, ValueError) as exc:
        raise ChargingError('数值无效或超出允许精度') from exc


def _at(cursor, supplied):
    if supplied is None:
        return _one(cursor, 'SELECT CURRENT_TIMESTAMP AS at_time')['at_time']
    if not isinstance(supplied, datetime) or supplied.tzinfo is not None or supplied.microsecond:
        raise ChargingError('业务时间采用北京时间，无时区 DATETIME，精确到秒')
    return supplied


def _order(cursor, order_id):
    order = _one(cursor, '''SELECT o.*,g.station_id FROM charging_order o
        JOIN charging_gun g ON g.gun_id=o.gun_id
        WHERE order_id=%s FOR UPDATE OF o''', (order_id,))
    if order is None:
        raise ChargingError('订单不存在')
    return order


def open_order(connection, *, user_id, vehicle_id, gun_id, channel,
               admission_id, at_time=None, start_soc=None, minimum_balance='5.00'):
    """到站后开单，并在同一事务中消费 A 的资格。余额门槛为 B 当前配置值。"""
    if channel not in ('RESERVATION', 'QUEUE') or not admission_id:
        raise ChargingError('先通过 A 预约或现场排队完成到站核验，再携资格开单')
    minimum = _number(minimum_balance)
    if start_soc is not None and (type(start_soc) is not int or not 0 <= start_soc <= 100):
        raise ChargingError('SOC 必须为 0 至 100 的整数')
    with connection.cursor() as cursor:
        at = _at(cursor, at_time)
        table, key = ('charging_reservation', 'reservation_id') if channel == 'RESERVATION' else ('queue_record', 'queue_id')
        qualification = _one(cursor, f'SELECT * FROM {table} WHERE {key}=%s FOR UPDATE', (admission_id,))
        if not qualification or (qualification['user_id'], qualification['vehicle_id'], qualification['gun_id']) != (user_id, vehicle_id, gun_id):
            raise ChargingError('到站资格与用户、车辆或枪不匹配')
        # 重试只能返回同一资格已生成的订单，避免产生第二笔。
        if qualification['status'] == 'CONSUMED':
            prior = _one(cursor, '''SELECT order_id FROM charging_order
                WHERE order_id=%s AND user_id=%s AND vehicle_id=%s AND gun_id=%s
                  AND channel=%s AND admission_id=%s FOR SHARE''',
                (qualification['consumed_order_id'], user_id, vehicle_id, gun_id, channel, admission_id))
            if not prior:
                raise ChargingError('资格消费记录与订单不一致')
            return prior['order_id']
        if qualification['status'] != 'CHECKED_IN':
            raise ChargingError('资格尚未核验或已经失效')
        if channel == 'RESERVATION':
            valid = qualification['starts_at'] <= at < qualification['ends_at'] + timedelta(minutes=qualification['late_grace_minutes'])
        else:
            valid = qualification['called_at'] <= at < qualification['call_expires_at']
        if not valid:
            raise ChargingError('开单时间不在资格有效区间')
        gun = _one(cursor, '''SELECT g.*,p.status AS pile_status,p.commissioned_on,
            s.status AS station_status,s.opens_minute,s.closes_minute
            FROM charging_gun g JOIN charging_pile p ON p.pile_id=g.pile_id
            JOIN station s ON s.station_id=g.station_id WHERE gun_id=%s FOR UPDATE''', (gun_id,))
        minute = at.hour * 60 + at.minute
        if (not gun or gun['status'] != 'READY' or gun['pile_status'] != 'READY'
                or gun['station_status'] != 'OPEN' or not gun['commissioned_on']
                or gun['commissioned_on'] > at.date()
                or not gun['opens_minute'] <= minute < gun['closes_minute']):
            raise ChargingError('场站、桩或枪不可用')
        outage = _one(cursor, '''SELECT outage_plan_id FROM equipment_outage_plan
            WHERE station_id=%s AND (gun_id IS NULL OR gun_id=%s) AND status='SCHEDULED'
              AND starts_at<=%s AND ends_at>%s LIMIT 1 FOR SHARE''', (gun['station_id'], gun_id, at, at))
        if outage:
            raise ChargingError('设备位于计划停运区间')
        user = _one(cursor, 'SELECT user_status,real_name_status,balance FROM `user` WHERE user_id=%s FOR UPDATE', (user_id,))
        vehicle = _one(cursor, 'SELECT user_id,vehicle_status FROM vehicle WHERE vehicle_id=%s FOR UPDATE', (vehicle_id,))
        if (not user or user['user_status'] != 'ACTIVE' or user['real_name_status'] != 'VERIFIED'
                or user['balance'] < minimum or not vehicle or vehicle['user_id'] != user_id
                or vehicle['vehicle_status'] != 'ACTIVE'):
            raise ChargingError('用户、实名、车辆归属或启动余额不满足条件')
        occupied = _one(cursor, '''SELECT * FROM parking_occupancy
            WHERE active_space_id=%s FOR UPDATE''', (gun['parking_space_id'],))
        if (not occupied or (occupied['user_id'], occupied['vehicle_id'], occupied['gun_id']) != (user_id, vehicle_id, gun_id)
                or occupied['occupied_at'] > at):
            raise ChargingError('A 尚未为本车核验占位或车位已释放')
        cursor.execute('''INSERT INTO charging_order(gun_id,user_id,vehicle_id,channel,admission_id,starts_at,start_soc)
            VALUES(%s,%s,%s,%s,%s,%s,%s)''',
            (gun_id, user_id, vehicle_id, channel, admission_id, at, start_soc))
        order_id = cursor.lastrowid
    consume_admission(connection, channel=channel, admission_id=admission_id,
                      order_id=order_id, at_time=at)
    return order_id


def add_readings(connection, *, order_id, readings):
    """批量写入累计读数；相同时间、相同读数的重试保持幂等。"""
    with connection.cursor() as cursor:
        order = _order(cursor, order_id)
        if order['state'] != 'ACTIVE':
            raise ChargingError('订单已经停止，补录请走人工复核')
        cleaned = []
        for at, value in readings:
            at = _at(cursor, at)
            if at < order['starts_at']:
                raise ChargingError('读数早于开单')
            number = _number(value, '0.001')
            existing = _one(cursor, 'SELECT cumulative_kwh FROM meter_reading WHERE order_id=%s AND read_at=%s FOR SHARE', (order_id, at))
            if existing and existing['cumulative_kwh'] != number:
                raise ChargingError('相同时点的读数不可覆盖')
            if not existing:
                cleaned.append((order_id, at, number))
        # 先检查合并后的时间序列，保证整批失败时由调用方回滚。
        cursor.execute('SELECT read_at,cumulative_kwh FROM meter_reading WHERE order_id=%s ORDER BY read_at FOR SHARE', (order_id,))
        series = {r['read_at']: r['cumulative_kwh'] for r in cursor.fetchall()}
        for _, at, number in cleaned:
            if at in series and series[at] != number:
                raise ChargingError('批次中存在矛盾读数')
            series[at] = number
        values = [series[at] for at in sorted(series)]
        if any(b < a for a, b in zip(values, values[1:])):
            raise ChargingError('累计读数不得倒退')
        cursor.executemany('INSERT INTO meter_reading(order_id,read_at,cumulative_kwh) VALUES(%s,%s,%s)',
                           list(dict.fromkeys(cleaned)))


def finish_order(connection, *, order_id, ends_at, end_soc=None,
                 disconnected=False, review_note=None, reviewed_readings=()):
    """结束并核价。缺边界或断连时保留 REVIEW，人工补录须附依据。"""
    if review_note is not None:
        if not isinstance(review_note,str) or not review_note.strip() or len(review_note)>255:
            raise ChargingError('复核依据必须为 1 至 255 字符的非空文本')
        review_note=review_note.strip()
    if end_soc is not None and (type(end_soc) is not int or not 0 <= end_soc <= 100):
        raise ChargingError('SOC 必须为 0 至 100 的整数')
    with connection.cursor() as cursor:
        order = _order(cursor, order_id)
        end = _at(cursor, ends_at)
        if order['state'] == 'BILLED':
            if order['ends_at'] != end:
                raise ChargingError('已出账订单的结束时间不允许改变')
            return {'state': 'BILLED', 'gross_amount': order['gross_amount']}
        if end <= order['starts_at']:
            raise ChargingError('结束时间必须晚于开始时间')
        if order['state'] == 'REVIEW' and (not review_note or end > order['ends_at']):
            raise ChargingError('复核需注明依据，结束时间不得晚于异常停止时点')
        if reviewed_readings and order['state'] != 'REVIEW':
            raise ChargingError('补录边界读数仅限人工复核')
        for at, value in reviewed_readings:
            at = _at(cursor, at)
            if not order['starts_at'] <= at <= end:
                raise ChargingError('复核读数超出订单时段')
            cursor.execute('INSERT INTO meter_reading VALUES(%s,%s,%s)', (order_id, at, _number(value, '0.001')))
        latest = _one(cursor, '''SELECT read_at FROM meter_reading WHERE order_id=%s
            ORDER BY read_at DESC LIMIT 1 FOR SHARE''', (order_id,))
        if latest and latest['read_at'] > end:
            raise ChargingError('结束时间早于已有读数，需先核对停止时点')
        cursor.execute('''SELECT read_at,cumulative_kwh FROM meter_reading
            WHERE order_id=%s AND read_at BETWEEN %s AND %s ORDER BY read_at FOR SHARE''', (order_id, order['starts_at'], end))
        readings = cursor.fetchall()
        cursor.execute('''SELECT b.*,r.valid_from,r.valid_until,r.free_minutes,r.minimum_fee
            FROM tariff_rule r JOIN tariff_band b ON b.rule_id=r.rule_id
            WHERE r.station_id=%s AND r.valid_from<=%s AND r.valid_until>%s
            ORDER BY r.valid_from,b.starts_minute FOR SHARE''',
            (order['station_id'], end.date(), order['starts_at'].date()))
        rates = cursor.fetchall()
        try:
            if disconnected and not review_note:
                raise ChargingError('断连需复核最后可信读数及差额')
            segments, kwh, gross = _calculate(order, end, readings, rates)
        except ChargingError as exc:
            if order['state'] == 'REVIEW':
                raise
            cursor.execute('''UPDATE charging_order SET state='REVIEW',ends_at=%s,end_soc=%s,
                review_reason=%s WHERE order_id=%s''', (end, end_soc, str(exc), order_id))
            return {'state': 'REVIEW', 'gross_amount': None}
        cursor.executemany('''INSERT INTO order_fee_detail(order_id,band_id,starts_at,ends_at,kwh,
            energy_price,service_price,service_basis,service_units,energy_amount,service_amount)
            VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)''', segments)
        cursor.execute('''UPDATE charging_order SET state='BILLED',ends_at=%s,end_soc=%s,
            total_kwh=%s,gross_amount=%s,review_note=%s WHERE order_id=%s''',
            (end, end_soc, kwh, gross, review_note, order_id))
        return {'state': 'BILLED', 'gross_amount': gross}


def confirm_bill(connection, *, order_id, coupon_id=None, at_time=None):
    """先锁 D 优惠券、再确认账单，重试确认不得替换优惠券。"""
    with connection.cursor() as cursor:
        order = _order(cursor, order_id)
        at = _at(cursor, at_time)
        if order['state'] != 'BILLED' or at < order['ends_at']:
            raise ChargingError('订单未出账或确认时间早于结束')
        locked = _one(cursor, "SELECT coupon_id,status FROM coupon WHERE locked_order_id=%s AND status IN ('LOCKED','USED') FOR UPDATE", (order_id,))
        if order['confirmed_at'] is not None:
            if (locked['coupon_id'] if locked else None) != coupon_id:
                raise ChargingError('账单已确认，不能替换优惠券')
            return order['gross_amount'] - order['discount_amount']
        if coupon_id is not None:
            if locked and locked['coupon_id'] != coupon_id:
                raise ChargingError('订单已锁定其他券')
            if not locked:
                lock_coupon_for_order(connection, coupon_id=coupon_id, order_id=order_id, locked_at=at)
        elif locked or order['discount_amount']:
            raise ChargingError('订单已有优惠，请指定已锁定的券')
        order = _order(cursor, order_id)
        cursor.execute('UPDATE charging_order SET confirmed_at=%s WHERE order_id=%s', (at, order_id))
        payable = order['gross_amount'] - order['discount_amount']
        if payable == 0 and coupon_id is not None:
            redeem_coupon_for_order(connection, coupon_id=coupon_id, order_id=order_id, redeemed_at=at)
        return payable


def record_payment(connection, *, order_id, channel, trade_ref, amount,
                   success=True, at_time=None):
    """记录外部支付凭证，足额时原子核销锁券；不直接扣 D 钱包余额。"""
    amount = _number(amount)
    if amount <= 0 or not channel.strip() or not trade_ref.strip() or len(channel) > 24 or len(trade_ref) > 64:
        raise ChargingError('支付渠道、流水号或金额无效')
    if type(success) is not bool:
        raise ChargingError('支付结果必须为布尔值')
    status = 'SUCCESS' if success else 'FAILED'
    with connection.cursor() as cursor:
        order = _order(cursor, order_id)
        existing = _one(cursor, 'SELECT * FROM payment_record WHERE channel=%s AND trade_ref=%s FOR UPDATE', (channel, trade_ref))
        if existing:
            if (existing['order_id'], existing['amount'], existing['status']) != (order_id, amount, status):
                raise ChargingError('支付流水号已被不同业务内容占用')
            return existing['payment_id']
        at = _at(cursor, at_time)
        if order['state'] != 'BILLED' or not order['confirmed_at'] or at < order['confirmed_at']:
            raise ChargingError('支付前须确认账单，支付时间不能早于确认')
        paid = _one(cursor, "SELECT COALESCE(SUM(amount),0) AS n FROM payment_record WHERE order_id=%s AND status='SUCCESS' FOR UPDATE", (order_id,))['n']
        payable = order['gross_amount'] - order['discount_amount']
        if success and paid + amount > payable:
            raise ChargingError('累计成功支付超过应付')
        locked = _one(cursor, "SELECT coupon_id FROM coupon WHERE locked_order_id=%s AND status='LOCKED' FOR UPDATE", (order_id,))
        cursor.execute('''INSERT INTO payment_record(order_id,channel,trade_ref,amount,status,occurred_at)
            VALUES(%s,%s,%s,%s,%s,%s)''', (order_id, channel, trade_ref, amount, status, at))
        payment_id = cursor.lastrowid
        if locked and success and paid + amount == payable:
            redeem_coupon_for_order(connection, coupon_id=locked['coupon_id'], order_id=order_id, redeemed_at=at)
        elif locked and not success and paid == 0:
            release_coupon_from_order(connection, coupon_id=locked['coupon_id'], order_id=order_id, released_at=at)
            cursor.execute('UPDATE charging_order SET confirmed_at=NULL WHERE order_id=%s', (order_id,))
        return payment_id


def record_refund(connection, *, payment_id, refund_ref, amount, reason, at_time=None):
    """记录已成功的外部退款，订单→原支付固定锁顺序控制累计可退额。"""
    amount = _number(amount)
    if amount <= 0 or not refund_ref.strip() or len(refund_ref) > 64 or not reason.strip() or len(reason) > 255:
        raise ChargingError('退款金额、流水号或原因无效')
    with connection.cursor() as cursor:
        reference = _one(cursor, 'SELECT order_id FROM payment_record WHERE payment_id=%s', (payment_id,))
        if not reference:
            raise ChargingError('原支付不存在')
        _order(cursor, reference['order_id'])
        payment = _one(cursor, 'SELECT * FROM payment_record WHERE payment_id=%s FOR UPDATE', (payment_id,))
        prior = _one(cursor, 'SELECT * FROM refund_record WHERE refund_ref=%s FOR UPDATE', (refund_ref,))
        if prior:
            if (prior['payment_id'], prior['amount'], prior['reason']) != (payment_id, amount, reason):
                raise ChargingError('退款流水号已被不同业务内容占用')
            return prior['refund_id']
        at = _at(cursor, at_time)
        if payment['status'] != 'SUCCESS' or at < payment['occurred_at']:
            raise ChargingError('须针对成功支付退款，退款时间不得早于支付')
        refunded = _one(cursor, 'SELECT COALESCE(SUM(amount),0) AS n FROM refund_record WHERE payment_id=%s FOR UPDATE', (payment_id,))['n']
        if refunded + amount > payment['amount']:
            raise ChargingError('累计退款超过原成功支付')
        cursor.execute('''INSERT INTO refund_record(payment_id,refund_ref,amount,reason,occurred_at)
            VALUES(%s,%s,%s,%s,%s)''', (payment_id, refund_ref, amount, reason, at))
        return cursor.lastrowid
