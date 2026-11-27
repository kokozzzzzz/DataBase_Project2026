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


def list_user_vehicles(
    connection: Connection,
    *,
    user_id: int,
    vehicle_status: str | None = "ACTIVE",
    limit: int = 20,
    offset: int = 0,
) -> list[dict[str, Any]]:
    """分页查询用户车辆；不返回车牌密文或摘要。"""

    _validate_positive_id(user_id, field_name="user_id")
    if vehicle_status is not None and vehicle_status not in {"ACTIVE", "DISABLED"}:
        raise ValueError(f"不支持的车辆状态：{vehicle_status}")
    _validate_pagination(limit=limit, offset=offset)

    status_filter = ""
    parameters: list[Any] = [user_id]
    if vehicle_status is not None:
        status_filter = "AND v.vehicle_status = %s"
        parameters.append(vehicle_status)

    sql = f"""
        SELECT
            v.vehicle_id,
            v.user_id,
            v.model,
            v.battery_capacity_kwh,
            v.max_charging_power_kw,
            v.fast_charge_supported,
            v.vehicle_status,
            v.created_at,
            v.updated_at
        FROM vehicle AS v
        WHERE v.user_id = %s
          {status_filter}
        ORDER BY v.vehicle_id
        LIMIT %s OFFSET %s
    """
    parameters.extend((limit, offset))
    with connection.cursor() as cursor:
        cursor.execute(sql, parameters)
        return list(cursor.fetchall())


def list_target_users(
    connection: Connection,
    *,
    level_id: int | None = None,
    registered_start: datetime | None = None,
    registered_end: datetime | None = None,
    require_verified: bool = True,
    limit: int = 100,
    offset: int = 0,
) -> list[dict[str, Any]]:
    """按会员等级和注册时段筛选定向发券用户。"""

    if level_id is not None:
        _validate_positive_id(level_id, field_name="level_id")
    if registered_start is not None and registered_end is not None:
        _validate_period(
            period_start=registered_start,
            period_end=registered_end,
        )
    _validate_pagination(limit=limit, offset=offset)

    conditions = ["u.user_status = 'ACTIVE'"]
    parameters: list[Any] = []
    if require_verified:
        conditions.append("u.real_name_status = 'VERIFIED'")
    if level_id is not None:
        conditions.append("u.level_id = %s")
        parameters.append(level_id)
    if registered_start is not None:
        conditions.append("u.registered_at >= %s")
        parameters.append(registered_start)
    if registered_end is not None:
        conditions.append("u.registered_at < %s")
        parameters.append(registered_end)

    sql = f"""
        SELECT
            u.user_id,
            u.real_name,
            u.real_name_status,
            u.registered_at,
            u.level_id,
            ml.level_code,
            ml.level_name
        FROM `user` AS u
        LEFT JOIN membership_level AS ml
            ON ml.level_id = u.level_id
        WHERE {' AND '.join(conditions)}
        ORDER BY u.registered_at, u.user_id
        LIMIT %s OFFSET %s
    """
    parameters.extend((limit, offset))
    with connection.cursor() as cursor:
        cursor.execute(sql, parameters)
        return list(cursor.fetchall())


def fetch_promotion_redemption_statistics(
    connection: Connection,
    *,
    promotion_id: int,
) -> dict[str, Any]:
    """统计活动发券量、核销量、核销率和实际优惠金额。"""

    _validate_positive_id(promotion_id, field_name="promotion_id")
    sql = """
        SELECT
            p.promotion_id,
            p.promotion_name,
            COUNT(DISTINCT c.coupon_id) AS issued_count,
            COUNT(DISTINCT cr.redemption_id) AS redeemed_count,
            CASE
                WHEN COUNT(DISTINCT c.coupon_id) = 0 THEN 0.0000
                ELSE ROUND(
                    COUNT(DISTINCT cr.redemption_id)
                    / COUNT(DISTINCT c.coupon_id),
                    4
                )
            END AS redemption_rate,
            COALESCE(SUM(cr.discount_amount), 0.00) AS total_discount_amount
        FROM promotion AS p
        LEFT JOIN coupon AS c
            ON c.promotion_id = p.promotion_id
        LEFT JOIN coupon_redemption AS cr
            ON cr.coupon_id = c.coupon_id
        WHERE p.promotion_id = %s
        GROUP BY p.promotion_id, p.promotion_name
    """
    with connection.cursor() as cursor:
        cursor.execute(sql, (promotion_id,))
        row = cursor.fetchone()

    if row is None:
        raise ValueError(f"优惠活动 {promotion_id} 不存在。")
    return row


