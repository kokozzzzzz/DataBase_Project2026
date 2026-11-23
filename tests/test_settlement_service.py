"""结算差异确认和跨期调整单元测试，不连接真实 MySQL。"""

from __future__ import annotations

from datetime import date, datetime
from decimal import Decimal
from typing import Any

import pytest

from app.services.settlement_service import (
    SettlementOperationError,
    apply_reconciliation_adjustment,
    confirm_reconciliation_difference,
)


DISCOVERED_AT = datetime(2027, 1, 3, 9, 0, 0)
PLATFORM_CONFIRMED_AT = datetime(2027, 1, 3, 10, 0, 0)
OPERATOR_CONFIRMED_AT = datetime(2027, 1, 3, 11, 0, 0)
RESOLVED_AT = datetime(2027, 1, 3, 12, 0, 0)


class FakeCursor:
    def __init__(self, fetch_results: list[Any]) -> None:
        self.fetch_results = fetch_results
        self.executions: list[tuple[str, tuple[Any, ...]]] = []
        self.rowcount = 1
        self.lastrowid = 90001

    def __enter__(self) -> "FakeCursor":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def execute(self, sql: str, parameters: tuple[Any, ...]) -> None:
        normalized = " ".join(sql.split())
        self.executions.append((normalized, parameters))
        self.rowcount = 1
        if normalized.startswith("INSERT INTO reconciliation_confirmation"):
            self.lastrowid = 91001
        elif normalized.startswith("INSERT INTO settlement_detail"):
            self.lastrowid = 92001

    def fetchone(self) -> dict[str, Any] | None:
        return self.fetch_results.pop(0)

    def fetchall(self) -> list[dict[str, Any]]:
        return self.fetch_results.pop(0)


class FakeConnection:
    def __init__(self, cursor: FakeCursor) -> None:
        self.fake_cursor = cursor

    def cursor(self) -> FakeCursor:
        return self.fake_cursor


def _difference(**overrides: Any) -> dict[str, Any]:
    row = {
        "difference_id": 1,
        "status": "PENDING",
        "adjustment_detail_id": None,
        "discovered_at": DISCOVERED_AT,
        "database_time": RESOLVED_AT,
    }
    row.update(overrides)
    return row


def _confirmations(
    platform_result: str = "AGREE",
    operator_result: str = "AGREE",
) -> list[dict[str, Any]]:
    return [
        {
            "confirmation_id": 2,
            "confirming_party": "OPERATOR",
            "confirmation_result": operator_result,
            "confirmed_at": OPERATOR_CONFIRMED_AT,
        },
        {
            "confirmation_id": 1,
            "confirming_party": "PLATFORM",
            "confirmation_result": platform_result,
            "confirmed_at": PLATFORM_CONFIRMED_AT,
        },
    ]


def _adjustment_difference(**overrides: Any) -> dict[str, Any]:
    row = {
        "difference_id": 1,
        "source_settlement_id": 2,
        "order_id": 45,
        "difference_type": "REFUND",
        "difference_value": Decimal("0.5000"),
        "difference_unit": "CNY",
        "status": "CONFIRMED",
        "adjustment_detail_id": None,
        "discovered_at": DISCOVERED_AT,
        "operator_id": 7200001,
        "station_id": 7200001,
        "source_period_end": date(2027, 1, 1),
        "database_time": RESOLVED_AT,
    }
    row.update(overrides)
    return row


def _target_statement(**overrides: Any) -> dict[str, Any]:
    row = {
        "settlement_id": 3,
        "operator_id": 7200001,
        "station_id": 7200001,
        "period_start": date(2027, 1, 1),
        "period_end": date(2027, 2, 1),
        "status": "GENERATED",
        "payable_amount": Decimal("0.00"),
    }
    row.update(overrides)
    return row


