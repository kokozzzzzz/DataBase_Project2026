"""⑤ 结算与对账的只读持久层。"""

from __future__ import annotations

from typing import Any

from pymysql.connections import Connection


VALID_SETTLEMENT_STATUSES = frozenset(
    {"DRAFT", "GENERATED", "CONFIRMED", "PAID", "VOID"}
)
VALID_RECONCILIATION_ACTIONS = frozenset(
    {"WAIT_PLATFORM", "WAIT_OPERATOR", "REVIEW_REJECTION", "CREATE_ADJUSTMENT", "SYNC_STATUS"}
)


def list_settlement_summaries(
    connection: Connection,
    *,
    operator_id: int | None = None,
    station_id: int | None = None,
    status: str | None = None,
    limit: int = 50,
    offset: int = 0,
) -> list[dict[str, Any]]:
    """分页读取结算汇总视图，不暴露发票税号等敏感字段。"""

    _validate_optional_id("operator_id", operator_id)
    _validate_optional_id("station_id", station_id)
    if status is not None and status not in VALID_SETTLEMENT_STATUSES:
        raise ValueError(f"不支持的结算状态：{status}")
    _validate_page(limit=limit, offset=offset)

    conditions: list[str] = []
    parameters: list[Any] = []
    if operator_id is not None:
        conditions.append("operator_id = %s")
        parameters.append(operator_id)
    if station_id is not None:
        conditions.append("station_id = %s")
        parameters.append(station_id)
    if status is not None:
        conditions.append("status = %s")
        parameters.append(status)

    where_clause = f"WHERE {' AND '.join(conditions)}" if conditions else ""
    sql = f"""
        SELECT
            settlement_id,
            statement_no,
            operator_id,
            operator_name,
            station_id,
            station_name,
            period_start,
            period_end,
            status,
            total_kwh,
            total_refund_amount,
            total_adjustment_amount,
            payable_amount,
            difference_count,
            unresolved_difference_count,
            net_invoice_amount,
            invoice_available_amount,
            generated_at,
            confirmed_at,
            paid_at
        FROM v_settlement_statement_summary
        {where_clause}
        ORDER BY period_start DESC, settlement_id DESC
        LIMIT %s OFFSET %s
    """
    parameters.extend((limit, offset))

    with connection.cursor() as cursor:
        cursor.execute(sql, parameters)
        return list(cursor.fetchall())


def list_pending_reconciliation(
    connection: Connection,
    *,
    operator_id: int | None = None,
    next_action: str | None = None,
    limit: int = 50,
    offset: int = 0,
) -> list[dict[str, Any]]:
    """分页读取未解决差异及双方最新结论，不返回确认人姓名。"""

    _validate_optional_id("operator_id", operator_id)
    if next_action is not None and next_action not in VALID_RECONCILIATION_ACTIONS:
        raise ValueError(f"不支持的下一步动作：{next_action}")
    _validate_page(limit=limit, offset=offset)

    conditions: list[str] = []
    parameters: list[Any] = []
    if operator_id is not None:
        conditions.append("operator_id = %s")
        parameters.append(operator_id)
    if next_action is not None:
        conditions.append("next_action = %s")
        parameters.append(next_action)

    where_clause = f"WHERE {' AND '.join(conditions)}" if conditions else ""
    sql = f"""
        SELECT
            difference_id,
            settlement_id,
            statement_no,
            operator_id,
            station_id,
            period_start,
            period_end,
            order_id,
            difference_type,
            expected_value,
            actual_value,
            difference_value,
            difference_unit,
            description,
            difference_status,
            resolution,
            discovered_at,
            platform_result,
            platform_confirmed_at,
            operator_result,
            operator_confirmed_at,
            both_agreed,
            next_action
        FROM v_reconciliation_pending
        {where_clause}
        ORDER BY discovered_at, difference_id
        LIMIT %s OFFSET %s
    """
    parameters.extend((limit, offset))

    with connection.cursor() as cursor:
        cursor.execute(sql, parameters)
        return list(cursor.fetchall())


def _validate_optional_id(field_name: str, value: int | None) -> None:
    if value is not None and value <= 0:
        raise ValueError(f"{field_name} 必须是正整数。")


def _validate_page(*, limit: int, offset: int) -> None:
    if not 1 <= limit <= 100:
        raise ValueError("limit 必须在 1 到 100 之间。")
    if offset < 0:
        raise ValueError("offset 不能小于 0。")
