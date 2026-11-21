from __future__ import annotations

from datetime import datetime
from typing import Any

import pytest

from app.database import c_repository as repository


class FakeCursor:
    def __init__(self, rows: list[dict[str, Any]] | None = None) -> None:
        self.rows = rows or []
        self.query: str | None = None
        self.parameters: Any = None
        self.rowcount = 1
        self.lastrowid = 17

    def __enter__(self) -> FakeCursor:
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def execute(self, query: str, parameters: Any = None) -> int:
        self.query = query
        self.parameters = parameters
        return 1

    def fetchall(self) -> list[dict[str, Any]]:
        return self.rows

    def fetchone(self) -> dict[str, Any] | None:
        return self.rows[0] if self.rows else None

    def nextset(self) -> bool:
        return False


class FakeConnection:
    def __init__(self, rows: list[dict[str, Any]] | None = None) -> None:
        self.cursor_instance = FakeCursor(rows)

    def cursor(self) -> FakeCursor:
        return self.cursor_instance


def test_list_alarms_uses_parameterized_filters() -> None:
    connection = FakeConnection([{"alarm_id": 1}])

    rows = repository.list_alarms(
        connection, pile_id=23, alarm_status="OPEN", limit=10, offset=5
    )

    assert rows == [{"alarm_id": 1}]
    assert "a.pile_id = %s" in connection.cursor_instance.query
    assert "a.alarm_status = %s" in connection.cursor_instance.query
    assert connection.cursor_instance.parameters == [23, "OPEN", 10, 5]


@pytest.mark.parametrize("limit", [0, 101, -1, True])
def test_list_inventory_rejects_invalid_page_size(limit: int) -> None:
    with pytest.raises(ValueError):
        repository.list_available_inventory(FakeConnection(), limit=limit)


def test_list_work_orders_rejects_unsupported_status() -> None:
    with pytest.raises(ValueError, match="Unsupported work_order_status"):
        repository.list_work_orders(FakeConnection(), work_order_status="IN_PROGRESS")


def test_list_telemetry_uses_half_open_time_range() -> None:
    connection = FakeConnection()
    since = datetime(2026, 11, 20, 9, 0)
    until = datetime(2026, 11, 20, 10, 0)

    repository.list_telemetry(
        connection, pile_id=3, since=since, until=until, limit=20
    )

    assert "collect_time >= %s AND collect_time < %s" in connection.cursor_instance.query
    assert connection.cursor_instance.parameters == (3, since, until, 20)


def test_list_telemetry_rejects_reversed_range() -> None:
    with pytest.raises(ValueError, match="earlier"):
        repository.list_telemetry(
            FakeConnection(),
            pile_id=3,
            since=datetime(2026, 11, 20, 10),
            until=datetime(2026, 11, 20, 9),
        )


def test_create_spare_part_uses_bound_values() -> None:
    connection = FakeConnection()

    part_id = repository.create_spare_part(
        connection, part_code="P-1", part_name="Fuse", unit="piece"
    )

    assert part_id == 17
    assert "%s" in connection.cursor_instance.query
    assert connection.cursor_instance.parameters == ("P-1", "Fuse", None, None, "piece")


def test_inventory_operation_name_is_allow_listed() -> None:
    with pytest.raises(ValueError, match="Unsupported inventory operation"):
        repository.record_inventory_movement(
            FakeConnection(), procedure="sp_c_injected", parameters=()
        )
