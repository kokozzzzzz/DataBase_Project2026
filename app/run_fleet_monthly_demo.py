"""企业车队月结与额度使用的真实数据库回滚演示。"""

from __future__ import annotations

import sys
from datetime import datetime
from decimal import Decimal

import pymysql

from app.database import DatabaseConfigError, database_connection
from app.database.membership_repository import (
    fetch_fleet_monthly_bill_summary,
    fetch_quota_usage,
    list_fleet_monthly_charging_details,
)


DEMO_FLEET_ID = 60001


def _month_period(value: datetime) -> tuple[datetime, datetime]:
    period_start = value.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    if period_start.month == 12:
        period_end = period_start.replace(
            year=period_start.year + 1,
            month=1,
        )
    else:
        period_end = period_start.replace(month=period_start.month + 1)
    return period_start, period_end


def main() -> int:
    """临时把一辆正式交易车辆加入车队，验证聚合后统一回滚。"""

    relation_id = 0
    quota_record_id = 0
    try:
        with database_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT
                        o.vehicle_id,
                        MIN(o.starts_at) AS first_start,
                        MIN(o.confirmed_at) AS first_confirmed
                    FROM charging_order AS o
                    WHERE o.state = 'BILLED'
                      AND o.confirmed_at IS NOT NULL
                      AND NOT EXISTS (
                          SELECT 1
                          FROM fleet_vehicle AS fv
                          WHERE fv.vehicle_id = o.vehicle_id
                            AND o.starts_at >= fv.joined_at
                            AND (fv.left_at IS NULL OR o.starts_at < fv.left_at)
                      )
                    GROUP BY o.vehicle_id
                    ORDER BY o.vehicle_id
                    LIMIT 1
                    """
                )
                candidate = cursor.fetchone()

            if candidate is None:
                print("业务错误：没有可用于回滚演示的已出账非车队车辆。", file=sys.stderr)
                return 2

            period_start, period_end = _month_period(candidate["first_confirmed"])
            connection.begin()
            try:
                with connection.cursor() as cursor:
                    cursor.execute(
                        """
                        INSERT INTO fleet_vehicle (
                            fleet_id,
                            vehicle_id,
                            joined_at,
                            left_at,
                            status
                        ) VALUES (%s, %s, %s, NULL, 'ACTIVE')
                        """,
                        (
                            DEMO_FLEET_ID,
                            candidate["vehicle_id"],
                            candidate["first_start"],
                        ),
                    )
                    relation_id = int(cursor.lastrowid)

                details = list_fleet_monthly_charging_details(
                    connection,
                    fleet_id=DEMO_FLEET_ID,
                    period_start=period_start,
                    period_end=period_end,
                )
                summary = fetch_fleet_monthly_bill_summary(
                    connection,
                    fleet_id=DEMO_FLEET_ID,
                    period_start=period_start,
                    period_end=period_end,
                )
                payable_amount = Decimal(summary["payable_amount"])

                with connection.cursor() as cursor:
                    cursor.execute(
                        """
                        INSERT INTO fleet_quota_record (
                            quota_scope,
                            enterprise_id,
                            fleet_id,
                            vehicle_id,
                            quota_type,
                            quota_limit,
                            period_start,
                            period_end,
                            change_reason
                        ) VALUES (
                            'FLEET', NULL, %s, NULL, 'AMOUNT',
                            %s, %s, %s, '车队月结回滚演示'
                        )
                        """,
                        (
                            DEMO_FLEET_ID,
                            payable_amount,
                            period_start,
                            period_end,
                        ),
                    )
                    quota_record_id = int(cursor.lastrowid)

                quota_usage = fetch_quota_usage(
                    connection,
                    quota_record_id=quota_record_id,
                )
                transaction_passed = (
                    len(details) > 0
                    and int(summary["order_count"]) == len(details)
                    and Decimal(quota_usage["used_value"]) == payable_amount
                    and quota_usage["quota_status"] == "WITHIN_LIMIT"
                )
                print(
                    "事务内验证："
                    f"fleet_id={DEMO_FLEET_ID}，"
                    f"账期={period_start:%Y-%m-%d}至{period_end:%Y-%m-%d}，"
                    f"订单={summary['order_count']} 笔，"
                    f"电量={summary['total_kwh']} kWh，"
                    f"应付={summary['payable_amount']}，"
                    f"净实收={summary['net_paid_amount']}，"
                    f"额度状态={quota_usage['quota_status']}，"
                    f"结果={'PASS' if transaction_passed else 'FAIL'}"
                )
            finally:
                connection.rollback()

            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT
                        (SELECT COUNT(*)
                         FROM fleet_vehicle
                         WHERE fleet_vehicle_id = %s) AS relation_count,
                        (SELECT COUNT(*)
                         FROM fleet_quota_record
                         WHERE quota_record_id = %s) AS quota_count
                    """,
                    (relation_id, quota_record_id),
                )
                rollback_result = cursor.fetchone()

    except DatabaseConfigError as exc:
        print(f"配置错误：{exc}", file=sys.stderr)
        return 2
    except pymysql.MySQLError as exc:
        print(f"数据库错误：{exc}", file=sys.stderr)
        return 3

    rollback_passed = (
        rollback_result is not None
        and int(rollback_result["relation_count"]) == 0
        and int(rollback_result["quota_count"]) == 0
    )
    print(
        "回滚后验证："
        f"临时车队关系={rollback_result['relation_count']} 条，"
        f"临时额度记录={rollback_result['quota_count']} 条，"
        f"结果={'PASS' if rollback_passed else 'FAIL'}"
    )
    return 0 if transaction_passed and rollback_passed else 5


if __name__ == "__main__":
    raise SystemExit(main())
