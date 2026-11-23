"""⑤ 对账确认与跨期调整事务服务。"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal, InvalidOperation
from typing import Any

from pymysql.connections import Connection


MONEY_UNIT = Decimal("0.01")
VALID_CONFIRMING_PARTIES = frozenset({"PLATFORM", "OPERATOR"})
VALID_CONFIRMATION_RESULTS = frozenset({"AGREE", "REJECT"})


class SettlementOperationError(ValueError):
    """结算或对账操作不满足业务规则。"""


def confirm_reconciliation_difference(
    connection: Connection,
    *,
    difference_id: int,
    confirming_party: str,
    confirmation_result: str,
    confirmer_name: str,
    confirmation_note: str | None = None,
    confirmed_at: datetime | None = None,
) -> dict[str, Any]:
    """追加一方确认历史，并根据双方最新结论更新差异状态。"""

    _validate_positive_id("difference_id", difference_id)
    party = confirming_party.strip().upper()
    result = confirmation_result.strip().upper()
    name = confirmer_name.strip()
    note = confirmation_note.strip() if confirmation_note else None
    if party not in VALID_CONFIRMING_PARTIES:
        raise SettlementOperationError(f"不支持的确认方：{confirming_party}")
    if result not in VALID_CONFIRMATION_RESULTS:
        raise SettlementOperationError(f"不支持的确认结论：{confirmation_result}")
    if not name or len(name) > 100:
        raise SettlementOperationError("confirmer_name 必须为 1 到 100 个字符。")
    if note is not None and len(note) > 500:
        raise SettlementOperationError("confirmation_note 不能超过 500 个字符。")
    if result == "REJECT" and not note:
        raise SettlementOperationError("拒绝确认时必须填写 confirmation_note。")

    with connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT
                difference_id,
                status,
                adjustment_detail_id,
                discovered_at,
                CURRENT_TIMESTAMP AS database_time
            FROM reconciliation_difference
            WHERE difference_id = %s
            FOR UPDATE
            """,
            (difference_id,),
        )
        difference = cursor.fetchone()
        if difference is None:
            raise SettlementOperationError(f"对账差异 {difference_id} 不存在。")
        if difference["status"] == "RESOLVED" or difference["adjustment_detail_id"] is not None:
            raise SettlementOperationError("已解决的差异不能继续追加确认。")

        operation_time = confirmed_at or difference["database_time"]
        if operation_time < difference["discovered_at"]:
            raise SettlementOperationError("确认时间不能早于差异发现时间。")

        cursor.execute(
            """
            INSERT INTO reconciliation_confirmation (
                difference_id,
                confirming_party,
                confirmer_name,
                confirmation_result,
                confirmation_note,
                confirmed_at
            ) VALUES (%s, %s, %s, %s, %s, %s)
            """,
            (difference_id, party, name, result, note, operation_time),
        )
        confirmation_id = cursor.lastrowid

        confirmations = _lock_and_read_confirmations(cursor, difference_id)
        latest = _latest_confirmation_by_party(confirmations)
        next_status, resolution = _derive_difference_state(latest)

        cursor.execute(
            """
            UPDATE reconciliation_difference
            SET status = %s,
                resolution = %s
            WHERE difference_id = %s
              AND adjustment_detail_id IS NULL
              AND status <> 'RESOLVED'
            """,
            (next_status, resolution, difference_id),
        )

    return {
        "confirmation_id": confirmation_id,
        "difference_id": difference_id,
        "confirming_party": party,
        "confirmation_result": result,
        "difference_status": next_status,
        "platform_result": latest.get("PLATFORM", {}).get("confirmation_result"),
        "operator_result": latest.get("OPERATOR", {}).get("confirmation_result"),
        "confirmed_at": operation_time,
    }


