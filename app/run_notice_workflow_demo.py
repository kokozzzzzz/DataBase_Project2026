"""⑧业务线定向停运公告发布、发送与撤回事務回滚演示。"""

from __future__ import annotations

import sys
from datetime import datetime

import pymysql

from app.database import DatabaseConfigError, database_connection
from app.database.notice_repository import list_pending_notifications
from app.database.procedure import DatabaseProcedureError
from app.services.notice_service import (
    create_notice,
    publish_notice,
    update_notification_status,
    withdraw_notice,
)


TEST_USER_ID = 10020
TEST_VEHICLE_ID = 20020
TEST_GUN_ID = 9401
TEST_STATION_ID = 9101
TEST_OUTAGE_PLAN_ID = 9501


def _read_notification_status(
    connection: pymysql.connections.Connection,
    notice_id: int,
) -> dict[str, object]:
    with connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT nf.notification_id, nf.status, nf.failure_reason
            FROM notification_record AS nf
            JOIN notice_recipient AS nr
              ON nr.recipient_id = nf.recipient_id
            WHERE nr.notice_id = %s
            ORDER BY nf.notification_id
            LIMIT 1
            """,
            (notice_id,),
        )
        row = cursor.fetchone()
    if row is None:
        raise RuntimeError(f"公告 {notice_id} 没有通知记录。")
    return row


def _counts(connection: pymysql.connections.Connection) -> tuple[int, int]:
    with connection.cursor() as cursor:
        cursor.execute("SELECT COUNT(*) AS c FROM station_notice")
        notices = int(cursor.fetchone()["c"])
        cursor.execute("SELECT COUNT(*) AS c FROM charging_reservation")
        reservations = int(cursor.fetchone()["c"])
    return notices, reservations


def main() -> int:
    """模拟预约后新增停运计划，发布定向公告、发送通知并撤回。"""

    try:
        with database_connection() as connection:
            before_notices, before_reservations = _counts(connection)
            connection.begin()
            try:
                # 直接插入一条与停运计划重叠的预约，模拟“先预约、后登记停运”。
                with connection.cursor() as cursor:
                    cursor.execute(
                        """
                        INSERT INTO charging_reservation (
                            user_id, vehicle_id, gun_id, station_id,
                            starts_at, ends_at, status, source
                        ) VALUES (%s, %s, %s, %s, %s, %s, 'BOOKED', 'APP')
                        """,
                        (
                            TEST_USER_ID,
                            TEST_VEHICLE_ID,
                            TEST_GUN_ID,
                            TEST_STATION_ID,
                            datetime(2026, 12, 1, 9, 0, 0),
                            datetime(2026, 12, 1, 10, 0, 0),
                        ),
                    )
                    reservation_id = int(cursor.lastrowid)

                notice_one = create_notice(
                    connection,
                    station_id=TEST_STATION_ID,
                    notice_type="OUTAGE_TARGETED",
                    severity="WARNING",
                    title="演示停运公告一",
                    content="演示：2026-12-01 08:00-12:00 停运。",
                    effective_from=datetime(2026, 11, 20, 0, 0, 0),
                    effective_to=datetime(2026, 12, 31, 23, 59, 59),
                    created_by="demo",
                    related_outage_plan_id=TEST_OUTAGE_PLAN_ID,
                )
                published_one = publish_notice(
                    connection,
                    notice_id=notice_one["notice_id"],
                    operator="demo",
                    at_time=datetime(2026, 11, 20, 9, 0, 0),
                )
                pending = list_pending_notifications(
                    connection,
                    notice_id=notice_one["notice_id"],
                    limit=10,
                )
                if not pending:
                    raise RuntimeError("发布后没有生成待发送通知。")
                sent = update_notification_status(
                    connection,
                    notification_id=pending[0]["notification_id"],
                    status="SENT",
                    provider_message_id="DEMO-MSG-1",
                    at_time=datetime(2026, 11, 20, 9, 1, 0),
                )
                withdrawn_one = withdraw_notice(
                    connection,
                    notice_id=notice_one["notice_id"],
                    operator="demo",
                    reason="演示撤回已发送公告",
                    at_time=datetime(2026, 11, 20, 9, 2, 0),
                )
                status_one = _read_notification_status(
                    connection, notice_one["notice_id"]
                )

                notice_two = create_notice(
                    connection,
                    station_id=TEST_STATION_ID,
                    notice_type="OUTAGE_TARGETED",
                    severity="EMERGENCY",
                    title="演示停运公告二",
                    content="演示：撤回未发送通知。",
                    effective_from=datetime(2026, 11, 20, 0, 0, 0),
                    effective_to=datetime(2026, 12, 31, 23, 59, 59),
                    created_by="demo",
                    related_outage_plan_id=TEST_OUTAGE_PLAN_ID,
                )
                published_two = publish_notice(
                    connection,
                    notice_id=notice_two["notice_id"],
                    operator="demo",
                    at_time=datetime(2026, 11, 20, 9, 3, 0),
                )
                withdrawn_two = withdraw_notice(
                    connection,
                    notice_id=notice_two["notice_id"],
                    operator="demo",
                    reason="演示撤回未发送通知",
                    at_time=datetime(2026, 11, 20, 9, 4, 0),
                )
                status_two = _read_notification_status(
                    connection, notice_two["notice_id"]
                )

                print(
                    f"模拟预约：reservation_id={reservation_id}，"
                    f"用户={TEST_USER_ID}，枪={TEST_GUN_ID}"
                )
                print(
                    "公告一："
                    f"notice_id={notice_one['notice_id']}，"
                    f"发布接收人={published_one['recipient_count']}，"
                    f"通知={published_one['notification_count']}，"
                    f"发送结果={sent['updated']}，"
                    f"撤回取消={withdrawn_one['cancelled_notifications']}，"
                    f"通知终态={status_one['status']}"
                )
                print(
                    "公告二："
                    f"notice_id={notice_two['notice_id']}，"
                    f"发布接收人={published_two['recipient_count']}，"
                    f"通知={published_two['notification_count']}，"
                    f"撤回取消={withdrawn_two['cancelled_notifications']}，"
                    f"通知终态={status_two['status']}，"
                    f"失败原因={status_two['failure_reason']}"
                )
            finally:
                connection.rollback()

            after_notices, after_reservations = _counts(connection)

    except (DatabaseConfigError, DatabaseProcedureError) as exc:
        print(f"业务错误：{exc}", file=sys.stderr)
        return 2
    except pymysql.MySQLError as exc:
        print(f"数据库错误：{exc}", file=sys.stderr)
        return 3

    passed = (
        before_notices == after_notices
        and before_reservations == after_reservations
    )
    print(
        "回滚后验证："
        f"公告数={after_notices}（原值 {before_notices}），"
        f"预约数={after_reservations}（原值 {before_reservations}），"
        f"结果={'PASS' if passed else 'FAIL'}"
    )
    return 0 if passed else 5


if __name__ == "__main__":
    raise SystemExit(main())
