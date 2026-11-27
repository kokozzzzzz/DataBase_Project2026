"""用户注册和车辆逻辑CRUD单元测试，不连接真实MySQL。"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Any

import pytest

from app.services.customer_service import (
    CustomerOperationError,
    change_vehicle_status,
    close_user,
    register_user_with_vehicle,
    register_vehicle,
    update_user_profile,
    update_vehicle_profile,
)


NOW = datetime(2026, 11, 23, 10, 0, 0)
VALID_TO = datetime(2026, 12, 31, 23, 59, 59)
PHONE_HASH = "a" * 64
PLATE_HASH = "b" * 64


class FakeCursor:
    def __init__(self, fetch_rows: list[Any]) -> None:
        self.fetch_rows = fetch_rows
        self.executions: list[tuple[str, tuple[Any, ...]]] = []
        self.lastrowid = 0
        self.rowcount = 1

    def __enter__(self) -> "FakeCursor":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def execute(self, sql: str, parameters: tuple[Any, ...]) -> None:
        normalized = " ".join(sql.split())
        self.executions.append((normalized, parameters))
        if normalized.startswith("INSERT INTO `user`"):
            self.lastrowid = 10001
        elif normalized.startswith("INSERT INTO vehicle"):
            self.lastrowid = 20001
        elif normalized.startswith("INSERT INTO coupon"):
            self.lastrowid = 30001

    def fetchone(self) -> dict[str, Any] | None:
        return self.fetch_rows.pop(0) if self.fetch_rows else None

    def fetchall(self) -> list[dict[str, Any]]:
        value = self.fetch_rows.pop(0) if self.fetch_rows else []
        return value if isinstance(value, list) else []


class FakeConnection:
    def __init__(self, cursor: FakeCursor) -> None:
        self.fake_cursor = cursor

    def cursor(self) -> FakeCursor:
        return self.fake_cursor


def test_register_user_vehicle_and_newcomer_coupon_as_one_unit() -> None:
    cursor = FakeCursor(
        [
            {
                "promotion_id": 40001,
                "promotion_name": "新人券",
                "total_quantity": 100,
                "per_user_limit": 1,
                "valid_from": datetime(2026, 11, 1),
                "valid_to": VALID_TO,
                "status": "ACTIVE",
                "database_time": NOW,
            },
            {"user_id": 10001, "user_status": "ACTIVE"},
            {"total_issued": 0, "user_issued": 0},
        ]
    )

    result = register_user_with_vehicle(  # type: ignore[arg-type]
        FakeConnection(cursor),
        phone_ciphertext=b"encrypted-phone",
        phone_hash=PHONE_HASH,
        real_name=" 测试新人 ",
        real_name_status="VERIFIED",
        registration_channel="APP",
        plate_ciphertext=b"encrypted-plate",
        plate_hash=PLATE_HASH,
        model=" 测试车型 ",
        battery_capacity_kwh=Decimal("60.00"),
        max_charging_power_kw=Decimal("120.00"),
        fast_charge_supported=True,
        registered_at=NOW,
        newcomer_promotion_id=40001,
        newcomer_coupon_code="NEW-10001",
    )

    assert result["user_id"] == 10001
    assert result["vehicle_id"] == 20001
    assert result["coupon"]["coupon_id"] == 30001
    assert result["coupon"]["status"] == "AVAILABLE"
    assert [sql.split()[0:3] for sql, _ in cursor.executions[:2]] == [
        ["INSERT", "INTO", "`user`"],
        ["INSERT", "INTO", "vehicle"],
    ]


def test_register_user_rejects_verified_without_name() -> None:
    with pytest.raises(CustomerOperationError, match="real_name"):
        register_user_with_vehicle(  # type: ignore[arg-type]
            FakeConnection(FakeCursor([])),
            phone_ciphertext=b"encrypted-phone",
            phone_hash=PHONE_HASH,
            real_name=None,
            real_name_status="VERIFIED",
            registration_channel="APP",
            plate_ciphertext=b"encrypted-plate",
            plate_hash=PLATE_HASH,
        )


def test_update_user_profile_rejects_closed_user() -> None:
    cursor = FakeCursor([{"user_id": 10001, "user_status": "CLOSED"}])

    with pytest.raises(CustomerOperationError, match="已关闭"):
        update_user_profile(  # type: ignore[arg-type]
            FakeConnection(cursor),
            user_id=10001,
            real_name="测试用户",
            real_name_status="VERIFIED",
            registration_channel="WEB",
        )


def test_register_vehicle_requires_active_user() -> None:
    cursor = FakeCursor([{"user_id": 10001, "user_status": "DISABLED"}])

    with pytest.raises(CustomerOperationError, match="有效用户"):
        register_vehicle(  # type: ignore[arg-type]
            FakeConnection(cursor),
            user_id=10001,
            plate_ciphertext=b"encrypted-plate",
            plate_hash=PLATE_HASH,
        )


def test_update_vehicle_profile_updates_non_sensitive_fields() -> None:
    cursor = FakeCursor([{"vehicle_id": 20001, "vehicle_status": "ACTIVE"}])

    result = update_vehicle_profile(  # type: ignore[arg-type]
        FakeConnection(cursor),
        vehicle_id=20001,
        model="新车型",
        battery_capacity_kwh=Decimal("75.00"),
        max_charging_power_kw=Decimal("150.00"),
        fast_charge_supported=True,
    )

    assert result == {"vehicle_id": 20001, "status": "ACTIVE"}
    assert cursor.executions[-1][0].startswith("UPDATE vehicle")


def test_change_vehicle_status_uses_logical_disable() -> None:
    cursor = FakeCursor([{"vehicle_id": 20001, "vehicle_status": "ACTIVE"}])

    result = change_vehicle_status(  # type: ignore[arg-type]
        FakeConnection(cursor),
        vehicle_id=20001,
        target_status="DISABLED",
    )

    assert result["status"] == "DISABLED"
    assert cursor.executions[-1][0].startswith("UPDATE vehicle")
    assert all(not sql.startswith("DELETE") for sql, _ in cursor.executions)


def test_close_user_disables_vehicles_and_cancels_available_coupons() -> None:
    cursor = FakeCursor(
        [
            {"user_id": 10001, "user_status": "ACTIVE"},
            [],
        ]
    )
    cursor.rowcount = 2

    result = close_user(  # type: ignore[arg-type]
        FakeConnection(cursor),
        user_id=10001,
    )

    assert result["status"] == "CLOSED"
    assert all(not sql.startswith("DELETE") for sql, _ in cursor.executions)


def test_close_user_rejects_locked_coupon() -> None:
    cursor = FakeCursor(
        [
            {"user_id": 10001, "user_status": "ACTIVE"},
            [{"coupon_id": 30001, "status": "LOCKED"}],
        ]
    )

    with pytest.raises(CustomerOperationError, match="锁定中"):
        close_user(FakeConnection(cursor), user_id=10001)  # type: ignore[arg-type]
