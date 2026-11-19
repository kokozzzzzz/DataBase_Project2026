"""会员等级变更业务单元测试，不连接真实 MySQL。"""

from __future__ import annotations

from typing import Any

import pytest

from app.services.membership_service import MembershipChangeError, change_membership_level


class FakeCursor:
    def __init__(self, fetch_rows: list[dict[str, Any] | None]) -> None:
        self.fetch_rows = fetch_rows
        self.executions: list[tuple[str, tuple[Any, ...]]] = []
        self.rowcount = 0
        self.lastrowid = 30021

    def __enter__(self) -> "FakeCursor":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def execute(self, sql: str, parameters: tuple[Any, ...]) -> None:
        normalized_sql = " ".join(sql.split())
        self.executions.append((normalized_sql, parameters))
        if normalized_sql.startswith("UPDATE `user`"):
            self.rowcount = 1

    def fetchone(self) -> dict[str, Any] | None:
        return self.fetch_rows.pop(0)


class FakeConnection:
    def __init__(self, cursor: FakeCursor) -> None:
        self.fake_cursor = cursor

    def cursor(self) -> FakeCursor:
        return self.fake_cursor


def test_change_membership_level_updates_user_and_history() -> None:
    cursor = FakeCursor(
        [
            {
                "user_id": 10001,
                "current_level_id": 1,
                "user_status": "ACTIVE",
                "current_sort_order": 1,
            },
            {
                "level_id": 2,
                "level_name": "银卡会员",
                "sort_order": 2,
                "status": "ACTIVE",
            },
        ]
    )
    connection = FakeConnection(cursor)

    result = change_membership_level(  # type: ignore[arg-type]
        connection,
        user_id=10001,
        target_level_id=2,
        change_reason="消费达标升级",
    )

    assert result["change_type"] == "UPGRADE"
    assert result["membership_record_id"] == 30021
    assert any(sql.startswith("UPDATE `user`") for sql, _ in cursor.executions)
    assert any(sql.startswith("INSERT INTO membership_record") for sql, _ in cursor.executions)
    assert cursor.executions[0][1] == (10001,)
    assert cursor.executions[2][1] == (2, 10001, 1)


def test_change_membership_level_rejects_same_level() -> None:
    cursor = FakeCursor(
        [
            {
                "user_id": 10001,
                "current_level_id": 1,
                "user_status": "ACTIVE",
                "current_sort_order": 1,
            }
        ]
    )
    connection = FakeConnection(cursor)

    with pytest.raises(MembershipChangeError, match="相同"):
        change_membership_level(  # type: ignore[arg-type]
            connection,
            user_id=10001,
            target_level_id=1,
            change_reason="重复操作",
        )


def test_change_membership_level_rejects_missing_user() -> None:
    connection = FakeConnection(FakeCursor([None]))

    with pytest.raises(MembershipChangeError, match="不存在"):
        change_membership_level(  # type: ignore[arg-type]
            connection,
            user_id=99999,
            target_level_id=2,
            change_reason="测试",
        )
