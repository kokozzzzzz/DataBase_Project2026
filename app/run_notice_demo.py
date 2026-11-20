"""⑧业务线公告、定向通知与送达统计演示（只读）。"""

from __future__ import annotations

import sys

import pymysql

from app.database import DatabaseConfigError, database_connection
from app.database.notice_repository import (
    fetch_notice_health,
    list_notice_delivery_stats,
    list_outage_affected_users,
    list_public_notices,
)


def main() -> int:
    """连接 charging_platform 并展示公告与通知看板。"""

    try:
        with database_connection() as connection:
            health = fetch_notice_health(connection)
            public_notices = list_public_notices(connection, limit=5)
            delivery_stats = list_notice_delivery_stats(connection, limit=5)
            affected_users = list_outage_affected_users(connection, limit=5)
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
        f"公告相关表 {health['notice_table_count']}/4"
    )

    print("\n当前有效公开公告：")
    for row in public_notices:
        print(
            f"- notice_id={row['notice_id']}，"
            f"场站={row['station_name']}，"
            f"级别={row['severity']}，"
            f"标题={row['title']}"
        )

    print("\n公告送达统计：")
    for row in delivery_stats:
        delivery_rate = (
            "N/A"
            if row["delivery_rate_pct"] is None
            else f"{row['delivery_rate_pct']}%"
        )
        read_rate = (
            "N/A"
            if row["read_rate_pct"] is None
            else f"{row['read_rate_pct']}%"
        )
        print(
            f"- notice_id={row['notice_id']}，"
            f"类型={row['notice_type']}，"
            f"接收={row['recipient_count']}，"
            f"送达率={delivery_rate}，"
            f"阅读率={read_rate}"
        )

    print("\n停运公告受影响用户：")
    for row in affected_users:
        print(
            f"- notice_id={row['notice_id']}，"
            f"用户={row['user_name']}，"
            f"预约={row['reservation_id']}，"
            f"预约状态={row['reservation_status']}，"
            f"原因={row['recipient_reason']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
