"""用户注册、车辆维护和逻辑关闭事务。"""

from __future__ import annotations

import re
from datetime import datetime
from decimal import Decimal
from typing import Any

from pymysql.connections import Connection

from .coupon_service import issue_coupon


HASH_PATTERN = re.compile(r"^[0-9a-f]{64}$")
VALID_REAL_NAME_STATUSES = frozenset({"PENDING", "VERIFIED", "REJECTED"})
VALID_REGISTRATION_CHANNELS = frozenset({"APP", "WEB", "WECHAT", "OTHER"})


class CustomerOperationError(ValueError):
    """用户或车辆操作不满足业务规则。"""


def register_user_with_vehicle(
    connection: Connection,
    *,
    phone_ciphertext: bytes,
    phone_hash: str,
    real_name: str | None,
    real_name_status: str,
    registration_channel: str,
    plate_ciphertext: bytes,
    plate_hash: str,
    model: str | None = None,
    battery_capacity_kwh: Decimal | None = None,
    max_charging_power_kw: Decimal | None = None,
    fast_charge_supported: bool = False,
    registered_at: datetime | None = None,
    newcomer_promotion_id: int | None = None,
    newcomer_coupon_code: str | None = None,
) -> dict[str, Any]:
    """注册、实名状态、首辆车绑定和新人券发放组成一个事务单元。"""

    _validate_ciphertext(phone_ciphertext, field_name="phone_ciphertext")
    _validate_hash(phone_hash, field_name="phone_hash")
    _validate_ciphertext(plate_ciphertext, field_name="plate_ciphertext")
    _validate_hash(plate_hash, field_name="plate_hash")
    normalized_real_name = _normalize_optional_text(
        real_name,
        field_name="real_name",
        max_length=50,
    )
    if real_name_status not in VALID_REAL_NAME_STATUSES:
        raise CustomerOperationError("real_name_status 取值无效。")
    if real_name_status == "VERIFIED" and normalized_real_name is None:
        raise CustomerOperationError("实名通过时 real_name 不能为空。")
    if registration_channel not in VALID_REGISTRATION_CHANNELS:
        raise CustomerOperationError("registration_channel 取值无效。")
    normalized_model = _normalize_optional_text(
        model,
        field_name="model",
        max_length=100,
    )
    _validate_positive_decimal(
        battery_capacity_kwh,
        field_name="battery_capacity_kwh",
    )
    _validate_positive_decimal(
        max_charging_power_kw,
        field_name="max_charging_power_kw",
    )
    if (newcomer_promotion_id is None) != (newcomer_coupon_code is None):
        raise CustomerOperationError("新人活动编号和券码必须同时提供或同时省略。")

    with connection.cursor() as cursor:
        cursor.execute(
            """
            INSERT INTO `user` (
                phone_ciphertext,
                phone_hash,
                real_name,
                real_name_status,
                registration_channel,
                registered_at,
                balance,
                user_status
            ) VALUES (
                %s, %s, %s, %s, %s,
                COALESCE(%s, CURRENT_TIMESTAMP),
                0.00,
                'ACTIVE'
            )
            """,
            (
                phone_ciphertext,
                phone_hash,
                normalized_real_name,
                real_name_status,
                registration_channel,
                registered_at,
            ),
        )
        user_id = int(cursor.lastrowid)

        cursor.execute(
            """
            INSERT INTO vehicle (
                user_id,
                plate_ciphertext,
                plate_hash,
                model,
                battery_capacity_kwh,
                max_charging_power_kw,
                fast_charge_supported,
                vehicle_status
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, 'ACTIVE')
            """,
            (
                user_id,
                plate_ciphertext,
                plate_hash,
                normalized_model,
                battery_capacity_kwh,
                max_charging_power_kw,
                int(fast_charge_supported),
            ),
        )
        vehicle_id = int(cursor.lastrowid)

    coupon_result = None
    if newcomer_promotion_id is not None and newcomer_coupon_code is not None:
        coupon_result = issue_coupon(
            connection,
            coupon_code=newcomer_coupon_code,
            promotion_id=newcomer_promotion_id,
            user_id=user_id,
            issued_at=registered_at,
        )

    return {
        "user_id": user_id,
        "vehicle_id": vehicle_id,
        "real_name_status": real_name_status,
        "registration_channel": registration_channel,
        "coupon": coupon_result,
    }


