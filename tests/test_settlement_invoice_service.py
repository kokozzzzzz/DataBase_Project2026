"""普通发票与红字冲销事务服务单元测试，不连接真实 MySQL。"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Any

import pytest

from app.services.settlement_invoice_service import (
    SettlementInvoiceError,
    issue_normal_invoice,
    issue_red_letter_invoice,
)


CONFIRMED_AT = datetime(2026, 12, 3, 9, 0, 0)
NORMAL_ISSUED_AT = datetime(2026, 12, 6, 9, 0, 0)
RED_ISSUED_AT = datetime(2026, 12, 7, 9, 0, 0)


class FakeCursor:
    def __init__(self, fetch_results: list[Any]) -> None:
        self.fetch_results = fetch_results
        self.executions: list[tuple[str, tuple[Any, ...]]] = []
        self.rowcount = 1
        self.lastrowid = 1001

    def __enter__(self) -> "FakeCursor":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def execute(self, sql: str, parameters: tuple[Any, ...]) -> None:
        normalized = " ".join(sql.split())
        self.executions.append((normalized, parameters))
        self.rowcount = 1
        if normalized.startswith("INSERT INTO invoice_record"):
            self.lastrowid = 2001

    def fetchone(self) -> dict[str, Any] | None:
        return self.fetch_results.pop(0)

    def fetchall(self) -> list[dict[str, Any]]:
        return self.fetch_results.pop(0)


class FakeConnection:
    def __init__(self, cursor: FakeCursor) -> None:
        self.fake_cursor = cursor

    def cursor(self) -> FakeCursor:
        return self.fake_cursor


def _statement(**overrides: Any) -> dict[str, Any]:
    row = {
        "settlement_id": 1,
        "status": "CONFIRMED",
        "payable_amount": Decimal("16.64"),
        "confirmed_at": CONFIRMED_AT,
        "database_time": NORMAL_ISSUED_AT,
    }
    row.update(overrides)
    return row


def _normal_invoice(**overrides: Any) -> dict[str, Any]:
    row = {
        "invoice_id": 11,
        "settlement_id": 1,
        "invoice_number": "NORMAL-001",
        "invoice_type": "NORMAL",
        "invoice_title": "测试运营商",
        "tax_number_ciphertext": b"encrypted-tax-number",
        "invoice_amount": Decimal("8.00"),
        "issued_at": NORMAL_ISSUED_AT,
        "status": "RED_FLUSHED",
        "original_invoice_id": None,
    }
    row.update(overrides)
    return row


def _red_invoice(**overrides: Any) -> dict[str, Any]:
    row = {
        "invoice_id": 12,
        "settlement_id": 1,
        "invoice_number": "RED-001",
        "invoice_type": "RED_LETTER",
        "invoice_title": "测试运营商",
        "tax_number_ciphertext": b"encrypted-tax-number",
        "invoice_amount": Decimal("1.00"),
        "issued_at": RED_ISSUED_AT,
        "status": "ISSUED",
        "original_invoice_id": 11,
    }
    row.update(overrides)
    return row


def test_issue_normal_invoice_respects_remaining_amount() -> None:
    cursor = FakeCursor([_statement(), [_normal_invoice(), _red_invoice()]])

    result = issue_normal_invoice(  # type: ignore[arg-type]
        FakeConnection(cursor),
        settlement_id=1,
        invoice_number=" NORMAL-002 ",
        invoice_title=" 测试运营商 ",
        invoice_amount=Decimal("2.00"),
        issued_at=RED_ISSUED_AT,
    )

    assert result["invoice_id"] == 2001
    assert result["net_invoice_amount"] == Decimal("9.00")
    assert result["invoice_available_amount"] == Decimal("7.64")
    assert any(
        sql.startswith("INSERT INTO invoice_record")
        for sql, _ in cursor.executions
    )


def test_issue_normal_invoice_rejects_exceeding_payable_amount() -> None:
    cursor = FakeCursor([_statement(), [_normal_invoice(), _red_invoice()]])

    with pytest.raises(SettlementInvoiceError, match="超过"):
        issue_normal_invoice(  # type: ignore[arg-type]
            FakeConnection(cursor),
            settlement_id=1,
            invoice_number="NORMAL-002",
            invoice_title="测试运营商",
            invoice_amount=Decimal("10.00"),
            issued_at=RED_ISSUED_AT,
        )


def test_issue_normal_invoice_rejects_generated_statement() -> None:
    cursor = FakeCursor([_statement(status="GENERATED"), []])

    with pytest.raises(SettlementInvoiceError, match="CONFIRMED"):
        issue_normal_invoice(  # type: ignore[arg-type]
            FakeConnection(cursor),
            settlement_id=1,
            invoice_number="NORMAL-002",
            invoice_title="测试运营商",
            invoice_amount=Decimal("2.00"),
            issued_at=RED_ISSUED_AT,
        )


def test_issue_normal_invoice_rejects_invalid_ciphertext_type() -> None:
    with pytest.raises(SettlementInvoiceError, match="bytes"):
        issue_normal_invoice(  # type: ignore[arg-type]
            FakeConnection(FakeCursor([])),
            settlement_id=1,
            invoice_number="NORMAL-002",
            invoice_title="测试运营商",
            invoice_amount=Decimal("2.00"),
            tax_number_ciphertext="plain-tax-number",  # type: ignore[arg-type]
            issued_at=RED_ISSUED_AT,
        )


def test_issue_red_letter_invoice_updates_original_status() -> None:
    original = _normal_invoice(status="ISSUED", invoice_amount=Decimal("2.00"))
    cursor = FakeCursor(
        [
            {"settlement_id": 1},
            _statement(database_time=RED_ISSUED_AT),
            [original],
        ]
    )

    result = issue_red_letter_invoice(  # type: ignore[arg-type]
        FakeConnection(cursor),
        original_invoice_id=11,
        invoice_number="RED-002",
        invoice_amount=Decimal("0.50"),
        issued_at=RED_ISSUED_AT,
    )

    assert result["invoice_id"] == 2001
    assert result["original_invoice_status"] == "RED_FLUSHED"
    assert result["red_flushed_amount"] == Decimal("0.50")
    assert result["net_invoice_amount"] == Decimal("1.50")
    assert any(
        sql.startswith("UPDATE invoice_record")
        for sql, _ in cursor.executions
    )


def test_issue_red_letter_invoice_rejects_cumulative_excess() -> None:
    original = _normal_invoice(invoice_amount=Decimal("2.00"))
    existing_red = _red_invoice(invoice_amount=Decimal("1.50"))
    cursor = FakeCursor(
        [
            {"settlement_id": 1},
            _statement(database_time=RED_ISSUED_AT),
            [original, existing_red],
        ]
    )

    with pytest.raises(SettlementInvoiceError, match="累计红字"):
        issue_red_letter_invoice(  # type: ignore[arg-type]
            FakeConnection(cursor),
            original_invoice_id=11,
            invoice_number="RED-002",
            invoice_amount=Decimal("1.00"),
            issued_at=RED_ISSUED_AT,
        )


def test_issue_red_letter_invoice_rejects_earlier_time() -> None:
    original = _normal_invoice(
        status="ISSUED",
        invoice_amount=Decimal("2.00"),
        issued_at=RED_ISSUED_AT,
    )
    cursor = FakeCursor(
        [
            {"settlement_id": 1},
            _statement(database_time=RED_ISSUED_AT),
            [original],
        ]
    )

    with pytest.raises(SettlementInvoiceError, match="不能早于"):
        issue_red_letter_invoice(  # type: ignore[arg-type]
            FakeConnection(cursor),
            original_invoice_id=11,
            invoice_number="RED-002",
            invoice_amount=Decimal("0.50"),
            issued_at=NORMAL_ISSUED_AT,
        )


def test_issue_red_letter_invoice_rejects_red_original() -> None:
    red_original = _red_invoice(invoice_id=12)
    cursor = FakeCursor(
        [
            {"settlement_id": 1},
            _statement(database_time=RED_ISSUED_AT),
            [red_original],
        ]
    )

    with pytest.raises(SettlementInvoiceError, match="普通发票"):
        issue_red_letter_invoice(  # type: ignore[arg-type]
            FakeConnection(cursor),
            original_invoice_id=12,
            invoice_number="RED-002",
            invoice_amount=Decimal("0.50"),
            issued_at=RED_ISSUED_AT,
        )
