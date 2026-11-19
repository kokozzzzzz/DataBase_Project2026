"""优惠计算服务单元测试。"""

from decimal import Decimal
from typing import Any

import pytest

from app.services.promotion_service import (
    PromotionCalculationError,
    calculate_promotion_discount,
    choose_best_promotion,
)


def _promotion(**overrides: Any) -> dict[str, Any]:
    promotion = {
        "promotion_id": 40001,
        "promotion_name": "测试活动",
        "discount_type": "FIXED",
        "discount_value": Decimal("10.00"),
        "minimum_spend": Decimal("20.00"),
        "max_discount_amount": None,
    }
    promotion.update(overrides)
    return promotion


def test_fixed_discount_uses_fixed_amount() -> None:
    quote = calculate_promotion_discount(
        _promotion(),
        order_amount=Decimal("100.00"),
    )

    assert quote["eligible"] is True
    assert quote["discount_amount"] == Decimal("10.00")
    assert quote["payable_amount"] == Decimal("90.00")


def test_percentage_value_is_payable_rate() -> None:
    quote = calculate_promotion_discount(
        _promotion(
            discount_type="PERCENTAGE",
            discount_value=Decimal("0.80"),
        ),
        order_amount=Decimal("100.00"),
    )

    assert quote["discount_amount"] == Decimal("20.00")
    assert quote["payable_amount"] == Decimal("80.00")


def test_percentage_discount_applies_cap() -> None:
    quote = calculate_promotion_discount(
        _promotion(
            discount_type="PERCENTAGE",
            discount_value=Decimal("0.50"),
            max_discount_amount=Decimal("30.00"),
        ),
        order_amount=Decimal("100.00"),
    )

    assert quote["discount_amount"] == Decimal("30.00")
    assert quote["payable_amount"] == Decimal("70.00")


def test_order_below_minimum_is_not_eligible() -> None:
    quote = calculate_promotion_discount(
        _promotion(minimum_spend=Decimal("120.00")),
        order_amount=Decimal("100.00"),
    )

    assert quote["eligible"] is False
    assert quote["discount_amount"] == Decimal("0.00")
    assert quote["payable_amount"] == Decimal("100.00")


def test_choose_best_promotion_prefers_largest_discount() -> None:
    best_quote = choose_best_promotion(
        [
            _promotion(promotion_id=40001, discount_value=Decimal("10.00")),
            _promotion(promotion_id=40002, discount_value=Decimal("24.00")),
        ],
        order_amount=Decimal("100.00"),
    )

    assert best_quote is not None
    assert best_quote["promotion_id"] == 40002
    assert best_quote["discount_amount"] == Decimal("24.00")


def test_invalid_percentage_rate_is_rejected() -> None:
    with pytest.raises(PromotionCalculationError, match="实付比例"):
        calculate_promotion_discount(
            _promotion(
                discount_type="PERCENTAGE",
                discount_value=Decimal("1.20"),
            ),
            order_amount=Decimal("100.00"),
        )
