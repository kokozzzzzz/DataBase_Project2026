"""④ 用户与会员运营的核心只读持久层。"""

from __future__ import annotations

from typing import Any

from pymysql.connections import Connection


VALID_USER_STATUSES = frozenset({"ACTIVE", "DISABLED", "CLOSED"})


def fetch_database_health(connection: Connection) -> dict[str, Any]:
    """返回数据库版本、当前库和核心表数量，用于连接健康检查。"""

    sql = """
        SELECT
            VERSION() AS mysql_version,
            DATABASE() AS database_name,
            (
                SELECT COUNT(*)
                FROM information_schema.TABLES
                WHERE TABLE_SCHEMA = DATABASE()
                  AND TABLE_NAME IN (
                      'membership_level', 'user', 'vehicle',
                      'membership_record', 'promotion',
                      'enterprise_customer', 'fleet',
                      'fleet_vehicle', 'fleet_quota_record'
                  )
            ) AS core_table_count
    """
    with connection.cursor() as cursor:
        cursor.execute(sql)
        row = cursor.fetchone()

    if row is None:
        raise RuntimeError("数据库健康检查没有返回结果。")
    return row


def list_user_profiles(
    connection: Connection,
    *,
    user_status: str | None = "ACTIVE",
    limit: int = 20,
    offset: int = 0,
) -> list[dict[str, Any]]:
    """分页查询用户、当前会员等级和有效车辆数。"""

    if user_status is not None and user_status not in VALID_USER_STATUSES:
        raise ValueError(f"不支持的用户状态：{user_status}")
    if not 1 <= limit <= 100:
        raise ValueError("limit 必须在 1 到 100 之间。")
    if offset < 0:
        raise ValueError("offset 不能小于 0。")

    where_clause = ""
    parameters: list[Any] = []
    if user_status is not None:
        where_clause = "WHERE u.user_status = %s"
        parameters.append(user_status)

    sql = f"""
        SELECT
            u.user_id,
            u.real_name,
            u.real_name_status,
            u.user_status,
            ml.level_code,
            ml.level_name,
            u.balance,
            COUNT(v.vehicle_id) AS active_vehicle_count
        FROM `user` AS u
        JOIN membership_level AS ml
            ON ml.level_id = u.level_id
        LEFT JOIN vehicle AS v
            ON v.user_id = u.user_id
           AND v.vehicle_status = 'ACTIVE'
        {where_clause}
        GROUP BY
            u.user_id,
            u.real_name,
            u.real_name_status,
            u.user_status,
            ml.level_code,
            ml.level_name,
            u.balance
        ORDER BY u.user_id
        LIMIT %s OFFSET %s
    """
    parameters.extend((limit, offset))

    with connection.cursor() as cursor:
        cursor.execute(sql, parameters)
        return list(cursor.fetchall())
