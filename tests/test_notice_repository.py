"""⑧公告持久层单元测试，不连接真实 MySQL。"""

from __future__ import annotations

from typing import Any

import pytest

from app.database.notice_repository import (
    get_notice_detail,
    list_notice_delivery_stats,
    list_notice_revision_history,
    list_outage_affected_users,
    list_pending_notifications,
    list_public_notices,
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


def test_list_public_notices_filters_and_paginates() -> None:
    cursor = FakeCursor([{"notice_id": 3001}])
    connection = FakeConnection(cursor)

    rows = list_public_notices(  # type: ignore[arg-type]
        connection, station_id=9101, severity="WARNING", limit=5, offset=10
    )

    assert rows == [{"notice_id": 3001}]
    sql, parameters = cursor.executions[0]
    assert "FROM v_a_public_notice_active" in sql
    assert parameters == [9101, "WARNING", 5, 10]


def test_list_public_notices_rejects_invalid_severity() -> None:
    connection = FakeConnection(FakeCursor([]))
    with pytest.raises(ValueError, match="公告级别"):
        list_public_notices(connection, severity="UNKNOWN")  # type: ignore[arg-type]


def test_list_notice_delivery_stats_filters_notice() -> None:
    cursor = FakeCursor([{"notice_id": 3011}])
    connection = FakeConnection(cursor)

    rows = list_notice_delivery_stats(  # type: ignore[arg-type]
        connection, notice_id=3011, limit=20
    )

    assert rows == [{"notice_id": 3011}]
    sql, parameters = cursor.executions[0]
    assert "WHERE notice_id = %s" in sql
    assert parameters == [3011, 20]


def test_list_outage_affected_users_filters_station() -> None:
    cursor = FakeCursor([{"recipient_id": 7011}])
    connection = FakeConnection(cursor)

    rows = list_outage_affected_users(  # type: ignore[arg-type]
        connection, station_id=9101, limit=50
    )

    assert rows == [{"recipient_id": 7011}]
    sql, parameters = cursor.executions[0]
    assert "FROM v_a_outage_affected_users" in sql
    assert parameters == [9101, 50]


def test_get_notice_detail_uses_parameter() -> None:
    cursor = FakeCursor([{"notice_id": 3001}])
    connection = FakeConnection(cursor)

    row = get_notice_detail(connection, 3001)  # type: ignore[arg-type]

    assert row == {"notice_id": 3001}
    sql, parameters = cursor.executions[0]
    assert "WHERE n.notice_id = %s" in sql
    assert parameters == (3001,)


def test_list_notice_revision_history_orders_by_revision() -> None:
    cursor = FakeCursor([{"revision_no": 1}])
    connection = FakeConnection(cursor)

    rows = list_notice_revision_history(connection, 3001)  # type: ignore[arg-type]

    assert rows == [{"revision_no": 1}]
    sql, parameters = cursor.executions[0]
    assert "ORDER BY revision_no" in sql
    assert parameters == (3001,)


def test_list_pending_notifications_filters_notice() -> None:
    cursor = FakeCursor([{"notification_id": 1}])
    connection = FakeConnection(cursor)

    rows = list_pending_notifications(  # type: ignore[arg-type]
        connection, notice_id=3011, limit=20
    )

    assert rows == [{"notification_id": 1}]
    sql, parameters = cursor.executions[0]
    assert "nf.status = 'PENDING'" in sql
    assert "nr.notice_id = %s" in sql
    assert parameters == [3011, 20]
