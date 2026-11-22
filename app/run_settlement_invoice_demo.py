"""⑤ 普通发票和红字冲销的真实数据库回滚演示。"""

from __future__ import annotations

import sys
from datetime import datetime
from decimal import Decimal
from uuid import uuid4

import pymysql

from app.database import DatabaseConfigError, database_connection
from app.services.settlement_invoice_service import (
    SettlementInvoiceError,
    issue_normal_invoice,
    issue_red_letter_invoice,
)


NORMAL_ISSUED_AT = datetime(2026, 12, 6, 9, 0, 0)
RED_ISSUED_AT = datetime(2026, 12, 7, 9, 0, 0)


def _select_fixture(connection: pymysql.connections.Connection) -> dict[str, object]:
    with connection.cursor() as cursor:
        cursor.execute(
            """
            SELECT
                settlement_id,
                statement_no,
                operator_name,
                payable_amount,
                net_invoice_amount,
                invoice_available_amount
            FROM v_settlement_statement_summary
            WHERE status IN ('CONFIRMED', 'PAID')
              AND payable_amount > 0
              AND invoice_available_amount >= 2.00
            ORDER BY settlement_id
            LIMIT 1
            """
        )
        row = cursor.fetchone()
    if row is None:
        raise RuntimeError("没有剩余可开票金额不少于 2.00 元的结算单。")
    return row


def main() -> int:
    """开普通票、开红字票并验证统一回滚。"""

    suffix = uuid4().hex[:16]
    normal_number = f"DEMO-N-{suffix}"
    red_number = f"DEMO-R-{suffix}"

    try:
        with database_connection() as connection:
            fixture = _select_fixture(connection)
            settlement_id = int(fixture["settlement_id"])
            before_net_amount = fixture["net_invoice_amount"]

            connection.begin()
            transaction_passed = False
            try:
                normal = issue_normal_invoice(
                    connection,
                    settlement_id=settlement_id,
                    invoice_number=normal_number,
                    invoice_title=str(fixture["operator_name"]),
                    invoice_amount=Decimal("2.00"),
                    issued_at=NORMAL_ISSUED_AT,
                )
                red = issue_red_letter_invoice(
                    connection,
                    original_invoice_id=int(normal["invoice_id"]),
                    invoice_number=red_number,
                    invoice_amount=Decimal("0.50"),
                    issued_at=RED_ISSUED_AT,
                )

                with connection.cursor() as cursor:
                    cursor.execute(
                        """
                        SELECT
                            normal_invoice.status AS normal_status,
                            red_invoice.status AS red_status,
                            red_invoice.original_invoice_id,
                            summary.net_invoice_amount
                        FROM invoice_record AS normal_invoice
                        JOIN invoice_record AS red_invoice
                          ON red_invoice.original_invoice_id = normal_invoice.invoice_id
                        JOIN v_settlement_statement_summary AS summary
                          ON summary.settlement_id = normal_invoice.settlement_id
                        WHERE normal_invoice.invoice_id = %s
                          AND red_invoice.invoice_id = %s
                        """,
                        (normal["invoice_id"], red["invoice_id"]),
                    )
                    state = cursor.fetchone()

                expected_net_amount = before_net_amount + Decimal("1.50")
                transaction_passed = bool(
                    state is not None
                    and state["normal_status"] == "RED_FLUSHED"
                    and state["red_status"] == "ISSUED"
                    and state["original_invoice_id"] == normal["invoice_id"]
                    and state["net_invoice_amount"] == expected_net_amount
                )
                print(
                    "事务内验证："
                    f"settlement_id={settlement_id}，"
                    "普通票=2.00，红字票=0.50，"
                    f"净开票={before_net_amount}→{expected_net_amount}，"
                    f"原票状态=RED_FLUSHED，结果={'PASS' if transaction_passed else 'FAIL'}"
                )
            finally:
                connection.rollback()

            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT COUNT(*) AS row_count
                    FROM invoice_record
                    WHERE invoice_number IN (%s, %s)
                    """,
                    (normal_number, red_number),
                )
                demo_invoice_count = int(cursor.fetchone()["row_count"])
                cursor.execute(
                    """
                    SELECT net_invoice_amount
                    FROM v_settlement_statement_summary
                    WHERE settlement_id = %s
                    """,
                    (settlement_id,),
                )
                restored = cursor.fetchone()

            rollback_passed = bool(
                demo_invoice_count == 0
                and restored is not None
                and restored["net_invoice_amount"] == before_net_amount
            )

    except (DatabaseConfigError, SettlementInvoiceError) as exc:
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
        f"演示发票={demo_invoice_count} 条，"
        f"净开票恢复={restored['net_invoice_amount']}，"
        f"结果={'PASS' if rollback_passed else 'FAIL'}"
    )
    return 0 if transaction_passed and rollback_passed else 5


if __name__ == "__main__":
    raise SystemExit(main())
