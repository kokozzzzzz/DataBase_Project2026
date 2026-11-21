"""A/B/C/D真实联调；普通用例回滚，库存竞争保留收货/领用/退料审计。"""
from concurrent.futures import ThreadPoolExecutor
from datetime import timedelta
import argparse
import json
from pathlib import Path
import sys
import threading
from uuid import uuid4

sys.path.insert(0,str(Path(__file__).resolve().parents[1]))
import pymysql
from app.database.connection import database_connection, transaction
from app.database import c_repository as c
from app.services import charging_service as b
from app.services.reservation_service import create_reservation, check_in_reservation
from app.services.notice_service import create_notice, publish_notice


KEY=7200002


def one(conn,sql,args=()):
    with conn.cursor() as cursor:
        cursor.execute(sql,args)
        return cursor.fetchone()


def sample(conn,**changes):
    values=dict(pile_id=KEY,gun_id=KEY,collect_time=one(conn,'SELECT CURRENT_TIMESTAMP(6) AS t')['t'],
                voltage=None,current=None,power=None,module_temp=None,offline_duration_sec=0,
                fault_code=None,quality_flag='NORMAL',offline_threshold_sec=60)
    values.update(changes)
    return c.ingest_telemetry(conn,**values)


def prepare(conn):
    start=one(conn,'SELECT CURRENT_TIMESTAMP AS t')['t']+timedelta(minutes=5)
    reservation=create_reservation(conn,user_id=KEY,vehicle_id=KEY,gun_id=KEY,
        starts_at=start,ends_at=start+timedelta(hours=1))['reservation_id']
    check_in_reservation(conn,reservation_id=reservation,at_time=start)
    return dict(user_id=KEY,vehicle_id=KEY,gun_id=KEY,channel='RESERVATION',admission_id=reservation,at_time=start)


def repair(conn,alarm,token):
    work=c.dispatch_work_order(conn,alarm_id=alarm,work_order_no=token,work_order_type='REPAIR',maintainer_id=1)
    for action in ('ACCEPT','ARRIVE','REPAIR'):
        c.advance_work_order(conn,work_order_id=work,action=action,repair_result='复核测试维修' if action=='REPAIR' else None)
    c.verify_work_order(conn,work_order_id=work,passed=True,remark='现场复核通过')
    return work


