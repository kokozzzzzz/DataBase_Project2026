"""⑤ 对账确认与跨期调整的真实数据库回滚演示。"""

from __future__ import annotations

import sys
from datetime import datetime
from decimal import Decimal
from uuid import uuid4

import pymysql

from app.database import DatabaseConfigError, database_connection
from app.services.settlement_service import (
    SettlementOperationError,
    apply_reconciliation_adjustment,
    confirm_reconciliation_difference,
)


CONFIRMED_AT = datetime(2027, 1, 3, 11, 30, 0)
EFFECTIVE_AT = datetime(2027, 1, 3, 12, 0, 0)


def _select_fixture(connection: pymysql.connections.Connection) -> dict[str, object]:
    with connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT
                pending.difference_id,
                pending.settlement_id AS source_settlement_id,
                pending.operator_id,
                pending.station_id,
                source.electricity_share_rate,
                source.service_share_rate,
                source.platform_fee_rate,
                source.operator_discount_rate
            FROM v_reconciliation_pending AS pending
            JOIN settlement_statement AS source
              ON source.settlement_id = pending.settlement_id
            WHERE pending.next_action = 'CREATE_ADJUSTMENT'
            ORDER BY pending.difference_id
            LIMIT 1
            """
        )
        row = cursor.fetchone()
    if row is None:
        raise RuntimeError("没有可用于演示的 CREATE_ADJUSTMENT 差异。")
    return row


def _create_target_statement(
    connection: pymysql.connections.Connection,
    fixture: dict[str, object],
    *,
    statement_no: str,
) -> int:
    with connection.cursor() as cursor:
        cursor.execute(
            """
            INSERT INTO settlement_statement (
                statement_no,
                operator_id,
                station_id,
                period_start,
                period_end,
                electricity_share_rate,
                service_share_rate,
                platform_fee_rate,
                operator_discount_rate,
                status,
                generated_at
            ) VALUES (
                %s, %s, %s, '2027-01-01', '2027-02-01',
                %s, %s, %s, %s,
                'GENERATED', '2027-01-02 09:00:00'
            )
            """,
            (
                statement_no,
                fixture["operator_id"],
                fixture["station_id"],
                fixture["electricity_share_rate"],
                fixture["service_share_rate"],
                fixture["platform_fee_rate"],
                fixture["operator_discount_rate"],
            ),
        )
        return int(cursor.lastrowid)


def main() -> int:
    """追加确认、应用跨期调整并验证统一回滚。"""

    statement_no = f"DEMO-ADJ-{uuid4().hex[:16]}"
    description = f"Python跨期调整回滚演示-{statement_no}"

    try:
        with database_connection() as connection:
            fixture = _select_fixture(connection)
            difference_id = int(fixture["difference_id"])

            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT COUNT(*) AS confirmation_count
                    FROM reconciliation_confirmation
                    WHERE difference_id = %s
                    """,
                    (difference_id,),
                )
                before_confirmation_count = int(
                    cursor.fetchone()["confirmation_count"]
                )

            connection.begin()
            transaction_passed = False
            try:
                target_settlement_id = _create_target_statement(
                    connection,
                    fixture,
                    statement_no=statement_no,
                )
                confirmation = confirm_reconciliation_difference(
                    connection,
                    difference_id=difference_id,
                    confirming_party="PLATFORM",
                    confirmation_result="AGREE",
                    confirmer_name="Python演示平台确认员",
                    confirmation_note="演示追加最新确认",
                    confirmed_at=CONFIRMED_AT,
                )
                adjustment = apply_reconciliation_adjustment(
                    connection,
                    difference_id=difference_id,
                    target_settlement_id=target_settlement_id,
                    adjustment_amount=Decimal("-0.50"),
                    description=description,
                    effective_at=EFFECTIVE_AT,
                    resolved_at=EFFECTIVE_AT,
                )

                with connection.cursor() as cursor:
                    cursor.execute(
                        """
                        SELECT
                            rd.status AS difference_status,
                            rd.adjustment_detail_id,
                            sd.detail_type,
                            sd.adjustment_amount,
                            ss.payable_amount
                        FROM reconciliation_difference AS rd
                        JOIN settlement_detail AS sd
                          ON sd.settlement_detail_id = rd.adjustment_detail_id
                        JOIN settlement_statement AS ss
                          ON ss.settlement_id = sd.settlement_id
                        WHERE rd.difference_id = %s
                        """,
                        (difference_id,),
                    )
                    state = cursor.fetchone()

                transaction_passed = bool(
                    confirmation["difference_status"] == "CONFIRMED"
                    and adjustment["difference_status"] == "RESOLVED"
                    and state is not None
                    and state["difference_status"] == "RESOLVED"
                    and state["detail_type"] == "OTHER_ADJUSTMENT"
                    and state["adjustment_amount"] == Decimal("-0.50")
                    and state["payable_amount"] == Decimal("-0.50")
                )
                print(
                    "事务内验证："
                    f"difference_id={difference_id}，"
                    "双方最新确认=AGREE/AGREE，"
                    f"adjustment_detail_id={adjustment['adjustment_detail_id']}，"
                    "调整=-0.50，目标账期应结=-0.50，"
                    f"结果={'PASS' if transaction_passed else 'FAIL'}"
                )
            finally:
                connection.rollback()

            with connection.cursor() as cursor:
                cursor.execute(
                    "SELECT COUNT(*) AS row_count FROM settlement_statement WHERE statement_no = %s",
                    (statement_no,),
                )
                target_count = int(cursor.fetchone()["row_count"])
                cursor.execute(
                    "SELECT COUNT(*) AS row_count FROM settlement_detail WHERE description = %s",
                    (description,),
                )
                adjustment_count = int(cursor.fetchone()["row_count"])
                cursor.execute(
                    """
                    SELECT status, adjustment_detail_id
                    FROM reconciliation_difference
                    WHERE difference_id = %s
                    """,
                    (difference_id,),
                )
                restored_difference = cursor.fetchone()
                cursor.execute(
                    """
                    SELECT COUNT(*) AS confirmation_count
                    FROM reconciliation_confirmation
                    WHERE difference_id = %s
                    """,
                    (difference_id,),
                )
                after_confirmation_count = int(
                    cursor.fetchone()["confirmation_count"]
                )

            rollback_passed = bool(
                target_count == 0
                and adjustment_count == 0
                and restored_difference is not None
                and restored_difference["status"] == "CONFIRMED"
                and restored_difference["adjustment_detail_id"] is None
                and after_confirmation_count == before_confirmation_count
            )

    except (DatabaseConfigError, SettlementOperationError) as exc:
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
        f"目标结算单={target_count} 条，"
        f"调整明细={adjustment_count} 条，"
        f"差异状态={restored_difference['status']}，"
        f"确认记录变化={after_confirmation_count - before_confirmation_count} 条，"
        f"结果={'PASS' if rollback_passed else 'FAIL'}"
    )
    return 0 if transaction_passed and rollback_passed else 5


if __name__ == "__main__":
    raise SystemExit(main())
