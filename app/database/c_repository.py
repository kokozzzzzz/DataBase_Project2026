"""Parameterized persistence operations for C's monitoring and inventory module."""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal
from typing import Any

from pymysql.connections import Connection


VALID_ALARM_STATUSES = frozenset({"OPEN", "ACKNOWLEDGED", "RESOLVED", "CLOSED"})
VALID_WORK_ORDER_STATUSES = frozenset(
    {"ASSIGNED", "ACCEPTED", "ARRIVED", "REPAIR_REQUIRED", "REPAIRED", "CLOSED", "CANCELLED"}
)
VALID_PART_STATUSES = frozenset({"ACTIVE", "INACTIVE"})
VALID_WAREHOUSE_STATUSES = frozenset({"ACTIVE", "INACTIVE"})
MAX_PAGE_SIZE = 100


def register_outage_plan(connection, *, station_id, gun_id, starts_at, ends_at, reason):
    """C登记共享停运，参与调用方事务，供A通知与B开单读取。"""
    _validate_id('station_id', station_id)
    if gun_id is not None:
        _validate_id('gun_id', gun_id)
    if (not isinstance(starts_at, datetime) or not isinstance(ends_at, datetime)
            or starts_at.tzinfo is not None or ends_at.tzinfo is not None or starts_at >= ends_at):
        raise ValueError('停运时间必须为有效的北京时间半开区间')
    if not isinstance(reason,str) or not reason.strip() or len(reason)>255:
        raise ValueError('停运原因不能为空且不得超过255字符')
    with connection.cursor() as cursor:
        cursor.execute('SELECT station_id FROM station WHERE station_id=%s FOR UPDATE',(station_id,))
        if cursor.fetchone() is None:
            raise LookupError('场站不存在')
        cursor.execute('''INSERT INTO equipment_outage_plan(station_id,gun_id,starts_at,ends_at,reason)
            VALUES(%s,%s,%s,%s,%s)''',(station_id,gun_id,starts_at,ends_at,reason.strip()))
        return cursor.lastrowid


def finish_outage_plan(connection, *, outage_plan_id, cancelled=False):
    """人工取消/完成计划；历史通知保留，后续变更通知由A发布。"""
    _validate_id('outage_plan_id',outage_plan_id)
    if type(cancelled) is not bool:
        raise ValueError('cancelled必须为布尔值')
    target='CANCELLED' if cancelled else 'COMPLETED'
    with connection.cursor() as cursor:
        cursor.execute('SELECT status,ends_at FROM equipment_outage_plan WHERE outage_plan_id=%s FOR UPDATE',(outage_plan_id,))
        record=cursor.fetchone()
        if record is None:
            raise LookupError('停运计划不存在')
        if record['status']==target:
            return
        if record['status']!='SCHEDULED':
            raise ValueError('已终结停运计划不得再次改变状态')
        if not cancelled:
            cursor.execute('SELECT CURRENT_TIMESTAMP AS now_time')
            if cursor.fetchone()['now_time'] < record['ends_at']:
                raise ValueError('计划尚未到期，如提前结束请取消并由A通知变更')
        cursor.execute('UPDATE equipment_outage_plan SET status=%s WHERE outage_plan_id=%s',(target,outage_plan_id))


def _validate_id(name: str, value: int) -> None:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ValueError(f"{name} must be a positive integer.")


def _validate_positive_int(name: str, value: int) -> None:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise ValueError(f"{name} must be a positive integer.")


def _validate_page(limit: int, offset: int) -> None:
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= MAX_PAGE_SIZE:
        raise ValueError(f"limit must be between 1 and {MAX_PAGE_SIZE}.")
    if isinstance(offset, bool) or not isinstance(offset, int) or offset < 0:
        raise ValueError("offset must be a non-negative integer.")


