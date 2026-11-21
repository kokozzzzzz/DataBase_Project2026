"""④业务线数据库连接与只读持久层演示入口。"""

from __future__ import annotations

import sys

import pymysql

from app.database import DatabaseConfigError, database_connection
from app.database.membership_repository import (
    fetch_database_health,
    list_user_profiles,
)


def main() -> int:
    """连接 charging_platform 并展示前五名有效用户。"""

    try:
        with database_connection() as connection:
            health = fetch_database_health(connection)
            profiles = list_user_profiles(connection, limit=5)
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
        f"会话时区 {health['session_time_zone']}，"
        f"④核心表 {health['core_table_count']}/9"
    )
    print("前 5 名有效用户：")
    for profile in profiles:
        print(
            f"- user_id={profile['user_id']}，"
            f"姓名={profile['real_name']}，"
            f"等级={profile['level_name']}，"
            f"余额={profile['balance']}，"
            f"有效车辆={profile['active_vehicle_count']}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
