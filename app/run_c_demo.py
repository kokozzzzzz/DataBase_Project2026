"""Read-only overview for C's alarm, work-order and inventory boards."""

from __future__ import annotations

from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from app.database.connection import database_connection
from app.database.c_repository import list_alarms, list_available_inventory, list_work_orders


def main() -> int:
    with database_connection() as connection:
        alarms = list_alarms(connection, alarm_status="OPEN", limit=10)
        work_orders = list_work_orders(connection, limit=10)
        inventory = list_available_inventory(connection, limit=10)

    print(f"open alarms: {len(alarms)}")
    for alarm in alarms:
        print(
            f"alarm={alarm['alarm_id']} pile={alarm['pile_id']} "
            f"code={alarm['alarm_code']} level={alarm['alarm_level']}"
        )
    print(f"recent work orders: {len(work_orders)}")
    for work_order in work_orders:
        print(
            f"work_order={work_order['work_order_no']} "
            f"status={work_order['work_order_status']} station={work_order['station_name']}"
        )
    print(f"inventory rows: {len(inventory)}")
    for row in inventory:
        print(
            f"warehouse={row['warehouse_code']} part={row['part_code']} "
            f"available={row['available_quantity']} {row['unit']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
