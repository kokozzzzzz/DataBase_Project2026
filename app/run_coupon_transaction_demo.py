"""优惠券发放、锁定、支付核销的真实数据库回滚演示。"""

from __future__ import annotations

import sys
from decimal import Decimal
from uuid import uuid4

import pymysql

from app.database import DatabaseConfigError, database_connection
from app.services.coupon_service import (
    CouponOperationError,
    issue_coupon,
    lock_coupon_for_order,
    redeem_coupon_for_order,
)


TEST_USER_ID = 10001
TEST_VEHICLE_ID = 20001
TEST_PROMOTION_ID = 40001
ORDER_GROSS_AMOUNT = Decimal("100.00")


def _create_order_fixture(
    connection: pymysql.connections.Connection,
    *,
    suffix: str,
) -> dict[str, int | str]:
    """在当前事务中创建最小 B 场站、设备和已出账订单。"""

    operator_name = f"券事务演示运营商-{suffix}"
    pile_serial = f"COUPON-PILE-{suffix}"
    trade_ref = f"COUPON-PAY-{suffix}"

    with connection.cursor() as cursor:
        cursor.execute(
            "INSERT INTO `operator` (name) VALUES (%s)",
            (operator_name,),
        )
        operator_id = cursor.lastrowid

        cursor.execute(
            """
            INSERT INTO station (
                operator_id, name, address, longitude, latitude, status
            ) VALUES (%s, %s, %s, %s, %s, 'OPEN')
            """,
            (
                operator_id,
                f"券事务演示场站-{suffix}",
                "课程设计临时事务数据",
                Decimal("120.000000"),
                Decimal("30.000000"),
            ),
        )
        station_id = cursor.lastrowid

        cursor.execute(
            """
            INSERT INTO charging_pile (
                station_id, serial_no, model, protocol, rated_kw,
                acceptance_status, status
            ) VALUES (%s, %s, 'DEMO-P1', 'OCPP', 120.00, 'PASSED', 'READY')
            """,
            (station_id, pile_serial),
        )
        pile_id = cursor.lastrowid

        cursor.execute(
            """
            INSERT INTO parking_space (station_id, code)
            VALUES (%s, %s)
            """,
            (station_id, f"D-{suffix}"),
        )
        parking_space_id = cursor.lastrowid

        cursor.execute(
            """
            INSERT INTO charging_gun (
                pile_id, station_id, parking_space_id, gun_no,
                gun_type, interface_type, max_kw, status
            ) VALUES (%s, %s, %s, 1, 'DC', 'GB/T', 60.00, 'READY')
            """,
            (pile_id, station_id, parking_space_id),
        )
        gun_id = cursor.lastrowid

        cursor.execute(
            """
            INSERT INTO charging_order (
                gun_id, user_id, vehicle_id, channel,
                starts_at, ends_at, start_soc, end_soc,
                state, total_kwh, gross_amount, discount_amount, confirmed_at
            ) VALUES (
                %s, %s, %s, 'DIRECT',
                CURRENT_TIMESTAMP - INTERVAL 70 MINUTE,
                CURRENT_TIMESTAMP - INTERVAL 10 MINUTE,
                20, 80, 'BILLED', 20.000, %s, 0.00, CURRENT_TIMESTAMP
            )
            """,
            (gun_id, TEST_USER_ID, TEST_VEHICLE_ID, ORDER_GROSS_AMOUNT),
        )
        order_id = cursor.lastrowid

    return {
        "operator_id": operator_id,
        "operator_name": operator_name,
        "station_id": station_id,
        "order_id": order_id,
        "trade_ref": trade_ref,
    }


