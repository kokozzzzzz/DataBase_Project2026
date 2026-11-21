"""A ⑥⑧ 模块真实 MySQL 结构、数据与事务验收。

在仓库根目录运行：
    python tests/verify_a_module.py
    python tests/verify_a_module.py --skip-concurrency
    python tests/verify_a_module.py --output ../A_本机验证

脚本复用 app.database 的 .env 配置，要求目标库已按顺序执行：
    D 核心种子 -> B 结构 -> A 结构/触发器/过程/视图 -> A 种子
业务样例在事务内执行并回滚；并发样例会短暂提交一条预约，结束后立即清理。
"""

from __future__ import annotations

import argparse
import json
import sys
import threading
import time
from datetime import datetime
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pymysql

from app.database.connection import database_connection
from app.database.procedure import DatabaseProcedureError
from app.database.notice_repository import list_pending_notifications
from app.services.notice_service import (
    create_notice,
    publish_notice,
    withdraw_notice,
)
from app.services.reservation_service import (
    check_in_reservation,
    create_reservation,
)


A_TABLES = (
    "charging_reservation",
    "reservation_status_log",
    "queue_record",
    "queue_status_log",
    "arrival_checkin",
    "parking_occupancy",
    "station_notice",
    "notice_revision",
    "notice_recipient",
    "notification_record",
)
A_VIEWS = (
    "v_a_reservation_board",
    "v_a_queue_board",
    "v_a_parking_occupancy_live",
    "v_a_reservation_fulfillment",
    "v_a_public_notice_active",
    "v_a_notice_delivery_stats",
    "v_a_outage_affected_users",
    "v_a_notice_revision_history",
)
A_PROCEDURES = (
    "sp_create_reservation",
    "sp_cancel_reservation",
    "sp_reschedule_reservation",
    "sp_check_in_reservation",
    "sp_join_queue",
    "sp_call_next_queue",
    "sp_check_in_queue",
    "sp_release_parking_space",
    "sp_consume_admission",
    "sp_expire_overdue_admissions",
    "sp_publish_notice",
    "sp_withdraw_notice",
    "sp_update_notification_status",
    "sp_expire_notices",
)
A_TRIGGERS = (
    "a_reservation_overlap_bi",
    "a_reservation_status_bu",
    "a_reservation_log_ai",
    "a_reservation_log_au",
    "a_queue_status_bu",
    "a_queue_log_ai",
    "a_queue_log_au",
    "a_checkin_qualification_bi",
    "a_checkin_occupancy_ai",
    "a_notice_transition_bu",
    "a_notice_revision_ai",
    "a_notice_revision_au",
    "a_notification_status_bu",
)


def _table_count(connection: pymysql.connections.Connection, table: str) -> int:
    with connection.cursor() as cursor:
        cursor.execute(f"SELECT COUNT(*) AS c FROM {table}")
        return int(cursor.fetchone()["c"])


def _run_workflow_checks(connection: pymysql.connections.Connection, check) -> None:
    before_reservations = _table_count(connection, "charging_reservation")
    before_checkins = _table_count(connection, "arrival_checkin")
    before_occupancies = _table_count(connection, "parking_occupancy")

    connection.begin()
    try:
        created = create_reservation(
            connection,
            user_id=10019,
            vehicle_id=20019,
            gun_id=9419,
            starts_at=datetime(2026, 12, 23, 10, 0, 0),
            ends_at=datetime(2026, 12, 23, 11, 0, 0),
            source="APP",
        )
        checked_in = check_in_reservation(
            connection,
            reservation_id=created["reservation_id"],
            method="QR_CODE",
            at_time=datetime(2026, 12, 23, 10, 5, 0),
        )
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT
                    r.status,
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
            row = cursor.fetchone()
        check(
            "预约创建后可到站核验并自动生成车位占用",
            row is not None
            and row["status"] == "CHECKED_IN"
            and row["occupancy_id"] == checked_in["occupancy_id"]
            and row["released_at"] is None,
        )
    finally:
        connection.rollback()

    check(
        "预约/核验/占用样例回滚后行数不变",
        _table_count(connection, "charging_reservation") == before_reservations
        and _table_count(connection, "arrival_checkin") == before_checkins
        and _table_count(connection, "parking_occupancy") == before_occupancies,
    )


