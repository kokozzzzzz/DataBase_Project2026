"""核对 B+D 建表及约束，业务样例全部放在事务中并最终回滚。

在仓库根目录运行 python tests/verify_b_structure.py。
复用 app.database 的连接配置，不创建或删除数据库。
"""
from __future__ import annotations

import argparse
import csv
import json
from decimal import Decimal
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import pymysql
from app.database.connection import database_connection


B_TABLES = (
    'operator', 'station', 'charging_pile', 'parking_space', 'charging_gun',
    'equipment_status_log', 'equipment_outage_plan', 'equipment_change_request',
    'equipment_offline_task', 'tariff_rule', 'tariff_band', 'charging_order',
    'meter_reading', 'order_fee_detail', 'payment_record', 'refund_record',
)


def run(output: Path | None = None) -> list[dict]:
    checks = []

    def check(name, condition):
        if not condition:
            raise AssertionError(name)
        checks.append({'检查': name, '结果': 'PASS'})
        print('PASS', name)

    with database_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute("SET SESSION time_zone = '+08:00'")
            cursor.execute('SELECT VERSION() AS version, @@session.time_zone AS zone')
            environment = cursor.fetchone()
            cursor.execute('''SELECT TABLE_NAME, ENGINE, TABLE_COLLATION
                FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE()
                AND TABLE_TYPE='BASE TABLE' ''')
            installed = {r['TABLE_NAME']: r for r in cursor.fetchall()}
            check('B 的 16 张表和 D 的 12 张表存在',
                  set(B_TABLES) | {'membership_level', 'user', 'vehicle', 'membership_record',
                  'promotion', 'enterprise_customer', 'fleet', 'fleet_vehicle',
                  'fleet_quota_record', 'promotion_station', 'coupon', 'coupon_redemption'} <= installed.keys())
            check('B 表均为 InnoDB / utf8mb4_0900_ai_ci', all(
                installed[t]['ENGINE']=='InnoDB' and installed[t]['TABLE_COLLATION']=='utf8mb4_0900_ai_ci'
                for t in B_TABLES))
            cursor.execute('''SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE,
                COLUMN_DEFAULT, COLUMN_KEY, EXTRA, GENERATION_EXPRESSION, COLUMN_COMMENT,
                NUMERIC_PRECISION, NUMERIC_SCALE, CHARACTER_MAXIMUM_LENGTH, DATETIME_PRECISION
                FROM information_schema.COLUMNS WHERE TABLE_SCHEMA=DATABASE()
                ORDER BY TABLE_NAME, ORDINAL_POSITION''')
            columns = [r for r in cursor.fetchall() if r['TABLE_NAME'] in B_TABLES]
            check('B 所有关联编号均为 BIGINT UNSIGNED', all(
                r['COLUMN_TYPE']=='bigint unsigned' for r in columns if r['COLUMN_NAME'].endswith('_id')))
            cursor.execute('''SELECT TABLE_NAME, COLUMN_NAME, CONSTRAINT_NAME,
                REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME, ORDINAL_POSITION
                FROM information_schema.KEY_COLUMN_USAGE
                WHERE TABLE_SCHEMA=DATABASE() AND REFERENCED_TABLE_NAME IS NOT NULL
                ORDER BY TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION''')
            foreign_keys = cursor.fetchall()
            check('订单 user_id 和 vehicle_id 已连接 D 正式主键',
                  {('user_id', 'user', 'user_id'), ('vehicle_id', 'vehicle', 'vehicle_id')} <= {
                      (r['COLUMN_NAME'],r['REFERENCED_TABLE_NAME'],r['REFERENCED_COLUMN_NAME'])
                      for r in foreign_keys if r['TABLE_NAME']=='charging_order'})
            cursor.execute('SHOW TRIGGERS')
            check('7 个设施结构触发器已创建', sum(r['Trigger'].startswith(('b_gun_power_', 'b_pile_power_', 'b_pile_status_', 'b_gun_status_')) for r in cursor.fetchall()) == 7)
            cursor.execute('SHOW FULL TABLES WHERE Table_type = %s', ('VIEW',))
            check('6 个 B 查询视图已创建', len([r for r in cursor.fetchall() if next(iter(r.values())).startswith('v_b_')])==6)
            cursor.execute('''SELECT tc.TABLE_NAME, tc.CONSTRAINT_NAME, cc.CHECK_CLAUSE
                FROM information_schema.TABLE_CONSTRAINTS tc
                JOIN information_schema.CHECK_CONSTRAINTS cc
                ON tc.CONSTRAINT_SCHEMA=cc.CONSTRAINT_SCHEMA AND tc.CONSTRAINT_NAME=cc.CONSTRAINT_NAME
                WHERE tc.TABLE_SCHEMA=DATABASE() AND tc.CONSTRAINT_TYPE='CHECK' ''')
            constraints = [r for r in cursor.fetchall() if r['TABLE_NAME'] in B_TABLES]
            indexes = []
            for table in B_TABLES:
                cursor.execute(f'SHOW INDEX FROM `{table}`')
                indexes.extend({'TABLE_NAME': table, **r} for r in cursor.fetchall())

            def insert(statement, values=()):
                cursor.execute(statement, values)
                return cursor.lastrowid

            def rejected(name, statement, values, expected_errno):
                cursor.execute('SAVEPOINT invalid_case')
                try:
                    cursor.execute(statement, values)
                except pymysql.MySQLError as exc:
                    check(name, exc.args[0] in expected_errno)
                else:
                    raise AssertionError(name + ' 应被拒绝却成功')
                finally:
                    cursor.execute('ROLLBACK TO SAVEPOINT invalid_case')
                    cursor.execute('RELEASE SAVEPOINT invalid_case')

            # 用自增编号和随机测试摘要，避免依赖 D 种子编号或已有数据。
            from uuid import uuid4
            token = uuid4().hex
            connection.begin()
            try:
                user = insert('''INSERT INTO `user`(phone_ciphertext,phone_hash,real_name_status,balance)
                    VALUES(%s,%s,'VERIFIED',100)''', (b'integration-test-only', token.ljust(64,'0')))
                vehicle = insert('''INSERT INTO vehicle(user_id,plate_ciphertext,plate_hash)
                    VALUES(%s,%s,%s)''', (user,b'integration-test-only',token.ljust(64,'1')))
                operator = insert('INSERT INTO `operator`(name) VALUES(%s)', ('B验证-'+token,))
                def station(name):
                    return insert('''INSERT INTO station(operator_id,name,address,longitude,latitude)
                        VALUES(%s,%s,'虚构验证地址',116,40)''', (operator,name))
                site = station('验证场站一')
                other_site = station('验证场站二')
                pile = insert('''INSERT INTO charging_pile(station_id,serial_no,model,protocol,rated_kw,
                    acceptance_status,commissioned_on,status)
                    VALUES(%s,%s,'验证型号','验证协议',120,'PASSED','2026-11-19','READY')''', (site,token))
                space = insert("INSERT INTO parking_space(station_id,code) VALUES(%s,'A01')", (site,))
                wrong_space = insert("INSERT INTO parking_space(station_id,code) VALUES(%s,'B01')", (other_site,))
                gun_sql = '''INSERT INTO charging_gun(pile_id,station_id,parking_space_id,gun_no,
                    gun_type,interface_type,max_kw) VALUES(%s,%s,%s,%s,'DC','验证接口',%s)'''
                gun = insert(gun_sql, (pile,site,space,1,60))
                rejected('跨场站绑定车位被复合外键拒绝',gun_sql,(pile,site,wrong_space,2,60),{1452})
                rejected('枪功率超过桩额定功率被拒绝',gun_sql,(pile,site,space,2,121),{1644})
                rejected('同一车位重复绑定枪被拒绝',gun_sql,(pile,site,space,2,60),{1062})
                rejected('降低桩功率至小于已有枪功率被拒绝',
                         'UPDATE charging_pile SET rated_kw=30 WHERE pile_id=%s',(pile,),{1644})
                cursor.execute("UPDATE charging_gun SET status='FAULT' WHERE gun_id=%s",(gun,))
                cursor.execute('SELECT COUNT(*) AS n FROM equipment_status_log WHERE gun_id=%s',(gun,))
                check('枪初始及变化状态历史均留存',cursor.fetchone()['n']==2)
                order_sql = '''INSERT INTO charging_order(gun_id,user_id,vehicle_id,starts_at)
                    VALUES(%s,%s,%s,'2026-11-19 07:30:00')'''
                order = insert(order_sql,(gun,user,vehicle))
                rejected('同枪第二笔 ACTIVE 订单被唯一约束拒绝',order_sql,(gun,user,vehicle),{1062})
                cursor.execute("SELECT COALESCE(MAX(user_id),0)+1 AS missing FROM `user`")
                missing = cursor.fetchone()['missing']
                rejected('不存在的 D 用户被正式外键拒绝',
                         'UPDATE charging_order SET user_id=%s WHERE order_id=%s',(missing,order),{1452})
                rejected('SOC 超过 100 被 CHECK 拒绝',
                         'UPDATE charging_order SET start_soc=101 WHERE order_id=%s',(order,),{3819})
                cursor.execute("UPDATE charging_order SET state='BILLED',ends_at='2026-11-19 08:30:00',total_kwh=16,gross_amount=12.60,discount_amount=2 WHERE order_id=%s",(order,))
                check('进行中订单转为已出账后释放 active_gun_id',
                      insert(order_sql,(gun,user,vehicle)) != order)
                payment_sql = '''INSERT INTO payment_record(order_id,channel,trade_ref,amount,status,occurred_at)
                    VALUES(%s,'TEST',%s,%s,%s,'2026-11-19 09:00:00')'''
                pay1=insert(payment_sql,(order,token+'1',6,'SUCCESS'))
                insert(payment_sql,(order,token+'2',4.60,'SUCCESS'))
                insert(payment_sql,(order,token+'3',20,'FAILED'))
                rejected('渠道加支付流水号重复被拒绝',payment_sql,(order,token+'1',6,'SUCCESS'),{1062})
                insert('''INSERT INTO refund_record(payment_id,refund_ref,amount,reason,occurred_at)
                    VALUES(%s,%s,1,'验证部分退款','2026-12-01 09:00:00')''',(pay1,token+'r1'))
                insert('''INSERT INTO refund_record(payment_id,refund_ref,amount,reason,occurred_at)
                    VALUES(%s,%s,2,'验证部分退款','2026-12-02 09:00:00')''',(pay1,token+'r2'))
                cursor.execute('SELECT payable,paid,refunded,net_received FROM v_b_order_funds WHERE order_id=%s',(order,))
                funds=cursor.fetchone()
                check('多支付、多退款分别汇总且失败支付排除，净实收 7.60', funds=={
                    'payable':Decimal('10.60'),'paid':Decimal('10.60'),
                    'refunded':Decimal('3.00'),'net_received':Decimal('7.60')})
                promotion=insert('''INSERT INTO promotion(promotion_name,discount_type,discount_value,
                    applicability_scope,valid_from,valid_to,status)
                    VALUES('验证活动','FIXED',2,'ALL','2026-01-01','2027-01-01','ACTIVE')''')
                insert('INSERT INTO promotion_station(promotion_id,station_id) VALUES(%s,%s)',(promotion,site))
                coupon=insert('''INSERT INTO coupon(coupon_code,promotion_id,user_id,issued_at,valid_from,valid_to)
                    VALUES(%s,%s,%s,'2026-11-01','2026-11-01','2027-01-01')''',(token,promotion,user))
                insert('INSERT INTO coupon_redemption(coupon_id,order_id,discount_amount) VALUES(%s,%s,2)',(coupon,order))
                check('D 活动场站与券核销可引用 B 正式场站和订单', True)
                rejected('同券同单重复核销被唯一约束拒绝',
                    'INSERT INTO coupon_redemption(coupon_id,order_id,discount_amount) VALUES(%s,%s,2)',(coupon,order),{1062})
                # 样例直接插入核销关系，用于验证结构；核销业务事务另行实现。
            finally:
                connection.rollback()
            cursor.execute('SELECT COUNT(*) AS n FROM `user` WHERE user_id=%s',(user,))
            check('测试事务已回滚，样例用户已撤回',cursor.fetchone()['n']==0)
            if output:
                output.mkdir(parents=True,exist_ok=True)
                report={'环境':environment,'检查':checks,
                        '范围':'结构与约束集成；并发开单、正式核销和退款限额事务待后续服务层验证'}
                (output/'建表验证结果.json').write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8')
                for filename,records in [('物理字段.csv',columns),('外键明细.csv',foreign_keys),
                                         ('检查约束.csv',constraints),('索引明细.csv',indexes)]:
                    with (output/filename).open('w',encoding='utf-8-sig',newline='') as stream:
                        writer=csv.DictWriter(stream,fieldnames=list(records[0]))
                        writer.writeheader()
                        writer.writerows(records)
    return checks


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,help='可选的验证结果与元数据输出目录')
    run(parser.parse_args().output)
