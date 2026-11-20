"""B 正式服务真实数据库验收。先安装 A/B/D 并提交 B-FORMAL-v1 测试集。

普通测试全部回滚；并发测试使用独立标记资格，最后删除该测试产生的精确记录。
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timedelta
from decimal import Decimal
import json
from pathlib import Path
import sys
import threading

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import pymysql
from app.database.connection import database_connection, transaction
from app.services import charging_service as b
from app.services.coupon_service import issue_coupon
from app.services.reservation_service import (
    check_in_reservation, join_queue, call_next_queue, check_in_queue,
)
from app.seed_b_integration import BASE, verify_seed


def scalar(connection, statement, parameters=()):
    with connection.cursor() as cursor:
        cursor.execute(statement,parameters)
        return cursor.fetchone()


def prepare(connection, start):
    key=BASE+1
    with connection.cursor() as cursor:
        cursor.execute('''INSERT INTO charging_reservation(user_id,vehicle_id,gun_id,station_id,
            starts_at,ends_at,status) VALUES(%s,%s,%s,%s,%s,%s,'BOOKED')''',
            (key,key,key,key,start,start+timedelta(hours=1)))
        admission=cursor.lastrowid
    checked=check_in_reservation(connection,reservation_id=admission,at_time=start)
    return dict(user_id=key,vehicle_id=key,gun_id=key,channel='RESERVATION',
                admission_id=admission,at_time=start),checked['occupancy_id']


def bill(connection, args):
    order=b.open_order(connection,**args)
    start=args['at_time']
    end=start+timedelta(hours=1)
    b.add_readings(connection,order_id=order,readings=[(start,0),(start+timedelta(minutes=30),6),(end,16)])
    result=b.finish_order(connection,order_id=order,ends_at=end)
    assert result['gross_amount']==Decimal('12.60')
    return order,end


def run(output=None):
    results=[]
    with database_connection() as connection:
        verify_seed(connection)
        connection.rollback()

        def case(name, callback):
            connection.begin()
            try:
                callback()
            finally:
                connection.rollback()
            results.append({'检查':name,'结果':'PASS'})
            print('PASS',name)

        def rejected(callback):
            with connection.cursor() as cursor:
                cursor.execute('SAVEPOINT rejection')
            try:
                callback()
            except ValueError:
                pass
            except pymysql.MySQLError as exc:
                if exc.args[0] not in (1062,1452,3819,1644):
                    raise
            else:
                raise AssertionError('本应拒绝的操作成功')
            finally:
                with connection.cursor() as cursor:
                    cursor.execute('ROLLBACK TO SAVEPOINT rejection')
                    cursor.execute('RELEASE SAVEPOINT rejection')

        start=datetime(2026,11,12,7,30)
        def open_and_retry():
            args,_=prepare(connection,start)
            order=b.open_order(connection,**args)
            assert b.open_order(connection,**args)==order
            record=scalar(connection,'SELECT status,consumed_order_id FROM charging_reservation WHERE reservation_id=%s',(args['admission_id'],))
            assert record=={'status':'CONSUMED','consumed_order_id':order}
        case('A核验占位→B开单→资格消费及重试幂等',open_and_retry)

        def walk_in_queue():
            key=BASE+1
            queue=join_queue(connection,station_id=key,user_id=key,vehicle_id=key,
                             gun_id=key,at_time=start)['queue_id']
            assert call_next_queue(connection,station_id=key,at_time=start)['queue_id']==queue
            check_in_queue(connection,queue_id=queue,at_time=start)
            order=b.open_order(connection,user_id=key,vehicle_id=key,gun_id=key,
                channel='QUEUE',admission_id=queue,at_time=start)
            assert scalar(connection,'SELECT consumed_order_id FROM queue_record WHERE queue_id=%s',(queue,))['consumed_order_id']==order
        case('现场排队→叫号→核验→B开单及资格消费',walk_in_queue)

        def rollback_atomic():
            args,_=prepare(connection,start)
            with connection.cursor() as cursor:
                cursor.execute('SAVEPOINT before_open')
            order=b.open_order(connection,**args)
            with connection.cursor() as cursor:
                cursor.execute('ROLLBACK TO SAVEPOINT before_open')
            assert scalar(connection,'SELECT status FROM charging_reservation WHERE reservation_id=%s',(args['admission_id'],))['status']=='CHECKED_IN'
            assert scalar(connection,'SELECT COUNT(*) AS n FROM charging_order WHERE order_id=%s',(order,))['n']==0
        case('订单与A资格消费一起回滚',rollback_atomic)

        def invalid_customer():
            args,_=prepare(connection,start)
            args['vehicle_id']=BASE+2
            rejected(lambda:b.open_order(connection,**args))
            args['vehicle_id']=BASE+1
            with connection.cursor() as cursor:
                cursor.execute('UPDATE `user` SET balance=0 WHERE user_id=%s',(BASE+1,))
            rejected(lambda:b.open_order(connection,**args))
        case('车辆归属和启动余额校验',invalid_customer)

        def bad_device():
            args,_=prepare(connection,start)
            with connection.cursor() as cursor:
                cursor.execute("UPDATE charging_gun SET status='FAULT' WHERE gun_id=%s",(BASE+1,))
            rejected(lambda:b.open_order(connection,**args))
            with connection.cursor() as cursor:
                cursor.execute("UPDATE charging_gun SET status='READY' WHERE gun_id=%s",(BASE+1,))
                cursor.execute('''INSERT INTO equipment_outage_plan(station_id,starts_at,ends_at,reason)
                    VALUES(%s,%s,%s,'验证停运')''',(BASE+1,start,start+timedelta(hours=1)))
            rejected(lambda:b.open_order(connection,**args))
        case('故障及共享停运拦截开单',bad_device)

        def billing_and_occupancy():
            args,occupancy=prepare(connection,start)
            order,end=bill(connection,args)
            assert scalar(connection,'SELECT released_at FROM parking_occupancy WHERE occupancy_id=%s',(occupancy,))['released_at'] is None
            assert scalar(connection,'SELECT COUNT(*) AS n FROM order_fee_detail WHERE order_id=%s',(order,))['n']==2
            rejected(lambda:scalar(connection,'UPDATE order_fee_detail SET kwh=100 WHERE order_id=%s',(order,)))
            assert b.finish_order(connection,order_id=order,ends_at=end)['gross_amount']==Decimal('12.60')
        case('跨谷平核价12.60元、明细保护、结束后保留占位',billing_and_occupancy)

        def review_missing_boundary():
            args,_=prepare(connection,start)
            order=b.open_order(connection,**args)
            end=start+timedelta(hours=1)
            b.add_readings(connection,order_id=order,readings=[(start,0),(end,16)])
            assert b.finish_order(connection,order_id=order,ends_at=end)['state']=='REVIEW'
            result=b.finish_order(connection,order_id=order,ends_at=end,review_note='核对设备边界报文',
                reviewed_readings=[(start+timedelta(minutes=30),6)])
            assert result['gross_amount']==Decimal('12.60')
        case('缺边界进入REVIEW，依据补录后核价',review_missing_boundary)

        def readings_reject():
            args,_=prepare(connection,start)
            order=b.open_order(connection,**args)
            b.add_readings(connection,order_id=order,readings=[(start,1)])
            b.add_readings(connection,order_id=order,readings=[(start,1)])
            rejected(lambda:b.add_readings(connection,order_id=order,readings=[(start,2)]))
            rejected(lambda:b.add_readings(connection,order_id=order,readings=[(start+timedelta(minutes=1),0)]))
        case('读数幂等、矛盾读数及倒退拦截',readings_reject)

        def split_payment_refund():
            args,_=prepare(connection,start)
            order,end=bill(connection,args)
            b.confirm_bill(connection,order_id=order,at_time=end)
            pay=b.record_payment(connection,order_id=order,channel='VERIFY',trade_ref='verify-pay1',amount=6,at_time=end)
            assert b.record_payment(connection,order_id=order,channel='VERIFY',trade_ref='verify-pay1',amount=6,at_time=end)==pay
            rejected(lambda:b.record_payment(connection,order_id=order,channel='VERIFY',trade_ref='verify-pay1',amount=5,at_time=end))
            rejected(lambda:b.record_payment(connection,order_id=order,channel='VERIFY',trade_ref='verify-over',amount=7,at_time=end))
            b.record_payment(connection,order_id=order,channel='VERIFY',trade_ref='verify-pay2',amount='6.60',at_time=end)
            refund=b.record_refund(connection,payment_id=pay,refund_ref='verify-r1',amount=3,reason='测试',at_time=end)
            assert b.record_refund(connection,payment_id=pay,refund_ref='verify-r1',amount=3,reason='测试',at_time=end)==refund
            rejected(lambda:b.record_refund(connection,payment_id=pay,refund_ref='verify-r2',amount=4,reason='测试',at_time=end))
        case('分次支付幂等、超付、部分退款及累计限额',split_payment_refund)

        def coupon_payment(fail, full=False):
            args,_=prepare(connection,start)
            order,end=bill(connection,args)
            with connection.cursor() as cursor:
                cursor.execute('''INSERT INTO promotion(promotion_name,discount_type,discount_value,
                    applicability_scope,valid_from,valid_to,status)
                    VALUES('验证券','FIXED',%s,'ALL','2026-01-01','2027-01-01','ACTIVE')''',
                    ('12.60' if full else '2.00',))
                promotion=cursor.lastrowid
            coupon=issue_coupon(connection,coupon_code='verify-coupon',promotion_id=promotion,
                                user_id=BASE+1,issued_at=start)['coupon_id']
            assert b.confirm_bill(connection,order_id=order,coupon_id=coupon,at_time=end)==(Decimal(0) if full else Decimal('10.60'))
            if full:
                assert scalar(connection,'SELECT status FROM coupon WHERE coupon_id=%s',(coupon,))['status']=='USED'
                assert scalar(connection,'SELECT COUNT(*) AS n FROM payment_record WHERE order_id=%s',(order,))['n']==0
                return
            if fail:
                b.record_payment(connection,order_id=order,channel='VERIFY',trade_ref='verify-failed',amount=1,success=False,at_time=end)
                assert scalar(connection,'SELECT status FROM coupon WHERE coupon_id=%s',(coupon,))['status']=='AVAILABLE'
                assert scalar(connection,'SELECT confirmed_at FROM charging_order WHERE order_id=%s',(order,))['confirmed_at'] is None
                b.confirm_bill(connection,order_id=order,coupon_id=coupon,at_time=end)
            b.record_payment(connection,order_id=order,channel='VERIFY',trade_ref='verify-c1',amount=6,at_time=end)
            assert scalar(connection,'SELECT status FROM coupon WHERE coupon_id=%s',(coupon,))['status']=='LOCKED'
            b.record_payment(connection,order_id=order,channel='VERIFY',trade_ref='verify-c2',amount='4.60',at_time=end)
            assert scalar(connection,'SELECT status FROM coupon WHERE coupon_id=%s',(coupon,))['status']=='USED'
        case('D锁券→部分支付保留锁定→足额支付原子核销',lambda:coupon_payment(False))
        case('首笔支付失败释放D券并重新确认',lambda:coupon_payment(True))
        case('全额优惠零应付原子核销且不伪造零元支付',lambda:coupon_payment(False,True))

    # 在独立事务准备一个资格，验证两个连接同时请求时只生成一单。
    parallel_start=datetime(2026,11,13,7,30)
    with database_connection() as setup:
        with transaction(setup):
            args,occupancy=prepare(setup,parallel_start)
    barrier=threading.Barrier(2)
    order_ids=[]
    try:
        def worker():
            with database_connection() as conn:
                barrier.wait(timeout=10)
                with transaction(conn):
                    return b.open_order(conn,**args)
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures=[pool.submit(worker) for _ in range(2)]
            order_ids=[future.result(timeout=20) for future in futures]
        assert order_ids[0]==order_ids[1]
        results.append({'检查':'两个连接同时开单仅生成一个订单并返回同一编号','结果':'PASS'})
        print('PASS 两连接同资格开单幂等')
    finally:
        with database_connection() as cleanup:
            with transaction(cleanup):
                with cleanup.cursor() as cursor:
                    cursor.execute('SELECT order_id FROM charging_order WHERE channel=%s AND admission_id=%s',('RESERVATION',args['admission_id']))
                    created=[r['order_id'] for r in cursor.fetchall()]
                    cursor.execute('DELETE FROM parking_occupancy WHERE occupancy_id=%s',(occupancy,))
                    cursor.execute('DELETE FROM arrival_checkin WHERE reservation_id=%s',(args['admission_id'],))
                    cursor.execute('DELETE FROM reservation_status_log WHERE reservation_id=%s',(args['admission_id'],))
                    cursor.execute('DELETE FROM charging_reservation WHERE reservation_id=%s',(args['admission_id'],))
                    for order in created:
                        cursor.execute("DELETE FROM charging_order WHERE order_id=%s AND state='ACTIVE'",(order,))
    with database_connection() as connection:
        verify_seed(connection)
    # RR 旧快照回归：调用方先读退款，再有其他连接成功退款。
    # 服务必须使用当前读重新计算可退额，不能使用事务开始时的旧汇总。
    with database_connection() as stale, database_connection() as writer:
        payment=scalar(writer,"SELECT payment_id FROM payment_record WHERE channel='TEST_EXTERNAL' AND trade_ref='B-FORMAL-v1-01-10-part1'")['payment_id']
        writer.rollback()
        stale.begin()
        scalar(stale,'SELECT SUM(amount) AS n FROM refund_record WHERE payment_id=%s',(payment,))
        created=None
        try:
            with transaction(writer):
                created=b.record_refund(writer,payment_id=payment,refund_ref='verify-stale-committed',
                    amount=2,reason='并发快照验证',at_time=datetime(2026,12,6))
            try:
                b.record_refund(stale,payment_id=payment,refund_ref='verify-stale-rejected',
                    amount=2,reason='并发快照验证',at_time=datetime(2026,12,6))
            except ValueError:
                pass
            else:
                raise AssertionError('旧快照导致累计退款超限')
            results.append({'检查':'RR旧快照下仍使用当前退款汇总拦截超退','结果':'PASS'})
        finally:
            stale.rollback()
            if created:
                with transaction(writer):
                    with writer.cursor() as cursor:
                        cursor.execute('DELETE FROM refund_record WHERE refund_id=%s AND refund_ref=%s',
                                       (created,'verify-stale-committed'))
    created_refunds=[]
    barrier=threading.Barrier(2)
    def refund_worker(number):
        with database_connection() as conn:
            barrier.wait(timeout=10)
            try:
                with transaction(conn):
                    refund=b.record_refund(conn,payment_id=payment,refund_ref=f'verify-refund-race-{number}',
                        amount=2,reason='并发退款验证',at_time=datetime(2026,12,6))
                    return refund
            except ValueError:
                return None
    try:
        with ThreadPoolExecutor(max_workers=2) as pool:
            futures=[pool.submit(refund_worker,i) for i in (1,2)]
            created_refunds=[f.result(timeout=20) for f in futures]
        assert len([r for r in created_refunds if r])==1
        results.append({'检查':'两连接争抢原支付剩余退款额度仅一笔成功','结果':'PASS'})
    finally:
        with database_connection() as cleanup:
            with transaction(cleanup):
                with cleanup.cursor() as cursor:
                    cursor.execute('DELETE FROM refund_record WHERE payment_id=%s AND refund_ref IN (%s,%s)',
                        (payment,'verify-refund-race-1','verify-refund-race-2'))
    with database_connection() as connection:
        verify_seed(connection)
        environment=scalar(connection,'SELECT VERSION() AS mysql_version, @@session.time_zone AS time_zone, CURRENT_TIMESTAMP AS verified_at')
    results.append({'检查':'固定种子集金额、规模与测试前保持一致','结果':'PASS'})
    if output:
        output.parent.mkdir(parents=True,exist_ok=True)
        output.write_text(json.dumps({'environment':environment,'checks':results},ensure_ascii=False,indent=2,default=str),encoding='utf-8')
    return results


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path)
    run(parser.parse_args().output)
