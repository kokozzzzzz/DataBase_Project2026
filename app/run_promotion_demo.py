"""全场优惠活动筛选与最优优惠计算演示。"""

from __future__ import annotations

import sys
from datetime import datetime
from decimal import Decimal

import pymysql

from app.database import DatabaseConfigError, database_connection
from app.database.membership_repository import list_available_global_promotions
from app.services.promotion_service import (
    PromotionCalculationError,
    choose_best_promotion,
)


TEST_ORDER_AMOUNT = Decimal("100.00")
TEST_QUERY_TIME = datetime(2026, 11, 19, 12, 0, 0)


def main() -> int:
    """从数据库读取可用活动并计算 100 元订单的最优优惠。"""

    try:
        with database_connection() as connection:
            promotions = list_available_global_promotions(
                connection,
                order_amount=TEST_ORDER_AMOUNT,
                at_time=TEST_QUERY_TIME,
            )
            best_quote = choose_best_promotion(
                promotions,
                order_amount=TEST_ORDER_AMOUNT,
            )
    except (DatabaseConfigError, PromotionCalculationError, ValueError) as exc:
        print(f"业务错误：{exc}", file=sys.stderr)
        return 2
    except pymysql.MySQLError as exc:
        print(f"数据库错误：{exc}", file=sys.stderr)
        return 3

    print(
        f"可用全场活动：{len(promotions)} 个，"
        f"查询时间={TEST_QUERY_TIME:%Y-%m-%d %H:%M:%S}，"
        f"订单金额={TEST_ORDER_AMOUNT:.2f}"
    )
    if best_quote is None:
        print("没有满足条件的活动。")
        return 0

    print(
        "最优活动："
        f"promotion_id={best_quote['promotion_id']}，"
        f"名称={best_quote['promotion_name']}，"
        f"类型={best_quote['discount_type']}，"
        f"优惠={best_quote['discount_amount']:.2f}，"
        f"实付={best_quote['payable_amount']:.2f}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
