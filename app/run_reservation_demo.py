"""⑥业务线预约、排队与车位实时看板演示（只读）。"""

from __future__ import annotations

import sys

import pymysql

from app.database import DatabaseConfigError, database_connection
from app.database.reservation_repository import (
    fetch_reservation_health,
    list_active_occupancies,
    list_queue_board,
    list_reservation_board,
)


def main() -> int:
    """连接 charging_platform 并展示 A 模块当前看板。"""

    try:
        with database_connection() as connection:
            health = fetch_reservation_health(connection)
            reservations = list_reservation_board(connection, limit=5)
            queues = list_queue_board(connection, limit=5)
            occupancies = list_active_occupancies(connection, limit=5)
    except DatabaseConfigError as exc:
        print(f"配置错误：{exc}", file=sys.stderr)
        return 2
    except pymysql.MySQLError as exc:
        print(f"数据库错误：{exc}", file=sys.stderr)
        return 3

    print(
        "连接成功："
        f"MySQL {health['mysql_version']}，"
        f"数据库 {health['database_name']}，"
        f"⑥⑧核心表 {health['core_table_count']}/10"
    )

    print("\n有效预约看板：")
    for row in reservations:
        print(
            f"- reservation_id={row['reservation_id']}，"
            f"场站={row['station_name']}，"
            f"{row['gun_no']}号枪，"
            f"{row['starts_at']}~{row['ends_at']}，"
            f"用户={row['user_name']}，状态={row['status']}"
        )

    print("\n现场排队看板：")
    for row in queues:
        print(
            f"- queue_id={row['queue_id']}，"
            f"场站={row['station_name']}，"
            f"排队号={row['ticket_no']}，"
            f"优先级={row['priority_class']}，"
            f"等待={row['waited_minutes']}分钟，状态={row['queue_state']}"
        )

    print("\n当前车位占用：")
    for row in occupancies:
        print(
            f"- occupancy_id={row['occupancy_id']}，"
            f"车位={row['space_code']}，"
            f"用户={row['user_name']}，"
            f"占用={row['occupied_minutes']}分钟，"
            f"状态={row['occupancy_state']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
