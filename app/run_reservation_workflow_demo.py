"""⑥业务线预约到站事务的真实数据库回滚演示。"""

from __future__ import annotations

import sys
from datetime import datetime

import pymysql

from app.database import DatabaseConfigError, database_connection
from app.database.procedure import DatabaseProcedureError
from app.services.reservation_service import (
    check_in_reservation,
    create_reservation,
)


TEST_USER_ID = 10019
TEST_VEHICLE_ID = 20019
TEST_GUN_ID = 9419


def _count_reservations(connection: pymysql.connections.Connection) -> int:
    with connection.cursor() as cursor:
        cursor.execute("SELECT COUNT(*) AS reservation_count FROM charging_reservation")
        row = cursor.fetchone()
    return int(row["reservation_count"]) if row else 0


def main() -> int:
    """创建预约并核验到站，验证核验后自动占位，最后整体回滚。"""

    try:
        with database_connection() as connection:
            before_count = _count_reservations(connection)
            connection.begin()
            try:
                created = create_reservation(
                    connection,
                    user_id=TEST_USER_ID,
                    vehicle_id=TEST_VEHICLE_ID,
                    gun_id=TEST_GUN_ID,
                    starts_at=datetime(2026, 12, 20, 10, 0, 0),
                    ends_at=datetime(2026, 12, 20, 11, 0, 0),
                    source="APP",
                    late_grace_minutes=15,
                )
                checked_in = check_in_reservation(
                    connection,
                    reservation_id=created["reservation_id"],
                    method="QR_CODE",
                    at_time=datetime(2026, 12, 20, 10, 5, 0),
                )

                with connection.cursor() as cursor:
                    cursor.execute(
                        """
                        SELECT
                            r.status,
                            ac.checkin_id,
                            po.occupancy_id,
                            po.parking_space_id,
                            po.released_at
                        FROM charging_reservation AS r
                        JOIN arrival_checkin AS ac
                            ON ac.reservation_id = r.reservation_id
                        JOIN parking_occupancy AS po
                            ON po.checkin_id = ac.checkin_id
                        WHERE r.reservation_id = %s
                        """,
                        (created["reservation_id"],),
                    )
                    workflow = cursor.fetchone()

                print(
                    "事务内验证："
                    f"reservation_id={created['reservation_id']}，"
                    f"status={workflow['status']}，"
                    f"checkin_id={workflow['checkin_id']}，"
                    f"occupancy_id={workflow['occupancy_id']}，"
                    f"parking_space_id={workflow['parking_space_id']}，"
                    f"released_at={workflow['released_at']}"
                )
                print(
                    "核验返回："
                    f"checkin_id={checked_in['checkin_id']}，"
                    f"occupancy_id={checked_in['occupancy_id']}"
                )
            finally:
                connection.rollback()

            after_count = _count_reservations(connection)

    except (DatabaseConfigError, DatabaseProcedureError) as exc:
        print(f"业务错误：{exc}", file=sys.stderr)
        return 2
    except pymysql.MySQLError as exc:
        print(f"数据库错误：{exc}", file=sys.stderr)
        return 3

    passed = before_count == after_count
    print(
        "回滚后验证："
        f"预约数={after_count}（原值 {before_count}），"
        f"结果={'PASS' if passed else 'FAIL'}"
    )
    return 0 if passed else 5


if __name__ == "__main__":
    raise SystemExit(main())
