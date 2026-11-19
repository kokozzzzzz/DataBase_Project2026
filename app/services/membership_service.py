"""④ 用户会员核心事务操作。"""

from __future__ import annotations

from datetime import datetime
from typing import Any

from pymysql.connections import Connection


class MembershipChangeError(ValueError):
    """会员等级变更不满足业务规则。"""


def change_membership_level(
    connection: Connection,
    *,
    user_id: int,
    target_level_id: int,
    change_reason: str,
    effective_at: datetime | None = None,
) -> dict[str, Any]:
    """更新用户当前等级并写入历史；事务提交或回滚由调用方控制。"""

    if user_id <= 0 or target_level_id <= 0:
        raise MembershipChangeError("user_id 和 target_level_id 必须是正整数。")
    normalized_reason = change_reason.strip()
    if not normalized_reason:
        raise MembershipChangeError("change_reason 不能为空。")
    if len(normalized_reason) > 255:
        raise MembershipChangeError("change_reason 不能超过 255 个字符。")

    with connection.cursor() as cursor:
        # 锁定用户行，防止两个并发请求同时基于旧等级进行变更。
        cursor.execute(
            """
            SELECT
                u.user_id,
                u.level_id AS current_level_id,
                u.user_status,
                ml.sort_order AS current_sort_order
            FROM `user` AS u
            JOIN membership_level AS ml
                ON ml.level_id = u.level_id
            WHERE u.user_id = %s
            FOR UPDATE
            """,
            (user_id,),
        )
        user_row = cursor.fetchone()
        if user_row is None:
            raise MembershipChangeError(f"用户 {user_id} 不存在。")
        if user_row["user_status"] != "ACTIVE":
            raise MembershipChangeError(f"用户 {user_id} 当前不是 ACTIVE 状态。")
        if user_row["current_level_id"] == target_level_id:
            raise MembershipChangeError("目标等级与用户当前等级相同，无需变更。")

        cursor.execute(
            """
            SELECT level_id, level_name, sort_order, status
            FROM membership_level
            WHERE level_id = %s
            """,
            (target_level_id,),
        )
        target_level = cursor.fetchone()
        if target_level is None:
            raise MembershipChangeError(f"会员等级 {target_level_id} 不存在。")
        if target_level["status"] != "ACTIVE":
            raise MembershipChangeError(f"会员等级 {target_level_id} 当前不可用。")

        current_sort_order = user_row["current_sort_order"]
        target_sort_order = target_level["sort_order"]
        if target_sort_order > current_sort_order:
            change_type = "UPGRADE"
        elif target_sort_order < current_sort_order:
            change_type = "DOWNGRADE"
        else:
            change_type = "ADJUST"

        cursor.execute(
            """
            UPDATE `user`
            SET level_id = %s
            WHERE user_id = %s
              AND level_id = %s
            """,
            (target_level_id, user_id, user_row["current_level_id"]),
        )
        if cursor.rowcount != 1:
            raise RuntimeError("用户等级更新失败，数据可能已被并发修改。")

        cursor.execute(
            """
            INSERT INTO membership_record (
                user_id,
                level_id,
                change_type,
                effective_at,
                change_reason
            ) VALUES (
                %s,
                %s,
                %s,
                COALESCE(%s, CURRENT_TIMESTAMP),
                %s
            )
            """,
            (
                user_id,
                target_level_id,
                change_type,
                effective_at,
                normalized_reason,
            ),
        )
        membership_record_id = cursor.lastrowid

    return {
        "membership_record_id": membership_record_id,
        "user_id": user_id,
        "previous_level_id": user_row["current_level_id"],
        "target_level_id": target_level_id,
        "target_level_name": target_level["level_name"],
        "change_type": change_type,
        "change_reason": normalized_reason,
    }
