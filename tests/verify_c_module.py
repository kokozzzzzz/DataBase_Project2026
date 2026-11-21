"""Read-only MySQL acceptance checks for C; run from the repository root."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.database.connection import database_connection


C_TABLES = (
    "device_telemetry",
    "alarm",
    "maintenance_work_order",
    "spare_part",
    "warehouse",
    "inventory",
    "inventory_transaction",
    "work_order_part",
)


def run(output: Path | None = None) -> list[dict[str, Any]]:
    checks: list[dict[str, Any]] = []

    def check(name: str, condition: bool, detail: str = "") -> None:
        result = "PASS" if condition else "FAIL"
        checks.append({"check": name, "result": result, "detail": detail})
        print(result, name, detail)
        if not condition:
            raise AssertionError(name)

    with database_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute("SET SESSION time_zone = '+08:00'")
            cursor.execute("SELECT VERSION() AS mysql_version, DATABASE() AS database_name")
            environment = cursor.fetchone()
            check(
                "connected to charging_platform",
                environment is not None and environment["database_name"] == "charging_platform",
                str(environment),
            )

            cursor.execute(
                """
                SELECT table_name AS table_name
                FROM information_schema.tables
                WHERE table_schema = DATABASE()
                  AND table_type = 'BASE TABLE'
                  AND table_name IN (%s, %s, %s, %s, %s, %s, %s, %s)
                """,
                C_TABLES,
            )
            installed_tables = {row["table_name"] for row in cursor.fetchall()}
            check("all eight C tables exist", installed_tables == set(C_TABLES))

            for table in C_TABLES:
                cursor.execute(f"SELECT COUNT(*) AS row_count FROM `{table}`")
                count = cursor.fetchone()["row_count"]
                check(f"{table} has at least 20 rows", count >= 20, f"rows={count}")

            cursor.execute(
                """
                SELECT COUNT(*) AS object_count
                FROM information_schema.views
                WHERE table_schema = DATABASE() AND LEFT(table_name, 4) = 'v_c_'
                """
            )
            check("six C views exist", cursor.fetchone()["object_count"] == 6)

            cursor.execute(
                """
                SELECT routine_name
                FROM information_schema.routines
                WHERE routine_schema = DATABASE()
                  AND routine_type = 'PROCEDURE'
                  AND LEFT(routine_name, 5) = 'sp_c_'
                """
            )
            procedure_count = len(cursor.fetchall())
            check("twelve C procedures exist", procedure_count == 12)

            cursor.execute(
                """
                SELECT trigger_name
                FROM information_schema.triggers
                WHERE trigger_schema = DATABASE() AND LEFT(trigger_name, 2) = 'c_'
                """
            )
            trigger_count = len(cursor.fetchall())
            check("eight C triggers exist", trigger_count == 8)

            cursor.execute(
                """
                SELECT COUNT(*) AS failure_count
                FROM inventory AS i
                LEFT JOIN (
                    SELECT warehouse_id, spare_part_id, SUM(quantity_change) AS net_change
                    FROM inventory_transaction
                    GROUP BY warehouse_id, spare_part_id
                ) AS ledger
                  ON ledger.warehouse_id = i.warehouse_id
                 AND ledger.spare_part_id = i.spare_part_id
                WHERE i.quantity <> COALESCE(ledger.net_change, 0)
                   OR i.locked_quantity > i.quantity
                """
            )
            result = cursor.fetchone()["failure_count"]
            check("inventory balances match immutable ledger", result == 0, f"failures={result}")

            cursor.execute(
                """
                SELECT COUNT(*) AS failure_count
                FROM work_order_part AS wop
                JOIN maintenance_work_order AS wo ON wo.work_order_id = wop.work_order_id
                WHERE wop.installed_qty + wop.returned_qty > wop.issued_qty
                   OR (wo.work_order_status = 'CLOSED'
                       AND wop.issued_qty <> wop.installed_qty + wop.returned_qty)
                """
            )
            result = cursor.fetchone()["failure_count"]
            check("part quantities reconcile without loss", result == 0, f"failures={result}")

            cursor.execute(
                """
                SELECT COUNT(*) AS failure_count
                FROM device_telemetry AS t
                LEFT JOIN charging_pile AS p ON p.pile_id = t.pile_id
                LEFT JOIN charging_gun AS g ON g.gun_id = t.gun_id
                WHERE p.pile_id IS NULL OR (t.gun_id IS NOT NULL AND g.pile_id <> t.pile_id)
                """
            )
            result = cursor.fetchone()["failure_count"]
            check("telemetry references existing matching B devices", result == 0, f"failures={result}")

    if output is not None:
        output.mkdir(parents=True, exist_ok=True)
        (output / "verify_c_module.json").write_text(
            json.dumps({"checks": checks}, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
    return checks


def main() -> int:
    parser = argparse.ArgumentParser(description="Run read-only C module database checks.")
    parser.add_argument("--output", type=Path, help="optional directory for a JSON report")
    args = parser.parse_args()
    run(args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
