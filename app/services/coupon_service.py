"""④ 优惠券发放、锁定、释放和核销事务操作。"""

from __future__ import annotations

from datetime import datetime
from decimal import Decimal, InvalidOperation
from typing import Any

from pymysql.connections import Connection

from .promotion_service import calculate_promotion_discount


MONEY_UNIT = Decimal("0.01")
ZERO = Decimal("0.00")


class CouponOperationError(ValueError):
    """优惠券操作不满足业务规则。"""


def issue_coupon(
    connection: Connection,
    *,
    coupon_code: str,
    promotion_id: int,
    user_id: int,
    issued_at: datetime | None = None,
) -> dict[str, Any]:
    """按活动规则发券；事务提交或回滚由调用方控制。"""

    _validate_ids(promotion_id=promotion_id, user_id=user_id)
    normalized_code = coupon_code.strip()
    if not normalized_code:
        raise CouponOperationError("coupon_code 不能为空。")
    if len(normalized_code) > 64:
        raise CouponOperationError("coupon_code 不能超过 64 个字符。")

    with connection.cursor() as cursor:
        # 活动行是同一活动并发发券的固定锁点，防止总量和单用户限额穿透。
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
            raise CouponOperationError(f"优惠活动 {promotion_id} 不存在。")

        operation_time = issued_at or promotion["database_time"]
        if promotion["status"] != "ACTIVE":
            raise CouponOperationError(f"优惠活动 {promotion_id} 当前不可发券。")
        if not promotion["valid_from"] <= operation_time < promotion["valid_to"]:
            raise CouponOperationError("发券时间不在活动有效期内。")

        cursor.execute(
            """
            SELECT user_id, user_status
            FROM `user`
            WHERE user_id = %s
            FOR UPDATE
            """,
            (user_id,),
        )
        user = cursor.fetchone()
        if user is None:
            raise CouponOperationError(f"用户 {user_id} 不存在。")
        if user["user_status"] != "ACTIVE":
            raise CouponOperationError(f"用户 {user_id} 当前不可领券。")

        cursor.execute(
            """
            SELECT
                COUNT(*) AS total_issued,
                COALESCE(SUM(user_id = %s), 0) AS user_issued
            FROM coupon
            WHERE promotion_id = %s
            """,
            (user_id, promotion_id),
        )
        counts = cursor.fetchone()
        total_issued = int(counts["total_issued"])
        user_issued = int(counts["user_issued"])
        total_quantity = promotion["total_quantity"]
        if total_quantity is not None and total_issued >= int(total_quantity):
            raise CouponOperationError("优惠活动发券总量已用完。")
        if user_issued >= int(promotion["per_user_limit"]):
            raise CouponOperationError("该用户已达到活动限领数量。")

        cursor.execute(
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
            (
                normalized_code,
                promotion_id,
                user_id,
                operation_time,
                operation_time,
                promotion["valid_to"],
            ),
        )
        coupon_id = cursor.lastrowid

    return {
        "coupon_id": coupon_id,
        "coupon_code": normalized_code,
        "promotion_id": promotion_id,
        "promotion_name": promotion["promotion_name"],
        "user_id": user_id,
        "status": "AVAILABLE",
        "valid_from": operation_time,
        "valid_to": promotion["valid_to"],
    }


