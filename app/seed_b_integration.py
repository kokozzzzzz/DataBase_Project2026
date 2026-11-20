"""生成 B-FORMAL-v1 固定测试集。默认回滚，--commit 才保留；可重复检查后跳过。"""
from __future__ import annotations

import argparse
from datetime import datetime, timedelta
from decimal import Decimal
import hashlib
import json
from pathlib import Path

from app.database.connection import database_connection
from app.services import charging_service as charging
from app.services.coupon_service import issue_coupon
from app.services.reservation_service import check_in_reservation, release_parking_space


BASE = 7200000
PREFIX = 'B-FORMAL-v1'
B_TABLES = (
    'operator', 'station', 'charging_pile', 'parking_space', 'charging_gun',
    'equipment_status_log', 'equipment_outage_plan', 'equipment_change_request',
    'equipment_offline_task', 'tariff_rule', 'tariff_band', 'charging_order',
    'meter_reading', 'order_fee_detail', 'payment_record', 'refund_record',
)


def seed(connection):
    """写入真实 A/B/D 表的虚构集成样例，事务边界由调用方管理。"""
    with connection.cursor() as cursor:
        cursor.execute('SELECT COUNT(*) AS n FROM `operator` WHERE operator_id BETWEEN %s AND %s', (BASE+1,BASE+20))
        existing = cursor.fetchone()['n']
        if existing:
            report = verify_seed(connection)
            report['reused'] = True
            return report
        # 预占固定编号前检查各个主数据表，失败时整笔回滚。
        for table, key in (
            ('station','station_id'), ('charging_pile','pile_id'),
            ('parking_space','parking_space_id'), ('charging_gun','gun_id'),
            ('user','user_id'), ('vehicle','vehicle_id'), ('tariff_rule','rule_id'),
            ('equipment_outage_plan','outage_plan_id'),
        ):
            cursor.execute(f'SELECT COUNT(*) AS n FROM `{table}` WHERE `{key}` BETWEEN %s AND %s', (BASE+1,BASE+20))
            if cursor.fetchone()['n']:
                raise ValueError(f'{table} 固定测试编号已被占用，请先协调编号')
        cursor.execute('''INSERT INTO promotion(promotion_id,promotion_name,discount_type,discount_value,
            applicability_scope,valid_from,valid_to,status,total_quantity,per_user_limit)
            VALUES(%s,%s,'FIXED',2,'SELECTED','2026-01-01','2027-01-01','ACTIVE',20,1)''', (BASE,PREFIX))
        for i in range(1,21):
            key = BASE+i
            label = f'{PREFIX}-{i:02}'
            phone_hash = hashlib.sha256((label+'phone').encode()).hexdigest()
            plate_hash = hashlib.sha256((label+'plate').encode()).hexdigest()
            cursor.execute('''INSERT INTO `user`(user_id,phone_ciphertext,phone_hash,real_name_status,
                balance,user_status) VALUES(%s,%s,%s,'VERIFIED',100,'ACTIVE')''', (key,b'fictional-B-test-only',phone_hash))
            cursor.execute('''INSERT INTO vehicle(vehicle_id,user_id,plate_ciphertext,plate_hash,
                model,battery_capacity_kwh,max_charging_power_kw,fast_charge_supported)
                VALUES(%s,%s,%s,%s,'B测试车辆',60,120,1)''', (key,key,b'fictional-B-test-only',plate_hash))
            cursor.execute('INSERT INTO `operator` VALUES(%s,%s)', (key,label))
            cursor.execute('''INSERT INTO station(station_id,operator_id,name,address,longitude,latitude)
                VALUES(%s,%s,%s,'虚构课设测试地址',116,40)''', (key,key,label))
            cursor.execute('''INSERT INTO charging_pile(pile_id,station_id,serial_no,model,protocol,rated_kw,
                accepted_at,acceptance_status,commissioned_on,warranty_until,last_heartbeat_at,status)
                VALUES(%s,%s,%s,'B测试桩','OCPP1.6',120,'2026-10-01','PASSED','2026-10-01',
                '2029-10-01','2026-11-10 07:30:00','READY')''', (key,key,label))
            cursor.execute("INSERT INTO parking_space VALUES(%s,%s,'B01')", (key,key))
            cursor.execute('''INSERT INTO charging_gun(gun_id,pile_id,station_id,parking_space_id,
                gun_no,gun_type,interface_type,max_kw) VALUES(%s,%s,%s,%s,1,'DC','GB/T',60)''', (key,key,key,key))
            cursor.execute('''INSERT INTO equipment_outage_plan(outage_plan_id,station_id,starts_at,ends_at,reason,status)
                VALUES(%s,%s,'2026-10-01','2026-10-02','虚构已完成停运','COMPLETED')''', (key,key))
            cursor.execute('''INSERT INTO equipment_change_request(request_id,pile_id,requester_id,
                old_model,proposed_model,reason,requested_at,state,reviewer_id,reviewed_at)
                VALUES(%s,%s,1,'B测试桩','B待核型号','虚构变更驳回样例','2026-10-02','REJECTED',2,'2026-10-03')''', (key,key))
            cursor.execute('''INSERT INTO equipment_offline_task(task_id,pile_id,created_at,closed_at)
                VALUES(%s,%s,'2026-10-02','2026-10-03')''', (key,key))
            cursor.execute('''INSERT INTO tariff_rule(rule_id,station_id,valid_from,valid_until)
                VALUES(%s,%s,'2026-01-01','2027-01-01')''', (key,key))
            cursor.executemany('''INSERT INTO tariff_band(rule_id,starts_minute,ends_minute,label,
                energy_price,service_price,service_basis) VALUES(%s,%s,%s,%s,%s,0.20,'KWH')''',
                [(key,0,480,'VALLEY','0.40'),(key,480,960,'FLAT','0.70'),(key,960,1440,'PEAK','1.20')])
            cursor.execute('INSERT INTO promotion_station(promotion_id,station_id) VALUES(%s,%s)', (BASE,key))
            coupon = issue_coupon(connection,coupon_code=label,promotion_id=BASE,user_id=key,
                                  issued_at=datetime(2026,11,1))['coupon_id']
            for day in (10,11):
                start = datetime(2026,11,day,7,30)
                end = start+timedelta(hours=1)
                reservation = BASE+i+(100 if day==11 else 0)
                # 固定历史测试夹具导入，避免正式预约过程对过去时间的限制。
                cursor.execute('''INSERT INTO charging_reservation(reservation_id,user_id,vehicle_id,
                    gun_id,station_id,starts_at,ends_at,status)
                    VALUES(%s,%s,%s,%s,%s,%s,%s,'BOOKED')''', (reservation,key,key,key,key,start,end))
                checked = check_in_reservation(connection,reservation_id=reservation,at_time=start)
                order = charging.open_order(connection,user_id=key,vehicle_id=key,gun_id=key,
                    channel='RESERVATION',admission_id=reservation,at_time=start)
                charging.add_readings(connection,order_id=order,readings=[
                    (start,0),(start+timedelta(minutes=30),6),(end,16)])
                charging.finish_order(connection,order_id=order,ends_at=end)
                payable=charging.confirm_bill(connection,order_id=order,
                    coupon_id=coupon if day==10 else None,at_time=end)
                if day==11:
                    charging.record_payment(connection,order_id=order,channel='TEST_EXTERNAL',
                        trade_ref=label+'-failed',amount=1,success=False,at_time=end)
                pay=charging.record_payment(connection,order_id=order,channel='TEST_EXTERNAL',
                    trade_ref=f'{label}-{day}-part1',amount=6,at_time=end)
                charging.record_payment(connection,order_id=order,channel='TEST_EXTERNAL',
                    trade_ref=f'{label}-{day}-part2',amount=payable-Decimal(6),at_time=end)
                if day==10:
                    charging.record_refund(connection,payment_id=pay,refund_ref=label+'-refund',
                        amount=3,reason='虚构次月部分退款',at_time=datetime(2026,12,5,9))
                release_parking_space(connection,occupancy_id=checked['occupancy_id'],at_time=end+timedelta(minutes=5))
    report=verify_seed(connection)
    report['reused']=False
    return report


