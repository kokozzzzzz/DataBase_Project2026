"""④ 用户与会员运营的核心只读持久层。"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Any

from pymysql.connections import Connection


VALID_USER_STATUSES = frozenset({"ACTIVE", "DISABLED", "CLOSED"})


def fetch_database_health(connection: Connection) -> dict[str, Any]:
    """返回版本、当前库、会话时区和核心表数量，用于连接健康检查。"""

    sql = """
        SELECT
            VERSION() AS mysql_version,
            DATABASE() AS database_name,
            @@session.time_zone AS session_time_zone,
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
        LEFT JOIN membership_level AS ml
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


def list_available_global_promotions(
    connection: Connection,
    *,
    order_amount: Decimal,
    at_time: datetime,
) -> list[dict[str, Any]]:
    """查询指定时点和金额可用的全场活动，不读取尚未联调的场站关联表。"""

    if order_amount < 0:
        raise ValueError("order_amount 不能小于 0。")

    sql = """
        SELECT
            promotion_id,
            promotion_name,
            discount_type,
            discount_value,
            minimum_spend,
            max_discount_amount,
            valid_from,
            valid_to
        FROM promotion
        WHERE status = 'ACTIVE'
          AND applicability_scope = 'ALL'
          AND valid_from <= %s
          AND valid_to > %s
          AND minimum_spend <= %s
        ORDER BY promotion_id
    """
    parameters = (at_time, at_time, order_amount)
    with connection.cursor() as cursor:
        cursor.execute(sql, parameters)
        return list(cursor.fetchall())


def list_fleet_monthly_charging_details(
    connection: Connection,
    *,
    fleet_id: int,
    period_start: datetime,
    period_end: datetime,
    limit: int = 50,
    offset: int = 0,
) -> list[dict[str, Any]]:
    """分页查询车队账期内已出账订单及支付退款净额。"""

    _validate_positive_id(fleet_id, field_name="fleet_id")
    _validate_period(period_start=period_start, period_end=period_end)
    _validate_pagination(limit=limit, offset=offset)

    sql = """
        WITH successful_payment AS (
            SELECT
                order_id,
                SUM(amount) AS paid_amount
            FROM payment_record
            WHERE status = 'SUCCESS'
            GROUP BY order_id
        ),
        successful_refund AS (
            SELECT
                pr.order_id,
                SUM(rr.amount) AS refund_amount
            FROM refund_record AS rr
            JOIN payment_record AS pr
                ON pr.payment_id = rr.payment_id
               AND pr.status = 'SUCCESS'
            GROUP BY pr.order_id
        )
        SELECT
            ec.enterprise_id,
            ec.enterprise_name,
            f.fleet_id,
            f.fleet_name,
            o.order_id,
            o.vehicle_id,
            v.model AS vehicle_model,
            o.user_id,
            u.real_name AS vehicle_owner,
            s.station_id,
            s.name AS station_name,
            o.starts_at,
            o.ends_at,
            o.confirmed_at,
            o.total_kwh,
            o.gross_amount,
            o.discount_amount,
            o.gross_amount - o.discount_amount AS payable_amount,
            COALESCE(sp.paid_amount, 0.00) AS paid_amount,
            COALESCE(sr.refund_amount, 0.00) AS refund_amount,
            COALESCE(sp.paid_amount, 0.00)
                - COALESCE(sr.refund_amount, 0.00) AS net_paid_amount
        FROM fleet AS f
        JOIN enterprise_customer AS ec
            ON ec.enterprise_id = f.enterprise_id
        JOIN fleet_vehicle AS fv
            ON fv.fleet_id = f.fleet_id
        JOIN charging_order AS o
            ON o.vehicle_id = fv.vehicle_id
           AND o.starts_at >= fv.joined_at
           AND (fv.left_at IS NULL OR o.starts_at < fv.left_at)
        JOIN vehicle AS v
            ON v.vehicle_id = o.vehicle_id
        JOIN `user` AS u
            ON u.user_id = o.user_id
        JOIN charging_gun AS cg
            ON cg.gun_id = o.gun_id
        JOIN station AS s
            ON s.station_id = cg.station_id
        LEFT JOIN successful_payment AS sp
            ON sp.order_id = o.order_id
        LEFT JOIN successful_refund AS sr
            ON sr.order_id = o.order_id
        WHERE f.fleet_id = %s
          AND o.state = 'BILLED'
          AND o.confirmed_at >= %s
          AND o.confirmed_at < %s
        ORDER BY o.confirmed_at, o.order_id
        LIMIT %s OFFSET %s
    """
    parameters = (fleet_id, period_start, period_end, limit, offset)
    with connection.cursor() as cursor:
        cursor.execute(sql, parameters)
        return list(cursor.fetchall())