def lock_coupon_for_order(
    connection: Connection,
    *,
    coupon_id: int,
    order_id: int,
    locked_at: datetime | None = None,
) -> dict[str, Any]:
    """锁券并把试算优惠写入已出账订单。"""

    _validate_ids(coupon_id=coupon_id, order_id=order_id)

    with connection.cursor() as cursor:
        order = _lock_order(cursor, order_id)
        if order["state"] != "BILLED" or order["gross_amount"] is None:
            raise CouponOperationError("只有已出账且金额确定的订单才能锁券。")
        if _as_money(order["discount_amount"], "order.discount_amount") != ZERO:
            raise CouponOperationError("订单已经存在优惠金额，不能重复锁券。")

        cursor.execute(
            """
            SELECT
                c.coupon_id,
                c.promotion_id,
                c.user_id,
                c.status,
                c.valid_from,
                c.valid_to,
                p.promotion_name,
                p.discount_type,
                p.discount_value,
                p.minimum_spend,
                p.max_discount_amount,
                p.applicability_scope,
                p.valid_from AS promotion_valid_from,
                p.valid_to AS promotion_valid_to,
                p.status AS promotion_status
            FROM coupon AS c
            JOIN promotion AS p
              ON p.promotion_id = c.promotion_id
            WHERE c.coupon_id = %s
            FOR UPDATE
            """,
            (coupon_id,),
        )
        coupon = cursor.fetchone()
        if coupon is None:
            raise CouponOperationError(f"优惠券 {coupon_id} 不存在。")
        if coupon["user_id"] != order["user_id"]:
            raise CouponOperationError("优惠券不属于订单用户。")
        if coupon["status"] != "AVAILABLE":
            raise CouponOperationError("优惠券当前不是 AVAILABLE 状态。")

        operation_time = locked_at or order["database_time"]
        if not coupon["valid_from"] <= operation_time < coupon["valid_to"]:
            raise CouponOperationError("优惠券不在有效期内。")
        if coupon["promotion_status"] != "ACTIVE":
            raise CouponOperationError("优惠活动当前不可用。")
        if not (
            coupon["promotion_valid_from"]
            <= operation_time
            < coupon["promotion_valid_to"]
        ):
            raise CouponOperationError("优惠活动不在有效期内。")

        cursor.execute(
            """
            SELECT coupon_id
            FROM coupon
            WHERE locked_order_id = %s
            FOR UPDATE
            """,
            (order_id,),
        )
        existing_coupon = cursor.fetchone()
        if existing_coupon is not None:
            raise CouponOperationError(
                f"订单 {order_id} 已锁定优惠券 {existing_coupon['coupon_id']}。"
            )

        if coupon["applicability_scope"] == "SELECTED":
            cursor.execute(
                """
                SELECT 1 AS applicable
                FROM promotion_station
                WHERE promotion_id = %s
                  AND station_id = %s
                """,
                (coupon["promotion_id"], order["station_id"]),
            )
            if cursor.fetchone() is None:
                raise CouponOperationError("优惠券不适用于订单所属场站。")

        quote = calculate_promotion_discount(
            coupon,
            order_amount=_as_money(order["gross_amount"], "order.gross_amount"),
        )
        if not quote["eligible"] or quote["discount_amount"] <= ZERO:
            raise CouponOperationError(quote["reason"] or "优惠金额必须大于 0。")

        cursor.execute(
            """
            UPDATE charging_order
            SET discount_amount = %s
            WHERE order_id = %s
              AND state = 'BILLED'
              AND discount_amount = 0
            """,
            (quote["discount_amount"], order_id),
        )
        if cursor.rowcount != 1:
            raise RuntimeError("订单优惠金额更新失败，数据可能已被并发修改。")

        cursor.execute(
            """
            UPDATE coupon
            SET
                status = 'LOCKED',
                locked_order_id = %s,
                locked_at = %s
            WHERE coupon_id = %s
              AND status = 'AVAILABLE'
            """,
            (order_id, operation_time, coupon_id),
        )
        if cursor.rowcount != 1:
            raise RuntimeError("优惠券锁定失败，数据可能已被并发修改。")

    return {
        "coupon_id": coupon_id,
        "order_id": order_id,
        "user_id": order["user_id"],
        "station_id": order["station_id"],
        "status": "LOCKED",
        "discount_amount": quote["discount_amount"],
        "payable_amount": quote["payable_amount"],
        "locked_at": operation_time,
    }