def _run_notice_checks(connection: pymysql.connections.Connection, check) -> None:
    before_notices = _table_count(connection, "station_notice")
    before_recipients = _table_count(connection, "notice_recipient")
    before_notifications = _table_count(connection, "notification_record")

    connection.begin()
    try:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                INSERT INTO charging_reservation (
                    user_id, vehicle_id, gun_id, station_id,
                    starts_at, ends_at, status, source
                ) VALUES (10020, 20020, 9401, 9101,
                          '2026-12-01 09:00:00', '2026-12-01 10:00:00',
                          'BOOKED', 'APP')
                """
            )

        created = create_notice(
            connection,
            station_id=9101,
            notice_type="OUTAGE_TARGETED",
            severity="WARNING",
            title="验收停运公告",
            content="验收：计划停运影响预约用户。",
            effective_from=datetime(2026, 11, 20, 0, 0, 0),
            effective_to=datetime(2026, 12, 31, 23, 59, 59),
            created_by="verify",
            related_outage_plan_id=9501,
        )
        published = publish_notice(
            connection,
            notice_id=created["notice_id"],
            operator="verify",
            at_time=datetime(2026, 11, 20, 9, 0, 0),
        )
        pending = list_pending_notifications(
            connection, notice_id=created["notice_id"], limit=10
        )
        withdrawn = withdraw_notice(
            connection,
            notice_id=created["notice_id"],
            operator="verify",
            reason="验收撤回",
            at_time=datetime(2026, 11, 20, 9, 5, 0),
        )
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT nf.status, nf.failure_reason
                FROM notification_record AS nf
                JOIN notice_recipient AS nr
                  ON nr.recipient_id = nf.recipient_id
                WHERE nr.notice_id = %s
                ORDER BY nf.notification_id
                LIMIT 1
                """,
                (created["notice_id"],),
            )
            final_notification = cursor.fetchone()

        check(
            "定向停运公告发布生成接收人与待发送通知",
            published["recipient_count"] >= 1
            and published["notification_count"] >= 1
            and len(pending) >= 1,
        )
        check(
            "撤回公告取消未发送通知",
            withdrawn["cancelled_notifications"] >= 1
            and final_notification is not None
            and final_notification["status"] == "FAILED"
            and final_notification["failure_reason"] == "NOTICE_WITHDRAWN",
        )
    finally:
        connection.rollback()

    check(
        "公告/接收人/通知样例回滚后行数不变",
        _table_count(connection, "station_notice") == before_notices
        and _table_count(connection, "notice_recipient") == before_recipients
        and _table_count(connection, "notification_record") == before_notifications,
    )


def _run_concurrency_check(check) -> None:
    starts_at = datetime(2026, 12, 24, 10, 0, 0)
    ends_at = datetime(2026, 12, 24, 11, 0, 0)
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
                        user_id=10019,
                        vehicle_id=20019,
                        gun_id=9419,
                        starts_at=starts_at,
                        ends_at=ends_at,
                        source="APP",
                    )
                    results["a"] = result
                    created_ids.append(result["reservation_id"])
                    first_inserted.set()
                    time.sleep(1.2)
                    connection.commit()
                except Exception:
                    connection.rollback()
                    raise
        except Exception as exc:  # pragma: no cover - 验收入口
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
                        user_id=10020,
                        vehicle_id=20020,
                        gun_id=9419,
                        starts_at=starts_at,
                        ends_at=ends_at,
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
        except Exception as exc:  # pragma: no cover - 验收入口
            results["b_unexpected_error"] = exc

    try:
        thread_a = threading.Thread(target=worker_a, name="verify-a")
        thread_b = threading.Thread(target=worker_b, name="verify-b")
        thread_a.start()
        thread_b.start()
        thread_a.join()
        thread_b.join()

        b_error = results.get("b_error")
        check(
            "同枪并发预约只允许一个事务成功",
            "a" in results
            and isinstance(b_error, DatabaseProcedureError)
            and b_error.code == 1644,
        )
    finally:
        if created_ids:
            placeholders = ", ".join(["%s"] * len(created_ids))
            with database_connection() as connection:
                connection.begin()
                try:
                    with connection.cursor() as cursor:
                        cursor.execute(
                            f"DELETE FROM reservation_status_log "
                            f"WHERE reservation_id IN ({placeholders})",
                            tuple(created_ids),
                        )
                        cursor.execute(
                            f"DELETE FROM charging_reservation "
                            f"WHERE reservation_id IN ({placeholders})",
                            tuple(created_ids),
                        )
                    connection.commit()
                except Exception:
                    connection.rollback()
                    raise

    with database_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute(
                """
                SELECT COUNT(*) AS c
                FROM charging_reservation
                WHERE gun_id = %s AND starts_at = %s
                  AND status IN ('BOOKED', 'CHECKED_IN')
                """,
                (9419, starts_at),
            )
            remaining = int(cursor.fetchone()["c"])
    check("并发样例清理后无残留有效预约", remaining == 0)


