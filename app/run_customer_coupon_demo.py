"""注册绑车、逻辑CRUD和目标用户批量发券的真实数据库回滚演示。"""

from __future__ import annotations

import hashlib
import sys
from datetime import timedelta
from decimal import Decimal
from uuid import uuid4

import pymysql

from app.database import DatabaseConfigError, database_connection
from app.database.membership_repository import (
    fetch_promotion_redemption_statistics,
    list_target_users,
    list_user_vehicles,
)
from app.services.coupon_service import CouponOperationError
from app.services.customer_service import (
    CustomerOperationError,
    change_vehicle_status,
    close_user,
    register_user_with_vehicle,
    update_user_profile,
    update_vehicle_profile,
)
from app.services.targeted_coupon_service import (
    TargetedCouponError,
    issue_coupons_batch,
)


def _digest(label: str) -> str:
    return hashlib.sha256(label.encode("utf-8")).hexdigest()


def main() -> int:
    """完成注册、维护、批量发券和逻辑关闭后统一回滚。"""

    token = uuid4().hex
    phone_hashes = [_digest(f"{token}-phone-{index}") for index in range(3)]
    plate_hashes = [_digest(f"{token}-plate-{index}") for index in range(3)]
    newcomer_code = f"NEW-{token[:20]}"
    batch_codes = [f"BATCH-{token[:18]}-{index}" for index in range(2)]

    try:
        with database_connection() as connection:
            with connection.cursor() as cursor:
                cursor.execute("SELECT CURRENT_TIMESTAMP AS database_time")
                database_time = cursor.fetchone()["database_time"]
                cursor.execute(
                    """
                    SELECT
                        p.promotion_id,
                        p.promotion_name,
                        p.total_quantity,
                        COUNT(c.coupon_id) AS issued_count
                    FROM promotion AS p
                    LEFT JOIN coupon AS c
                        ON c.promotion_id = p.promotion_id
                    WHERE p.status = 'ACTIVE'
                      AND p.valid_from <= %s
                      AND p.valid_to > %s
                    GROUP BY
                        p.promotion_id,
                        p.promotion_name,
                        p.total_quantity
                    HAVING p.total_quantity IS NULL
                        OR COUNT(c.coupon_id) + 2 <= p.total_quantity
                    ORDER BY p.promotion_id
                    LIMIT 2
                    """,
                    (database_time, database_time),
                )
                promotions = list(cursor.fetchall())
            connection.rollback()

            if len(promotions) < 2:
                print("业务错误：至少需要两个当前可发券活动。", file=sys.stderr)
                return 2

            baseline_newcomer = fetch_promotion_redemption_statistics(
                connection,
                promotion_id=promotions[0]["promotion_id"],
            )
            baseline_batch = fetch_promotion_redemption_statistics(
                connection,
                promotion_id=promotions[1]["promotion_id"],
            )
            connection.rollback()

            connection.begin()
            try:
                registrations = []
                for index in range(3):
                    registrations.append(
                        register_user_with_vehicle(
                            connection,
                            phone_ciphertext=f"demo-phone-{token}-{index}".encode(),
                            phone_hash=phone_hashes[index],
                            real_name=f"演示用户{index + 1}",
                            real_name_status="VERIFIED",
                            registration_channel="APP",
                            plate_ciphertext=f"demo-plate-{token}-{index}".encode(),
                            plate_hash=plate_hashes[index],
                            model=f"演示车型{index + 1}",
                            battery_capacity_kwh=Decimal("60.00"),
                            max_charging_power_kw=Decimal("120.00"),
                            fast_charge_supported=True,
                            registered_at=database_time,
                            newcomer_promotion_id=(
                                promotions[0]["promotion_id"] if index == 0 else None
                            ),
                            newcomer_coupon_code=(
                                newcomer_code if index == 0 else None
                            ),
                        )
                    )

                update_user_profile(
                    connection,
                    user_id=registrations[1]["user_id"],
                    real_name="演示用户二号",
                    real_name_status="VERIFIED",
                    registration_channel="WEB",
                )
                update_vehicle_profile(
                    connection,
                    vehicle_id=registrations[1]["vehicle_id"],
                    model="更新后的演示车型",
                    battery_capacity_kwh=Decimal("75.00"),
                    max_charging_power_kw=Decimal("150.00"),
                    fast_charge_supported=True,
                )
                change_vehicle_status(
                    connection,
                    vehicle_id=registrations[1]["vehicle_id"],
                    target_status="DISABLED",
                )
                change_vehicle_status(
                    connection,
                    vehicle_id=registrations[1]["vehicle_id"],
                    target_status="ACTIVE",
                )

                targets = list_target_users(
                    connection,
                    registered_start=database_time - timedelta(seconds=1),
                    registered_end=database_time + timedelta(seconds=1),
                    require_verified=True,
                    limit=100,
                )
                target_ids = {int(row["user_id"]) for row in targets}
                batch_result = issue_coupons_batch(
                    connection,
                    promotion_id=promotions[1]["promotion_id"],
                    recipients=[
                        (registrations[1]["user_id"], batch_codes[0]),
                        (registrations[2]["user_id"], batch_codes[1]),
                    ],
                    issued_at=database_time,
                )
                close_result = close_user(
                    connection,
                    user_id=registrations[2]["user_id"],
                )
                vehicles = list_user_vehicles(
                    connection,
                    user_id=registrations[1]["user_id"],
                    vehicle_status="ACTIVE",
                )
                newcomer_stats = fetch_promotion_redemption_statistics(
                    connection,
                    promotion_id=promotions[0]["promotion_id"],
                )
                batch_stats = fetch_promotion_redemption_statistics(
                    connection,
                    promotion_id=promotions[1]["promotion_id"],
                )

                created_ids = {int(row["user_id"]) for row in registrations}
                transaction_passed = (
                    created_ids.issubset(target_ids)
                    and registrations[0]["coupon"] is not None
                    and batch_result["issued_count"] == 2
                    and close_result["status"] == "CLOSED"
                    and close_result["disabled_vehicle_count"] == 1
                    and close_result["cancelled_coupon_count"] == 1
                    and len(vehicles) == 1
                    and int(newcomer_stats["issued_count"])
                    == int(baseline_newcomer["issued_count"]) + 1
                    and int(batch_stats["issued_count"])
                    == int(baseline_batch["issued_count"]) + 2
                )
                print(
                    "事务内验证："
                    f"注册绑车={len(registrations)} 组，"
                    f"新人券=1 张，批量发券={batch_result['issued_count']} 张，"
                    f"目标用户命中={len(created_ids & target_ids)} 人，"
                    f"逻辑关闭={close_result['status']}，"
                    f"结果={'PASS' if transaction_passed else 'FAIL'}"
                )
            finally:
                connection.rollback()

            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT
                        (SELECT COUNT(*) FROM `user`
                         WHERE phone_hash IN (%s, %s, %s)) AS user_count,
                        (SELECT COUNT(*) FROM vehicle
                         WHERE plate_hash IN (%s, %s, %s)) AS vehicle_count,
                        (SELECT COUNT(*) FROM coupon
                         WHERE coupon_code IN (%s, %s, %s)) AS coupon_count
                    """,
                    (
                        *phone_hashes,
                        *plate_hashes,
                        newcomer_code,
                        *batch_codes,
                    ),
                )
                rollback_result = cursor.fetchone()

    except (
        DatabaseConfigError,
        CustomerOperationError,
        TargetedCouponError,
        CouponOperationError,
    ) as exc:
        print(f"业务错误：{exc}", file=sys.stderr)
        return 2
    except pymysql.MySQLError as exc:
        print(f"数据库错误：{exc}", file=sys.stderr)
        return 3

    rollback_passed = (
        int(rollback_result["user_count"]) == 0
        and int(rollback_result["vehicle_count"]) == 0
        and int(rollback_result["coupon_count"]) == 0
    )
    print(
        "回滚后验证："
        f"用户={rollback_result['user_count']}，"
        f"车辆={rollback_result['vehicle_count']}，"
        f"优惠券={rollback_result['coupon_count']}，"
        f"结果={'PASS' if rollback_passed else 'FAIL'}"
    )
    return 0 if transaction_passed and rollback_passed else 5


if __name__ == "__main__":
    raise SystemExit(main())