def list_alarms(
    connection: Connection,
    *,
    pile_id: int | None = None,
    alarm_status: str | None = None,
    limit: int = 50,
    offset: int = 0,
) -> list[dict[str, Any]]:
    """Return a page of alarm details with source sampling and work-order counts."""

    _validate_page(limit, offset)
    if pile_id is not None:
        _validate_id("pile_id", pile_id)
    if alarm_status is not None and alarm_status not in VALID_ALARM_STATUSES:
        raise ValueError(f"Unsupported alarm_status: {alarm_status}")

    filters: list[str] = []
    parameters: list[Any] = []
    if pile_id is not None:
        filters.append("a.pile_id = %s")
        parameters.append(pile_id)
    if alarm_status is not None:
        filters.append("a.alarm_status = %s")
        parameters.append(alarm_status)
    where_sql = f"WHERE {' AND '.join(filters)}" if filters else ""
    sql = f"""
        SELECT
            a.alarm_id, a.pile_id, a.gun_id, a.alarm_code, a.alarm_level,
            a.alarm_status, a.occur_time, a.recover_time,
            t.telemetry_id AS source_telemetry_id,
            COUNT(DISTINCT wo.work_order_id) AS work_order_count
        FROM alarm AS a
        LEFT JOIN device_telemetry AS t
            ON t.telemetry_id = a.source_telemetry_id
        LEFT JOIN maintenance_work_order AS wo
            ON wo.alarm_id = a.alarm_id
        {where_sql}
        GROUP BY
            a.alarm_id, a.pile_id, a.gun_id, a.alarm_code, a.alarm_level,
            a.alarm_status, a.occur_time, a.recover_time, t.telemetry_id
        ORDER BY a.occur_time DESC, a.alarm_id DESC
        LIMIT %s OFFSET %s
    """
    parameters.extend((limit, offset))
    with connection.cursor() as cursor:
        cursor.execute(sql, parameters)
        return list(cursor.fetchall())


def list_telemetry(
    connection: Connection,
    *,
    pile_id: int,
    since: datetime,
    until: datetime,
    limit: int = 100,
) -> list[dict[str, Any]]:
    """Return device samples in the half-open interval [since, until)."""

    _validate_id("pile_id", pile_id)
    _validate_page(limit, 0)
    if since >= until:
        raise ValueError("since must be earlier than until.")
    sql = """
        SELECT telemetry_id, pile_id, gun_id, collect_time, voltage, current,
               power, module_temp, offline_duration_sec, fault_code, quality_flag
        FROM device_telemetry
        WHERE pile_id = %s AND collect_time >= %s AND collect_time < %s
        ORDER BY collect_time DESC, telemetry_id DESC
        LIMIT %s
    """
    with connection.cursor() as cursor:
        cursor.execute(sql, (pile_id, since, until, limit))
        return list(cursor.fetchall())


def list_work_orders(
    connection: Connection,
    *,
    work_order_status: str | None = None,
    alarm_id: int | None = None,
    limit: int = 50,
    offset: int = 0,
) -> list[dict[str, Any]]:
    """Return work orders joined to their alarm and B-owned station metadata."""

    _validate_page(limit, offset)
    if alarm_id is not None:
        _validate_id("alarm_id", alarm_id)
    if work_order_status is not None and work_order_status not in VALID_WORK_ORDER_STATUSES:
        raise ValueError(f"Unsupported work_order_status: {work_order_status}")
    filters: list[str] = []
    parameters: list[Any] = []
    if work_order_status is not None:
        filters.append("wo.work_order_status = %s")
        parameters.append(work_order_status)
    if alarm_id is not None:
        filters.append("wo.alarm_id = %s")
        parameters.append(alarm_id)
    where_sql = f"WHERE {' AND '.join(filters)}" if filters else ""
    sql = f"""
        SELECT
            wo.work_order_id, wo.work_order_no, wo.alarm_id,
            wo.work_order_type, wo.maintainer_id, wo.dispatch_time,
            wo.accept_time, wo.arrive_time, wo.repair_finish_time,
            wo.verify_time, wo.work_order_status, wo.repair_result,
            wo.verify_result, a.alarm_code, a.alarm_level, a.pile_id,
            a.gun_id, s.station_id, s.name AS station_name
        FROM maintenance_work_order AS wo
        JOIN alarm AS a ON a.alarm_id = wo.alarm_id
        JOIN charging_pile AS p ON p.pile_id = a.pile_id
        JOIN station AS s ON s.station_id = p.station_id
        {where_sql}
        ORDER BY wo.dispatch_time DESC, wo.work_order_id DESC
        LIMIT %s OFFSET %s
    """
    parameters.extend((limit, offset))
    with connection.cursor() as cursor:
        cursor.execute(sql, parameters)
        return list(cursor.fetchall())