def release_coupon_from_order(
    connection: Connection,
    *,
    coupon_id: int,
    order_id: int,
    released_at: datetime | None = None,
) -> dict[str, Any]:
    """支付未成功时释放锁券，并清零订单优惠金额。"""

    _validate_ids(coupon_id=coupon_id, order_id=order_id)

    with connection.cursor() as cursor:
        order = _lock_order(cursor, order_id)
        cursor.execute(
            """
            SELECT
                coupon_id,
                status,
                locked_order_id,
                valid_to,
                CURRENT_TIMESTAMP AS database_time
            FROM coupon
            WHERE coupon_id = %s
            FOR UPDATE
            """,
            (coupon_id,),
        )
        coupon = cursor.fetchone()
        if coupon is None:
            raise CouponOperationError(f"优惠券 {coupon_id} 不存在。")
        if coupon["status"] != "LOCKED" or coupon["locked_order_id"] != order_id:
            raise CouponOperationError("优惠券未锁定到指定订单。")

        cursor.execute(
            """
            SELECT COUNT(*) AS success_count
            FROM payment_record
            WHERE order_id = %s
              AND status = 'SUCCESS'
            FOR UPDATE
            """,
            (order_id,),
        )
        if int(cursor.fetchone()["success_count"]) > 0:
            raise CouponOperationError("订单已有成功支付，不能释放优惠券。")

        operation_time = released_at or coupon["database_time"]
        next_status = "AVAILABLE" if operation_time < coupon["valid_to"] else "EXPIRED"

        cursor.execute(
            """
            UPDATE charging_order
            SET discount_amount = 0, confirmed_at = NULL
            WHERE order_id = %s
            """,
            (order_id,),
        )
        if cursor.rowcount != 1:
            raise RuntimeError("订单优惠金额清零失败。")

        cursor.execute(
            """
            UPDATE coupon
            SET
                status = %s,
                locked_order_id = NULL,
                locked_at = NULL
            WHERE coupon_id = %s
              AND status = 'LOCKED'
              AND locked_order_id = %s
            """,
            (next_status, coupon_id, order_id),
        )
        if cursor.rowcount != 1:
            raise RuntimeError("优惠券释放失败，数据可能已被并发修改。")

    return {
        "coupon_id": coupon_id,
        "order_id": order_id,
        "status": next_status,
        "released_at": operation_time,
        "previous_discount_amount": _as_money(
            order["discount_amount"], "order.discount_amount"
        ),
    }


def redeem_coupon_for_order(
    connection: Connection,
    *,
    coupon_id: int,
    order_id: int,
    redeemed_at: datetime | None = None,
) -> dict[str, Any]:
    """成功支付后核销锁券，并写入不可重复的核销记录。"""

    _validate_ids(coupon_id=coupon_id, order_id=order_id)

    with connection.cursor() as cursor:
        order = _lock_order(cursor, order_id)
        if order["state"] != "BILLED" or order["gross_amount"] is None:
            raise CouponOperationError("只有已出账订单才能核销优惠券。")
        discount_amount = _as_money(
            order["discount_amount"], "order.discount_amount"
        )
        if discount_amount <= ZERO:
            raise CouponOperationError("订单没有可核销的优惠金额。")

        cursor.execute(
            """
            SELECT
                coupon_id,
                user_id,
                status,
                locked_order_id,
                locked_at,
                CURRENT_TIMESTAMP AS database_time
            FROM coupon
            WHERE coupon_id = %s
            FOR UPDATE
            """,
            (coupon_id,),
        )
        coupon = cursor.fetchone()
        if coupon is None:
            raise CouponOperationError(f"优惠券 {coupon_id} 不存在。")
        if coupon["user_id"] != order["user_id"]:
            raise CouponOperationError("优惠券不属于订单用户。")
        if coupon["status"] != "LOCKED" or coupon["locked_order_id"] != order_id:
            raise CouponOperationError("优惠券未锁定到指定订单。")

        cursor.execute(
            """
            SELECT COALESCE(SUM(amount), 0) AS paid_amount
            FROM payment_record
            WHERE order_id = %s
              AND status = 'SUCCESS'
            FOR UPDATE
            """,
            (order_id,),
        )
        paid_amount = _as_money(cursor.fetchone()["paid_amount"], "paid_amount")
        gross_amount = _as_money(order["gross_amount"], "order.gross_amount")
        payable_amount = gross_amount - discount_amount
        if payable_amount > ZERO and paid_amount < payable_amount:
            raise CouponOperationError("订单成功支付金额不足，不能核销优惠券。")

        operation_time = redeemed_at or coupon["database_time"]
        if operation_time < coupon["locked_at"]:
            raise CouponOperationError("核销时间不能早于锁券时间。")

        cursor.execute(
            """
            UPDATE coupon
            SET
                status = 'USED',
                used_at = %s
            WHERE coupon_id = %s
              AND status = 'LOCKED'
              AND locked_order_id = %s
            """,
            (operation_time, coupon_id, order_id),
        )
        if cursor.rowcount != 1:
            raise RuntimeError("优惠券核销失败，数据可能已被并发修改。")

        cursor.execute(
            """
            INSERT INTO coupon_redemption (
                coupon_id,
                order_id,
                discount_amount,
                redeemed_at
            ) VALUES (%s, %s, %s, %s)
            """,
            (coupon_id, order_id, discount_amount, operation_time),
        )
        redemption_id = cursor.lastrowid

    return {
        "redemption_id": redemption_id,
        "coupon_id": coupon_id,
        "order_id": order_id,
        "status": "USED",
        "discount_amount": discount_amount,
        "paid_amount": paid_amount,
        "redeemed_at": operation_time,
    }