def fetch_fleet_monthly_bill_summary(
    connection: Connection,
    *,
    fleet_id: int,
    period_start: datetime,
    period_end: datetime,
) -> dict[str, Any]:
    """动态汇总车队账期内的电量、订单金额、支付与退款。"""

    _validate_positive_id(fleet_id, field_name="fleet_id")
    _validate_period(period_start=period_start, period_end=period_end)

    sql = """
        WITH successful_payment AS (
            SELECT
                order_id,
                SUM(amount) AS paid_amount
            FROM payment_record
            WHERE status = 'SUCCESS'
            GROUP BY order_id
        ),
        successful_refund AS (
            SELECT
                pr.order_id,
                SUM(rr.amount) AS refund_amount
            FROM refund_record AS rr
            JOIN payment_record AS pr
                ON pr.payment_id = rr.payment_id
               AND pr.status = 'SUCCESS'
            GROUP BY pr.order_id
        )
        SELECT
            ec.enterprise_id,
            ec.enterprise_name,
            f.fleet_id,
            f.fleet_name,
            %s AS period_start,
            %s AS period_end,
            COUNT(o.order_id) AS order_count,
            COUNT(DISTINCT o.vehicle_id) AS vehicle_count,
            COALESCE(SUM(o.total_kwh), 0.000) AS total_kwh,
            COALESCE(SUM(o.gross_amount), 0.00) AS gross_amount,
            COALESCE(SUM(o.discount_amount), 0.00) AS discount_amount,
            COALESCE(SUM(o.gross_amount - o.discount_amount), 0.00)
                AS payable_amount,
            COALESCE(SUM(sp.paid_amount), 0.00) AS paid_amount,
            COALESCE(SUM(sr.refund_amount), 0.00) AS refund_amount,
            COALESCE(SUM(sp.paid_amount), 0.00)
                - COALESCE(SUM(sr.refund_amount), 0.00) AS net_paid_amount
        FROM fleet AS f
        JOIN enterprise_customer AS ec
            ON ec.enterprise_id = f.enterprise_id
        LEFT JOIN fleet_vehicle AS fv
            ON fv.fleet_id = f.fleet_id
        LEFT JOIN charging_order AS o
            ON o.vehicle_id = fv.vehicle_id
           AND o.starts_at >= fv.joined_at
           AND (fv.left_at IS NULL OR o.starts_at < fv.left_at)
           AND o.state = 'BILLED'
           AND o.confirmed_at >= %s
           AND o.confirmed_at < %s
        LEFT JOIN successful_payment AS sp
            ON sp.order_id = o.order_id
        LEFT JOIN successful_refund AS sr
            ON sr.order_id = o.order_id
        WHERE f.fleet_id = %s
        GROUP BY
            ec.enterprise_id,
            ec.enterprise_name,
            f.fleet_id,
            f.fleet_name
    """
    parameters = (
        period_start,
        period_end,
        period_start,
        period_end,
        fleet_id,
    )
    with connection.cursor() as cursor:
        cursor.execute(sql, parameters)
        row = cursor.fetchone()

    if row is None:
        raise ValueError(f"车队 {fleet_id} 不存在。")
    return row