def list_available_inventory(
    connection: Connection,
    *,
    warehouse_id: int | None = None,
    spare_part_id: int | None = None,
    limit: int = 100,
    offset: int = 0,
) -> list[dict[str, Any]]:
    """Query current stock through the view, without exposing unrelated tables."""

    _validate_page(limit, offset)
    if warehouse_id is not None:
        _validate_id("warehouse_id", warehouse_id)
    if spare_part_id is not None:
        _validate_id("spare_part_id", spare_part_id)
    filters: list[str] = []
    parameters: list[Any] = []
    if warehouse_id is not None:
        filters.append("warehouse_id = %s")
        parameters.append(warehouse_id)
    if spare_part_id is not None:
        filters.append("spare_part_id = %s")
        parameters.append(spare_part_id)
    where_sql = f"WHERE {' AND '.join(filters)}" if filters else ""
    sql = f"""
        SELECT inventory_id, warehouse_id, warehouse_code, warehouse_name,
               spare_part_id, part_code, part_name, unit, quantity,
               locked_quantity, available_quantity, version_no, updated_at
        FROM v_c_inventory_available
        {where_sql}
        ORDER BY warehouse_code, part_code
        LIMIT %s OFFSET %s
    """
    parameters.extend((limit, offset))
    with connection.cursor() as cursor:
        cursor.execute(sql, parameters)
        return list(cursor.fetchall())


def list_inventory_transactions(
    connection: Connection,
    *,
    warehouse_id: int,
    spare_part_id: int,
    limit: int = 100,
    offset: int = 0,
) -> list[dict[str, Any]]:
    """Return the append-only audit trail for one warehouse/part pair."""

    _validate_id("warehouse_id", warehouse_id)
    _validate_id("spare_part_id", spare_part_id)
    _validate_page(limit, offset)
    sql = """
        SELECT transaction_id, transaction_no, work_order_id, transaction_type,
               quantity_change, before_quantity, after_quantity, occurred_at,
               operator_id, related_transaction_id
        FROM inventory_transaction
        WHERE warehouse_id = %s AND spare_part_id = %s
        ORDER BY occurred_at DESC, transaction_id DESC
        LIMIT %s OFFSET %s
    """
    with connection.cursor() as cursor:
        cursor.execute(sql, (warehouse_id, spare_part_id, limit, offset))
        return list(cursor.fetchall())


def create_spare_part(
    connection: Connection,
    *,
    part_code: str,
    part_name: str,
    unit: str,
    model: str | None = None,
    spec: str | None = None,
) -> int:
    """Create one spare-part master record and return its generated ID."""

    if not part_code.strip() or not part_name.strip() or not unit.strip():
        raise ValueError("part_code, part_name and unit are required.")
    sql = """
        INSERT INTO spare_part (part_code, part_name, model, spec, unit)
        VALUES (%s, %s, %s, %s, %s)
    """
    with connection.cursor() as cursor:
        cursor.execute(sql, (part_code.strip(), part_name.strip(), model, spec, unit.strip()))
        return int(cursor.lastrowid)


def create_warehouse(
    connection: Connection,
    *,
    warehouse_code: str,
    warehouse_name: str,
    location: str | None = None,
) -> int:
    """Create one warehouse master record and return its generated ID."""

    if not warehouse_code.strip() or not warehouse_name.strip():
        raise ValueError("warehouse_code and warehouse_name are required.")
    with connection.cursor() as cursor:
        cursor.execute(
            """
            INSERT INTO warehouse (warehouse_code, warehouse_name, location)
            VALUES (%s, %s, %s)
            """,
            (warehouse_code.strip(), warehouse_name.strip(), location),
        )
        return int(cursor.lastrowid)