def reissue_coupon_after_full_refund(
    connection: Connection,
    *,
    coupon_id: int,
    reviewed_at: datetime | None = None,
) -> dict[str, Any]:
    """全额退款经人工审核后补发同活动券；部分退款不返券。

    原券和核销记录保持不变，新券使用 ``REFUND-原券编号`` 作为幂等业务码。
    补发不再次受单用户限领数约束，但仍受活动总量、有效期和用户状态约束。
    事务提交或回滚由调用方控制。
    """

    _validate_ids(coupon_id=coupon_id)

    with connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT
                c.coupon_id,
                c.promotion_id,
                c.user_id,
                c.status,
                cr.redemption_id,
                cr.order_id,
                p.promotion_name,
                p.total_quantity,
                p.valid_from,
                p.valid_to,
                p.status AS promotion_status,
                u.user_status,
                CURRENT_TIMESTAMP AS database_time
            FROM coupon AS c
            JOIN coupon_redemption AS cr
              ON cr.coupon_id = c.coupon_id
            JOIN charging_order AS o
              ON o.order_id = cr.order_id
             AND o.user_id = c.user_id
            JOIN promotion AS p
              ON p.promotion_id = c.promotion_id
            JOIN `user` AS u
              ON u.user_id = c.user_id
            WHERE c.coupon_id = %s
            FOR UPDATE
            """,
            (coupon_id,),
        )
        original = cursor.fetchone()
        if original is None:
            raise CouponOperationError("原优惠券不存在或没有有效核销记录。")
        if original["status"] != "USED":
            raise CouponOperationError("只有已核销优惠券才能申请退款补发。")
        if original["user_status"] != "ACTIVE":
            raise CouponOperationError("持券用户当前不可接收补发券。")

        cursor.execute(
            """
            SELECT payment_id, amount
            FROM payment_record
            WHERE order_id = %s
              AND status = 'SUCCESS'
            ORDER BY payment_id
            FOR UPDATE
            """,
            (original["order_id"],),
        )
        payments = list(cursor.fetchall())
        paid_amount = sum(
            (_as_money(row["amount"], "payment.amount") for row in payments),
            ZERO,
        )
        if paid_amount <= ZERO:
            raise CouponOperationError("原订单没有成功支付记录。")

        cursor.execute(
            """
            SELECT rr.refund_id, rr.amount, rr.occurred_at
            FROM refund_record AS rr
            JOIN payment_record AS pr
              ON pr.payment_id = rr.payment_id
             AND pr.status = 'SUCCESS'
            WHERE pr.order_id = %s
            ORDER BY rr.refund_id
            FOR UPDATE
            """,
            (original["order_id"],),
        )
        refunds = list(cursor.fetchall())
        refunded_amount = sum(
            (_as_money(row["amount"], "refund.amount") for row in refunds),
            ZERO,
        )
        if refunded_amount < paid_amount:
            raise CouponOperationError("订单尚未全额退款，部分退款不补发优惠券。")

        operation_time = reviewed_at or original["database_time"]
        latest_refund_at = max(row["occurred_at"] for row in refunds)
        if operation_time < latest_refund_at:
            raise CouponOperationError("退款补发审核时间不能早于最后退款时间。")
        if original["promotion_status"] != "ACTIVE":
            raise CouponOperationError("原优惠活动当前不可补发。")
        if not original["valid_from"] <= operation_time < original["valid_to"]:
            raise CouponOperationError("审核时间不在原优惠活动有效期内。")

        compensation_code = f"REFUND-{coupon_id}"
        cursor.execute(
            """
            SELECT coupon_id, promotion_id, user_id, status, valid_from, valid_to
            FROM coupon
            WHERE coupon_code = %s
            FOR UPDATE
            """,
            (compensation_code,),
        )
        existing = cursor.fetchone()
        if existing is not None:
            if (
                existing["promotion_id"] != original["promotion_id"]
                or existing["user_id"] != original["user_id"]
            ):
                raise CouponOperationError("退款补发业务码发生冲突。")
            return {
                "coupon_id": existing["coupon_id"],
                "coupon_code": compensation_code,
                "original_coupon_id": coupon_id,
                "order_id": original["order_id"],
                "promotion_id": original["promotion_id"],
                "user_id": original["user_id"],
                "status": existing["status"],
                "paid_amount": paid_amount,
                "refunded_amount": refunded_amount,
                "valid_from": existing["valid_from"],
                "valid_to": existing["valid_to"],
                "reused": True,
            }

        cursor.execute(
            "SELECT COUNT(*) AS total_issued FROM coupon WHERE promotion_id = %s",
            (original["promotion_id"],),
        )
        total_issued = int(cursor.fetchone()["total_issued"])
        total_quantity = original["total_quantity"]
        if total_quantity is not None and total_issued >= int(total_quantity):
            raise CouponOperationError("原优惠活动发券总量已用完，不能补发。")

        cursor.execute(
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
            (
                compensation_code,
                original["promotion_id"],
                original["user_id"],
                operation_time,
                operation_time,
                original["valid_to"],
            ),
        )
        compensation_coupon_id = cursor.lastrowid

    return {
        "coupon_id": compensation_coupon_id,
        "coupon_code": compensation_code,
        "original_coupon_id": coupon_id,
        "order_id": original["order_id"],
        "promotion_id": original["promotion_id"],
        "user_id": original["user_id"],
        "status": "AVAILABLE",
        "paid_amount": paid_amount,
        "refunded_amount": refunded_amount,
        "valid_from": operation_time,
        "valid_to": original["valid_to"],
        "reused": False,
    }


def _lock_order(cursor: Any, order_id: int) -> dict[str, Any]:
    cursor.execute(
        """
        SELECT
            o.order_id,
            o.user_id,
            o.state,
            o.gross_amount,
            o.discount_amount,
            cg.station_id,
            CURRENT_TIMESTAMP AS database_time
        FROM charging_order AS o
        JOIN charging_gun AS cg
          ON cg.gun_id = o.gun_id
        WHERE o.order_id = %s
        FOR UPDATE
        """,
        (order_id,),
    )
    order = cursor.fetchone()
    if order is None:
        raise CouponOperationError(f"充电订单 {order_id} 不存在。")
    return order


def _as_money(value: Any, field_name: str) -> Decimal:
    try:
        amount = value if isinstance(value, Decimal) else Decimal(str(value))
        rounded = amount.quantize(MONEY_UNIT)
    except (InvalidOperation, TypeError, ValueError) as exc:
        raise CouponOperationError(f"{field_name} 不是有效金额。") from exc
    if rounded != amount:
        raise CouponOperationError(f"{field_name} 最多保留两位小数。")
    return rounded


def _validate_ids(**identifiers: int) -> None:
    for field_name, value in identifiers.items():
        if value <= 0:
            raise CouponOperationError(f"{field_name} 必须是正整数。")
