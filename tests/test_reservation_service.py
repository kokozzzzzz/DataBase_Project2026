"""⑥预约事务服务单元测试，不连接真实 MySQL。"""

from __future__ import annotations

from datetime import datetime
from typing import Any

import pytest

from app.services.reservation_service import (
    call_next_queue,
    cancel_reservation,
    check_in_reservation,
    consume_admission,
    create_reservation,
    expire_overdue_admissions,
    join_queue,
    release_parking_space,
)


class FakeCursor:
    def __init__(self, out_row: dict[str, Any] | None = None) -> None:
        self.out_row = out_row or {}
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


def test_create_reservation_calls_procedure() -> None:
    cursor = FakeCursor({"p_reservation_id": 501})
    connection = FakeConnection(cursor)

    result = create_reservation(  # type: ignore[arg-type]
        connection,
        user_id=10001,
        vehicle_id=20001,
        gun_id=9401,
        starts_at=datetime(2026, 12, 20, 10, 0),
        ends_at=datetime(2026, 12, 20, 11, 0),
        source="APP",
        late_grace_minutes=15,
    )

    assert result == {"reservation_id": 501}
    sql, parameters = cursor.executions[0]
    assert "CALL sp_create_reservation" in sql
    assert parameters == (
        10001,
        20001,
        9401,
        datetime(2026, 12, 20, 10, 0),
        datetime(2026, 12, 20, 11, 0),
        "APP",
        15,
    )


def test_create_reservation_rejects_invalid_time_before_database() -> None:
    connection = FakeConnection(FakeCursor())
    with pytest.raises(ValueError, match="starts_at"):
        create_reservation(  # type: ignore[arg-type]
            connection,
            user_id=10001,
            vehicle_id=20001,
            gun_id=9401,
            starts_at=datetime(2026, 12, 20, 11, 0),
            ends_at=datetime(2026, 12, 20, 10, 0),
        )


def test_create_reservation_rejects_invalid_source() -> None:
    connection = FakeConnection(FakeCursor())
    with pytest.raises(ValueError, match="预约来源"):
        create_reservation(  # type: ignore[arg-type]
            connection,
            user_id=10001,
            vehicle_id=20001,
            gun_id=9401,
            starts_at=datetime(2026, 12, 20, 10, 0),
            ends_at=datetime(2026, 12, 20, 11, 0),
            source="UNKNOWN",
        )


def test_cancel_reservation_returns_released_occupancy() -> None:
    cursor = FakeCursor({"p_released_occupancy_id": 6001})
    connection = FakeConnection(cursor)

    result = cancel_reservation(  # type: ignore[arg-type]
        connection, reservation_id=1010, reason="用户取消"
    )

    assert result == {
        "reservation_id": 1010,
        "released_occupancy_id": 6001,
    }
    assert "CALL sp_cancel_reservation" in cursor.executions[0][0]


def test_check_in_reservation_returns_ids() -> None:
    cursor = FakeCursor({"p_checkin_id": 5001, "p_occupancy_id": 6001})
    connection = FakeConnection(cursor)

    result = check_in_reservation(  # type: ignore[arg-type]
        connection,
        reservation_id=1007,
        method="QR_CODE",
        at_time=datetime(2026, 11, 20, 8, 5),
    )

    assert result["checkin_id"] == 5001
    assert result["occupancy_id"] == 6001


def test_join_queue_returns_ticket() -> None:
    cursor = FakeCursor({"p_queue_id": 2001, "p_ticket_no": 1})
    connection = FakeConnection(cursor)

    result = join_queue(  # type: ignore[arg-type]
        connection,
        station_id=9101,
        user_id=10001,
        vehicle_id=20001,
        gun_id=9401,
        priority_class="WALK_IN",
        hold_minutes=10,
        at_time=datetime(2026, 11, 20, 8, 0),
    )

    assert result == {"queue_id": 2001, "ticket_no": 1}
    assert "CALL sp_join_queue" in cursor.executions[0][0]


def test_call_next_queue_without_waiting_returns_zero() -> None:
    cursor = FakeCursor(
        {
            "p_queue_id": 0,
            "p_user_id": 0,
            "p_vehicle_id": 0,
            "p_gun_id": 0,
            "p_ticket_no": 0,
        }
    )
    connection = FakeConnection(cursor)

    result = call_next_queue(  # type: ignore[arg-type]
        connection, station_id=9101, at_time=datetime(2026, 11, 20, 9, 0)
    )

    assert result["queue_id"] == 0
    assert result["has_waiting_queue"] is False


def test_release_parking_space_returns_bool() -> None:
    cursor = FakeCursor({"p_released": 1})
    connection = FakeConnection(cursor)

    result = release_parking_space(  # type: ignore[arg-type]
        connection, occupancy_id=6001, reason="VEHICLE_LEFT"
    )

    assert result["released"] is True


def test_consume_admission_rejects_invalid_channel() -> None:
    connection = FakeConnection(FakeCursor())
    with pytest.raises(ValueError, match="资格类型"):
        consume_admission(  # type: ignore[arg-type]
            connection, channel="DIRECT", admission_id=1001, order_id=8001
        )


def test_expire_overdue_admissions_returns_counts() -> None:
    cursor = FakeCursor(
        {"p_expired_reservations": 3, "p_expired_queues": 2}
    )
    connection = FakeConnection(cursor)

    result = expire_overdue_admissions(  # type: ignore[arg-type]
        connection, at_time=datetime(2026, 11, 20, 12, 0)
    )

    assert result == {"expired_reservations": 3, "expired_queues": 2}
