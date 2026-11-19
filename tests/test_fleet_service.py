"""车队车辆事务服务单元测试，不连接真实 MySQL。"""

from __future__ import annotations

from datetime import datetime
from typing import Any

import pytest

from app.services.fleet_service import (
    FleetVehicleError,
    add_vehicle_to_fleet,
    remove_vehicle_from_fleet,
)


class FakeCursor:
    def __init__(self, fetch_rows: list[dict[str, Any] | None]) -> None:
        self.fetch_rows = fetch_rows
        self.executions: list[tuple[str, tuple[Any, ...]]] = []
        self.rowcount = 0
        self.lastrowid = 70021

    def __enter__(self) -> "FakeCursor":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def execute(self, sql: str, parameters: tuple[Any, ...]) -> None:
        normalized_sql = " ".join(sql.split())
        self.executions.append((normalized_sql, parameters))
        if normalized_sql.startswith("UPDATE fleet_vehicle"):
            self.rowcount = 1

    def fetchone(self) -> dict[str, Any] | None:
        return self.fetch_rows.pop(0)


class FakeConnection:
    def __init__(self, cursor: FakeCursor) -> None:
        self.fake_cursor = cursor

    def cursor(self) -> FakeCursor:
        return self.fake_cursor


def test_add_vehicle_to_fleet_creates_active_relation() -> None:
    cursor = FakeCursor(
        [
            {"vehicle_id": 20001, "vehicle_status": "ACTIVE"},
            {
                "fleet_id": 60002,
                "fleet_name": "测试车队02",
                "fleet_status": "ACTIVE",
                "enterprise_status": "ACTIVE",
            },
            None,
        ]
    )

    result = add_vehicle_to_fleet(  # type: ignore[arg-type]
        FakeConnection(cursor),
        vehicle_id=20001,
        fleet_id=60002,
    )

    assert result["fleet_vehicle_id"] == 70021
    assert result["status"] == "ACTIVE"
    assert all("FOR UPDATE" in sql for sql, _ in cursor.executions[:3])
    assert cursor.executions[3][0].startswith("INSERT INTO fleet_vehicle")


def test_add_vehicle_to_fleet_rejects_existing_active_relation() -> None:
    cursor = FakeCursor(
        [
            {"vehicle_id": 20001, "vehicle_status": "ACTIVE"},
            {
                "fleet_id": 60002,
                "fleet_name": "测试车队02",
                "fleet_status": "ACTIVE",
                "enterprise_status": "ACTIVE",
            },
            {"fleet_vehicle_id": 70001, "fleet_id": 60001},
        ]
    )

    with pytest.raises(FleetVehicleError, match="先退出原车队"):
        add_vehicle_to_fleet(  # type: ignore[arg-type]
            FakeConnection(cursor),
            vehicle_id=20001,
            fleet_id=60002,
        )


def test_remove_vehicle_from_fleet_closes_relation() -> None:
    joined_at = datetime(2026, 11, 2, 8, 0, 0)
    left_at = datetime(2026, 11, 19, 12, 0, 0)
    cursor = FakeCursor(
        [
            {"vehicle_id": 20001},
            {
                "fleet_vehicle_id": 70001,
                "fleet_id": 60001,
                "joined_at": joined_at,
            },
        ]
    )

    result = remove_vehicle_from_fleet(  # type: ignore[arg-type]
        FakeConnection(cursor),
        vehicle_id=20001,
        fleet_id=60001,
        left_at=left_at,
    )

    assert result["status"] == "LEFT"
    assert cursor.executions[2][0].startswith("UPDATE fleet_vehicle")
    assert cursor.executions[2][1] == (left_at, 70001)


def test_remove_vehicle_from_fleet_rejects_missing_active_relation() -> None:
    cursor = FakeCursor([{"vehicle_id": 20001}, None])

    with pytest.raises(FleetVehicleError, match="不属于任何有效车队"):
        remove_vehicle_from_fleet(  # type: ignore[arg-type]
            FakeConnection(cursor),
            vehicle_id=20001,
        )
