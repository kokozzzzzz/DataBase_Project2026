"""目标用户批量发券事务。"""

from __future__ import annotations

from collections.abc import Sequence
from datetime import datetime
from typing import Any

from pymysql.connections import Connection


MAX_BATCH_SIZE = 100


class TargetedCouponError(ValueError):
    """定向批量发券不满足业务规则。"""


def issue_coupons_batch(
    connection: Connection,
    *,
    promotion_id: int,
    recipients: Sequence[tuple[int, str]],
    issued_at: datetime | None = None,
) -> dict[str, Any]:
    """锁定活动和目标用户后批量写入优惠券；提交由调用方控制。"""

    if promotion_id <= 0:
        raise TargetedCouponError("promotion_id 必须是正整数。")
    normalized_recipients = _normalize_recipients(recipients)
    user_ids = sorted(user_id for user_id, _ in normalized_recipients)
    coupon_codes = [code for _, code in normalized_recipients]

    with connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT
                promotion_id,
                promotion_name,
                total_quantity,
                per_user_limit,
                valid_from,
                valid_to,
                status,
                CURRENT_TIMESTAMP AS database_time
            FROM promotion
            WHERE promotion_id = %s
            FOR UPDATE
            """,
            (promotion_id,),
        )
        promotion = cursor.fetchone()
        if promotion is None:
            raise TargetedCouponError(f"优惠活动 {promotion_id} 不存在。")
        operation_time = issued_at or promotion["database_time"]
        if promotion["status"] != "ACTIVE":
            raise TargetedCouponError("优惠活动当前不可发券。")
        if not promotion["valid_from"] <= operation_time < promotion["valid_to"]:
            raise TargetedCouponError("发券时间不在活动有效期内。")

        user_placeholders = ", ".join(["%s"] * len(user_ids))
        cursor.execute(
            f"""
            SELECT user_id, user_status
            FROM `user`
            WHERE user_id IN ({user_placeholders})
            ORDER BY user_id
            FOR UPDATE
            """,
            tuple(user_ids),
        )
        users = list(cursor.fetchall())
        found_ids = {int(user["user_id"]) for user in users}
        missing_ids = sorted(set(user_ids) - found_ids)
        if missing_ids:
            raise TargetedCouponError(f"目标用户不存在：{missing_ids}")
        invalid_ids = [
            int(user["user_id"])
            for user in users
            if user["user_status"] != "ACTIVE"
        ]
        if invalid_ids:
            raise TargetedCouponError(f"目标用户当前不可领券：{invalid_ids}")

        cursor.execute(
            "SELECT COUNT(*) AS total_issued FROM coupon WHERE promotion_id = %s",
            (promotion_id,),
        )
        total_issued = int(cursor.fetchone()["total_issued"])
        total_quantity = promotion["total_quantity"]
        if (
            total_quantity is not None
            and total_issued + len(normalized_recipients) > int(total_quantity)
        ):
            raise TargetedCouponError("本批次超过活动剩余发券总量。")

        cursor.execute(
            f"""
            SELECT user_id, COUNT(*) AS issued_count
            FROM coupon
            WHERE promotion_id = %s
              AND user_id IN ({user_placeholders})
            GROUP BY user_id
            """,
            (promotion_id, *user_ids),
        )
        existing_counts = {
            int(row["user_id"]): int(row["issued_count"])
            for row in cursor.fetchall()
        }
        exceeded_users = [
            user_id
            for user_id in user_ids
            if existing_counts.get(user_id, 0) + 1
            > int(promotion["per_user_limit"])
        ]
        if exceeded_users:
            raise TargetedCouponError(f"用户超过活动限领数量：{exceeded_users}")

        code_placeholders = ", ".join(["%s"] * len(coupon_codes))
        cursor.execute(
            f"""
            SELECT coupon_code
            FROM coupon
            WHERE coupon_code IN ({code_placeholders})
            """,
            tuple(coupon_codes),
        )
        existing_codes = [row["coupon_code"] for row in cursor.fetchall()]
        if existing_codes:
            raise TargetedCouponError(f"券码已经存在：{existing_codes}")

        rows = [
            (
                code,
                promotion_id,
                user_id,
                operation_time,
                operation_time,
                promotion["valid_to"],
            )
            for user_id, code in normalized_recipients
        ]
        cursor.executemany(
            """
            INSERT INTO coupon (
                coupon_code,
                promotion_id,
                user_id,
                issued_at,
                valid_from,
                valid_to,
                status
            ) VALUES (%s, %s, %s, %s, %s, %s, 'AVAILABLE')
            """,
            rows,
        )
        if cursor.rowcount != len(rows):
            raise RuntimeError("批量发券写入数量与目标数量不一致。")

    return {
        "promotion_id": promotion_id,
        "promotion_name": promotion["promotion_name"],
        "issued_count": len(rows),
        "user_ids": user_ids,
        "issued_at": operation_time,
        "status": "AVAILABLE",
    }


def _normalize_recipients(
    recipients: Sequence[tuple[int, str]],
) -> list[tuple[int, str]]:
    if not recipients:
        raise TargetedCouponError("recipients 不能为空。")
    if len(recipients) > MAX_BATCH_SIZE:
        raise TargetedCouponError(f"单批次最多发放 {MAX_BATCH_SIZE} 张券。")

    normalized: list[tuple[int, str]] = []
    for user_id, coupon_code in recipients:
        if user_id <= 0:
            raise TargetedCouponError("user_id 必须是正整数。")
        code = coupon_code.strip()
        if not code or len(code) > 64:
            raise TargetedCouponError("coupon_code 长度必须在 1 到 64 之间。")
        normalized.append((user_id, code))

    user_ids = [user_id for user_id, _ in normalized]
    coupon_codes = [code for _, code in normalized]
    if len(set(user_ids)) != len(user_ids):
        raise TargetedCouponError("同一批次不能包含重复用户。")
    if len(set(coupon_codes)) != len(coupon_codes):
        raise TargetedCouponError("同一批次不能包含重复券码。")
    return normalized