def set_spare_part_status(
    connection: Connection,
    *,
    spare_part_id: int,
    status: str,
) -> None:
    _validate_id("spare_part_id", spare_part_id)
    if status not in VALID_PART_STATUSES:
        raise ValueError(f"Unsupported spare-part status: {status}")
    with connection.cursor() as cursor:
        cursor.execute(
            "UPDATE spare_part SET part_status = %s WHERE spare_part_id = %s",
            (status, spare_part_id),
        )
        if cursor.rowcount != 1:
            raise LookupError(f"Spare part {spare_part_id} was not found.")


def set_warehouse_status(
    connection: Connection,
    *,
    warehouse_id: int,
    status: str,
) -> None:
    _validate_id("warehouse_id", warehouse_id)
    if status not in VALID_WAREHOUSE_STATUSES:
        raise ValueError(f"Unsupported warehouse status: {status}")
    with connection.cursor() as cursor:
        cursor.execute(
            "UPDATE warehouse SET warehouse_status = %s WHERE warehouse_id = %s",
            (status, warehouse_id),
        )
        if cursor.rowcount != 1:
            raise LookupError(f"Warehouse {warehouse_id} was not found.")


def _call_for_id(
    connection: Connection,
    *,
    call_sql: str,
    parameters: tuple[Any, ...],
    output_variables: tuple[str, ...],
) -> dict[str, Any]:
    """Call a fixed stored-procedure statement and fetch its OUT parameters."""

    with connection.cursor() as cursor:
        cursor.execute("SET " + ", ".join(f"{name} = NULL" for name in output_variables))
        cursor.execute(call_sql, parameters)
        while cursor.nextset():
            pass
        selection = ", ".join(f"{name} AS {name.lstrip('@')}" for name in output_variables)
        cursor.execute(f"SELECT {selection}")
        row = cursor.fetchone()
    if row is None:
        raise RuntimeError("C stored procedure did not return its OUT parameters.")
    return row


def ingest_telemetry(
    connection: Connection,
    *,
    pile_id: int,
    gun_id: int | None,
    collect_time: datetime,
    voltage: Decimal | None,
    current: Decimal | None,
    power: Decimal | None,
    module_temp: Decimal | None,
    offline_duration_sec: int,
    fault_code: str | None,
    quality_flag: str,
    offline_threshold_sec: int,
) -> dict[str, int | None]:
    """Persist a sample and return the generated sample/alarm IDs."""

    _validate_id("pile_id", pile_id)
    if gun_id is not None:
        _validate_id("gun_id", gun_id)
    if not isinstance(collect_time, datetime):
        raise TypeError("collect_time must be a datetime.")
    if isinstance(offline_duration_sec, bool) or not isinstance(offline_duration_sec, int) or offline_duration_sec < 0:
        raise ValueError("offline_duration_sec must be non-negative.")
    if isinstance(offline_threshold_sec, bool) or not isinstance(offline_threshold_sec, int) or offline_threshold_sec < 0:
        raise ValueError("offline_threshold_sec must be non-negative.")
    if quality_flag not in {"NORMAL", "ABNORMAL", "RECOLLECT"}:
        raise ValueError("Unsupported quality_flag.")
    for name, value in (
        ("voltage", voltage),
        ("current", current),
        ("power", power),
        ("module_temp", module_temp),
    ):
        if value is not None and not isinstance(value, Decimal):
            raise TypeError(f"{name} must be Decimal or None.")
    if fault_code is not None and len(fault_code) > 50:
        raise ValueError("fault_code must contain at most 50 characters.")
    row = _call_for_id(
        connection,
        call_sql=(
            "CALL sp_c_ingest_telemetry("
            "%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, %s, @c_telemetry_id, @c_alarm_id)"
        ),
        parameters=(
            pile_id,
            gun_id,
            collect_time,
            voltage,
            current,
            power,
            module_temp,
            offline_duration_sec,
            fault_code,
            quality_flag,
            offline_threshold_sec,
        ),
        output_variables=("@c_telemetry_id", "@c_alarm_id"),
    )
    return {
        "telemetry_id": row["c_telemetry_id"],
        "alarm_id": row["c_alarm_id"],
    }


