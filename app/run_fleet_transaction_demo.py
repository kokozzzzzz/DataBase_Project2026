"""车辆调换车队的真实数据库回滚演示。"""

from __future__ import annotations

import sys

import pymysql

from app.database import DatabaseConfigError, database_connection
from app.services.fleet_service import (
    FleetVehicleError,
    add_vehicle_to_fleet,
    remove_vehicle_from_fleet,
)


TEST_VEHICLE_ID = 20001
ORIGINAL_FLEET_ID = 60001
TARGET_FLEET_ID = 60002


def _active_relations(
    connection: pymysql.connections.Connection,
) -> list[dict[str, int]]:
    with connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT fleet_vehicle_id, fleet_id
            FROM fleet_vehicle
            WHERE vehicle_id = %s
              AND status = 'ACTIVE'
            ORDER BY fleet_vehicle_id
            """,
            (TEST_VEHICLE_ID,),
        )
        return list(cursor.fetchall())


def main() -> int:
    """退出原车队并加入目标车队，验证后回滚整个调车事务。"""

    try:
        with database_connection() as connection:
            connection.begin()
            try:
                removed = remove_vehicle_from_fleet(
                    connection,
                    vehicle_id=TEST_VEHICLE_ID,
                    fleet_id=ORIGINAL_FLEET_ID,
                )
                added = add_vehicle_to_fleet(
                    connection,
                    vehicle_id=TEST_VEHICLE_ID,
                    fleet_id=TARGET_FLEET_ID,
                )
                transaction_relations = _active_relations(connection)

                with connection.cursor() as cursor:
                    cursor.execute(
                        """
                        SELECT status, left_at
                        FROM fleet_vehicle
                        WHERE fleet_vehicle_id = %s
                        """,
                        (removed["fleet_vehicle_id"],),
                    )
                    original_relation = cursor.fetchone()

                transaction_passed = (
                    original_relation is not None
                    and original_relation["status"] == "LEFT"
                    and original_relation["left_at"] is not None
                    and len(transaction_relations) == 1
                    and transaction_relations[0]["fleet_id"] == TARGET_FLEET_ID
                )
                original_status = (
                    original_relation["status"]
                    if original_relation is not None
                    else "MISSING"
                )
                current_fleet_id = (
                    transaction_relations[0]["fleet_id"]
                    if len(transaction_relations) == 1
                    else "INVALID"
                )
                print(
                    "事务内验证："
                    f"原关系={original_status}，"
                    f"当前有效车队={current_fleet_id}，"
                    f"有效关系={len(transaction_relations)} 条，"
                    f"结果={'PASS' if transaction_passed else 'FAIL'}"
                )
            finally:
                connection.rollback()

            rollback_relations = _active_relations(connection)
            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT COUNT(*) AS record_count
                    FROM fleet_vehicle
                    WHERE fleet_vehicle_id = %s
                    """,
                    (added["fleet_vehicle_id"],),
                )
                added_relation_count = int(cursor.fetchone()["record_count"])

    except (DatabaseConfigError, FleetVehicleError) as exc:
        print(f"业务错误：{exc}", file=sys.stderr)
        return 2
    except pymysql.MySQLError as exc:
        print(f"数据库错误：{exc}", file=sys.stderr)
        return 3

    rollback_passed = (
        len(rollback_relations) == 1
        and rollback_relations[0]["fleet_id"] == ORIGINAL_FLEET_ID
        and added_relation_count == 0
    )
    rollback_fleet_id = (
        rollback_relations[0]["fleet_id"]
        if len(rollback_relations) == 1
        else "INVALID"
    )
    print(
        "回滚后验证："
        f"当前有效车队={rollback_fleet_id}，"
        f"新增关系={added_relation_count} 条，"
        f"结果={'PASS' if rollback_passed else 'FAIL'}"
    )
    return 0 if transaction_passed and rollback_passed else 5


if __name__ == "__main__":
    raise SystemExit(main())