def test_confirm_difference_updates_status_when_both_parties_agree() -> None:
    cursor = FakeCursor([_difference(), _confirmations()])

    result = confirm_reconciliation_difference(  # type: ignore[arg-type]
        FakeConnection(cursor),
        difference_id=1,
        confirming_party="platform",
        confirmation_result="agree",
        confirmer_name="测试平台确认员",
        confirmed_at=RESOLVED_AT,
    )

    assert result["confirmation_id"] == 91001
    assert result["difference_status"] == "CONFIRMED"
    assert result["platform_result"] == "AGREE"
    assert result["operator_result"] == "AGREE"
    assert any(
        sql.startswith("INSERT INTO reconciliation_confirmation")
        for sql, _ in cursor.executions
    )


def test_confirm_difference_requires_rejection_note() -> None:
    with pytest.raises(SettlementOperationError, match="必须填写"):
        confirm_reconciliation_difference(  # type: ignore[arg-type]
            FakeConnection(FakeCursor([])),
            difference_id=1,
            confirming_party="OPERATOR",
            confirmation_result="REJECT",
            confirmer_name="测试运营商确认员",
        )


def test_confirm_difference_rejects_resolved_difference() -> None:
    cursor = FakeCursor([_difference(status="RESOLVED", adjustment_detail_id=88)])

    with pytest.raises(SettlementOperationError, match="已解决"):
        confirm_reconciliation_difference(  # type: ignore[arg-type]
            FakeConnection(cursor),
            difference_id=1,
            confirming_party="PLATFORM",
            confirmation_result="AGREE",
            confirmer_name="测试平台确认员",
            confirmed_at=RESOLVED_AT,
        )


def test_apply_adjustment_creates_detail_and_resolves_difference() -> None:
    cursor = FakeCursor(
        [_adjustment_difference(), _confirmations(), _target_statement()]
    )

    result = apply_reconciliation_adjustment(  # type: ignore[arg-type]
        FakeConnection(cursor),
        difference_id=1,
        target_settlement_id=3,
        adjustment_amount=Decimal("-0.50"),
        description="退款差异跨期调整",
        effective_at=RESOLVED_AT,
        resolved_at=RESOLVED_AT,
    )

    assert result["adjustment_detail_id"] == 92001
    assert result["difference_status"] == "RESOLVED"
    assert result["target_payable_amount"] == Decimal("-0.50")
    assert any(
        sql.startswith("INSERT INTO settlement_detail")
        for sql, _ in cursor.executions
    )
    assert any(
        sql.startswith("UPDATE settlement_statement")
        for sql, _ in cursor.executions
    )


def test_apply_adjustment_requires_bilateral_agreement() -> None:
    cursor = FakeCursor(
        [_adjustment_difference(), _confirmations(operator_result="REJECT")]
    )

    with pytest.raises(SettlementOperationError, match="最新确认"):
        apply_reconciliation_adjustment(  # type: ignore[arg-type]
            FakeConnection(cursor),
            difference_id=1,
            target_settlement_id=3,
            adjustment_amount=Decimal("-0.50"),
            description="退款差异跨期调整",
            effective_at=RESOLVED_AT,
            resolved_at=RESOLVED_AT,
        )


def test_apply_adjustment_rejects_other_station_target() -> None:
    cursor = FakeCursor(
        [
            _adjustment_difference(),
            _confirmations(),
            _target_statement(station_id=7200002),
        ]
    )

    with pytest.raises(SettlementOperationError, match="同一运营商和场站"):
        apply_reconciliation_adjustment(  # type: ignore[arg-type]
            FakeConnection(cursor),
            difference_id=1,
            target_settlement_id=3,
            adjustment_amount=Decimal("-0.50"),
            description="退款差异跨期调整",
            effective_at=RESOLVED_AT,
            resolved_at=RESOLVED_AT,
        )


def test_apply_adjustment_rejects_time_outside_target_period() -> None:
    cursor = FakeCursor(
        [_adjustment_difference(), _confirmations(), _target_statement()]
    )

    with pytest.raises(SettlementOperationError, match="半开账期"):
        apply_reconciliation_adjustment(  # type: ignore[arg-type]
            FakeConnection(cursor),
            difference_id=1,
            target_settlement_id=3,
            adjustment_amount=Decimal("-0.50"),
            description="退款差异跨期调整",
            effective_at=datetime(2027, 2, 1, 0, 0, 0),
            resolved_at=datetime(2027, 2, 1, 0, 0, 0),
        )