def update_user_profile(
    connection: Connection,
    *,
    user_id: int,
    real_name: str | None,
    real_name_status: str,
    registration_channel: str,
) -> dict[str, Any]:
    """更新非密钥型用户资料；手机号变更应走单独的重新加密流程。"""

    _validate_positive_id(user_id, field_name="user_id")
    normalized_real_name = _normalize_optional_text(
        real_name,
        field_name="real_name",
        max_length=50,
    )
    if real_name_status not in VALID_REAL_NAME_STATUSES:
        raise CustomerOperationError("real_name_status 取值无效。")
    if real_name_status == "VERIFIED" and normalized_real_name is None:
        raise CustomerOperationError("实名通过时 real_name 不能为空。")
    if registration_channel not in VALID_REGISTRATION_CHANNELS:
        raise CustomerOperationError("registration_channel 取值无效。")

    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT user_id, user_status FROM `user` WHERE user_id = %s FOR UPDATE",
            (user_id,),
        )
        user = cursor.fetchone()
        if user is None:
            raise CustomerOperationError(f"用户 {user_id} 不存在。")
        if user["user_status"] == "CLOSED":
            raise CustomerOperationError("已关闭用户不能修改资料。")
        cursor.execute(
            """
            UPDATE `user`
            SET real_name = %s,
                real_name_status = %s,
                registration_channel = %s
            WHERE user_id = %s
            """,
            (
                normalized_real_name,
                real_name_status,
                registration_channel,
                user_id,
            ),
        )

    return {
        "user_id": user_id,
        "real_name": normalized_real_name,
        "real_name_status": real_name_status,
        "registration_channel": registration_channel,
    }


def register_vehicle(
    connection: Connection,
    *,
    user_id: int,
    plate_ciphertext: bytes,
    plate_hash: str,
    model: str | None = None,
    battery_capacity_kwh: Decimal | None = None,
    max_charging_power_kw: Decimal | None = None,
    fast_charge_supported: bool = False,
) -> dict[str, Any]:
    """为有效用户新增车辆。"""

    _validate_positive_id(user_id, field_name="user_id")
    _validate_ciphertext(plate_ciphertext, field_name="plate_ciphertext")
    _validate_hash(plate_hash, field_name="plate_hash")
    normalized_model = _normalize_optional_text(
        model,
        field_name="model",
        max_length=100,
    )
    _validate_positive_decimal(
        battery_capacity_kwh,
        field_name="battery_capacity_kwh",
    )
    _validate_positive_decimal(
        max_charging_power_kw,
        field_name="max_charging_power_kw",
    )

    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT user_id, user_status FROM `user` WHERE user_id = %s FOR UPDATE",
            (user_id,),
        )
        user = cursor.fetchone()
        if user is None:
            raise CustomerOperationError(f"用户 {user_id} 不存在。")
        if user["user_status"] != "ACTIVE":
            raise CustomerOperationError("只有有效用户可以新增车辆。")
        cursor.execute(
            """
            INSERT INTO vehicle (
                user_id, plate_ciphertext, plate_hash, model,
                battery_capacity_kwh, max_charging_power_kw,
                fast_charge_supported, vehicle_status
            ) VALUES (%s, %s, %s, %s, %s, %s, %s, 'ACTIVE')
            """,
            (
                user_id,
                plate_ciphertext,
                plate_hash,
                normalized_model,
                battery_capacity_kwh,
                max_charging_power_kw,
                int(fast_charge_supported),
            ),
        )
        vehicle_id = int(cursor.lastrowid)

    return {"user_id": user_id, "vehicle_id": vehicle_id, "status": "ACTIVE"}


def update_vehicle_profile(
    connection: Connection,
    *,
    vehicle_id: int,
    model: str | None,
    battery_capacity_kwh: Decimal | None,
    max_charging_power_kw: Decimal | None,
    fast_charge_supported: bool,
) -> dict[str, Any]:
    """更新车辆非敏感技术资料。"""

    _validate_positive_id(vehicle_id, field_name="vehicle_id")
    normalized_model = _normalize_optional_text(
        model,
        field_name="model",
        max_length=100,
    )
    _validate_positive_decimal(
        battery_capacity_kwh,
        field_name="battery_capacity_kwh",
    )
    _validate_positive_decimal(
        max_charging_power_kw,
        field_name="max_charging_power_kw",
    )

    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT vehicle_id, vehicle_status FROM vehicle WHERE vehicle_id = %s FOR UPDATE",
            (vehicle_id,),
        )
        vehicle = cursor.fetchone()
        if vehicle is None:
            raise CustomerOperationError(f"车辆 {vehicle_id} 不存在。")
        if vehicle["vehicle_status"] != "ACTIVE":
            raise CustomerOperationError("已停用车辆不能修改资料。")
        cursor.execute(
            """
            UPDATE vehicle
            SET model = %s,
                battery_capacity_kwh = %s,
                max_charging_power_kw = %s,
                fast_charge_supported = %s
            WHERE vehicle_id = %s
            """,
            (
                normalized_model,
                battery_capacity_kwh,
                max_charging_power_kw,
                int(fast_charge_supported),
                vehicle_id,
            ),
        )

    return {"vehicle_id": vehicle_id, "status": "ACTIVE"}