def apply_reconciliation_adjustment(
    connection: Connection,
    *,
    difference_id: int,
    target_settlement_id: int,
    adjustment_amount: Decimal,
    description: str,
    effective_at: datetime,
    resolved_at: datetime | None = None,
) -> dict[str, Any]:
    """把双方同意的差异写入后续账期，并将差异标记为已解决。"""

    _validate_positive_id("difference_id", difference_id)
    _validate_positive_id("target_settlement_id", target_settlement_id)
    amount = _as_money(adjustment_amount, "adjustment_amount")
    if amount == 0:
        raise SettlementOperationError("adjustment_amount 不能为 0。")
    normalized_description = description.strip()
    if not normalized_description or len(normalized_description) > 200:
        raise SettlementOperationError("description 必须为 1 到 200 个字符。")

    with connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT
                rd.difference_id,
                rd.settlement_id AS source_settlement_id,
                rd.order_id,
                rd.difference_type,
                rd.difference_value,
                rd.difference_unit,
                rd.status,
                rd.adjustment_detail_id,
                rd.discovered_at,
                source_statement.operator_id,
                source_statement.station_id,
                source_statement.period_end AS source_period_end,
                CURRENT_TIMESTAMP AS database_time
            FROM reconciliation_difference AS rd
            JOIN settlement_statement AS source_statement
              ON source_statement.settlement_id = rd.settlement_id
            WHERE rd.difference_id = %s
            FOR UPDATE
            """,
            (difference_id,),
        )
        difference = cursor.fetchone()
        if difference is None:
            raise SettlementOperationError(f"对账差异 {difference_id} 不存在。")
        if difference["status"] != "CONFIRMED":
            raise SettlementOperationError("只有 CONFIRMED 差异才能生成调整明细。")
        if difference["adjustment_detail_id"] is not None:
            raise SettlementOperationError("该差异已经生成调整明细。")

        confirmations = _lock_and_read_confirmations(cursor, difference_id)
        latest = _latest_confirmation_by_party(confirmations)
        if not _both_parties_agree(latest):
            raise SettlementOperationError("平台与运营商的最新确认必须均为 AGREE。")

        cursor.execute(
            """
            SELECT
                settlement_id,
                operator_id,
                station_id,
                period_start,
                period_end,
                status,
                payable_amount
            FROM settlement_statement
            WHERE settlement_id = %s
            FOR UPDATE
            """,
            (target_settlement_id,),
        )
        target = cursor.fetchone()
        if target is None:
            raise SettlementOperationError(f"目标结算单 {target_settlement_id} 不存在。")
        if target["settlement_id"] == difference["source_settlement_id"]:
            raise SettlementOperationError("调整必须写入后续账期，不能回写源差异结算单。")
        if (
            target["operator_id"] != difference["operator_id"]
            or target["station_id"] != difference["station_id"]
        ):
            raise SettlementOperationError("目标结算单必须与源差异属于同一运营商和场站。")
        if target["status"] != "GENERATED":
            raise SettlementOperationError("目标结算单必须处于 GENERATED 状态。")
        if target["period_start"] < difference["source_period_end"]:
            raise SettlementOperationError("目标结算单必须属于源差异之后的账期。")
        if not target["period_start"] <= effective_at.date() < target["period_end"]:
            raise SettlementOperationError("调整生效时间不在目标半开账期内。")

        resolution_time = resolved_at or difference["database_time"]
        latest_confirmation_time = max(
            latest["PLATFORM"]["confirmed_at"],
            latest["OPERATOR"]["confirmed_at"],
        )
        if resolution_time < difference["discovered_at"]:
            raise SettlementOperationError("解决时间不能早于差异发现时间。")
        if resolution_time < latest_confirmation_time:
            raise SettlementOperationError("解决时间不能早于双方最新确认时间。")

        cursor.execute(
            """
            INSERT INTO settlement_detail (
                settlement_id,
                order_id,
                detail_type,
                event_at,
                adjustment_amount,
                payable_amount,
                description
            ) VALUES (%s, %s, 'OTHER_ADJUSTMENT', %s, %s, %s, %s)
            """,
            (
                target_settlement_id,
                difference["order_id"],
                effective_at,
                amount,
                amount,
                normalized_description,
            ),
        )
        adjustment_detail_id = cursor.lastrowid

        cursor.execute(
            """
            UPDATE settlement_statement
            SET total_adjustment_amount = total_adjustment_amount + %s,
                payable_amount = payable_amount + %s
            WHERE settlement_id = %s
              AND status = 'GENERATED'
            """,
            (amount, amount, target_settlement_id),
        )
        if cursor.rowcount != 1:
            raise RuntimeError("目标结算单汇总更新失败，数据可能已被并发修改。")

        resolution = f"双方确认后生成调整明细：{normalized_description}"
        cursor.execute(
            """
            UPDATE reconciliation_difference
            SET status = 'RESOLVED',
                resolution = %s,
                adjustment_detail_id = %s,
                resolved_at = %s
            WHERE difference_id = %s
              AND status = 'CONFIRMED'
              AND adjustment_detail_id IS NULL
            """,
            (resolution, adjustment_detail_id, resolution_time, difference_id),
        )
        if cursor.rowcount != 1:
            raise RuntimeError("对账差异解决状态更新失败，数据可能已被并发修改。")

    target_payable = _as_money(target["payable_amount"], "target.payable_amount")
    return {
        "difference_id": difference_id,
        "source_settlement_id": difference["source_settlement_id"],
        "target_settlement_id": target_settlement_id,
        "adjustment_detail_id": adjustment_detail_id,
        "adjustment_amount": amount,
        "target_payable_amount": target_payable + amount,
        "difference_status": "RESOLVED",
        "effective_at": effective_at,
        "resolved_at": resolution_time,
    }


def _lock_and_read_confirmations(cursor: Any, difference_id: int) -> list[dict[str, Any]]:
    cursor.execute(
        """
        SELECT
            confirmation_id,
            confirming_party,
            confirmation_result,
            confirmed_at
        FROM reconciliation_confirmation
        WHERE difference_id = %s
        ORDER BY confirmation_id DESC
        FOR UPDATE
        """,
        (difference_id,),
    )
    return list(cursor.fetchall())


def _latest_confirmation_by_party(
    confirmations: list[dict[str, Any]],
) -> dict[str, dict[str, Any]]:
    latest: dict[str, dict[str, Any]] = {}
    for confirmation in confirmations:
        latest.setdefault(confirmation["confirming_party"], confirmation)
    return latest


def _derive_difference_state(
    latest: dict[str, dict[str, Any]],
) -> tuple[str, str | None]:
    if _both_parties_agree(latest):
        return "CONFIRMED", "平台与运营商最新确认均同意，等待生成调整明细"
    if any(
        confirmation["confirmation_result"] == "REJECT"
        for confirmation in latest.values()
    ):
        return "REJECTED", "至少一方最新确认拒绝，等待重新核对"
    return "PENDING", None


def _both_parties_agree(latest: dict[str, dict[str, Any]]) -> bool:
    return all(
        latest.get(party, {}).get("confirmation_result") == "AGREE"
        for party in VALID_CONFIRMING_PARTIES
    )


def _as_money(value: Any, field_name: str) -> Decimal:
    try:
        amount = value if isinstance(value, Decimal) else Decimal(str(value))
        rounded = amount.quantize(MONEY_UNIT)
    except (InvalidOperation, TypeError, ValueError) as exc:
        raise SettlementOperationError(f"{field_name} 不是有效金额。") from exc
    if amount != rounded:
        raise SettlementOperationError(f"{field_name} 最多保留两位小数。")
    return rounded


def _validate_positive_id(field_name: str, value: int) -> None:
    if value <= 0:
        raise SettlementOperationError(f"{field_name} 必须是正整数。")
