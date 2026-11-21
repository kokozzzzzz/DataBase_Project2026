"""优惠券事务服务单元测试，不连接真实 MySQL。"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Any

import pytest

from app.services.coupon_service import (
    CouponOperationError,
    issue_coupon,
    lock_coupon_for_order,
    redeem_coupon_for_order,
    release_coupon_from_order,
)


NOW = datetime(2026, 11, 20, 12, 0, 0)
VALID_FROM = datetime(2026, 11, 20, 0, 0, 0)
VALID_TO = datetime(2026, 12, 20, 0, 0, 0)


class FakeCursor:
    def __init__(self, fetch_rows: list[dict[str, Any] | None]) -> None:
        self.fetch_rows = fetch_rows
        self.executions: list[tuple[str, tuple[Any, ...]]] = []
        self.rowcount = 1
        self.lastrowid = 50001

    def __enter__(self) -> "FakeCursor":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def execute(self, sql: str, parameters: tuple[Any, ...]) -> None:
        self.executions.append((" ".join(sql.split()), parameters))
        if self.executions[-1][0].startswith("INSERT INTO coupon_redemption"):
            self.lastrowid = 70001

    def fetchone(self) -> dict[str, Any] | None:
        return self.fetch_rows.pop(0)


class FakeConnection:
    def __init__(self, cursor: FakeCursor) -> None:
        self.fake_cursor = cursor

    def cursor(self) -> FakeCursor:
        return self.fake_cursor


def _promotion(**overrides: Any) -> dict[str, Any]:
    row = {
        "promotion_id": 40001,
        "promotion_name": "测试优惠活动",
        "total_quantity": 100,
        "per_user_limit": 1,
        "valid_from": VALID_FROM,
        "valid_to": VALID_TO,
        "status": "ACTIVE",
        "database_time": NOW,
    }
    row.update(overrides)
    return row


def _order(**overrides: Any) -> dict[str, Any]:
    row = {
        "order_id": 80001,
        "user_id": 10001,
        "state": "BILLED",
        "gross_amount": Decimal("100.00"),
        "discount_amount": Decimal("0.00"),
        "station_id": 20001,
        "database_time": NOW,
    }
    row.update(overrides)
    return row


def _available_coupon(**overrides: Any) -> dict[str, Any]:
    row = {
        "coupon_id": 50001,
        "promotion_id": 40001,
        "user_id": 10001,
        "status": "AVAILABLE",
        "valid_from": VALID_FROM,
        "valid_to": VALID_TO,
        "promotion_name": "测试优惠活动",
        "discount_type": "FIXED",
        "discount_value": Decimal("20.00"),
        "minimum_spend": Decimal("50.00"),
        "max_discount_amount": None,
        "applicability_scope": "ALL",
        "promotion_valid_from": VALID_FROM,
        "promotion_valid_to": VALID_TO,
        "promotion_status": "ACTIVE",
    }
    row.update(overrides)
    return row


def test_issue_coupon_checks_limits_and_inserts_available_coupon() -> None:
    cursor = FakeCursor(
        [
            _promotion(),
            {"user_id": 10001, "user_status": "ACTIVE"},
            {"total_issued": 3, "user_issued": 0},
        ]
    )

    result = issue_coupon(  # type: ignore[arg-type]
        FakeConnection(cursor),
        coupon_code=" CP-20261120-001 ",
        promotion_id=40001,
        user_id=10001,
    )

    assert result["coupon_code"] == "CP-20261120-001"
    assert result["status"] == "AVAILABLE"
    assert result["valid_from"] == NOW
    assert any(sql.startswith("INSERT INTO coupon") for sql, _ in cursor.executions)


def test_issue_coupon_rejects_per_user_limit() -> None:
    cursor = FakeCursor(
        [
            _promotion(),
            {"user_id": 10001, "user_status": "ACTIVE"},
            {"total_issued": 3, "user_issued": 1},
        ]
    )

    with pytest.raises(CouponOperationError, match="限领"):
        issue_coupon(  # type: ignore[arg-type]
            FakeConnection(cursor),
            coupon_code="CP-20261120-002",
            promotion_id=40001,
            user_id=10001,
        )


def test_lock_coupon_applies_discount_to_billed_order() -> None:
    cursor = FakeCursor([_order(), _available_coupon(), None])

    result = lock_coupon_for_order(  # type: ignore[arg-type]
        FakeConnection(cursor),
        coupon_id=50001,
        order_id=80001,
    )

    assert result["status"] == "LOCKED"
    assert result["discount_amount"] == Decimal("20.00")
    assert result["payable_amount"] == Decimal("80.00")
    assert any(
        sql.startswith("UPDATE charging_order") for sql, _ in cursor.executions
    )
    assert any(sql.startswith("UPDATE coupon") for sql, _ in cursor.executions)


def test_lock_coupon_rejects_other_users_coupon() -> None:
    cursor = FakeCursor([_order(), _available_coupon(user_id=10002)])

    with pytest.raises(CouponOperationError, match="不属于订单用户"):
        lock_coupon_for_order(  # type: ignore[arg-type]
            FakeConnection(cursor),
            coupon_id=50001,
            order_id=80001,
        )


def test_lock_coupon_rejects_unlisted_station() -> None:
    cursor = FakeCursor(
        [
            _order(station_id=20002),
            _available_coupon(applicability_scope="SELECTED"),
            None,
            None,
        ]
    )

    with pytest.raises(CouponOperationError, match="不适用于"):
        lock_coupon_for_order(  # type: ignore[arg-type]
            FakeConnection(cursor),
            coupon_id=50001,
            order_id=80001,
        )


def test_release_coupon_clears_order_discount() -> None:
    locked_coupon = {
        "coupon_id": 50001,
        "status": "LOCKED",
        "locked_order_id": 80001,
        "valid_to": VALID_TO,
        "database_time": NOW,
    }
    cursor = FakeCursor(
        [
            _order(discount_amount=Decimal("20.00")),
            locked_coupon,
            {"success_count": 0},
        ]
    )

    result = release_coupon_from_order(  # type: ignore[arg-type]
        FakeConnection(cursor),
        coupon_id=50001,
        order_id=80001,
    )

    assert result["status"] == "AVAILABLE"
    assert result["previous_discount_amount"] == Decimal("20.00")
    assert any(
        sql.startswith("UPDATE charging_order") for sql, _ in cursor.executions
    )


def test_release_coupon_rejects_successfully_paid_order() -> None:
    cursor = FakeCursor(
        [
            _order(discount_amount=Decimal("20.00")),
            {
                "coupon_id": 50001,
                "status": "LOCKED",
                "locked_order_id": 80001,
                "valid_to": VALID_TO,
                "database_time": NOW,
            },
            {"success_count": 1},
        ]
    )

    with pytest.raises(CouponOperationError, match="成功支付"):
        release_coupon_from_order(  # type: ignore[arg-type]
            FakeConnection(cursor),
            coupon_id=50001,
            order_id=80001,
        )


def test_redeem_coupon_requires_full_successful_payment() -> None:
    locked_at = datetime(2026, 11, 20, 11, 55, 0)
    cursor = FakeCursor(
        [
            _order(discount_amount=Decimal("20.00")),
            {
                "coupon_id": 50001,
                "user_id": 10001,
                "status": "LOCKED",
                "locked_order_id": 80001,
                "locked_at": locked_at,
                "database_time": NOW,
            },
            {"paid_amount": Decimal("80.00")},
        ]
    )

    result = redeem_coupon_for_order(  # type: ignore[arg-type]
        FakeConnection(cursor),
        coupon_id=50001,
        order_id=80001,
    )

    assert result["status"] == "USED"
    assert result["redemption_id"] == 70001
    assert result["discount_amount"] == Decimal("20.00")
    assert any(
        sql.startswith("INSERT INTO coupon_redemption")
        for sql, _ in cursor.executions
    )


def test_redeem_coupon_rejects_insufficient_payment() -> None:
    cursor = FakeCursor(
        [
            _order(discount_amount=Decimal("20.00")),
            {
                "coupon_id": 50001,
                "user_id": 10001,
                "status": "LOCKED",
                "locked_order_id": 80001,
                "locked_at": datetime(2026, 11, 20, 11, 55, 0),
                "database_time": NOW,
            },
            {"paid_amount": Decimal("70.00")},
        ]
    )

    with pytest.raises(CouponOperationError, match="金额不足"):
        redeem_coupon_for_order(  # type: ignore[arg-type]
            FakeConnection(cursor),
            coupon_id=50001,
            order_id=80001,
        )
