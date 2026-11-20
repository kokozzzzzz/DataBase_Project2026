"""⑧ 场站服务公告与通知的只读持久层。"""

from __future__ import annotations

from typing import Any

from pymysql.connections import Connection


def fetch_notice_health(connection: Connection) -> dict[str, Any]:
    """返回数据库版本、当前库和 A 模块公告相关表数量。"""

    sql = """
        SELECT
            VERSION() AS mysql_version,
            DATABASE() AS database_name,
            (
                SELECT COUNT(*)
                FROM information_schema.TABLES
                WHERE TABLE_SCHEMA = DATABASE()
                  AND TABLE_NAME IN (
                      'station_notice', 'notice_revision',
                      'notice_recipient', 'notification_record'
                  )
            ) AS notice_table_count
    """
    with connection.cursor() as cursor:
        cursor.execute(sql)
        row = cursor.fetchone()
    if row is None:
        raise RuntimeError("数据库健康检查没有返回结果。")
    return row


def list_public_notices(
    connection: Connection,
    *,
    station_id: int | None = None,
    severity: str | None = None,
    limit: int = 20,
    offset: int = 0,
) -> list[dict[str, Any]]:
    """分页查询当前有效公开公告。"""

    if not 1 <= limit <= 100:
        raise ValueError("limit 必须在 1 到 100 之间。")
    if offset < 0:
        raise ValueError("offset 不能小于 0。")
    if station_id is not None and station_id <= 0:
        raise ValueError("station_id 必须是正整数。")
    if severity is not None and severity not in {"INFO", "WARNING", "EMERGENCY"}:
        raise ValueError(f"不支持的公告级别：{severity}")

    where_clauses: list[str] = []
    parameters: list[Any] = []
    if station_id is not None:
        where_clauses.append("station_id = %s")
        parameters.append(station_id)
    if severity is not None:
        where_clauses.append("severity = %s")
        parameters.append(severity)

    where_sql = ""
    if where_clauses:
        where_sql = "WHERE " + " AND ".join(where_clauses)
    parameters.extend((limit, offset))

    sql = f"""
        SELECT
            notice_id, station_id, station_name, severity, title,
            content, effective_from, effective_to, published_at
        FROM v_a_public_notice_active
        {where_sql}
        ORDER BY severity DESC, published_at DESC, notice_id DESC
        LIMIT %s OFFSET %s
    """
    with connection.cursor() as cursor:
        cursor.execute(sql, parameters)
        return list(cursor.fetchall())


def list_notice_delivery_stats(
    connection: Connection,
    *,
    notice_id: int | None = None,
    station_id: int | None = None,
    limit: int = 50,
) -> list[dict[str, Any]]:
    """查询公告接收与送达统计。"""

    if not 1 <= limit <= 200:
        raise ValueError("limit 必须在 1 到 200 之间。")
    if notice_id is not None and notice_id <= 0:
        raise ValueError("notice_id 必须是正整数。")
    if station_id is not None and station_id <= 0:
        raise ValueError("station_id 必须是正整数。")

    where_clauses: list[str] = []
    parameters: list[Any] = []
    if notice_id is not None:
        where_clauses.append("notice_id = %s")
        parameters.append(notice_id)
    if station_id is not None:
        where_clauses.append("station_id = %s")
        parameters.append(station_id)

    where_sql = ""
    if where_clauses:
        where_sql = "WHERE " + " AND ".join(where_clauses)
    parameters.append(limit)

    sql = f"""
        SELECT
            notice_id, station_id, station_name, notice_type, severity,
            notice_status, title, recipient_count, notification_count,
            sent_count, read_count, failed_count,
            delivery_rate_pct, read_rate_pct
        FROM v_a_notice_delivery_stats
        {where_sql}
        ORDER BY notice_id DESC
        LIMIT %s
    """
    with connection.cursor() as cursor:
        cursor.execute(sql, parameters)
        return list(cursor.fetchall())


