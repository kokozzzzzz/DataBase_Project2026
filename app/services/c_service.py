"""Validation and orchestration for C-module persistence operations."""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Any

from pymysql.connections import Connection

from app.database import c_repository as repository


def ingest_sample(
    connection: Connection,
    *,
    pile_id: int,
    gun_id: int | None,
    collect_time: datetime,
    voltage: Decimal | None = None,
    current: Decimal | None = None,
    power: Decimal | None = None,
    module_temp: Decimal | None = None,
    offline_duration_sec: int = 0,
    fault_code: str | None = None,
    offline_threshold_sec: int = 0,
    quality_flag: str = "NORMAL",
) -> dict[str, int | None]:
    """Validate a device sample before the DB transaction writes it and any alarm."""

    for name, value in (
        ("voltage", voltage),
        ("current", current),
        ("power", power),
    ):
        if value is not None and not isinstance(value, Decimal):
            raise TypeError(f"{name} must be Decimal or None.")
        if value is not None and value < 0:
            raise ValueError(f"{name} cannot be negative.")
    if module_temp is not None and not isinstance(module_temp, Decimal):
        raise TypeError("module_temp must be Decimal or None.")
    if module_temp is not None and not Decimal("-50") <= module_temp <= Decimal("200"):
        raise ValueError("module_temp must be between -50 and 200.")
    if fault_code is not None and not fault_code.strip():
        fault_code = None
    return repository.ingest_telemetry(
        connection,
        pile_id=pile_id,
        gun_id=gun_id,
        collect_time=collect_time,
        voltage=voltage,
        current=current,
        power=power,
        module_temp=module_temp,
        offline_duration_sec=offline_duration_sec,
        fault_code=fault_code,
        quality_flag=quality_flag,
        offline_threshold_sec=offline_threshold_sec,
    )


def dispatch_alarm(
    connection: Connection,
    *,
    alarm_id: int,
    work_order_no: str,
    maintainer_id: int,
    work_order_type: str = "REPAIR",
) -> int:
    """Create a new work order for an active alarm; repeat dispatches stay auditable."""

    return repository.dispatch_work_order(
        connection,
        alarm_id=alarm_id,
        work_order_no=work_order_no,
        work_order_type=work_order_type,
        maintainer_id=maintainer_id,
    )


def list_alarm_board(
    connection: Connection,
    *,
    pile_id: int | None = None,
    alarm_status: str | None = None,
    limit: int = 50,
    offset: int = 0,
) -> list[dict[str, Any]]:
    return repository.list_alarms(
        connection,
        pile_id=pile_id,
        alarm_status=alarm_status,
        limit=limit,
        offset=offset,
    )


def list_work_order_board(
    connection: Connection,
    *,
    work_order_status: str | None = None,
    alarm_id: int | None = None,
    limit: int = 50,
    offset: int = 0,
) -> list[dict[str, Any]]:
    return repository.list_work_orders(
        connection,
        work_order_status=work_order_status,
        alarm_id=alarm_id,
        limit=limit,
        offset=offset,
    )
