"""⑥ 预约、排队与到站管理的只读持久层。"""

from __future__ import annotations

from datetime import date
from typing import Any

from pymysql.connections import Connection


VALID_RESERVATION_STATUSES = frozenset(
    {"BOOKED", "CHECKED_IN", "CONSUMED", "CANCELLED", "EXPIRED", "NO_SHOW"}
)
VALID_QUEUE_STATUSES = frozenset(
    {
        "WAITING",
        "CALLED",
        "CHECKED_IN",
        "CONSUMED",
        "CANCELLED",
        "EXPIRED",
        "NO_SHOW",
    }
)

A_CORE_TABLES = (
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


def _validate_pagination(*, limit: int, offset: int) -> None:
    if not 1 <= limit <= 100:
        raise ValueError("limit 必须在 1 到 100 之间。")
    if offset < 0:
        raise ValueError("offset 不能小于 0。")


def fetch_reservation_health(connection: Connection) -> dict[str, Any]:
    """返回数据库版本、当前库和 A 模块核心表数量。"""

    placeholders = ", ".join(["%s"] * len(A_CORE_TABLES))
    sql = f"""
        SELECT
            VERSION() AS mysql_version,
            DATABASE() AS database_name,
            (
                SELECT COUNT(*)
                FROM information_schema.TABLES
                WHERE TABLE_SCHEMA = DATABASE()
                  AND TABLE_NAME IN ({placeholders})
            ) AS core_table_count
    """
    with connection.cursor() as cursor:
        cursor.execute(sql, A_CORE_TABLES)
        row = cursor.fetchone()
    if row is None:
        raise RuntimeError("数据库健康检查没有返回结果。")
    return row


def list_reservation_board(
    connection: Connection,
    *,
    station_id: int | None = None,
    status: str | None = None,
    limit: int = 20,
    offset: int = 0,
) -> list[dict[str, Any]]:
    """分页查询有效预约看板；不返回手机号或车牌敏感字段。"""

    _validate_pagination(limit=limit, offset=offset)
    if station_id is not None and station_id <= 0:
        raise ValueError("station_id 必须是正整数。")
    if status is not None and status not in VALID_RESERVATION_STATUSES:
        raise ValueError(f"不支持的预约状态：{status}")

    where_clauses: list[str] = []
    parameters: list[Any] = []
    if station_id is not None:
        where_clauses.append("station_id = %s")
        parameters.append(station_id)
    if status is not None:
        where_clauses.append("status = %s")
        parameters.append(status)

    where_sql = ""
    if where_clauses:
        where_sql = "WHERE " + " AND ".join(where_clauses)

    sql = f"""
        SELECT
            reservation_id, station_id, station_name, gun_id, gun_no,
            gun_type, parking_space_id, space_code, user_id, user_name,
            vehicle_id, vehicle_model, starts_at, ends_at,
            late_grace_minutes, latest_checkin_at, status, source, created_at
        FROM v_a_reservation_board
        {where_sql}
        ORDER BY starts_at, reservation_id
        LIMIT %s OFFSET %s
    """
    parameters.extend((limit, offset))

    with connection.cursor() as cursor:
        cursor.execute(sql, parameters)
        return list(cursor.fetchall())


def list_queue_board(
    connection: Connection,
    *,
    station_id: int | None = None,
    status: str | None = None,
    limit: int = 20,
    offset: int = 0,
) -> list[dict[str, Any]]:
    """分页查询现场排队与叫号看板。"""

    _validate_pagination(limit=limit, offset=offset)
    if station_id is not None and station_id <= 0:
        raise ValueError("station_id 必须是正整数。")
    if status is not None and status not in VALID_QUEUE_STATUSES:
        raise ValueError(f"不支持的排队状态：{status}")

    where_clauses: list[str] = []
    parameters: list[Any] = []
    if station_id is not None:
        where_clauses.append("station_id = %s")
        parameters.append(station_id)
    if status is not None:
        where_clauses.append("status = %s")
        parameters.append(status)

    where_sql = ""
    if where_clauses:
        where_sql = "WHERE " + " AND ".join(where_clauses)

    sql = f"""
        SELECT
            queue_id, station_id, station_name, gun_id, gun_no,
            ticket_no, queue_date, priority_class, priority_score,
            status, user_id, user_name, vehicle_id, vehicle_model,
            joined_at, called_at, call_expires_at,
            waited_minutes, queue_state
        FROM v_a_queue_board
        {where_sql}
        ORDER BY priority_score DESC, joined_at ASC, queue_id ASC
        LIMIT %s OFFSET %s
    """
    parameters.extend((limit, offset))

    with connection.cursor() as cursor:
        cursor.execute(sql, parameters)
        return list(cursor.fetchall())


def list_active_occupancies(
    connection: Connection,
    *,
    station_id: int | None = None,
    limit: int = 50,
) -> list[dict[str, Any]]:
    """查询当前未释放车位，按已占用时长降序。"""

    if not 1 <= limit <= 200:
        raise ValueError("limit 必须在 1 到 200 之间。")
    if station_id is not None and station_id <= 0:
        raise ValueError("station_id 必须是正整数。")

    where_sql = ""
    parameters: list[Any] = []
    if station_id is not None:
        where_sql = "WHERE station_id = %s"
        parameters.append(station_id)
    parameters.append(limit)

    sql = f"""
        SELECT
            occupancy_id, station_id, station_name, parking_space_id,
            space_code, gun_id, gun_no, user_id, user_name,
            vehicle_id, vehicle_model, reservation_id, queue_id,
            occupied_at, occupied_minutes, latest_order_id,
            latest_order_state, charging_started_at, charging_ended_at,
            occupancy_state
        FROM v_a_parking_occupancy_live
        {where_sql}
        ORDER BY occupied_minutes DESC, occupancy_id
        LIMIT %s
    """
    with connection.cursor() as cursor:
        cursor.execute(sql, parameters)
        return list(cursor.fetchall())


def list_reservation_fulfillment(
    connection: Connection,
    *,
    station_id: int | None = None,
    from_date: date | None = None,
    to_date: date | None = None,
) -> list[dict[str, Any]]:
    """查询预约履约日统计，支持场站和日期范围筛选。"""

    if station_id is not None and station_id <= 0:
        raise ValueError("station_id 必须是正整数。")
    if from_date is not None and to_date is not None and from_date > to_date:
        raise ValueError("from_date 不能晚于 to_date。")

    where_clauses: list[str] = []
    parameters: list[Any] = []
    if station_id is not None:
        where_clauses.append("station_id = %s")
        parameters.append(station_id)
    if from_date is not None:
        where_clauses.append("reservation_date >= %s")
        parameters.append(from_date)
    if to_date is not None:
        where_clauses.append("reservation_date <= %s")
        parameters.append(to_date)

    where_sql = ""
    if where_clauses:
        where_sql = "WHERE " + " AND ".join(where_clauses)

    sql = f"""
        SELECT
            station_id, station_name, reservation_date,
            total_reservations, booked_count, checked_in_count,
            consumed_count, cancelled_count, expired_count,
            no_show_count, fulfillment_rate_pct
        FROM v_a_reservation_fulfillment
        {where_sql}
        ORDER BY reservation_date, station_id
    """
    with connection.cursor() as cursor:
        cursor.execute(sql, parameters)
        return list(cursor.fetchall())


def get_reservation_detail(
    connection: Connection,
    reservation_id: int,
) -> dict[str, Any] | None:
    """查询单条预约及其车辆、枪、车位和最新状态日志。"""

    if reservation_id <= 0:
        raise ValueError("reservation_id 必须是正整数。")

    sql = """
        SELECT
            r.reservation_id,
            r.station_id,
            s.name AS station_name,
            r.gun_id,
            g.gun_no,
            g.parking_space_id,
            ps.code AS space_code,
            r.user_id,
            u.real_name AS user_name,
            r.vehicle_id,
            v.model AS vehicle_model,
            r.starts_at,
            r.ends_at,
            r.late_grace_minutes,
            r.status,
            r.source,
            r.created_at,
            r.cancelled_at,
            r.cancel_reason,
            r.consumed_at,
            r.consumed_order_id,
            (
                SELECT l.new_status
                FROM reservation_status_log AS l
                WHERE l.reservation_id = r.reservation_id
                ORDER BY l.changed_at DESC, l.log_id DESC
                LIMIT 1
            ) AS latest_log_status
        FROM charging_reservation AS r
        JOIN station AS s
            ON s.station_id = r.station_id
        JOIN charging_gun AS g
            ON g.gun_id = r.gun_id
           AND g.station_id = r.station_id
        JOIN parking_space AS ps
            ON ps.parking_space_id = g.parking_space_id
           AND ps.station_id = r.station_id
        JOIN `user` AS u
            ON u.user_id = r.user_id
        JOIN vehicle AS v
            ON v.vehicle_id = r.vehicle_id
        WHERE r.reservation_id = %s
    """
    with connection.cursor() as cursor:
        cursor.execute(sql, (reservation_id,))
        return cursor.fetchone()


def list_status_history(
    connection: Connection,
    *,
    reservation_id: int | None = None,
    queue_id: int | None = None,
    limit: int = 50,
) -> list[dict[str, Any]]:
    """查询预约或排队状态历史，二选一。"""

    if (reservation_id is None) == (queue_id is None):
        raise ValueError("reservation_id 和 queue_id 必须且只能提供一个。")
    if not 1 <= limit <= 200:
        raise ValueError("limit 必须在 1 到 200 之间。")

    if reservation_id is not None:
        if reservation_id <= 0:
            raise ValueError("reservation_id 必须是正整数。")
        sql = """
            SELECT
                'RESERVATION' AS admission_type,
                log_id, reservation_id AS admission_id,
                old_status, new_status, changed_at, change_reason
            FROM reservation_status_log
            WHERE reservation_id = %s
            ORDER BY changed_at, log_id
            LIMIT %s
        """
        parameters: tuple[Any, ...] = (reservation_id, limit)
    else:
        assert queue_id is not None
        if queue_id <= 0:
            raise ValueError("queue_id 必须是正整数。")
        sql = """
            SELECT
                'QUEUE' AS admission_type,
                log_id, queue_id AS admission_id,
                old_status, new_status, changed_at, change_reason
            FROM queue_status_log
            WHERE queue_id = %s
            ORDER BY changed_at, log_id
            LIMIT %s
        """
        parameters = (queue_id, limit)

    with connection.cursor() as cursor:
        cursor.execute(sql, parameters)
        return list(cursor.fetchall())
