"""⑥业务线同枪并发预约的真实数据库并发演示。

两个连接同时为同一把枪、同一时段创建预约：
  * 连接 A 先锁定枪行并提交；
  * 连接 B 在 A 提交后重新检查，得到 RESERVATION_GUN_OVERLAP；
  * 演示结束后清理本次创建的预约和状态日志。
"""

from __future__ import annotations

import sys
import threading
import time
from datetime import datetime
from typing import Any

import pymysql

from app.database import DatabaseConfigError, database_connection
from app.database.procedure import DatabaseProcedureError
from app.services.reservation_service import create_reservation


TEST_USER_ID = 10019
TEST_VEHICLE_ID = 20019
TEST_GUN_ID = 9419
STARTS_AT = datetime(2026, 12, 22, 10, 0, 0)
ENDS_AT = datetime(2026, 12, 22, 11, 0, 0)


def _cleanup(reservation_ids: list[int]) -> int:
    """删除本演示创建、且没有下游引用的预约。"""

    if not reservation_ids:
        return 0
    placeholders = ", ".join(["%s"] * len(reservation_ids))
    with database_connection() as connection:
        connection.begin()
        try:
            with connection.cursor() as cursor:
                cursor.execute(
                    f"DELETE FROM reservation_status_log "
                    f"WHERE reservation_id IN ({placeholders})",
                    tuple(reservation_ids),
                )
                cursor.execute(
                    f"DELETE FROM charging_reservation "
                    f"WHERE reservation_id IN ({placeholders})",
                    tuple(reservation_ids),
                )
                deleted = cursor.rowcount
            connection.commit()
        except Exception:
            connection.rollback()
            raise
    return deleted


def main() -> int:
    """运行两个连接的并发预约测试。"""

    first_inserted = threading.Event()
    results: dict[str, Any] = {}
    created_ids: list[int] = []

    def worker_a() -> None:
        try:
            with database_connection() as connection:
                connection.begin()
                try:
                    result = create_reservation(
                        connection,
                        user_id=TEST_USER_ID,
                        vehicle_id=TEST_VEHICLE_ID,
                        gun_id=TEST_GUN_ID,
                        starts_at=STARTS_AT,
                        ends_at=ENDS_AT,
                        source="APP",
                    )
                    results["a"] = result
                    created_ids.append(result["reservation_id"])
                    first_inserted.set()
                    time.sleep(1.5)
                    connection.commit()
                except Exception:
                    connection.rollback()
                    raise
        except Exception as exc:  # pragma: no cover - 演示入口
            results["a_error"] = exc
            first_inserted.set()

    def worker_b() -> None:
        first_inserted.wait(timeout=5)
        try:
            with database_connection() as connection:
                connection.begin()
                try:
                    result = create_reservation(
                        connection,
                        user_id=TEST_USER_ID + 1,
                        vehicle_id=TEST_VEHICLE_ID + 1,
                        gun_id=TEST_GUN_ID,
                        starts_at=STARTS_AT,
                        ends_at=ENDS_AT,
                        source="APP",
                    )
                    results["b"] = result
                    created_ids.append(result["reservation_id"])
                    connection.commit()
                except Exception:
                    connection.rollback()
                    raise
        except DatabaseProcedureError as exc:
            results["b_error"] = exc
        except Exception as exc:  # pragma: no cover - 演示入口
            results["b_unexpected_error"] = exc

    thread_a = threading.Thread(target=worker_a, name="reservation-a")
    thread_b = threading.Thread(target=worker_b, name="reservation-b")
    thread_a.start()
    thread_b.start()
    thread_a.join()
    thread_b.join()

    try:
        cleaned = _cleanup(created_ids)

        with database_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT COUNT(*) AS remaining
                    FROM charging_reservation
                    WHERE gun_id = %s
                      AND starts_at = %s
                      AND status IN ('BOOKED', 'CHECKED_IN')
                    """,
                    (TEST_GUN_ID, STARTS_AT),
                )
                remaining = int(cursor.fetchone()["remaining"])
    except pymysql.MySQLError as exc:
        print(f"清理或复核失败：{exc}", file=sys.stderr)
        return 3

    a_ok = "a" in results
    b_error = results.get("b_error")
    b_rejected = (
        isinstance(b_error, DatabaseProcedureError)
        and b_error.code == 1644
    )

    print(
        "并发结果："
        f"A={'成功' if a_ok else '失败'}，"
        f"B={'被拒绝' if b_rejected else '未按预期拒绝'}"
    )
    if a_ok:
        print(f"A reservation_id={results['a']['reservation_id']}")
    if b_error is not None:
        print(f"B 错误：code={getattr(b_error, 'code', '?')}，{b_error}")
    print(f"清理预约={cleaned} 条，复核同枪同时段有效预约={remaining} 条")

    passed = a_ok and b_rejected and remaining == 0
    print(f"结果={'PASS' if passed else 'FAIL'}")
    return 0 if passed else 5


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except DatabaseConfigError as exc:
        print(f"配置错误：{exc}", file=sys.stderr)
        raise SystemExit(2)