def run(*, output: Path | None = None, skip_concurrency: bool = False) -> int:
    checks: list[dict[str, Any]] = []

    def check(name: str, condition: bool, detail: str = "") -> None:
        checks.append(
            {
                "检查": name,
                "结果": "PASS" if condition else "FAIL",
                "说明": detail,
            }
        )
        print(("PASS " if condition else "FAIL ") + name)

    with database_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute("SET SESSION time_zone = '+08:00'")
            cursor.execute(
                "SELECT VERSION() AS version, @@collation_database AS collation_name"
            )
            environment = cursor.fetchone()

            cursor.execute(
                """
                SELECT TABLE_NAME, ENGINE, TABLE_COLLATION
                FROM information_schema.TABLES
                WHERE TABLE_SCHEMA = DATABASE() AND TABLE_TYPE = 'BASE TABLE'
                """
            )
            installed = {row["TABLE_NAME"]: row for row in cursor.fetchall()}
            check(
                "10 张 A 表全部存在",
                all(table in installed for table in A_TABLES),
            )
            check(
                "A 表均为 InnoDB / utf8mb4_0900_ai_ci",
                all(
                    installed[table]["ENGINE"] == "InnoDB"
                    and installed[table]["TABLE_COLLATION"] == "utf8mb4_0900_ai_ci"
                    for table in A_TABLES
                ),
            )

            cursor.execute(
                """
                SELECT TABLE_NAME
                FROM information_schema.VIEWS
                WHERE TABLE_SCHEMA = DATABASE()
                  AND TABLE_NAME LIKE 'v\\_a\\_%'
                """
            )
            installed_views = {row["TABLE_NAME"] for row in cursor.fetchall()}
            check(
                "8 个 A 视图全部存在",
                set(A_VIEWS) <= installed_views,
            )

            cursor.execute(
                """
                SELECT ROUTINE_NAME
                FROM information_schema.ROUTINES
                WHERE ROUTINE_SCHEMA = DATABASE()
                  AND ROUTINE_TYPE = 'PROCEDURE'
                """
            )
            installed_procedures = {row["ROUTINE_NAME"] for row in cursor.fetchall()}
            check(
                "14 个 A 存储过程全部存在",
                set(A_PROCEDURES) <= installed_procedures,
            )

            cursor.execute(
                """
                SELECT TRIGGER_NAME
                FROM information_schema.TRIGGERS
                WHERE TRIGGER_SCHEMA = DATABASE()
                """
            )
            installed_triggers = {row["TRIGGER_NAME"] for row in cursor.fetchall()}
            check(
                "13 个 A 触发器全部存在",
                set(A_TRIGGERS) <= installed_triggers,
            )

            row_counts = {
                table: _table_count(connection, table) for table in A_TABLES
            }
            check(
                "每张 A 表至少 20 条测试数据",
                all(count >= 20 for count in row_counts.values()),
                str(row_counts),
            )

            cursor.execute(
                """
                SELECT COUNT(*) AS c
                FROM charging_reservation AS a
                JOIN charging_reservation AS b
                  ON b.gun_id = a.gun_id
                 AND b.reservation_id > a.reservation_id
                 AND a.status IN ('BOOKED', 'CHECKED_IN')
                 AND b.status IN ('BOOKED', 'CHECKED_IN')
                 AND a.starts_at < b.ends_at
                 AND b.starts_at < a.ends_at
                """
            )
            check("不存在同枪有效预约重叠", int(cursor.fetchone()["c"]) == 0)

            cursor.execute(
                """
                SELECT COUNT(*) AS c
                FROM (
                    SELECT parking_space_id
                    FROM parking_occupancy
                    WHERE released_at IS NULL
                    GROUP BY parking_space_id
                    HAVING COUNT(*) > 1
                ) AS x
                """
            )
            check("不存在同一车位重复有效占用", int(cursor.fetchone()["c"]) == 0)

            cursor.execute(
                """
                SELECT COUNT(*) AS c
                FROM (
                    SELECT user_id
                    FROM queue_record
                    WHERE status IN ('WAITING', 'CALLED', 'CHECKED_IN')
                    GROUP BY user_id
                    HAVING COUNT(*) > 1
                ) AS x
                """
            )
            check("不存在同一用户重复有效排队", int(cursor.fetchone()["c"]) == 0)

            cursor.execute(
                """
                SELECT COUNT(*) AS c
                FROM notification_record
                WHERE (status IN ('PENDING', 'FAILED')) <> (sent_at IS NULL)
                   OR (status = 'READ') <> (read_at IS NOT NULL)
                   OR (status = 'FAILED') <> (failure_reason IS NOT NULL)
                """
            )
            check("通知状态与时间字段一致", int(cursor.fetchone()["c"]) == 0)

        _run_workflow_checks(connection, check)
        _run_notice_checks(connection, check)

    if not skip_concurrency:
        _run_concurrency_check(check)

    passed = sum(1 for item in checks if item["结果"] == "PASS")
    failed = len(checks) - passed
    print(f"\n汇总：{passed} PASS / {failed} FAIL / {len(checks)} total")

    if output is not None:
        output.mkdir(parents=True, exist_ok=True)
        payload = {
            "environment": environment,
            "row_counts": row_counts,
            "checks": checks,
            "summary": {
                "passed": passed,
                "failed": failed,
                "total": len(checks),
            },
        }
        target = output / "verify_a_module.json"
        target.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2, default=str),
            encoding="utf-8",
        )
        print(f"结果已写入 {target}")

    return 0 if failed == 0 else 1


def main() -> int:
    parser = argparse.ArgumentParser(description="A ⑥⑧ 模块真实数据库验收")
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="可选：将 JSON 结果写入指定目录",
    )
    parser.add_argument(
        "--skip-concurrency",
        action="store_true",
        help="跳过会短暂提交并清理数据的并发测试",
    )
    args = parser.parse_args()
    try:
        return run(output=args.output, skip_concurrency=args.skip_concurrency)
    except pymysql.MySQLError as exc:
        print(f"数据库错误：{exc}", file=sys.stderr)
        return 3


if __name__ == "__main__":
    raise SystemExit(main())
