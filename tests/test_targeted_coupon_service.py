"""目标用户批量发券单元测试，不连接真实MySQL。"""

from __future__ import annotations

from datetime import datetime
from typing import Any

import pytest

from app.services.targeted_coupon_service import (
    TargetedCouponError,
    issue_coupons_batch,
)


NOW = datetime(2026, 11, 23, 10, 0, 0)
VALID_TO = datetime(2026, 12, 31, 23, 59, 59)


class FakeCursor:
    def __init__(self, results: list[Any]) -> None:
        self.results = results
        self.executions: list[tuple[str, tuple[Any, ...]]] = []
        self.batch_rows: list[tuple[Any, ...]] = []
        self.rowcount = 0

    def __enter__(self) -> "FakeCursor":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def execute(self, sql: str, parameters: tuple[Any, ...]) -> None:
        self.executions.append((" ".join(sql.split()), parameters))

    def executemany(self, sql: str, rows: list[tuple[Any, ...]]) -> None:
        self.executions.append((" ".join(sql.split()), ()))
        self.batch_rows = rows
        self.rowcount = len(rows)

    def fetchone(self) -> dict[str, Any] | None:
        value = self.results.pop(0)
        return value

    def fetchall(self) -> list[dict[str, Any]]:
        value = self.results.pop(0)
        return value


class FakeConnection:
    def __init__(self, cursor: FakeCursor) -> None:
        self.fake_cursor = cursor

    def cursor(self) -> FakeCursor:
        return self.fake_cursor


def _promotion(**overrides: Any) -> dict[str, Any]:
    row = {
        "promotion_id": 40001,
        "promotion_name": "定向活动",
        "total_quantity": 100,
        "per_user_limit": 1,
        "valid_from": datetime(2026, 11, 1),
        "valid_to": VALID_TO,
        "status": "ACTIVE",
        "database_time": NOW,
    }
    row.update(overrides)
    return row


def test_batch_issue_locks_users_and_uses_executemany() -> None:
    cursor = FakeCursor(
        [
            _promotion(),
            [
                {"user_id": 10001, "user_status": "ACTIVE"},
                {"user_id": 10002, "user_status": "ACTIVE"},
            ],
            {"total_issued": 10},
            [],
            [],
        ]
    )

    result = issue_coupons_batch(  # type: ignore[arg-type]
        FakeConnection(cursor),
        promotion_id=40001,
        recipients=[(10002, "BATCH-002"), (10001, "BATCH-001")],
        issued_at=NOW,
    )

    assert result["issued_count"] == 2
    assert result["user_ids"] == [10001, 10002]
    assert len(cursor.batch_rows) == 2
    assert cursor.executions[-1][0].startswith("INSERT INTO coupon")
    assert any("FOR UPDATE" in sql for sql, _ in cursor.executions)


def test_batch_issue_rejects_total_quantity_overflow() -> None:
    cursor = FakeCursor(
        [
            _promotion(total_quantity=11),
            [
                {"user_id": 10001, "user_status": "ACTIVE"},
                {"user_id": 10002, "user_status": "ACTIVE"},
            ],
            {"total_issued": 10},
        ]
    )

    with pytest.raises(TargetedCouponError, match="剩余发券总量"):
        issue_coupons_batch(  # type: ignore[arg-type]
            FakeConnection(cursor),
            promotion_id=40001,
            recipients=[(10001, "BATCH-001"), (10002, "BATCH-002")],
            issued_at=NOW,
        )


def test_batch_issue_rejects_inactive_user() -> None:
    cursor = FakeCursor(
        [
            _promotion(),
            [{"user_id": 10001, "user_status": "CLOSED"}],
        ]
    )

    with pytest.raises(TargetedCouponError, match="不可领券"):
        issue_coupons_batch(  # type: ignore[arg-type]
            FakeConnection(cursor),
            promotion_id=40001,
            recipients=[(10001, "BATCH-001")],
            issued_at=NOW,
        )


def test_batch_issue_rejects_duplicate_user_before_sql() -> None:
    with pytest.raises(TargetedCouponError, match="重复用户"):
        issue_coupons_batch(  # type: ignore[arg-type]
            FakeConnection(FakeCursor([])),
            promotion_id=40001,
            recipients=[(10001, "BATCH-001"), (10001, "BATCH-002")],
            issued_at=NOW,
        )
