"""⑧公告事务服务单元测试，不连接真实 MySQL。"""

from __future__ import annotations

from datetime import datetime
from typing import Any

import pytest

from app.services.notice_service import (
    create_notice,
    expire_notices,
    publish_notice,
    update_notification_status,
    withdraw_notice,
)


class FakeCursor:
    def __init__(
        self,
        out_row: dict[str, Any] | None = None,
        *,
        lastrowid: int = 3001,
    ) -> None:
        self.out_row = out_row or {}
        self.lastrowid = lastrowid
        self.executions: list[tuple[str, tuple[Any, ...]]] = []

    def __enter__(self) -> "FakeCursor":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def execute(self, sql: str, parameters: tuple[Any, ...] = ()) -> None:
        self.executions.append((" ".join(sql.split()), tuple(parameters)))

    def nextset(self) -> None:
        return None

    def fetchone(self) -> dict[str, Any] | None:
        return self.out_row


class FakeConnection:
    def __init__(self, cursor: FakeCursor) -> None:
        self.fake_cursor = cursor

    def cursor(self) -> FakeCursor:
        return self.fake_cursor


def test_create_notice_inserts_draft() -> None:
    cursor = FakeCursor(lastrowid=3101)
    connection = FakeConnection(cursor)

    result = create_notice(  # type: ignore[arg-type]
        connection,
        station_id=9101,
        notice_type="PUBLIC",
        severity="INFO",
        title="测试公告",
        content="测试正文",
        effective_from=datetime(2026, 11, 20, 0, 0),
        effective_to=datetime(2026, 12, 31, 23, 59, 59),
        created_by="tester",
    )

    assert result == {"notice_id": 3101, "status": "DRAFT"}
    sql, parameters = cursor.executions[0]
    assert "INSERT INTO station_notice" in sql
    assert "'DRAFT'" in sql
    assert parameters[0] == 9101
    assert parameters[-1] is None


def test_create_notice_requires_outage_plan_for_targeted() -> None:
    connection = FakeConnection(FakeCursor())
    with pytest.raises(ValueError, match="related_outage_plan_id"):
        create_notice(  # type: ignore[arg-type]
            connection,
            station_id=9101,
            notice_type="OUTAGE_TARGETED",
            severity="WARNING",
            title="停运",
            content="停运正文",
            effective_from=datetime(2026, 11, 20, 0, 0),
            effective_to=None,
            created_by="tester",
        )


def test_create_notice_rejects_public_with_plan() -> None:
    connection = FakeConnection(FakeCursor())
    with pytest.raises(ValueError, match="公开公告"):
        create_notice(  # type: ignore[arg-type]
            connection,
            station_id=9101,
            notice_type="PUBLIC",
            severity="INFO",
            title="公开",
            content="公开正文",
            effective_from=datetime(2026, 11, 20, 0, 0),
            effective_to=None,
            created_by="tester",
            related_outage_plan_id=9501,
        )


def test_publish_notice_returns_counts() -> None:
    cursor = FakeCursor(
        {"p_recipient_count": 3, "p_notification_count": 3}
    )
    connection = FakeConnection(cursor)

    result = publish_notice(  # type: ignore[arg-type]
        connection,
        notice_id=3011,
        operator="tester",
        at_time=datetime(2026, 11, 20, 9, 0),
    )

    assert result["recipient_count"] == 3
    assert result["notification_count"] == 3
    assert "CALL sp_publish_notice" in cursor.executions[0][0]


def test_withdraw_notice_requires_reason() -> None:
    connection = FakeConnection(FakeCursor())
    with pytest.raises(ValueError, match="reason"):
        withdraw_notice(  # type: ignore[arg-type]
            connection,
            notice_id=3011,
            operator="tester",
            reason="   ",
        )


def test_update_notification_status_rejects_invalid_status() -> None:
    connection = FakeConnection(FakeCursor())
    with pytest.raises(ValueError, match="通知状态"):
        update_notification_status(  # type: ignore[arg-type]
            connection, notification_id=1, status="UNKNOWN"
        )


def test_expire_notices_returns_count() -> None:
    cursor = FakeCursor({"p_expired_count": 2})
    connection = FakeConnection(cursor)

    result = expire_notices(  # type: ignore[arg-type]
        connection, at_time=datetime(2026, 11, 20, 12, 0)
    )

    assert result == {"expired_notices": 2}
    assert "CALL sp_expire_notices" in cursor.executions[0][0]