def dispatch_work_order(
    connection: Connection,
    *,
    alarm_id: int,
    work_order_no: str,
    work_order_type: str,
    maintainer_id: int | None,
) -> int:
    _validate_id("alarm_id", alarm_id)
    if maintainer_id is not None:
        _validate_id("maintainer_id", maintainer_id)
    if not work_order_no.strip():
        raise ValueError("work_order_no is required.")
    row = _call_for_id(
        connection,
        call_sql="CALL sp_c_dispatch_work_order(%s, %s, %s, %s, @c_work_order_id)",
        parameters=(alarm_id, work_order_no.strip(), work_order_type, maintainer_id),
        output_variables=("@c_work_order_id",),
    )
    return int(row["c_work_order_id"])


def advance_work_order(
    connection: Connection,
    *,
    work_order_id: int,
    action: str,
    maintainer_id: int | None = None,
    repair_result: str | None = None,
) -> None:
    _validate_id("work_order_id", work_order_id)
    if action not in {"ACCEPT", "ARRIVE", "REPAIR"}:
        raise ValueError(f"Unsupported work-order action: {action}")
    if maintainer_id is not None:
        _validate_id("maintainer_id", maintainer_id)
    with connection.cursor() as cursor:
        cursor.execute(
            "CALL sp_c_advance_work_order(%s, %s, %s, %s)",
            (work_order_id, action, maintainer_id, repair_result),
        )
        while cursor.nextset():
            pass


def verify_work_order(
    connection: Connection,
    *,
    work_order_id: int,
    passed: bool,
    remark: str | None = None,
) -> None:
    _validate_id("work_order_id", work_order_id)
    if not isinstance(passed, bool):
        raise ValueError("passed must be a bool.")
    with connection.cursor() as cursor:
        cursor.execute(
            "CALL sp_c_verify_work_order(%s, %s, %s)",
            (work_order_id, passed, remark),
        )
        while cursor.nextset():
            pass


def cancel_work_order(
    connection: Connection,
    *,
    work_order_id: int,
    reason: str,
) -> None:
    _validate_id("work_order_id", work_order_id)
    if not reason.strip():
        raise ValueError("reason is required.")
    with connection.cursor() as cursor:
        cursor.execute(
            "CALL sp_c_cancel_work_order(%s, %s)",
            (work_order_id, reason.strip()),
        )
        while cursor.nextset():
            pass


def plan_work_order_part(
    connection: Connection,
    *,
    work_order_id: int,
    spare_part_id: int,
    warehouse_id: int,
    planned_qty: int,
    remark: str | None = None,
) -> int:
    for name, value in (
        ("work_order_id", work_order_id),
        ("spare_part_id", spare_part_id),
        ("warehouse_id", warehouse_id),
    ):
        _validate_id(name, value)
    _validate_positive_int("planned_qty", planned_qty)
    row = _call_for_id(
        connection,
        call_sql=(
            "CALL sp_c_plan_work_order_part(%s, %s, %s, %s, %s, @c_work_order_part_id)"
        ),
        parameters=(work_order_id, spare_part_id, warehouse_id, planned_qty, remark),
        output_variables=("@c_work_order_part_id",),
    )
    return int(row["c_work_order_part_id"])


def record_part_installation(
    connection: Connection,
    *,
    work_order_id: int,
    spare_part_id: int,
    warehouse_id: int,
    quantity: int,
) -> None:
    for name, value in (
        ("work_order_id", work_order_id),
        ("spare_part_id", spare_part_id),
        ("warehouse_id", warehouse_id),
    ):
        _validate_id(name, value)
    _validate_positive_int("quantity", quantity)
    with connection.cursor() as cursor:
        cursor.execute(
            "CALL sp_c_record_part_installation(%s, %s, %s, %s)",
            (work_order_id, spare_part_id, warehouse_id, quantity),
        )
        while cursor.nextset():
            pass