def fetch_quota_usage(
    connection: Connection,
    *,
    quota_record_id: int,
) -> dict[str, Any]:
    """按额度记录的范围和周期计算金额、电量或订单次数使用量。"""

    _validate_positive_id(quota_record_id, field_name="quota_record_id")

    sql = """
        WITH selected_quota AS (
            SELECT
                quota_record_id,
                quota_scope,
                enterprise_id,
                fleet_id,
                vehicle_id,
                quota_type,
                quota_limit,
                period_start,
                period_end
            FROM fleet_quota_record
            WHERE quota_record_id = %s
        ),
        quota_orders AS (
            SELECT o.order_id, o.vehicle_id, o.total_kwh,
                   o.gross_amount - o.discount_amount AS payable_amount
            FROM selected_quota AS q
            JOIN charging_order AS o
                ON q.quota_scope = 'VEHICLE'
               AND o.vehicle_id = q.vehicle_id
               AND o.state = 'BILLED'
               AND o.confirmed_at >= q.period_start
               AND o.confirmed_at < q.period_end
            UNION ALL
            SELECT o.order_id, o.vehicle_id, o.total_kwh,
                   o.gross_amount - o.discount_amount AS payable_amount
            FROM selected_quota AS q
            JOIN fleet_vehicle AS fv
                ON q.quota_scope = 'FLEET'
               AND fv.fleet_id = q.fleet_id
            JOIN charging_order AS o
                ON o.vehicle_id = fv.vehicle_id
               AND o.starts_at >= fv.joined_at
               AND (fv.left_at IS NULL OR o.starts_at < fv.left_at)
               AND o.state = 'BILLED'
               AND o.confirmed_at >= q.period_start
               AND o.confirmed_at < q.period_end
            UNION ALL
            SELECT o.order_id, o.vehicle_id, o.total_kwh,
                   o.gross_amount - o.discount_amount AS payable_amount
            FROM selected_quota AS q
            JOIN fleet AS f
                ON q.quota_scope = 'ENTERPRISE'
               AND f.enterprise_id = q.enterprise_id
            JOIN fleet_vehicle AS fv
                ON fv.fleet_id = f.fleet_id
            JOIN charging_order AS o
                ON o.vehicle_id = fv.vehicle_id
               AND o.starts_at >= fv.joined_at
               AND (fv.left_at IS NULL OR o.starts_at < fv.left_at)
               AND o.state = 'BILLED'
               AND o.confirmed_at >= q.period_start
               AND o.confirmed_at < q.period_end
        ),
        aggregated_usage AS (
            SELECT
                COUNT(*) AS order_count,
                COALESCE(SUM(total_kwh), 0.000) AS energy_used,
                COALESCE(SUM(payable_amount), 0.00) AS amount_used
            FROM quota_orders
        )
        SELECT
            q.quota_record_id,
            q.quota_scope,
            q.enterprise_id,
            q.fleet_id,
            q.vehicle_id,
            q.quota_type,
            q.quota_limit,
            q.period_start,
            q.period_end,
            CASE q.quota_type
                WHEN 'AMOUNT' THEN au.amount_used
                WHEN 'ENERGY' THEN au.energy_used
                WHEN 'ORDER_COUNT' THEN au.order_count
            END AS used_value,
            GREATEST(
                q.quota_limit - CASE q.quota_type
                    WHEN 'AMOUNT' THEN au.amount_used
                    WHEN 'ENERGY' THEN au.energy_used
                    WHEN 'ORDER_COUNT' THEN au.order_count
                END,
                0
            ) AS remaining_value,
            GREATEST(
                CASE q.quota_type
                    WHEN 'AMOUNT' THEN au.amount_used
                    WHEN 'ENERGY' THEN au.energy_used
                    WHEN 'ORDER_COUNT' THEN au.order_count
                END - q.quota_limit,
                0
            ) AS exceeded_value,
            CASE
                WHEN CASE q.quota_type
                    WHEN 'AMOUNT' THEN au.amount_used
                    WHEN 'ENERGY' THEN au.energy_used
                    WHEN 'ORDER_COUNT' THEN au.order_count
                END > q.quota_limit
                THEN 'EXCEEDED'
                ELSE 'WITHIN_LIMIT'
            END AS quota_status
        FROM selected_quota AS q
        CROSS JOIN aggregated_usage AS au
    """
    with connection.cursor() as cursor:
        cursor.execute(sql, (quota_record_id,))
        row = cursor.fetchone()

    if row is None:
        raise ValueError(f"额度记录 {quota_record_id} 不存在。")
    return row


def _validate_positive_id(value: int, *, field_name: str) -> None:
    if value <= 0:
        raise ValueError(f"{field_name} 必须是正整数。")


def _validate_period(*, period_start: datetime, period_end: datetime) -> None:
    if period_start >= period_end:
        raise ValueError("period_start 必须早于 period_end。")


def _validate_pagination(*, limit: int, offset: int) -> None:
    if not 1 <= limit <= 100:
        raise ValueError("limit 必须在 1 到 100 之间。")
    if offset < 0:
        raise ValueError("offset 不能小于 0。")
