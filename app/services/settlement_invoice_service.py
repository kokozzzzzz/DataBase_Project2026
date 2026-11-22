"""⑤ 普通发票开具与红字冲销事务服务。"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal, InvalidOperation
from typing import Any

from pymysql.connections import Connection


MONEY_UNIT = Decimal("0.01")
ZERO = Decimal("0.00")
INVOICEABLE_SETTLEMENT_STATUSES = frozenset({"CONFIRMED", "PAID"})


class SettlementInvoiceError(ValueError):
    """发票操作不满足结算业务规则。"""


def issue_normal_invoice(
    connection: Connection,
    *,
    settlement_id: int,
    invoice_number: str,
    invoice_title: str,
    invoice_amount: Decimal,
    tax_number_ciphertext: bytes | None = None,
    issued_at: datetime | None = None,
) -> dict[str, Any]:
    """开具普通发票；提交或回滚由调用方控制。"""

    _validate_positive_id("settlement_id", settlement_id)
    number = _normalize_text(invoice_number, "invoice_number", 50)
    title = _normalize_text(invoice_title, "invoice_title", 200)
    amount = _as_positive_money(invoice_amount, "invoice_amount")
    tax_ciphertext = _normalize_ciphertext(tax_number_ciphertext)

    with connection.cursor() as cursor:
        statement, invoices = _lock_statement_and_invoices(cursor, settlement_id)
        _validate_invoiceable_statement(statement)

        operation_time = issued_at or statement["database_time"]
        if operation_time < statement["confirmed_at"]:
            raise SettlementInvoiceError("开票时间不能早于结算确认时间。")

        current_net_amount = _net_invoice_amount(invoices)
        payable_amount = _as_money(statement["payable_amount"], "payable_amount")
        if current_net_amount < ZERO or current_net_amount > payable_amount:
            raise SettlementInvoiceError("结算单现有净开票额不符合业务约束。")
        if current_net_amount + amount > payable_amount:
            raise SettlementInvoiceError("本次开票后累计净额将超过结算应结金额。")

        cursor.execute(
            """
            INSERT INTO invoice_record (
                settlement_id,
                invoice_number,
                invoice_type,
                invoice_title,
                tax_number_ciphertext,
                invoice_amount,
                issued_at,
                status,
                original_invoice_id
            ) VALUES (%s, %s, 'NORMAL', %s, %s, %s, %s, 'ISSUED', NULL)
            """,
            (
                settlement_id,
                number,
                title,
                tax_ciphertext,
                amount,
                operation_time,
            ),
        )
        invoice_id = cursor.lastrowid

    return {
        "invoice_id": invoice_id,
        "settlement_id": settlement_id,
        "invoice_number": number,
        "invoice_type": "NORMAL",
        "invoice_amount": amount,
        "status": "ISSUED",
        "net_invoice_amount": current_net_amount + amount,
        "invoice_available_amount": payable_amount - current_net_amount - amount,
        "issued_at": operation_time,
    }


def issue_red_letter_invoice(
    connection: Connection,
    *,
    original_invoice_id: int,
    invoice_number: str,
    invoice_amount: Decimal,
    issued_at: datetime | None = None,
) -> dict[str, Any]:
    """开具红字票并把原普通票标记为 RED_FLUSHED。"""

    _validate_positive_id("original_invoice_id", original_invoice_id)
    number = _normalize_text(invoice_number, "invoice_number", 50)
    amount = _as_positive_money(invoice_amount, "invoice_amount")

    with connection.cursor() as cursor:
        # 先只读取归属编号，再按固定顺序锁定结算单和该结算单全部发票。
        cursor.execute(
            """
            SELECT settlement_id
            FROM invoice_record
            WHERE invoice_id = %s
            """,
            (original_invoice_id,),
        )
        ownership = cursor.fetchone()
        if ownership is None:
            raise SettlementInvoiceError(f"原发票 {original_invoice_id} 不存在。")

        settlement_id = int(ownership["settlement_id"])
        statement, invoices = _lock_statement_and_invoices(cursor, settlement_id)
        _validate_invoiceable_statement(statement)

        original = next(
            (
                invoice
                for invoice in invoices
                if invoice["invoice_id"] == original_invoice_id
            ),
            None,
        )
        if original is None:
            raise SettlementInvoiceError("原发票在锁定后不存在，请重试。")
        if original["invoice_type"] != "NORMAL":
            raise SettlementInvoiceError("红字票只能关联普通发票。")
        if original["status"] not in {"ISSUED", "RED_FLUSHED"}:
            raise SettlementInvoiceError("原普通发票当前状态不允许红冲。")
        if original["issued_at"] is None:
            raise SettlementInvoiceError("原普通发票缺少开具时间。")

        operation_time = issued_at or statement["database_time"]
        if operation_time < original["issued_at"]:
            raise SettlementInvoiceError("红字票开具时间不能早于原普通发票。")

        original_amount = _as_money(original["invoice_amount"], "original.invoice_amount")
        issued_red_amount = sum(
            (
                _as_money(invoice["invoice_amount"], "red.invoice_amount")
                for invoice in invoices
                if invoice["invoice_type"] == "RED_LETTER"
                and invoice["original_invoice_id"] == original_invoice_id
                and invoice["status"] == "ISSUED"
            ),
            ZERO,
        )
        if issued_red_amount + amount > original_amount:
            raise SettlementInvoiceError("累计红字金额不能超过原普通发票金额。")

        current_net_amount = _net_invoice_amount(invoices)
        if current_net_amount - amount < ZERO:
            raise SettlementInvoiceError("本次红冲后结算单净开票额不能为负。")

        cursor.execute(
            """
            INSERT INTO invoice_record (
                settlement_id,
                invoice_number,
                invoice_type,
                invoice_title,
                tax_number_ciphertext,
                invoice_amount,
                issued_at,
                status,
                original_invoice_id
            ) VALUES (%s, %s, 'RED_LETTER', %s, %s, %s, %s, 'ISSUED', %s)
            """,
            (
                settlement_id,
                number,
                original["invoice_title"],
                original["tax_number_ciphertext"],
                amount,
                operation_time,
                original_invoice_id,
            ),
        )
        red_invoice_id = cursor.lastrowid

        cursor.execute(
            """
            UPDATE invoice_record
            SET status = 'RED_FLUSHED'
            WHERE invoice_id = %s
              AND invoice_type = 'NORMAL'
              AND status IN ('ISSUED', 'RED_FLUSHED')
            """,
            (original_invoice_id,),
        )

    return {
        "invoice_id": red_invoice_id,
        "settlement_id": settlement_id,
        "invoice_number": number,
        "invoice_type": "RED_LETTER",
        "invoice_amount": amount,
        "status": "ISSUED",
        "original_invoice_id": original_invoice_id,
        "original_invoice_status": "RED_FLUSHED",
        "red_flushed_amount": issued_red_amount + amount,
        "net_invoice_amount": current_net_amount - amount,
        "issued_at": operation_time,
    }


def _lock_statement_and_invoices(
    cursor: Any,
    settlement_id: int,
) -> tuple[dict[str, Any], list[dict[str, Any]]]:
    cursor.execute(
        """
        SELECT
            settlement_id,
            status,
            payable_amount,
            confirmed_at,
            CURRENT_TIMESTAMP AS database_time
        FROM settlement_statement
        WHERE settlement_id = %s
        FOR UPDATE
        """,
        (settlement_id,),
    )
    statement = cursor.fetchone()
    if statement is None:
        raise SettlementInvoiceError(f"结算单 {settlement_id} 不存在。")

    cursor.execute(
        """
        SELECT
            invoice_id,
            settlement_id,
            invoice_number,
            invoice_type,
            invoice_title,
            tax_number_ciphertext,
            invoice_amount,
            issued_at,
            status,
            original_invoice_id
        FROM invoice_record
        WHERE settlement_id = %s
        ORDER BY invoice_id
        FOR UPDATE
        """,
        (settlement_id,),
    )
    return statement, list(cursor.fetchall())


def _validate_invoiceable_statement(statement: dict[str, Any]) -> None:
    if statement["status"] not in INVOICEABLE_SETTLEMENT_STATUSES:
        raise SettlementInvoiceError("只有 CONFIRMED 或 PAID 结算单允许开票。")
    payable_amount = _as_money(statement["payable_amount"], "payable_amount")
    if payable_amount <= ZERO:
        raise SettlementInvoiceError("净应结金额非正的结算单不能开具发票。")
    if statement["confirmed_at"] is None:
        raise SettlementInvoiceError("可开票结算单必须具有确认时间。")


def _net_invoice_amount(invoices: list[dict[str, Any]]) -> Decimal:
    net_amount = ZERO
    for invoice in invoices:
        amount = _as_money(invoice["invoice_amount"], "invoice.invoice_amount")
        if invoice["invoice_type"] == "NORMAL" and invoice["status"] in {
            "ISSUED",
            "RED_FLUSHED",
        }:
            net_amount += amount
        elif invoice["invoice_type"] == "RED_LETTER" and invoice["status"] == "ISSUED":
            net_amount -= amount
    return net_amount


def _normalize_text(value: str, field_name: str, maximum_length: int) -> str:
    normalized = value.strip()
    if not normalized or len(normalized) > maximum_length:
        raise SettlementInvoiceError(
            f"{field_name} 必须为 1 到 {maximum_length} 个字符。"
        )
    return normalized


def _normalize_ciphertext(value: bytes | None) -> bytes | None:
    if value is None:
        return None
    if not isinstance(value, bytes):
        raise SettlementInvoiceError("tax_number_ciphertext 必须是 bytes。")
    if not value or len(value) > 512:
        raise SettlementInvoiceError("tax_number_ciphertext 必须为 1 到 512 字节。")
    return value


def _as_positive_money(value: Any, field_name: str) -> Decimal:
    amount = _as_money(value, field_name)
    if amount <= ZERO:
        raise SettlementInvoiceError(f"{field_name} 必须大于 0。")
    return amount


def _as_money(value: Any, field_name: str) -> Decimal:
    try:
        amount = value if isinstance(value, Decimal) else Decimal(str(value))
        rounded = amount.quantize(MONEY_UNIT)
    except (InvalidOperation, TypeError, ValueError) as exc:
        raise SettlementInvoiceError(f"{field_name} 不是有效金额。") from exc
    if amount != rounded:
        raise SettlementInvoiceError(f"{field_name} 最多保留两位小数。")
    return rounded


def _validate_positive_id(field_name: str, value: int) -> None:
    if value <= 0:
        raise SettlementInvoiceError(f"{field_name} 必须是正整数。")
