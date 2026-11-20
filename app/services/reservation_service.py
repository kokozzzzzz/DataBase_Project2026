"""⑥ 预约、排队、到站与车位事务服务。

服务层不开启或提交事务：调用方使用 app.database.connection.transaction
包住一个或多个服务调用，发生异常时统一回滚。
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from pymysql.connections import Connection

from app.database.procedure import call_procedure


VALID_SOURCES = frozenset({"APP", "WEB", "WECHAT", "MINI_PROGRAM", "STAFF"})
VALID_CHECKIN_METHODS = frozenset({"QR_CODE", "STAFF", "AUTO"})
VALID_PRIORITY_CLASSES = frozenset({"WALK_IN", "RESERVATION_LATE"})
VALID_RELEASE_REASONS = frozenset(
    {"VEHICLE_LEFT", "STAFF", "CHECKIN_CANCELLED", "OTHER"}
)
VALID_ADMISSION_CHANNELS = frozenset({"RESERVATION", "QUEUE"})


def _require_positive_int(name: str, value: int) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise ValueError(f"{name} 必须是正整数。")
    return value


def _require_datetime_pair(starts_at: datetime, ends_at: datetime) -> None:
    if not isinstance(starts_at, datetime) or not isinstance(ends_at, datetime):
        raise ValueError("starts_at 和 ends_at 必须是 datetime。")
    if starts_at >= ends_at:
        raise ValueError("starts_at 必须早于 ends_at。")
    minutes = int((ends_at - starts_at).total_seconds() // 60)
    if not 5 <= minutes <= 1440:
        raise ValueError("预约时长必须在 5 分钟到 24 小时之间。")


def _require_optional_datetime(name: str, value: datetime | None) -> None:
    if value is not None and not isinstance(value, datetime):
        raise ValueError(f"{name} 必须是 datetime 或 None。")


def _require_reason(reason: str, *, field_name: str = "reason") -> str:
    if not isinstance(reason, str):
        raise ValueError(f"{field_name} 必须是字符串。")
    normalized = reason.strip()
    if not normalized:
        raise ValueError(f"{field_name} 不能为空。")
    if len(normalized) > 255:
        raise ValueError(f"{field_name} 不能超过 255 个字符。")
    return normalized


def create_reservation(
    connection: Connection,
    *,
    user_id: int,
    vehicle_id: int,
    gun_id: int,
    starts_at: datetime,
    ends_at: datetime,
    source: str = "APP",
    late_grace_minutes: int = 15,
) -> dict[str, Any]:
    """创建预约，返回 reservation_id。"""

    _require_positive_int("user_id", user_id)
    _require_positive_int("vehicle_id", vehicle_id)
    _require_positive_int("gun_id", gun_id)
    _require_datetime_pair(starts_at, ends_at)
    if source not in VALID_SOURCES:
        raise ValueError(f"不支持的预约来源：{source}")
    if not isinstance(late_grace_minutes, int) or isinstance(late_grace_minutes, bool):
        raise ValueError("late_grace_minutes 必须是整数。")
    if not 1 <= late_grace_minutes <= 120:
        raise ValueError("late_grace_minutes 必须在 1 到 120 之间。")

    row = call_procedure(
        connection,
        """
        CALL sp_create_reservation(
            %s, %s, %s, %s, %s, %s, %s, @p_reservation_id
        )
        """,
        (
            user_id,
            vehicle_id,
            gun_id,
            starts_at,
            ends_at,
            source,
            late_grace_minutes,
        ),
        ("p_reservation_id",),
    )
    return {"reservation_id": int(row["p_reservation_id"])}


def cancel_reservation(
    connection: Connection,
    *,
    reservation_id: int,
    reason: str,
    at_time: datetime | None = None,
) -> dict[str, Any]:
    """取消预约；CHECKED_IN 时同时释放对应车位。"""

    _require_positive_int("reservation_id", reservation_id)
    normalized_reason = _require_reason(reason, field_name="reason")
    _require_optional_datetime("at_time", at_time)

    row = call_procedure(
        connection,
        """
        CALL sp_cancel_reservation(
            %s, %s, %s, @p_released_occupancy_id
        )
        """,
        (reservation_id, normalized_reason, at_time),
        ("p_released_occupancy_id",),
    )
    return {
        "reservation_id": reservation_id,
        "released_occupancy_id": int(row["p_released_occupancy_id"]),
    }


def reschedule_reservation(
    connection: Connection,
    *,
    reservation_id: int,
    starts_at: datetime,
    ends_at: datetime,
    source: str = "APP",
    late_grace_minutes: int = 15,
    at_time: datetime | None = None,
) -> dict[str, Any]:
    """改约：取消旧预约并创建新预约。"""

    _require_positive_int("reservation_id", reservation_id)
    _require_datetime_pair(starts_at, ends_at)
    _require_optional_datetime("at_time", at_time)
    if source not in VALID_SOURCES:
        raise ValueError(f"不支持的预约来源：{source}")
    if not 1 <= late_grace_minutes <= 120:
        raise ValueError("late_grace_minutes 必须在 1 到 120 之间。")

    row = call_procedure(
        connection,
        """
        CALL sp_reschedule_reservation(
            %s, %s, %s, %s, %s, %s, @p_new_reservation_id
        )
        """,
        (
            reservation_id,
            starts_at,
            ends_at,
            source,
            late_grace_minutes,
            at_time,
        ),
        ("p_new_reservation_id",),
    )
    return {
        "old_reservation_id": reservation_id,
        "new_reservation_id": int(row["p_new_reservation_id"]),
    }


def check_in_reservation(
    connection: Connection,
    *,
    reservation_id: int,
    method: str = "QR_CODE",
    at_time: datetime | None = None,
) -> dict[str, Any]:
    """预约到站核验，返回 checkin_id 和自动生成的 occupancy_id。"""

    _require_positive_int("reservation_id", reservation_id)
    if method not in VALID_CHECKIN_METHODS:
        raise ValueError(f"不支持的核验方式：{method}")
    _require_optional_datetime("at_time", at_time)

    row = call_procedure(
        connection,
        """
        CALL sp_check_in_reservation(
            %s, %s, %s, @p_checkin_id, @p_occupancy_id
        )
        """,
        (reservation_id, method, at_time),
        ("p_checkin_id", "p_occupancy_id"),
    )
    return {
        "reservation_id": reservation_id,
        "checkin_id": int(row["p_checkin_id"]),
        "occupancy_id": int(row["p_occupancy_id"]),
    }


def join_queue(
    connection: Connection,
    *,
    station_id: int,
    user_id: int,
    vehicle_id: int,
    gun_id: int,
    priority_class: str = "WALK_IN",
    hold_minutes: int = 10,
    at_time: datetime | None = None,
) -> dict[str, Any]:
    """现场排队入队，返回 queue_id 和当日排队号。"""

    _require_positive_int("station_id", station_id)
    _require_positive_int("user_id", user_id)
    _require_positive_int("vehicle_id", vehicle_id)
    _require_positive_int("gun_id", gun_id)
    if priority_class not in VALID_PRIORITY_CLASSES:
        raise ValueError(f"不支持的排队优先级：{priority_class}")
    if not isinstance(hold_minutes, int) or isinstance(hold_minutes, bool):
        raise ValueError("hold_minutes 必须是整数。")
    if not 1 <= hold_minutes <= 60:
        raise ValueError("hold_minutes 必须在 1 到 60 之间。")
    _require_optional_datetime("at_time", at_time)

    row = call_procedure(
        connection,
        """
        CALL sp_join_queue(
            %s, %s, %s, %s, %s, %s, %s,
            @p_queue_id, @p_ticket_no
        )
        """,
        (
            station_id,
            user_id,
            vehicle_id,
            gun_id,
            priority_class,
            hold_minutes,
            at_time,
        ),
        ("p_queue_id", "p_ticket_no"),
    )
    return {
        "queue_id": int(row["p_queue_id"]),
        "ticket_no": int(row["p_ticket_no"]),
    }


def call_next_queue(
    connection: Connection,
    *,
    station_id: int,
    at_time: datetime | None = None,
) -> dict[str, Any]:
    """叫下一号；没有等待队列时 queue_id 为 0。"""

    _require_positive_int("station_id", station_id)
    _require_optional_datetime("at_time", at_time)

    row = call_procedure(
        connection,
        """
        CALL sp_call_next_queue(
            %s, %s, @p_queue_id, @p_user_id, @p_vehicle_id,
            @p_gun_id, @p_ticket_no
        )
        """,
        (station_id, at_time),
        (
            "p_queue_id",
            "p_user_id",
            "p_vehicle_id",
            "p_gun_id",
            "p_ticket_no",
        ),
    )
    queue_id = int(row["p_queue_id"])
    return {
        "queue_id": queue_id,
        "user_id": int(row["p_user_id"]),
        "vehicle_id": int(row["p_vehicle_id"]),
        "gun_id": int(row["p_gun_id"]),
        "ticket_no": int(row["p_ticket_no"]),
        "has_waiting_queue": queue_id > 0,
    }


def check_in_queue(
    connection: Connection,
    *,
    queue_id: int,
    method: str = "QR_CODE",
    at_time: datetime | None = None,
) -> dict[str, Any]:
    """排队到站核验，返回 checkin_id 和 occupancy_id。"""

    _require_positive_int("queue_id", queue_id)
    if method not in VALID_CHECKIN_METHODS:
        raise ValueError(f"不支持的核验方式：{method}")
    _require_optional_datetime("at_time", at_time)

    row = call_procedure(
        connection,
        """
        CALL sp_check_in_queue(
            %s, %s, %s, @p_checkin_id, @p_occupancy_id
        )
        """,
        (queue_id, method, at_time),
        ("p_checkin_id", "p_occupancy_id"),
    )
    return {
        "queue_id": queue_id,
        "checkin_id": int(row["p_checkin_id"]),
        "occupancy_id": int(row["p_occupancy_id"]),
    }


def release_parking_space(
    connection: Connection,
    *,
    occupancy_id: int,
    reason: str = "VEHICLE_LEFT",
    at_time: datetime | None = None,
) -> dict[str, Any]:
    """释放车位；正常驶离要求车辆已结束充电。"""

    _require_positive_int("occupancy_id", occupancy_id)
    if reason not in VALID_RELEASE_REASONS:
        raise ValueError(f"不支持的车位释放原因：{reason}")
    _require_optional_datetime("at_time", at_time)

    row = call_procedure(
        connection,
        """
        CALL sp_release_parking_space(
            %s, %s, %s, @p_released
        )
        """,
        (occupancy_id, reason, at_time),
        ("p_released",),
    )
    return {
        "occupancy_id": occupancy_id,
        "released": bool(int(row["p_released"])),
    }


def consume_admission(
    connection: Connection,
    *,
    channel: str,
    admission_id: int,
    order_id: int,
    at_time: datetime | None = None,
) -> dict[str, Any]:
    """供 B 模块开单后消费预约/排队资格。"""

    if channel not in VALID_ADMISSION_CHANNELS:
        raise ValueError(f"不支持的资格类型：{channel}")
    _require_positive_int("admission_id", admission_id)
    _require_positive_int("order_id", order_id)
    _require_optional_datetime("at_time", at_time)

    row = call_procedure(
        connection,
        """
        CALL sp_consume_admission(
            %s, %s, %s, %s, @p_consumed
        )
        """,
        (channel, admission_id, order_id, at_time),
        ("p_consumed",),
    )
    return {
        "channel": channel,
        "admission_id": admission_id,
        "order_id": order_id,
        "consumed": bool(int(row["p_consumed"])),
    }


def expire_overdue_admissions(
    connection: Connection,
    *,
    at_time: datetime | None = None,
) -> dict[str, int]:
    """批量过期预约和排队。"""

    _require_optional_datetime("at_time", at_time)
    row = call_procedure(
        connection,
        """
        CALL sp_expire_overdue_admissions(
            %s, @p_expired_reservations, @p_expired_queues
        )
        """,
        (at_time,),
        ("p_expired_reservations", "p_expired_queues"),
    )
    return {
        "expired_reservations": int(row["p_expired_reservations"]),
        "expired_queues": int(row["p_expired_queues"]),
    }