def change_vehicle_status(
    connection: Connection,
    *,
    vehicle_id: int,
    target_status: str,
) -> dict[str, Any]:
    """启用或停用车辆，不物理删除历史记录。"""

    _validate_positive_id(vehicle_id, field_name="vehicle_id")
    if target_status not in {"ACTIVE", "DISABLED"}:
        raise CustomerOperationError("target_status 取值无效。")
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT vehicle_id, vehicle_status FROM vehicle WHERE vehicle_id = %s FOR UPDATE",
            (vehicle_id,),
        )
        vehicle = cursor.fetchone()
        if vehicle is None:
            raise CustomerOperationError(f"车辆 {vehicle_id} 不存在。")
        if vehicle["vehicle_status"] == target_status:
            raise CustomerOperationError("车辆已经处于目标状态。")
        cursor.execute(
            "UPDATE vehicle SET vehicle_status = %s WHERE vehicle_id = %s",
            (target_status, vehicle_id),
        )
    return {"vehicle_id": vehicle_id, "status": target_status}


def close_user(connection: Connection, *, user_id: int) -> dict[str, Any]:
    """逻辑关闭用户，同时停用车辆并释放未使用且未锁定的券。"""

    _validate_positive_id(user_id, field_name="user_id")
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT user_id, user_status FROM `user` WHERE user_id = %s FOR UPDATE",
            (user_id,),
        )
        user = cursor.fetchone()
        if user is None:
            raise CustomerOperationError(f"用户 {user_id} 不存在。")
        if user["user_status"] == "CLOSED":
            raise CustomerOperationError("用户已经关闭。")

        cursor.execute(
            """
            SELECT coupon_id, status
            FROM coupon
            WHERE user_id = %s
            ORDER BY coupon_id
            FOR UPDATE
            """,
            (user_id,),
        )
        user_coupons = list(cursor.fetchall())
        if any(coupon["status"] == "LOCKED" for coupon in user_coupons):
            raise CustomerOperationError("用户存在锁定中的优惠券，不能关闭。")

        cursor.execute(
            "UPDATE vehicle SET vehicle_status = 'DISABLED' WHERE user_id = %s AND vehicle_status = 'ACTIVE'",
            (user_id,),
        )
        disabled_vehicle_count = int(cursor.rowcount)
        cursor.execute(
            """
            UPDATE coupon
            SET status = 'CANCELLED'
            WHERE user_id = %s
              AND status = 'AVAILABLE'
            """,
            (user_id,),
        )
        cancelled_coupon_count = int(cursor.rowcount)
        cursor.execute(
            "UPDATE `user` SET user_status = 'CLOSED' WHERE user_id = %s",
            (user_id,),
        )

    return {
        "user_id": user_id,
        "status": "CLOSED",
        "disabled_vehicle_count": disabled_vehicle_count,
        "cancelled_coupon_count": cancelled_coupon_count,
    }


def _validate_positive_id(value: int, *, field_name: str) -> None:
    if value <= 0:
        raise CustomerOperationError(f"{field_name} 必须是正整数。")


def _validate_ciphertext(value: bytes, *, field_name: str) -> None:
    if not isinstance(value, bytes) or not value:
        raise CustomerOperationError(f"{field_name} 必须是非空 bytes。")
    if len(value) > 512:
        raise CustomerOperationError(f"{field_name} 不能超过 512 字节。")


def _validate_hash(value: str, *, field_name: str) -> None:
    if not HASH_PATTERN.fullmatch(value):
        raise CustomerOperationError(f"{field_name} 必须是64位小写十六进制摘要。")


def _normalize_optional_text(
    value: str | None,
    *,
    field_name: str,
    max_length: int,
) -> str | None:
    if value is None:
        return None
    normalized = value.strip()
    if not normalized:
        return None
    if len(normalized) > max_length:
        raise CustomerOperationError(f"{field_name} 不能超过 {max_length} 个字符。")
    return normalized


def _validate_positive_decimal(
    value: Decimal | None,
    *,
    field_name: str,
) -> None:
    if value is not None and value <= 0:
        raise CustomerOperationError(f"{field_name} 必须大于 0。")
