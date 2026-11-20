"""⑥预约持久层单元测试，不连接真实 MySQL。"""

from __future__ import annotations

from datetime import date
from typing import Any

import pytest

from app.database.reservation_repository import (
    get_reservation_detail,
    list_active_occupancies,
    list_queue_board,
    list_reservation_board,
    list_reservation_fulfillment,
    list_status_history,
)


class FakeCursor:
    def __init__(self, rows: list[dict[str, Any]]) -> None:
        self.rows = rows
        self.executions: list[tuple[str, Any]] = []

    def __enter__(self) -> "FakeCursor":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def execute(self, sql: str, parameters: Any) -> None:
        self.executions.append((" ".join(sql.split()), parameters))

    def fetchall(self) -> list[dict[str, Any]]:
        return self.rows

    def fetchone(self) -> dict[str, Any] | None:
        return self.rows[0] if self.rows else None


class FakeConnection:
    def __init__(self, cursor: FakeCursor) -> None:
        self.fake_cursor = cursor

    def cursor(self) -> FakeCursor:
        return self.fake_cursor


def test_list_reservation_board_filters_and_paginates() -> None:
    expected = [{"reservation_id": 1001}]
    cursor = FakeCursor(expected)
    connection = FakeConnection(cursor)

    rows = list_reservation_board(  # type: ignore[arg-type]
        connection,
        station_id=9101,
        status="BOOKED",
        limit=5,
        offset=10,
    )

    assert rows == expected
    sql, parameters = cursor.executions[0]
    assert "FROM v_a_reservation_board" in sql
    assert "station_id = %s" in sql
    assert "status = %s" in sql
    assert parameters == [9101, "BOOKED", 5, 10]


@pytest.mark.parametrize("invalid_limit", [0, 101])
def test_list_reservation_board_rejects_invalid_limit(invalid_limit: int) -> None:
    connection = FakeConnection(FakeCursor([]))
    with pytest.raises(ValueError, match="limit"):
        list_reservation_board(connection, limit=invalid_limit)  # type: ignore[arg-type]


def test_list_reservation_board_rejects_invalid_status() -> None:
    connection = FakeConnection(FakeCursor([]))
    with pytest.raises(ValueError, match="预约状态"):
        list_reservation_board(connection, status="UNKNOWN")  # type: ignore[arg-type]


def test_list_queue_board_orders_by_priority() -> None:
    cursor = FakeCursor([{"queue_id": 2005}])
    connection = FakeConnection(cursor)

    rows = list_queue_board(  # type: ignore[arg-type]
        connection, station_id=9101, status="CALLED", limit=20, offset=0
    )

    assert rows == [{"queue_id": 2005}]
    sql, parameters = cursor.executions[0]
    assert "ORDER BY priority_score DESC, joined_at ASC" in sql
    assert parameters == [9101, "CALLED", 20, 0]


def test_list_active_occupancies_uses_station_filter() -> None:
    cursor = FakeCursor([{"occupancy_id": 6001}])
    connection = FakeConnection(cursor)

    rows = list_active_occupancies(  # type: ignore[arg-type]
        connection, station_id=9101, limit=10
    )

    assert rows == [{"occupancy_id": 6001}]
    sql, parameters = cursor.executions[0]
    assert "FROM v_a_parking_occupancy_live" in sql
    assert "WHERE station_id = %s" in sql
    assert parameters == [9101, 10]


def test_list_reservation_fulfillment_rejects_reversed_dates() -> None:
    connection = FakeConnection(FakeCursor([]))
    with pytest.raises(ValueError, match="from_date"):
        list_reservation_fulfillment(  # type: ignore[arg-type]
            connection,
            from_date=date(2026, 11, 21),
            to_date=date(2026, 11, 20),
        )


def test_get_reservation_detail_uses_parameter() -> None:
    cursor = FakeCursor([{"reservation_id": 1001}])
    connection = FakeConnection(cursor)

    row = get_reservation_detail(connection, 1001)  # type: ignore[arg-type]

    assert row == {"reservation_id": 1001}
    sql, parameters = cursor.executions[0]
    assert "WHERE r.reservation_id = %s" in sql
    assert parameters == (1001,)


def test_list_status_history_requires_exactly_one_identifier() -> None:
    connection = FakeConnection(FakeCursor([]))

    with pytest.raises(ValueError, match="只能提供一个"):
        list_status_history(connection)  # type: ignore[arg-type]

    with pytest.raises(ValueError, match="只能提供一个"):
        list_status_history(  # type: ignore[arg-type]
            connection, reservation_id=1001, queue_id=2001
        )
