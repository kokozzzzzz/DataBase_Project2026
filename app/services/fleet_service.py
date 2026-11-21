"""④ 企业车队车辆关系的事务操作。"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from pymysql.connections import Connection


class FleetVehicleError(ValueError):
    """车辆加入或退出车队时不满足业务规则。"""


def add_vehicle_to_fleet(
    connection: Connection,
    *,
    vehicle_id: int,
    fleet_id: int,
    joined_at: datetime | None = None,
) -> dict[str, Any]:
    """建立有效车队关系；事务提交或回滚由调用方控制。"""

    _validate_ids(vehicle_id=vehicle_id, fleet_id=fleet_id)

    with connection.cursor() as cursor:
        # vehicle 是并发控制的固定锁点，确保同一车辆的加入请求串行执行。
        cursor.execute(
            """
            SELECT vehicle_id, vehicle_status
            FROM vehicle
            WHERE vehicle_id = %s
            FOR UPDATE
            """,
            (vehicle_id,),
        )
        vehicle = cursor.fetchone()
        if vehicle is None:
            raise FleetVehicleError(f"车辆 {vehicle_id} 不存在。")
        if vehicle["vehicle_status"] != "ACTIVE":
            raise FleetVehicleError(f"车辆 {vehicle_id} 当前不可用。")

        cursor.execute(
            """
            SELECT
                f.fleet_id,
                f.fleet_name,
                f.status AS fleet_status,
                ec.status AS enterprise_status
            FROM fleet AS f
            JOIN enterprise_customer AS ec
                ON ec.enterprise_id = f.enterprise_id
            WHERE f.fleet_id = %s
            FOR UPDATE
            """,
            (fleet_id,),
        )
        fleet = cursor.fetchone()
        if fleet is None:
            raise FleetVehicleError(f"车队 {fleet_id} 不存在。")
        if fleet["fleet_status"] != "ACTIVE":
            raise FleetVehicleError(f"车队 {fleet_id} 当前不可用。")
        if fleet["enterprise_status"] != "ACTIVE":
            raise FleetVehicleError(f"车队 {fleet_id} 所属企业当前不可用。")

        cursor.execute(
            """
            SELECT fleet_vehicle_id, fleet_id
            FROM fleet_vehicle
            WHERE vehicle_id = %s
              AND status = 'ACTIVE'
            FOR UPDATE
            """,
            (vehicle_id,),
        )
        active_relation = cursor.fetchone()
        if active_relation is not None:
            if active_relation["fleet_id"] == fleet_id:
                raise FleetVehicleError(
                    f"车辆 {vehicle_id} 已在车队 {fleet_id} 中，无需重复加入。"
                )
            raise FleetVehicleError(
                f"车辆 {vehicle_id} 已属于车队 {active_relation['fleet_id']}，"
                "必须先退出原车队。"
            )

        cursor.execute(
            """
            INSERT INTO fleet_vehicle (
                fleet_id,
                vehicle_id,
                joined_at,
                left_at,
                status
            ) VALUES (
                %s,
                %s,
                COALESCE(%s, CURRENT_TIMESTAMP),
                NULL,
                'ACTIVE'
            )
            """,
            (fleet_id, vehicle_id, joined_at),
        )
        fleet_vehicle_id = cursor.lastrowid

    return {
        "fleet_vehicle_id": fleet_vehicle_id,
        "fleet_id": fleet_id,
        "fleet_name": fleet["fleet_name"],
        "vehicle_id": vehicle_id,
        "status": "ACTIVE",
    }


def remove_vehicle_from_fleet(
    connection: Connection,
    *,
    vehicle_id: int,
    fleet_id: int | None = None,
    left_at: datetime | None = None,
) -> dict[str, Any]:
    """结束车辆当前的有效车队关系；保留历史记录。"""

    if vehicle_id <= 0:
        raise FleetVehicleError("vehicle_id 必须是正整数。")
    if fleet_id is not None and fleet_id <= 0:
        raise FleetVehicleError("fleet_id 必须是正整数。")

    with connection.cursor() as cursor:
        # 与加入操作使用相同锁点和锁顺序，避免并发穿透检查。
        cursor.execute(
            """
            SELECT vehicle_id
            FROM vehicle
            WHERE vehicle_id = %s
            FOR UPDATE
            """,
            (vehicle_id,),
        )
        if cursor.fetchone() is None:
            raise FleetVehicleError(f"车辆 {vehicle_id} 不存在。")

        cursor.execute(
            """
            SELECT fleet_vehicle_id, fleet_id, joined_at
            FROM fleet_vehicle
            WHERE vehicle_id = %s
              AND status = 'ACTIVE'
            FOR UPDATE
            """,
            (vehicle_id,),
        )
        active_relation = cursor.fetchone()
        if active_relation is None:
            raise FleetVehicleError(f"车辆 {vehicle_id} 当前不属于任何有效车队。")
        if fleet_id is not None and active_relation["fleet_id"] != fleet_id:
            raise FleetVehicleError(
                f"车辆 {vehicle_id} 当前属于车队 {active_relation['fleet_id']}，"
                f"不是车队 {fleet_id}。"
            )
        if left_at is not None and left_at < active_relation["joined_at"]:
            raise FleetVehicleError("退出时间不能早于加入时间。")

        cursor.execute(
            """
            UPDATE fleet_vehicle
            SET
                left_at = COALESCE(%s, CURRENT_TIMESTAMP),
                status = 'LEFT'
            WHERE fleet_vehicle_id = %s
              AND status = 'ACTIVE'
            """,
            (left_at, active_relation["fleet_vehicle_id"]),
        )
        if cursor.rowcount != 1:
            raise RuntimeError("车辆退出车队失败，关系可能已被并发修改。")

    return {
        "fleet_vehicle_id": active_relation["fleet_vehicle_id"],
        "fleet_id": active_relation["fleet_id"],
        "vehicle_id": vehicle_id,
        "status": "LEFT",
    }


def _validate_ids(*, vehicle_id: int, fleet_id: int) -> None:
    if vehicle_id <= 0 or fleet_id <= 0:
        raise FleetVehicleError("vehicle_id 和 fleet_id 必须是正整数。")
