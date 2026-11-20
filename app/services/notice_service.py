"""⑧ 场站公告、定向通知与发送状态事务服务。

服务层不开启或提交事务，由调用方统一控制事务边界。
"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from pymysql.connections import Connection

from app.database.procedure import call_procedure


VALID_NOTICE_TYPES = frozenset({"PUBLIC", "OUTAGE_TARGETED"})
VALID_SEVERITIES = frozenset({"INFO", "WARNING", "EMERGENCY"})
VALID_NOTIFICATION_STATUSES = frozenset({"PENDING", "SENT", "FAILED", "READ"})


def _require_positive_int(name: str, value: int) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        raise ValueError(f"{name} 必须是正整数。")
    return value


def _require_text(
    name: str,
    value: str,
    *,
    max_length: int | None = None,
) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{name} 必须是字符串。")
    normalized = value.strip()
    if not normalized:
        raise ValueError(f"{name} 不能为空。")
    if max_length is not None and len(normalized) > max_length:
        raise ValueError(f"{name} 不能超过 {max_length} 个字符。")
    return normalized


def _require_optional_datetime(name: str, value: datetime | None) -> None:
    if value is not None and not isinstance(value, datetime):
        raise ValueError(f"{name} 必须是 datetime 或 None。")


def create_notice(
    connection: Connection,
    *,
    station_id: int,
    notice_type: str,
    severity: str,
    title: str,
    content: str,
    effective_from: datetime,
    effective_to: datetime | None,
    created_by: str,
    related_outage_plan_id: int | None = None,
) -> dict[str, Any]:
    """创建 DRAFT 公告；发布必须再调用 publish_notice。"""

    _require_positive_int("station_id", station_id)
    if notice_type not in VALID_NOTICE_TYPES:
        raise ValueError(f"不支持的公告类型：{notice_type}")
    if severity not in VALID_SEVERITIES:
        raise ValueError(f"不支持的公告级别：{severity}")
    normalized_title = _require_text("title", title, max_length=200)
    normalized_content = _require_text("content", content)
    normalized_created_by = _require_text("created_by", created_by, max_length=64)
    if not isinstance(effective_from, datetime):
        raise ValueError("effective_from 必须是 datetime。")
    _require_optional_datetime("effective_to", effective_to)
    if effective_to is not None and effective_to <= effective_from:
        raise ValueError("effective_to 必须晚于 effective_from。")

    if notice_type == "OUTAGE_TARGETED":
        if related_outage_plan_id is None:
            raise ValueError("定向停运公告必须提供 related_outage_plan_id。")
        _require_positive_int("related_outage_plan_id", related_outage_plan_id)
    elif related_outage_plan_id is not None:
        raise ValueError("公开公告不能关联停运计划。")

    sql = """
        INSERT INTO station_notice (
            station_id, notice_type, severity, title, content,
            status, effective_from, effective_to,
            created_by, updated_by, related_outage_plan_id
        ) VALUES (
            %s, %s, %s, %s, %s,
            'DRAFT', %s, %s,
            %s, %s, %s
        )
    """
    with connection.cursor() as cursor:
        cursor.execute(
            sql,
            (
                station_id,
                notice_type,
                severity,
                normalized_title,
                normalized_content,
                effective_from,
                effective_to,
                normalized_created_by,
                normalized_created_by,
                related_outage_plan_id,
            ),
        )
        notice_id = int(cursor.lastrowid)

    return {"notice_id": notice_id, "status": "DRAFT"}


def publish_notice(
    connection: Connection,
    *,
    notice_id: int,
    operator: str,
    at_time: datetime | None = None,
) -> dict[str, Any]:
    """发布公告；定向公告自动生成接收人和待发送通知。"""

    _require_positive_int("notice_id", notice_id)
    normalized_operator = _require_text("operator", operator, max_length=64)
    _require_optional_datetime("at_time", at_time)

    row = call_procedure(
        connection,
        """
        CALL sp_publish_notice(
            %s, %s, %s, @p_recipient_count, @p_notification_count
        )
        """,
        (notice_id, normalized_operator, at_time),
        ("p_recipient_count", "p_notification_count"),
    )
    return {
        "notice_id": notice_id,
        "status": "PUBLISHED",
        "recipient_count": int(row["p_recipient_count"]),
        "notification_count": int(row["p_notification_count"]),
    }


def withdraw_notice(
    connection: Connection,
    *,
    notice_id: int,
    operator: str,
    reason: str,
    at_time: datetime | None = None,
) -> dict[str, Any]:
    """撤回公告，并把尚未发送的通知标记为 FAILED。"""

    _require_positive_int("notice_id", notice_id)
    normalized_operator = _require_text("operator", operator, max_length=64)
    normalized_reason = _require_text("reason", reason, max_length=255)
    _require_optional_datetime("at_time", at_time)

    row = call_procedure(
        connection,
        """
        CALL sp_withdraw_notice(
            %s, %s, %s, %s, @p_cancelled_notifications
        )
        """,
        (notice_id, normalized_operator, normalized_reason, at_time),
        ("p_cancelled_notifications",),
    )
    return {
        "notice_id": notice_id,
        "status": "WITHDRAWN",
        "cancelled_notifications": int(row["p_cancelled_notifications"]),
    }


def update_notification_status(
    connection: Connection,
    *,
    notification_id: int,
    status: str,
    provider_message_id: str | None = None,
    failure_reason: str | None = None,
    at_time: datetime | None = None,
) -> dict[str, Any]:
    """更新通知状态；状态机由触发器和过程共同校验。"""

    _require_positive_int("notification_id", notification_id)
    if status not in VALID_NOTIFICATION_STATUSES:
        raise ValueError(f"不支持的通知状态：{status}")
    if provider_message_id is not None and len(provider_message_id) > 64:
        raise ValueError("provider_message_id 不能超过 64 个字符。")
    if failure_reason is not None and len(failure_reason) > 255:
        raise ValueError("failure_reason 不能超过 255 个字符。")
    _require_optional_datetime("at_time", at_time)

    row = call_procedure(
        connection,
        """
        CALL sp_update_notification_status(
            %s, %s, %s, %s, %s, @p_updated
        )
        """,
        (
            notification_id,
            status,
            provider_message_id,
            failure_reason,
            at_time,
        ),
        ("p_updated",),
    )
    return {
        "notification_id": notification_id,
        "status": status,
        "updated": bool(int(row["p_updated"])),
    }


def expire_notices(
    connection: Connection,
    *,
    at_time: datetime | None = None,
) -> dict[str, int]:
    """把超过 effective_to 的已发布公告置为 EXPIRED。"""

    _require_optional_datetime("at_time", at_time)
    row = call_procedure(
        connection,
        """
        CALL sp_expire_notices(%s, @p_expired_count)
        """,
        (at_time,),
        ("p_expired_count",),
    )
    return {"expired_notices": int(row["p_expired_count"])}
