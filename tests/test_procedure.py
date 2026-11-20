"""存储过程错误翻译与 OUT 参数读取单元测试。"""

from __future__ import annotations

from typing import Any

import pymysql
import pytest

from app.database.procedure import (
    DatabaseProcedureError,
    call_procedure,
    translate_database_error,
)


class FakeCursor:
    def __init__(self, out_row: dict[str, Any] | None = None) -> None:
        self.out_row = out_row or {}
        self.executions: list[str] = []

    def __enter__(self) -> "FakeCursor":
        return self

    def __exit__(self, *args: object) -> None:
        return None

    def execute(self, sql: str, parameters: Any = None) -> None:
        self.executions.append(" ".join(sql.split()))

    def nextset(self) -> None:
        return None

    def fetchone(self) -> dict[str, Any] | None:
        return self.out_row


class FakeConnection:
    def __init__(self, cursor: FakeCursor) -> None:
        self.fake_cursor = cursor

    def cursor(self) -> FakeCursor:
        return self.fake_cursor


def test_translate_procedure_signal() -> None:
    error = pymysql.err.OperationalError(1644, "RESERVATION_GUN_OVERLAP")
    translated = translate_database_error(error)

    assert isinstance(translated, DatabaseProcedureError)
    assert translated.code == 1644
    assert "充电枪" in translated.message


def test_translate_check_constraint() -> None:
    error = pymysql.err.OperationalError(
        3819, "Check constraint 'ck_reservation_cancelled' is violated."
    )
    translated = translate_database_error(error)

    assert translated.code == 3819
    assert "取消" in translated.message


def test_translate_unique_and_foreign_key() -> None:
    unique = translate_database_error(
        pymysql.err.IntegrityError(1062, "Duplicate entry")
    )
    foreign_key = translate_database_error(
        pymysql.err.IntegrityError(1452, "Cannot add or update child row")
    )

    assert unique.code == 1062
    assert "唯一" in unique.message
    assert foreign_key.code == 1452
    assert "外部记录" in foreign_key.message


def test_call_procedure_reads_out_parameters() -> None:
    cursor = FakeCursor({"p_reservation_id": 501})
    connection = FakeConnection(cursor)

    row = call_procedure(  # type: ignore[arg-type]
        connection,
        "CALL sp_test(%s, @p_reservation_id)",
        (10001,),
        ("p_reservation_id",),
    )

    assert row == {"p_reservation_id": 501}
    assert cursor.executions[0].startswith("CALL sp_test")
    assert cursor.executions[1] == "SELECT @p_reservation_id AS p_reservation_id"


def test_call_procedure_requires_out_names() -> None:
    connection = FakeConnection(FakeCursor())
    with pytest.raises(ValueError, match="out_names"):
        call_procedure(connection, "CALL sp_test()", (), ())  # type: ignore[arg-type]