def _transaction_state(
    connection: pymysql.connections.Connection,
    *,
    coupon_id: int,
    order_id: int,
) -> dict[str, object]:
    with connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT status, locked_order_id, used_at
            FROM coupon
            WHERE coupon_id = %s
            """,
            (coupon_id,),
        )
        coupon = cursor.fetchone()

        cursor.execute(
            """
            SELECT discount_amount
            FROM charging_order
            WHERE order_id = %s
            """,
            (order_id,),
        )
        order = cursor.fetchone()

        cursor.execute(
            """
            SELECT COUNT(*) AS redemption_count
            FROM coupon_redemption
            WHERE coupon_id = %s
              AND order_id = %s
            """,
            (coupon_id, order_id),
        )
        redemption_count = int(cursor.fetchone()["redemption_count"])

    return {
        "coupon": coupon,
        "order": order,
        "redemption_count": redemption_count,
    }


def _rollback_counts(
    connection: pymysql.connections.Connection,
    *,
    coupon_code: str,
    order_id: int,
    operator_name: str,
    trade_ref: str,
) -> dict[str, int]:
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT COUNT(*) AS row_count FROM coupon WHERE coupon_code = %s",
            (coupon_code,),
        )
        coupon_count = int(cursor.fetchone()["row_count"])

        cursor.execute(
            "SELECT COUNT(*) AS row_count FROM charging_order WHERE order_id = %s",
            (order_id,),
        )
        order_count = int(cursor.fetchone()["row_count"])

        cursor.execute(
            "SELECT COUNT(*) AS row_count FROM `operator` WHERE name = %s",
            (operator_name,),
        )
        operator_count = int(cursor.fetchone()["row_count"])

        cursor.execute(
            "SELECT COUNT(*) AS row_count FROM payment_record WHERE trade_ref = %s",
            (trade_ref,),
        )
        payment_count = int(cursor.fetchone()["row_count"])

    return {
        "coupon": coupon_count,
        "order": order_count,
        "operator": operator_count,
        "payment": payment_count,
    }


def main() -> int:
    """完成发券→锁券→成功支付→核销，并验证整体回滚。"""

    suffix = uuid4().hex[:12]
    coupon_code = f"COUPON-DEMO-{suffix}"

    try:
        with database_connection() as connection:
            connection.begin()
            fixture: dict[str, int | str] | None = None
            transaction_passed = False
            try:
                fixture = _create_order_fixture(connection, suffix=suffix)
                order_id = int(fixture["order_id"])

                issued = issue_coupon(
                    connection,
                    coupon_code=coupon_code,
                    promotion_id=TEST_PROMOTION_ID,
                    user_id=TEST_USER_ID,
                )
                coupon_id = int(issued["coupon_id"])

                locked = lock_coupon_for_order(
                    connection,
                    coupon_id=coupon_id,
                    order_id=order_id,
                )

                with connection.cursor() as cursor:
                    cursor.execute(
                        """
                        INSERT INTO payment_record (
                            order_id, channel, trade_ref, amount, status
                        ) VALUES (%s, 'DEMO', %s, %s, 'SUCCESS')
                        """,
                        (
                            order_id,
                            fixture["trade_ref"],
                            locked["payable_amount"],
                        ),
                    )

                redeemed = redeem_coupon_for_order(
                    connection,
                    coupon_id=coupon_id,
                    order_id=order_id,
                )
                state = _transaction_state(
                    connection,
                    coupon_id=coupon_id,
                    order_id=order_id,
                )
                coupon = state["coupon"]
                order = state["order"]
                transaction_passed = bool(
                    coupon is not None
                    and coupon["status"] == "USED"
                    and coupon["locked_order_id"] == order_id
                    and coupon["used_at"] is not None
                    and order is not None
                    and order["discount_amount"] == locked["discount_amount"]
                    and state["redemption_count"] == 1
                    and redeemed["discount_amount"] == locked["discount_amount"]
                )

                print(
                    "事务内验证："
                    f"coupon_id={coupon_id}，"
                    "状态=AVAILABLE→LOCKED→USED，"
                    f"优惠={locked['discount_amount']}，"
                    f"实付={locked['payable_amount']}，"
                    f"核销记录={state['redemption_count']} 条，"
                    f"结果={'PASS' if transaction_passed else 'FAIL'}"
                )
            finally:
                connection.rollback()

            if fixture is None:
                raise RuntimeError("临时订单数据未创建成功。")

            counts = _rollback_counts(
                connection,
                coupon_code=coupon_code,
                order_id=int(fixture["order_id"]),
                operator_name=str(fixture["operator_name"]),
                trade_ref=str(fixture["trade_ref"]),
            )
            rollback_passed = all(value == 0 for value in counts.values())

    except (DatabaseConfigError, CouponOperationError) as exc:
        print(f"业务错误：{exc}", file=sys.stderr)
        return 2
    except pymysql.MySQLError as exc:
        print(f"数据库错误：{exc}", file=sys.stderr)
        return 3
    except RuntimeError as exc:
        print(f"演示错误：{exc}", file=sys.stderr)
        return 4

    print(
        "回滚后验证："
        f"优惠券={counts['coupon']} 条，"
        f"订单={counts['order']} 条，"
        f"运营商={counts['operator']} 条，"
        f"支付记录={counts['payment']} 条，"
        f"结果={'PASS' if rollback_passed else 'FAIL'}"
    )
    return 0 if transaction_passed and rollback_passed else 5


if __name__ == "__main__":
    raise SystemExit(main())