def list_outage_affected_users(
    connection: Connection,
    *,
    notice_id: int | None = None,
    station_id: int | None = None,
    limit: int = 100,
) -> list[dict[str, Any]]:
    """查询定向停运公告的受影响用户和预约/排队资格。"""

    if not 1 <= limit <= 500:
        raise ValueError("limit 必须在 1 到 500 之间。")
    if notice_id is not None and notice_id <= 0:
        raise ValueError("notice_id 必须是正整数。")
    if station_id is not None and station_id <= 0:
        raise ValueError("station_id 必须是正整数。")

    where_clauses: list[str] = []
    parameters: list[Any] = []
    if notice_id is not None:
        where_clauses.append("notice_id = %s")
        parameters.append(notice_id)
    if station_id is not None:
        where_clauses.append("station_id = %s")
        parameters.append(station_id)

    where_sql = ""
    if where_clauses:
        where_sql = "WHERE " + " AND ".join(where_clauses)
    parameters.append(limit)

    sql = f"""
        SELECT
            notice_id, title, notice_status, station_id, station_name,
            related_outage_plan_id, outage_starts_at, outage_ends_at,
            recipient_id, recipient_reason, user_id, user_name,
            vehicle_id, vehicle_model, reservation_id,
            reservation_starts_at, reservation_ends_at, reservation_status,
            queue_id, ticket_no, queue_status
        FROM v_a_outage_affected_users
        {where_sql}
        ORDER BY notice_id, recipient_id
        LIMIT %s
    """
    with connection.cursor() as cursor:
        cursor.execute(sql, parameters)
        return list(cursor.fetchall())


def get_notice_detail(
    connection: Connection,
    notice_id: int,
) -> dict[str, Any] | None:
    """查询单条公告、接收人数和最新版本号。"""

    if notice_id <= 0:
        raise ValueError("notice_id 必须是正整数。")

    sql = """
        SELECT
            n.notice_id,
            n.station_id,
            s.name AS station_name,
            n.notice_type,
            n.severity,
            n.title,
            n.content,
            n.status,
            n.effective_from,
            n.effective_to,
            n.published_at,
            n.withdrawn_at,
            n.withdraw_reason,
            n.created_by,
            n.updated_by,
            n.related_outage_plan_id,
            (
                SELECT COUNT(*)
                FROM notice_recipient AS nr
                WHERE nr.notice_id = n.notice_id
            ) AS recipient_count,
            (
                SELECT COALESCE(MAX(rev.revision_no), 0)
                FROM notice_revision AS rev
                WHERE rev.notice_id = n.notice_id
            ) AS latest_revision_no
        FROM station_notice AS n
        JOIN station AS s
            ON s.station_id = n.station_id
        WHERE n.notice_id = %s
    """
    with connection.cursor() as cursor:
        cursor.execute(sql, (notice_id,))
        return cursor.fetchone()


def list_notice_revision_history(
    connection: Connection,
    notice_id: int,
) -> list[dict[str, Any]]:
    """查询公告版本历史。"""

    if notice_id <= 0:
        raise ValueError("notice_id 必须是正整数。")

    sql = """
        SELECT
            revision_id, notice_id, station_id, station_name,
            notice_type, revision_no, action, title, content,
            changed_at, changed_by
        FROM v_a_notice_revision_history
        WHERE notice_id = %s
        ORDER BY revision_no
    """
    with connection.cursor() as cursor:
        cursor.execute(sql, (notice_id,))
        return list(cursor.fetchall())


def list_pending_notifications(
    connection: Connection,
    *,
    notice_id: int | None = None,
    limit: int = 100,
) -> list[dict[str, Any]]:
    """查询待发送通知，供通知渠道轮询。"""

    if not 1 <= limit <= 500:
        raise ValueError("limit 必须在 1 到 500 之间。")
    if notice_id is not None and notice_id <= 0:
        raise ValueError("notice_id 必须是正整数。")

    where_clauses = ["nf.status = 'PENDING'"]
    parameters: list[Any] = []
    if notice_id is not None:
        where_clauses.append("nr.notice_id = %s")
        parameters.append(notice_id)
    parameters.append(limit)

    sql = f"""
        SELECT
            nf.notification_id,
            nf.recipient_id,
            nf.channel,
            nf.status,
            nf.retry_count,
            nr.notice_id,
            nr.user_id,
            n.notice_type,
            n.severity,
            n.title
        FROM notification_record AS nf
        JOIN notice_recipient AS nr
            ON nr.recipient_id = nf.recipient_id
        JOIN station_notice AS n
            ON n.notice_id = nr.notice_id
        WHERE {" AND ".join(where_clauses)}
        ORDER BY nf.created_at, nf.notification_id
        LIMIT %s
    """
    with connection.cursor() as cursor:
        cursor.execute(sql, parameters)
        return list(cursor.fetchall())
