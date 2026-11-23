"""会员持久层单元测试，不连接真实 MySQL。"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Any

import pytest

from app.database.membership_repository import (
    fetch_user_account_overview,
    fetch_fleet_monthly_bill_summary,
    fetch_database_health,
    fetch_promotion_redemption_statistics,
    fetch_quota_usage,
    list_available_global_promotions,
    list_fleet_monthly_charging_details,
    list_target_users,
    list_user_charging_history,
    list_user_order_invoice_trace,
    list_user_vehicles,
    list_user_profiles,
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

    def execute(
        self,
        sql: str,
        parameters: list[Any] | tuple[Any, ...] = (),
    ) -> None:
        self.sql = sql
        self.parameters = list(parameters)

    def fetchone(self) -> dict[str, Any] | None:
        return self.rows[0] if self.rows else None

    def fetchall(self) -> list[dict[str, Any]]:
        return self.rows


class FakeConnection:
    def __init__(self, cursor: FakeCursor) -> None:
        self.fake_cursor = cursor

    def cursor(self) -> FakeCursor:
        return self.fake_cursor


def test_fetch_database_health_includes_session_time_zone() -> None:
    expected_row = {
        "mysql_version": "8.0.46",
        "database_name": "charging_platform",
        "session_time_zone": "+08:00",
        "core_table_count": 9,
    }
    cursor = FakeCursor([expected_row])
    connection = FakeConnection(cursor)

    actual_row = fetch_database_health(connection)  # type: ignore[arg-type]

    assert actual_row == expected_row
    assert "@@session.time_zone AS session_time_zone" in cursor.sql


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
    assert "LEFT JOIN membership_level AS ml" in cursor.sql
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


def test_list_available_global_promotions_uses_time_and_amount_parameters() -> None:
    cursor = FakeCursor([{"promotion_id": 40001}])
    connection = FakeConnection(cursor)
    query_time = datetime(2026, 11, 19, 12, 0, 0)
    order_amount = Decimal("100.00")

    rows = list_available_global_promotions(  # type: ignore[arg-type]
        connection,
        order_amount=order_amount,
        at_time=query_time,
    )

    assert rows == [{"promotion_id": 40001}]
    assert cursor.parameters == [query_time, query_time, order_amount]
    assert "applicability_scope = 'ALL'" in cursor.sql
    assert "minimum_spend <= %s" in cursor.sql


def test_list_user_vehicles_does_not_expose_plate_fields() -> None:
    cursor = FakeCursor([{"vehicle_id": 20001, "model": "测试车型"}])
    connection = FakeConnection(cursor)

    rows = list_user_vehicles(  # type: ignore[arg-type]
        connection,
        user_id=10001,
        vehicle_status="ACTIVE",
        limit=10,
        offset=5,
    )

    assert rows == [{"vehicle_id": 20001, "model": "测试车型"}]
    assert cursor.parameters == [10001, "ACTIVE", 10, 5]
    assert "plate_ciphertext" not in cursor.sql
    assert "plate_hash" not in cursor.sql


def test_list_target_users_uses_level_and_half_open_registration_period() -> None:
    cursor = FakeCursor([{"user_id": 10001, "level_id": 1}])
    connection = FakeConnection(cursor)
    period_start = datetime(2026, 11, 1)
    period_end = datetime(2026, 12, 1)

    rows = list_target_users(  # type: ignore[arg-type]
        connection,
        level_id=1,
        registered_start=period_start,
        registered_end=period_end,
        limit=50,
    )

    assert rows == [{"user_id": 10001, "level_id": 1}]
    assert cursor.parameters == [1, period_start, period_end, 50, 0]
    assert "u.real_name_status = 'VERIFIED'" in cursor.sql
    assert "u.registered_at >= %s" in cursor.sql
    assert "u.registered_at < %s" in cursor.sql


def test_fetch_promotion_redemption_statistics_is_parameterized() -> None:
    expected = {
        "promotion_id": 40001,
        "issued_count": 20,
        "redeemed_count": 10,
        "redemption_rate": Decimal("0.5000"),
    }
    cursor = FakeCursor([expected])

    row = fetch_promotion_redemption_statistics(  # type: ignore[arg-type]
        FakeConnection(cursor),
        promotion_id=40001,
    )

    assert row == expected
    assert cursor.parameters == [40001]
    assert "COUNT(DISTINCT c.coupon_id)" in cursor.sql
    assert "COUNT(DISTINCT cr.redemption_id)" in cursor.sql


def test_list_user_charging_history_uses_half_open_period_and_aggregates() -> None:
    expected = [{"order_id": 5, "net_paid_amount": Decimal("7.00")}]
    cursor = FakeCursor(expected)
    period_start = datetime(2026, 11, 1)
    period_end = datetime(2026, 12, 1)

    rows = list_user_charging_history(  # type: ignore[arg-type]
        FakeConnection(cursor),
        user_id=10001,
        period_start=period_start,
        period_end=period_end,
        limit=20,
        offset=5,
    )

    assert rows == expected
    assert cursor.parameters == [10001, period_start, period_end, 20, 5]
    assert "WITH successful_payment AS" in cursor.sql
    assert "o.starts_at >= %s" in cursor.sql
    assert "o.starts_at < %s" in cursor.sql
    assert "LEFT JOIN coupon_redemption AS cr" in cursor.sql


def test_fetch_user_account_overview_separates_balance_from_funds() -> None:
    expected = {
        "user_id": 10001,
        "current_balance": Decimal("10.00"),
        "net_paid_amount": Decimal("7.00"),
    }
    cursor = FakeCursor([expected])

    row = fetch_user_account_overview(  # type: ignore[arg-type]
        FakeConnection(cursor),
        user_id=10001,
    )

    assert row == expected
    assert cursor.parameters == [10001, 10001, 10001]
    assert "u.balance AS current_balance" in cursor.sql
    assert "pr.status = 'SUCCESS'" in cursor.sql
    assert "SUM(rr.amount)" in cursor.sql


def test_list_user_order_invoice_trace_does_not_expose_tax_ciphertext() -> None:
    expected = [{"order_id": 5, "statement_no": "ST-001"}]
    cursor = FakeCursor(expected)

    rows = list_user_order_invoice_trace(  # type: ignore[arg-type]
        FakeConnection(cursor),
        user_id=10001,
        limit=10,
        offset=2,
    )

    assert rows == expected
    assert cursor.parameters == [10001, 10, 2]
    assert "sd.detail_type = 'ORDER'" in cursor.sql
    assert "LEFT JOIN invoice_record AS ir" in cursor.sql
    assert "tax_number_ciphertext" not in cursor.sql


def test_list_fleet_monthly_details_aggregates_payments_before_join() -> None:
    expected_rows = [{"order_id": 5, "net_paid_amount": Decimal("8.00")}]
    cursor = FakeCursor(expected_rows)
    connection = FakeConnection(cursor)
    period_start = datetime(2026, 11, 1)
    period_end = datetime(2026, 12, 1)

    rows = list_fleet_monthly_charging_details(  # type: ignore[arg-type]
        connection,
        fleet_id=60001,
        period_start=period_start,
        period_end=period_end,
        limit=20,
        offset=5,
    )

    assert rows == expected_rows
    assert cursor.parameters == [60001, period_start, period_end, 20, 5]
    assert "WITH successful_payment AS" in cursor.sql
    assert "pr.status = 'SUCCESS'" in cursor.sql
    assert "o.starts_at >= fv.joined_at" in cursor.sql
    assert "o.confirmed_at >= %s" in cursor.sql
    assert "o.confirmed_at < %s" in cursor.sql


def test_fetch_fleet_monthly_summary_returns_zero_capable_aggregate() -> None:
    expected = {
        "fleet_id": 60001,
        "order_count": 2,
        "payable_amount": Decimal("16.00"),
    }
    cursor = FakeCursor([expected])
    connection = FakeConnection(cursor)
    period_start = datetime(2026, 11, 1)
    period_end = datetime(2026, 12, 1)

    row = fetch_fleet_monthly_bill_summary(  # type: ignore[arg-type]
        connection,
        fleet_id=60001,
        period_start=period_start,
        period_end=period_end,
    )

    assert row == expected
    assert cursor.parameters == [
        period_start,
        period_end,
        period_start,
        period_end,
        60001,
    ]
    assert "COUNT(DISTINCT o.vehicle_id)" in cursor.sql
    assert "COALESCE(SUM(sr.refund_amount), 0.00)" in cursor.sql


def test_fetch_fleet_monthly_summary_rejects_invalid_period() -> None:
    connection = FakeConnection(FakeCursor([]))
    same_time = datetime(2026, 11, 1)

    with pytest.raises(ValueError, match="period_start"):
        fetch_fleet_monthly_bill_summary(  # type: ignore[arg-type]
            connection,
            fleet_id=60001,
            period_start=same_time,
            period_end=same_time,
        )


def test_fetch_quota_usage_supports_all_three_scopes() -> None:
    expected = {
        "quota_record_id": 80001,
        "quota_type": "AMOUNT",
        "used_value": Decimal("16.00"),
        "quota_status": "WITHIN_LIMIT",
    }
    cursor = FakeCursor([expected])
    connection = FakeConnection(cursor)

    row = fetch_quota_usage(  # type: ignore[arg-type]
        connection,
        quota_record_id=80001,
    )

    assert row == expected
    assert cursor.parameters == [80001]
    assert "q.quota_scope = 'VEHICLE'" in cursor.sql
    assert "q.quota_scope = 'FLEET'" in cursor.sql
    assert "q.quota_scope = 'ENTERPRISE'" in cursor.sql
    assert "THEN 'EXCEEDED'" in cursor.sql


@pytest.mark.parametrize("invalid_id", [0, -1])
def test_fetch_quota_usage_rejects_invalid_id(invalid_id: int) -> None:
    connection = FakeConnection(FakeCursor([]))

    with pytest.raises(ValueError, match="quota_record_id"):
        fetch_quota_usage(  # type: ignore[arg-type]
            connection,
            quota_record_id=invalid_id,
        )
