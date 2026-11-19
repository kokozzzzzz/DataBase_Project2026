"""会员持久层单元测试，不连接真实 MySQL。"""

from __future__ import annotations

from typing import Any

import pytest

from app.database.membership_repository import list_user_profiles


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
        self.sql = sql
        self.parameters = parameters

    def fetchall(self) -> list[dict[str, Any]]:
        return self.rows


class FakeConnection:
    def __init__(self, cursor: FakeCursor) -> None:
        self.fake_cursor = cursor

    def cursor(self) -> FakeCursor:
        return self.fake_cursor


def test_list_user_profiles_uses_parameters() -> None:
    expected_rows = [{"user_id": 10001, "level_name": "测试等级01"}]
    cursor = FakeCursor(expected_rows)
    connection = FakeConnection(cursor)

    actual_rows = list_user_profiles(  # type: ignore[arg-type]
        connection,
        user_status="ACTIVE",
        limit=5,
        offset=10,
    )

    assert actual_rows == expected_rows
    assert cursor.parameters == ["ACTIVE", 5, 10]
    assert "WHERE u.user_status = %s" in cursor.sql
    assert "LIMIT %s OFFSET %s" in cursor.sql


@pytest.mark.parametrize("invalid_limit", [0, 101])
def test_list_user_profiles_rejects_invalid_limit(invalid_limit: int) -> None:
    connection = FakeConnection(FakeCursor([]))

    with pytest.raises(ValueError, match="limit"):
        list_user_profiles(connection, limit=invalid_limit)  # type: ignore[arg-type]


def test_list_user_profiles_rejects_invalid_status() -> None:
    connection = FakeConnection(FakeCursor([]))

    with pytest.raises(ValueError, match="用户状态"):
        list_user_profiles(connection, user_status="UNKNOWN")  # type: ignore[arg-type]