def run(output=None):
    checks=[]
    def passed(name):
        checks.append({'check':name,'result':'PASS'})
        print('PASS',name)
    with database_connection() as conn:
        environment=one(conn,'SELECT VERSION() AS version,@@session.time_zone AS time_zone')
        conn.rollback()
        # C不能在外层回滚之前偷偷提交设备状态、告警和订单。
        baseline=one(conn,'SELECT COUNT(*) AS n FROM device_telemetry')['n']
        conn.rollback()
        conn.begin()
        try:
            args=prepare(conn)
            fault=sample(conn,fault_code='HIGH_INTEGRATION_ROLLBACK')['alarm_id']
            try:
                b.open_order(conn,**args)
            except ValueError:
                pass
            else:
                raise AssertionError('故障未阻止开单')
            sample(conn)
            assert one(conn,'SELECT status FROM charging_gun WHERE gun_id=%s',(KEY,))['status']=='FAULT'
            repair(conn,fault,'ABCD-'+uuid4().hex)
            assert b.open_order(conn,**args)>0
        finally:
            conn.rollback()
        assert one(conn,'SELECT COUNT(*) AS n FROM device_telemetry')['n']==baseline
        conn.rollback()
        passed('故障拦截、健康报文不越过维修、复核恢复后开单，整笔回滚无残留')
        conn.begin()
        try:
            with conn.cursor() as cursor:
                cursor.execute("UPDATE charging_gun SET status='DISABLED' WHERE gun_id=%s",(KEY,))
            alarm=sample(conn,fault_code='DISABLED_TEST')['alarm_id']
            repair(conn,alarm,'DISABLED-'+uuid4().hex)
            assert one(conn,'SELECT status FROM charging_gun WHERE gun_id=%s',(KEY,))['status']=='DISABLED'
        finally:
            conn.rollback()
        passed('故障上报及维修不覆盖B人工禁用状态')
        conn.begin()
        try:
            args=prepare(conn)
            sample(conn,gun_id=None,offline_duration_sec=120)
            assert one(conn,'SELECT status FROM charging_pile WHERE pile_id=%s',(KEY,))['status']=='OFFLINE'
            try:
                b.open_order(conn,**args)
            except ValueError:
                pass
            else:
                raise AssertionError('离线未阻止开单')
            sample(conn,gun_id=None)
            assert one(conn,'SELECT status FROM charging_pile WHERE pile_id=%s',(KEY,))['status']=='READY'
            assert one(conn,'SELECT COUNT(*) AS n FROM equipment_offline_task WHERE pile_id=%s AND closed_at IS NULL',(KEY,))['n']==0
            old=one(conn,'SELECT CURRENT_TIMESTAMP(6) AS t')['t']-timedelta(days=1)
            sample(conn,gun_id=None,collect_time=old,fault_code='OLD_PACKET')
            assert one(conn,'SELECT status FROM charging_pile WHERE pile_id=%s',(KEY,))['status']=='READY'
            b.open_order(conn,**args)
        finally:
            conn.rollback()
        passed('离线拦截、健康通信恢复与待办关闭、旧报文不回退状态')
        conn.begin()
        try:
            token='ROLLBACK-'+uuid4().hex
            part=c.create_spare_part(conn,part_code=token,part_name='回滚备件',model=None,spec=None,unit='件')
            warehouse=c.create_warehouse(conn,warehouse_code=token,warehouse_name='回滚仓库')
            c.receive_stock(conn,warehouse_id=warehouse,spare_part_id=part,quantity=1,operator_id=1,transaction_no=token)
        finally:
            conn.rollback()
        assert one(conn,'SELECT COUNT(*) AS n FROM spare_part WHERE part_code=%s',(token,))['n']==0
        conn.rollback()
        passed('库存主数据、库存余额与流水随调用方事务一起回滚')
        conn.begin()
        try:
            token='INSTALL-'+uuid4().hex
            alarm=sample(conn,fault_code=token)['alarm_id']
            part=c.create_spare_part(conn,part_code=token,part_name='安装验证备件',model=None,spec=None,unit='件')
            warehouse=c.create_warehouse(conn,warehouse_code=token,warehouse_name='安装验证仓库')
            c.receive_stock(conn,warehouse_id=warehouse,spare_part_id=part,quantity=2,operator_id=1,transaction_no=token+'-IN')
            work=c.dispatch_work_order(conn,alarm_id=alarm,work_order_no=token,work_order_type='REPAIR',maintainer_id=1)
            for action in ('ACCEPT','ARRIVE'):
                c.advance_work_order(conn,work_order_id=work,action=action)
            c.plan_work_order_part(conn,work_order_id=work,spare_part_id=part,warehouse_id=warehouse,planned_qty=2)
            c.issue_stock_to_work_order(conn,work_order_id=work,spare_part_id=part,warehouse_id=warehouse,quantity=2,operator_id=1,transaction_no=token+'-OUT')
            c.record_part_installation(conn,work_order_id=work,spare_part_id=part,warehouse_id=warehouse,quantity=1)
            assert one(conn,'SELECT part_usage_status FROM work_order_part WHERE work_order_id=%s',(work,))['part_usage_status']=='ISSUED'
            c.return_stock_from_work_order(conn,work_order_id=work,spare_part_id=part,warehouse_id=warehouse,quantity=1,operator_id=1,transaction_no=token+'-RETURN')
            assert one(conn,'SELECT part_usage_status FROM work_order_part WHERE work_order_id=%s',(work,))['part_usage_status']=='COMPLETED'
            c.advance_work_order(conn,work_order_id=work,action='REPAIR',repair_result='领用2，安装1，退库1')
            c.verify_work_order(conn,work_order_id=work,passed=True,remark='数量闭合')
        finally:
            conn.rollback()
        passed('领用2→安装1→退库1→数量闭合并复核关单')
        conn.begin()
        try:
            args=prepare(conn)
            now=one(conn,'SELECT CURRENT_TIMESTAMP AS t')['t']
            plan=c.register_outage_plan(conn,station_id=KEY,gun_id=KEY,starts_at=now,
                ends_at=args['at_time']+timedelta(hours=1),reason='联调计划停运')
            notice=create_notice(conn,station_id=KEY,notice_type='OUTAGE_TARGETED',severity='WARNING',
                title='联调停运',content='通知已核验的测试用户',effective_from=now,
                effective_to=args['at_time']+timedelta(hours=1),created_by='C集成测试',related_outage_plan_id=plan)['notice_id']
            publish_notice(conn,notice_id=notice,operator='C集成测试',at_time=now)
            assert one(conn,'SELECT COUNT(*) AS n FROM notice_recipient WHERE notice_id=%s',(notice,))['n']>0
            try:
                b.open_order(conn,**args)
            except ValueError:
                pass
            else:
                raise AssertionError('计划停运未阻止开单')
            c.finish_outage_plan(conn,outage_plan_id=plan,cancelled=True)
            b.open_order(conn,**args)
        finally:
            conn.rollback()
        passed('C唯一停运记录→A定向通知快照→B禁止开单→取消后放行')
    # 两连接争抢最后一件，真实提交后用退库保留审计，不删除库存流水。
    token='RACE-'+uuid4().hex
    with database_connection() as conn:
        with transaction(conn):
            alarm=sample(conn,fault_code=token)['alarm_id']
            part=c.create_spare_part(conn,part_code=token,part_name='并发验证备件',model=None,spec=None,unit='件')
            warehouse=c.create_warehouse(conn,warehouse_code=token,warehouse_name='并发验证仓库')
            c.receive_stock(conn,warehouse_id=warehouse,spare_part_id=part,quantity=1,operator_id=1,transaction_no=token+'-IN')
            works=[]
            for i in range(2):
                work=c.dispatch_work_order(conn,alarm_id=alarm,work_order_no=token+str(i),work_order_type='REPAIR',maintainer_id=1)
                c.advance_work_order(conn,work_order_id=work,action='ACCEPT')
                c.advance_work_order(conn,work_order_id=work,action='ARRIVE')
                c.plan_work_order_part(conn,work_order_id=work,spare_part_id=part,warehouse_id=warehouse,planned_qty=1,remark='并发验证')
                works.append(work)
    barrier=threading.Barrier(2)
    def issue(i):
        with database_connection() as conn:
            barrier.wait(timeout=10)
            try:
                with transaction(conn):
                    return c.issue_stock_to_work_order(conn,work_order_id=works[i],spare_part_id=part,
                        warehouse_id=warehouse,quantity=1,operator_id=1,transaction_no=token+'-OUT'+str(i))
            except pymysql.MySQLError as exc:
                if exc.args[0]!=1644 or 'INSUFFICIENT' not in str(exc):
                    raise
                return None
    with ThreadPoolExecutor(max_workers=2) as pool:
        futures=[pool.submit(issue,i) for i in range(2)]
        result=[f.result(timeout=30) for f in futures]
    assert sum(value is not None for value in result)==1
    with database_connection() as conn:
        with transaction(conn):
            assert one(conn,'SELECT quantity FROM inventory WHERE warehouse_id=%s AND spare_part_id=%s',(warehouse,part))['quantity']==0
            winner=works[0 if result[0] else 1]
            c.return_stock_from_work_order(conn,work_order_id=winner,spare_part_id=part,warehouse_id=warehouse,
                quantity=1,operator_id=1,transaction_no=token+'-RETURN')
            for work in works:
                c.advance_work_order(conn,work_order_id=work,action='REPAIR',repair_result='测试结束，实物退库')
                c.verify_work_order(conn,work_order_id=work,passed=True,remark='测试完成')
            assert one(conn,'SELECT quantity FROM inventory WHERE warehouse_id=%s AND spare_part_id=%s',(warehouse,part))['quantity']==1
            assert one(conn,'SELECT status FROM charging_gun WHERE gun_id=%s',(KEY,))['status']=='READY'
    passed('两工单争抢最后一件仅一笔成功，退库及维修闭环保留真实审计')
    report={'environment':environment,'checks':checks,'audit_prefix':token,
            'note':'并发验证保留已闭环工单与收货/领用/退料流水，其他用例均回滚'}
    if output:
        output.parent.mkdir(parents=True,exist_ok=True)
        output.write_text(json.dumps(report,ensure_ascii=False,indent=2,default=str),encoding='utf-8')
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path)
    run(parser.parse_args().output)
