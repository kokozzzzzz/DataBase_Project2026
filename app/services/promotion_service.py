"""④ 优惠活动金额计算。"""

from __future__ import annotations

from decimal import ROUND_HALF_UP, Decimal
from typing import Any, Iterable


MONEY_UNIT = Decimal("0.01")
ONE = Decimal("1")
ZERO = Decimal("0")


class PromotionCalculationError(ValueError):
    """优惠规则或订单金额不满足计算要求。"""


def calculate_promotion_discount(
    promotion: dict[str, Any],
    *,
    order_amount: Decimal,
) -> dict[str, Any]:
    """计算单个活动的优惠金额和实付金额。"""

    amount = _as_decimal(order_amount, field_name="order_amount")
    if amount < ZERO:
        raise PromotionCalculationError("order_amount 不能小于 0。")

    minimum_spend = _as_decimal(
        promotion["minimum_spend"], field_name="minimum_spend"
    )
    if amount < minimum_spend:
        return _build_quote(
            promotion,
            order_amount=amount,
            eligible=False,
            discount_amount=ZERO,
            reason="未达到最低消费门槛",
        )

    discount_type = promotion["discount_type"]
    discount_value = _as_decimal(
        promotion["discount_value"], field_name="discount_value"
    )

    if discount_type == "FIXED":
        if discount_value <= ZERO:
            raise PromotionCalculationError("固定减免金额必须大于 0。")
        raw_discount = discount_value
    elif discount_type == "PERCENTAGE":
        if not ZERO < discount_value <= ONE:
            raise PromotionCalculationError("实付比例必须大于 0 且不超过 1。")
        # 0.80 表示八折，即用户支付原价的 80%，优惠原价的 20%。
        raw_discount = amount * (ONE - discount_value)
        max_discount = promotion.get("max_discount_amount")
        if max_discount is not None:
            cap = _as_decimal(max_discount, field_name="max_discount_amount")
            if cap <= ZERO:
                raise PromotionCalculationError("最高优惠金额必须大于 0。")
            raw_discount = min(raw_discount, cap)
    else:
        raise PromotionCalculationError(f"不支持的优惠类型：{discount_type}")

    discount_amount = min(raw_discount, amount).quantize(
        MONEY_UNIT, rounding=ROUND_HALF_UP
    )
    return _build_quote(
        promotion,
        order_amount=amount,
        eligible=True,
        discount_amount=discount_amount,
        reason=None,
    )


def choose_best_promotion(
    promotions: Iterable[dict[str, Any]],
    *,
    order_amount: Decimal,
) -> dict[str, Any] | None:
    """选择优惠金额最大的活动；金额相同时选择编号较小的活动。"""

    quotes = [
        calculate_promotion_discount(promotion, order_amount=order_amount)
        for promotion in promotions
    ]
    eligible_quotes = [quote for quote in quotes if quote["eligible"]]
    if not eligible_quotes:
        return None

    return max(
        eligible_quotes,
        key=lambda quote: (
            quote["discount_amount"],
            -int(quote["promotion_id"]),
        ),
    )


def _build_quote(
    promotion: dict[str, Any],
    *,
    order_amount: Decimal,
    eligible: bool,
    discount_amount: Decimal,
    reason: str | None,
) -> dict[str, Any]:
    rounded_amount = order_amount.quantize(MONEY_UNIT, rounding=ROUND_HALF_UP)
    rounded_discount = discount_amount.quantize(MONEY_UNIT, rounding=ROUND_HALF_UP)
    payable_amount = (rounded_amount - rounded_discount).quantize(
        MONEY_UNIT, rounding=ROUND_HALF_UP
    )
    return {
        "promotion_id": promotion["promotion_id"],
        "promotion_name": promotion["promotion_name"],
        "discount_type": promotion["discount_type"],
        "eligible": eligible,
        "order_amount": rounded_amount,
        "discount_amount": rounded_discount,
        "payable_amount": payable_amount,
        "reason": reason,
    }


def _as_decimal(value: Any, *, field_name: str) -> Decimal:
    try:
        return value if isinstance(value, Decimal) else Decimal(str(value))
    except Exception as exc:
        raise PromotionCalculationError(f"{field_name} 不是有效数字。") from exc
