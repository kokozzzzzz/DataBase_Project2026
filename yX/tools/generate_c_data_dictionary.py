"""Export C table columns, keys and references from the deployed MySQL schema."""

from __future__ import annotations

import csv
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from app.database.connection import database_connection


TABLES = (
    "device_telemetry",
    "alarm",
    "maintenance_work_order",
    "spare_part",
    "warehouse",
    "inventory",
    "inventory_transaction",
    "work_order_part",
)


def main() -> int:
    output = Path(__file__).resolve().parents[1] / "C_03_07_physical_dictionary.csv"
    placeholders = ", ".join(["%s"] * len(TABLES))
    query = f"""
        SELECT
            c.TABLE_NAME,
            c.ORDINAL_POSITION,
            c.COLUMN_NAME,
            c.COLUMN_TYPE,
            c.IS_NULLABLE,
            c.COLUMN_DEFAULT,
            c.COLUMN_KEY,
            c.EXTRA,
            c.COLUMN_COMMENT,
            (
                SELECT GROUP_CONCAT(
                    CONCAT(k.CONSTRAINT_NAME, ' -> ', k.REFERENCED_TABLE_NAME,
                           '.', k.REFERENCED_COLUMN_NAME)
                    ORDER BY k.CONSTRAINT_NAME SEPARATOR '; '
                )
                FROM information_schema.KEY_COLUMN_USAGE AS k
                WHERE k.TABLE_SCHEMA = c.TABLE_SCHEMA
                  AND k.TABLE_NAME = c.TABLE_NAME
                  AND k.COLUMN_NAME = c.COLUMN_NAME
                  AND k.REFERENCED_TABLE_NAME IS NOT NULL
            ) AS foreign_keys
        FROM information_schema.COLUMNS AS c
        WHERE c.TABLE_SCHEMA = DATABASE()
          AND c.TABLE_NAME IN ({placeholders})
        ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION
    """
    with database_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute(query, TABLES)
            rows = cursor.fetchall()
    if not rows:
        raise RuntimeError("No C tables were found; create the schema before exporting.")
    with output.open("w", newline="", encoding="utf-8-sig") as file:
        writer = csv.DictWriter(file, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)
    print(f"Exported {len(rows)} C columns to {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