def list_user_charging_history(
    connection: Connection,
    *,
    user_id: int,
    period_start: datetime,
    period_end: datetime,
    limit: int = 50,
    offset: int = 0,
) -> list[dict[str, Any]]:
    """分页查询用户充电、支付、退款和优惠券核销历史。"""

    _validate_positive_id(user_id, field_name="user_id")
    _validate_period(period_start=period_start, period_end=period_end)
    _validate_pagination(limit=limit, offset=offset)
    sql = """
        WITH successful_payment AS (
            SELECT order_id, SUM(amount) AS paid_amount
            FROM payment_record
            WHERE status = 'SUCCESS'
            GROUP BY order_id
        ),
        successful_refund AS (
            SELECT pr.order_id, SUM(rr.amount) AS refund_amount
            FROM refund_record AS rr
            JOIN payment_record AS pr
              ON pr.payment_id = rr.payment_id
             AND pr.status = 'SUCCESS'
            GROUP BY pr.order_id
        )
        SELECT
            o.order_id,
            o.vehicle_id,
            v.model AS vehicle_model,
            s.station_id,
            s.name AS station_name,
            o.starts_at,
            o.ends_at,
            o.state,
            o.total_kwh,
            o.gross_amount,
            o.discount_amount,
            o.gross_amount - o.discount_amount AS payable_amount,
            COALESCE(sp.paid_amount, 0.00) AS paid_amount,
            COALESCE(sr.refund_amount, 0.00) AS refund_amount,
            COALESCE(sp.paid_amount, 0.00)
                - COALESCE(sr.refund_amount, 0.00) AS net_paid_amount,
            c.coupon_id,
            c.coupon_code,
            cr.redeemed_at AS coupon_redeemed_at
        FROM charging_order AS o
        JOIN vehicle AS v
          ON v.vehicle_id = o.vehicle_id
         AND v.user_id = o.user_id
        JOIN charging_gun AS cg
          ON cg.gun_id = o.gun_id
        JOIN station AS s
          ON s.station_id = cg.station_id
        LEFT JOIN successful_payment AS sp
          ON sp.order_id = o.order_id
        LEFT JOIN successful_refund AS sr
          ON sr.order_id = o.order_id
        LEFT JOIN coupon_redemption AS cr
          ON cr.order_id = o.order_id
        LEFT JOIN coupon AS c
          ON c.coupon_id = cr.coupon_id
        WHERE o.user_id = %s
          AND o.starts_at >= %s
          AND o.starts_at < %s
        ORDER BY o.starts_at DESC, o.order_id DESC
        LIMIT %s OFFSET %s
    """
    parameters = (user_id, period_start, period_end, limit, offset)
    with connection.cursor() as cursor:
        cursor.execute(sql, parameters)
        return list(cursor.fetchall())


def fetch_user_account_overview(
    connection: Connection,
    *,
    user_id: int,
) -> dict[str, Any]:
    """返回当前账户余额和累计充电资金概览，不冒充余额流水。"""

    _validate_positive_id(user_id, field_name="user_id")
    sql = """
        WITH order_funds AS (
            SELECT
                o.order_id,
                o.user_id,
                o.total_kwh,
                o.gross_amount,
                o.discount_amount,
                COALESCE(SUM(
                    CASE WHEN pr.status = 'SUCCESS' THEN pr.amount ELSE 0 END
                ), 0.00) AS paid_amount
            FROM charging_order AS o
            LEFT JOIN payment_record AS pr
              ON pr.order_id = o.order_id
            WHERE o.user_id = %s
              AND o.state = 'BILLED'
            GROUP BY
                o.order_id,
                o.user_id,
                o.total_kwh,
                o.gross_amount,
                o.discount_amount
        ),
        order_refunds AS (
            SELECT pr.order_id, SUM(rr.amount) AS refund_amount
            FROM refund_record AS rr
            JOIN payment_record AS pr
              ON pr.payment_id = rr.payment_id
             AND pr.status = 'SUCCESS'
            JOIN charging_order AS o
              ON o.order_id = pr.order_id
            WHERE o.user_id = %s
            GROUP BY pr.order_id
        )
        SELECT
            u.user_id,
            u.real_name,
            u.user_status,
            u.balance AS current_balance,
            COUNT(ofu.order_id) AS billed_order_count,
            COALESCE(SUM(ofu.total_kwh), 0.000) AS total_kwh,
            COALESCE(SUM(ofu.gross_amount), 0.00) AS gross_amount,
            COALESCE(SUM(ofu.discount_amount), 0.00) AS discount_amount,
            COALESCE(SUM(ofu.paid_amount), 0.00) AS paid_amount,
            COALESCE(SUM(orf.refund_amount), 0.00) AS refund_amount,
            COALESCE(SUM(ofu.paid_amount), 0.00)
                - COALESCE(SUM(orf.refund_amount), 0.00) AS net_paid_amount
        FROM `user` AS u
        LEFT JOIN order_funds AS ofu
          ON ofu.user_id = u.user_id
        LEFT JOIN order_refunds AS orf
          ON orf.order_id = ofu.order_id
        WHERE u.user_id = %s
        GROUP BY
            u.user_id,
            u.real_name,
            u.user_status,
            u.balance
    """
    with connection.cursor() as cursor:
        cursor.execute(sql, (user_id, user_id, user_id))
        row = cursor.fetchone()
    if row is None:
        raise ValueError(f"用户 {user_id} 不存在。")
    return row


def list_user_order_invoice_trace(
    connection: Connection,
    *,
    user_id: int,
    limit: int = 50,
    offset: int = 0,
) -> list[dict[str, Any]]:
    """查询用户订单进入运营商结算及开票的追溯关系。"""

    _validate_positive_id(user_id, field_name="user_id")
    _validate_pagination(limit=limit, offset=offset)
    sql = """
        SELECT
            o.order_id,
            o.starts_at,
            o.total_kwh,
            sd.settlement_detail_id,
            ss.settlement_id,
            ss.statement_no,
            ss.period_start,
            ss.period_end,
            ss.status AS settlement_status,
            sd.payable_amount AS order_settlement_amount,
            ir.invoice_id,
            ir.invoice_number,
            ir.invoice_type,
            ir.invoice_amount,
            ir.status AS invoice_status,
            ir.issued_at
        FROM charging_order AS o
        LEFT JOIN settlement_detail AS sd
          ON sd.order_id = o.order_id
         AND sd.detail_type = 'ORDER'
        LEFT JOIN settlement_statement AS ss
          ON ss.settlement_id = sd.settlement_id
        LEFT JOIN invoice_record AS ir
          ON ir.settlement_id = ss.settlement_id
        WHERE o.user_id = %s
        ORDER BY o.starts_at DESC, o.order_id DESC, ir.invoice_id
        LIMIT %s OFFSET %s
    """
    with connection.cursor() as cursor:
        cursor.execute(sql, (user_id, limit, offset))
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
