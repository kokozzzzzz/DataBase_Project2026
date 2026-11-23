"""结算只读持久层单元测试，不连接真实 MySQL。"""

from __future__ import annotations

from typing import Any

import pytest

from app.database.settlement_repository import (
    list_pending_reconciliation,
    list_settlement_summaries,
)


class FakeCursor:
    def __init__(self, rows: list[dict[str, Any]]) -> None:
        self.rows = rows
        self.sql = ""
        self.parameters: list[Any] = []

    def __enter__(self) -> "FakeCursor":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def execute(self, sql: str, parameters: list[Any]) -> None:
        self.sql = " ".join(sql.split())
        self.parameters = list(parameters)

    def fetchall(self) -> list[dict[str, Any]]:
        return self.rows


class FakeConnection:
    def __init__(self, cursor: FakeCursor) -> None:
        self.fake_cursor = cursor

    def cursor(self) -> FakeCursor:
        return self.fake_cursor


def test_list_settlement_summaries_uses_optional_filters_and_page() -> None:
    cursor = FakeCursor([{"settlement_id": 1}])

    rows = list_settlement_summaries(  # type: ignore[arg-type]
        FakeConnection(cursor),
        operator_id=7200001,
        station_id=7200001,
        status="CONFIRMED",
        limit=10,
        offset=5,
    )

    assert rows == [{"settlement_id": 1}]
    assert cursor.parameters == [7200001, 7200001, "CONFIRMED", 10, 5]
    assert "FROM v_settlement_statement_summary" in cursor.sql
    assert "tax_number_ciphertext" not in cursor.sql


def test_list_pending_reconciliation_hides_confirmer_name() -> None:
    cursor = FakeCursor([{"difference_id": 1, "next_action": "CREATE_ADJUSTMENT"}])

    rows = list_pending_reconciliation(  # type: ignore[arg-type]
        FakeConnection(cursor),
        operator_id=7200001,
        next_action="CREATE_ADJUSTMENT",
        limit=20,
    )

    assert rows[0]["difference_id"] == 1
    assert cursor.parameters == [7200001, "CREATE_ADJUSTMENT", 20, 0]
    assert "FROM v_reconciliation_pending" in cursor.sql
    assert "confirmer_name" not in cursor.sql


@pytest.mark.parametrize("invalid_limit", [0, 101])
def test_repository_rejects_invalid_limit(invalid_limit: int) -> None:
    with pytest.raises(ValueError, match="limit"):
        list_settlement_summaries(  # type: ignore[arg-type]
            FakeConnection(FakeCursor([])),
            limit=invalid_limit,
        )


def test_repository_rejects_unknown_action() -> None:
    with pytest.raises(ValueError, match="下一步动作"):
        list_pending_reconciliation(  # type: ignore[arg-type]
            FakeConnection(FakeCursor([])),
            next_action="DELETE_DIFFERENCE",
        )