def record_inventory_movement(
    connection: Connection,
    *,
    procedure: str,
    parameters: tuple[Any, ...],
) -> int:
    """Call one of the fixed stock procedures; SQL procedure names are allow-listed."""

    allowed = {
        "receive": "sp_c_receive_stock",
        "issue": "sp_c_issue_work_order_part",
        "return": "sp_c_return_work_order_part",
        "adjust": "sp_c_adjust_stock",
        "reverse": "sp_c_reverse_inventory_transaction",
    }
    if procedure not in allowed:
        raise ValueError(f"Unsupported inventory operation: {procedure}")
    row = _call_for_id(
        connection,
        call_sql=f"CALL {allowed[procedure]}("
        + ", ".join(["%s"] * len(parameters))
        + ", @c_transaction_id)",
        parameters=parameters,
        output_variables=("@c_transaction_id",),
    )
    return int(row["c_transaction_id"])


def receive_stock(
    connection: Connection,
    *,
    warehouse_id: int,
    spare_part_id: int,
    quantity: int,
    operator_id: int | None,
    transaction_no: str,
) -> int:
    _validate_id("warehouse_id", warehouse_id)
    _validate_id("spare_part_id", spare_part_id)
    _validate_positive_int("quantity", quantity)
    if operator_id is not None:
        _validate_id("operator_id", operator_id)
    return record_inventory_movement(
        connection,
        procedure="receive",
        parameters=(warehouse_id, spare_part_id, quantity, operator_id, transaction_no),
    )


def issue_stock_to_work_order(
    connection: Connection,
    *,
    work_order_id: int,
    spare_part_id: int,
    warehouse_id: int,
    quantity: int,
    operator_id: int | None,
    transaction_no: str,
) -> int:
    for name, value in (
        ("work_order_id", work_order_id),
        ("spare_part_id", spare_part_id),
        ("warehouse_id", warehouse_id),
    ):
        _validate_id(name, value)
    _validate_positive_int("quantity", quantity)
    if operator_id is not None:
        _validate_id("operator_id", operator_id)
    return record_inventory_movement(
        connection,
        procedure="issue",
        parameters=(
            work_order_id, spare_part_id, warehouse_id, quantity,
            operator_id, transaction_no,
        ),
    )


def return_stock_from_work_order(
    connection: Connection,
    *,
    work_order_id: int,
    spare_part_id: int,
    warehouse_id: int,
    quantity: int,
    operator_id: int | None,
    transaction_no: str,
) -> int:
    for name, value in (
        ("work_order_id", work_order_id),
        ("spare_part_id", spare_part_id),
        ("warehouse_id", warehouse_id),
    ):
        _validate_id(name, value)
    _validate_positive_int("quantity", quantity)
    if operator_id is not None:
        _validate_id("operator_id", operator_id)
    return record_inventory_movement(
        connection,
        procedure="return",
        parameters=(
            work_order_id, spare_part_id, warehouse_id, quantity,
            operator_id, transaction_no,
        ),
    )


def adjust_stock(
    connection: Connection,
    *,
    warehouse_id: int,
    spare_part_id: int,
    delta: int,
    operator_id: int | None,
    transaction_no: str,
    reason: str,
) -> int:
    _validate_id("warehouse_id", warehouse_id)
    _validate_id("spare_part_id", spare_part_id)
    if isinstance(delta, bool) or not isinstance(delta, int) or delta == 0:
        raise ValueError("delta must be a non-zero integer.")
    if operator_id is not None:
        _validate_id("operator_id", operator_id)
    if not transaction_no.strip() or not reason.strip():
        raise ValueError("transaction_no and reason are required.")
    return record_inventory_movement(
        connection,
        procedure="adjust",
        parameters=(warehouse_id, spare_part_id, delta, operator_id, transaction_no, reason),
    )


def reverse_stock_transaction(
    connection: Connection,
    *,
    transaction_id: int,
    transaction_no: str,
    operator_id: int | None,
    reason: str,
) -> int:
    _validate_id("transaction_id", transaction_id)
    if operator_id is not None:
        _validate_id("operator_id", operator_id)
    if not transaction_no.strip() or not reason.strip():
        raise ValueError("transaction_no and reason are required.")
    return record_inventory_movement(
        connection,
        procedure="reverse",
        parameters=(transaction_id, transaction_no, operator_id, reason),
    )