def verify_seed(connection):
    """验证固定主数据、订单关联及金额，再允许重复执行跳过。"""
    with connection.cursor() as cursor:
        for i in range(1,21):
            cursor.execute('SELECT name FROM `operator` WHERE operator_id=%s',(BASE+i,))
            if cursor.fetchone() != {'name':f'{PREFIX}-{i:02}'}:
                raise ValueError('固定编号部分占用或测试集不完整，拒绝覆盖')
        # 分别检查本测试集的明细，避免其他模块的数据掩盖本测试集的缺失。
        scoped={}
        keys={'operator':'operator_id','station':'station_id','charging_pile':'pile_id',
              'parking_space':'parking_space_id','charging_gun':'gun_id',
              'equipment_outage_plan':'outage_plan_id','equipment_change_request':'request_id',
              'equipment_offline_task':'task_id','tariff_rule':'rule_id','tariff_band':'rule_id',
              'charging_order':'gun_id'}
        for table,key in keys.items():
            cursor.execute(f'SELECT COUNT(*) AS n FROM `{table}` WHERE `{key}` BETWEEN %s AND %s',(BASE+1,BASE+20))
            scoped[table]=cursor.fetchone()['n']
            expected=60 if table=='tariff_band' else 40 if table=='charging_order' else 20
            if scoped[table]!=expected:
                raise ValueError(f'{table} 固定测试集行数已改变，拒绝自动修补')
        cursor.execute("SELECT COUNT(*) AS n FROM coupon WHERE coupon_code LIKE %s AND status='USED'",(PREFIX+'-%',))
        if cursor.fetchone()['n']!=20:
            raise ValueError('固定测试集优惠券数量或状态已改变')
        cursor.execute('''SELECT o.order_id,o.gross_amount,o.discount_amount,v.paid,v.refunded,
            v.net_received,o.admission_id FROM charging_order o
            JOIN v_b_order_funds v ON v.order_id=o.order_id
            WHERE o.gun_id BETWEEN %s AND %s ORDER BY o.admission_id''',(BASE+1,BASE+20))
        orders=cursor.fetchall()
        if len(orders)!=40:
            raise ValueError('固定测试枪的订单规模已改变，请核对后再使用测试集')
        for row in orders:
            first=row['admission_id']<=BASE+20
            expected=(Decimal('12.60'),Decimal('2.00') if first else Decimal(0),
                      Decimal('10.60') if first else Decimal('12.60'),
                      Decimal(3) if first else Decimal(0),Decimal('7.60') if first else Decimal('12.60'))
            if tuple(row[k] for k in ('gross_amount','discount_amount','paid','refunded','net_received'))!=expected:
                raise ValueError('固定测试订单金额已改变，请先核对')
        counts={}
        for table in B_TABLES:
            cursor.execute(f'SELECT COUNT(*) AS n FROM `{table}`')
            counts[table]=cursor.fetchone()['n']
        if min(counts.values())<20:
            raise ValueError('B 存在少于 20 行的表')
        return {'dataset':PREFIX,'id_range':[BASE+1,BASE+20],
                'order_ids':[r['order_id'] for r in orders],
                'b_table_counts':counts,'billed_paid_orders':len(orders),
                'fixture_counts':scoped,
                'note':'11月支付、12月退款，供 D 半开账期及调整样例；所有账户和流水均为虚构'}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--commit',action='store_true')
    parser.add_argument('--output',type=Path)
    args=parser.parse_args()
    with database_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute("SELECT GET_LOCK('b_formal_seed_v1',10) AS acquired")
            if cursor.fetchone()['acquired']!=1:
                raise RuntimeError('另一连接正在生成 B 测试集，请稍后重试')
        try:
            report=seed(connection)
            if args.commit:
                connection.commit()
            else:
                connection.rollback()
            report['committed']=args.commit
            if args.output:
                args.output.parent.mkdir(parents=True,exist_ok=True)
                args.output.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
            print(json.dumps(report,ensure_ascii=False,indent=2))
        except Exception:
            connection.rollback()
            raise
        finally:
            with connection.cursor() as cursor:
                cursor.execute("SELECT RELEASE_LOCK('b_formal_seed_v1')")


if __name__=='__main__':
    main()
