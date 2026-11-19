"""会员等级变更事务的真实数据库回滚演示。"""

from __future__ import annotations

import sys

import pymysql

from app.database import DatabaseConfigError, database_connection
from app.services.membership_service import MembershipChangeError, change_membership_level


TEST_USER_ID = 10001
TEST_TARGET_LEVEL_ID = 2


def _read_user_level(connection: pymysql.connections.Connection) -> int:
    with connection.cursor() as cursor:
        cursor.execute(
            "SELECT level_id FROM `user` WHERE user_id = %s",
            (TEST_USER_ID,),
        )
        row = cursor.fetchone()
    if row is None:
        raise RuntimeError(f"测试用户 {TEST_USER_ID} 不存在。")
    return int(row["level_id"])


def main() -> int:
    """执行等级变更并回滚，用于验证事务内两张表的一致性。"""

    try:
        with database_connection() as connection:
            before_level_id = _read_user_level(connection)
            if before_level_id == TEST_TARGET_LEVEL_ID:
                print(
                    f"测试前提不满足：用户 {TEST_USER_ID} 已是等级 {TEST_TARGET_LEVEL_ID}。",
                    file=sys.stderr,
                )
                return 4

            connection.begin()
            try:
                result = change_membership_level(
                    connection,
                    user_id=TEST_USER_ID,
                    target_level_id=TEST_TARGET_LEVEL_ID,
                    change_reason="Python事务回滚演示",
                )
                changed_level_id = _read_user_level(connection)

                with connection.cursor() as cursor:
                    cursor.execute(
                        """
                        SELECT COUNT(*) AS record_count
                        FROM membership_record
                        WHERE membership_record_id = %s
                          AND user_id = %s
                          AND level_id = %s
                        """,
                        (
                            result["membership_record_id"],
                            TEST_USER_ID,
                            TEST_TARGET_LEVEL_ID,
                        ),
                    )
                    record_count = int(cursor.fetchone()["record_count"])

                print(
                    "事务内验证："
                    f"level_id={changed_level_id}，"
                    f"membership_record={record_count} 条，"
                    f"change_type={result['change_type']}"
                )
            finally:
                connection.rollback()

            after_level_id = _read_user_level(connection)
            with connection.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT COUNT(*) AS record_count
                    FROM membership_record
                    WHERE change_reason = %s
                    """,
                    ("Python事务回滚演示",),
                )
                remaining_records = int(cursor.fetchone()["record_count"])

    except (DatabaseConfigError, MembershipChangeError) as exc:
        print(f"业务错误：{exc}", file=sys.stderr)
        return 2
    except pymysql.MySQLError as exc:
        print(f"数据库错误：{exc}", file=sys.stderr)
        return 3

    rollback_passed = (
        after_level_id == before_level_id and remaining_records == 0
    )
    print(
        "回滚后验证："
        f"level_id={after_level_id}（原值 {before_level_id}），"
        f"演示历史记录={remaining_records} 条，"
        f"结果={'PASS' if rollback_passed else 'FAIL'}"
    )
    return 0 if rollback_passed else 5


if __name__ == "__main__":
    raise SystemExit(main())
