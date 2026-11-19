"""事务上下文单元测试。"""

import pytest

from app.database.connection import transaction


class FakeConnection:
    def __init__(self) -> None:
        self.calls: list[str] = []

    def begin(self) -> None:
        self.calls.append("begin")

    def commit(self) -> None:
        self.calls.append("commit")

    def rollback(self) -> None:
        self.calls.append("rollback")


def test_transaction_commits_on_success() -> None:
    connection = FakeConnection()

    with transaction(connection):  # type: ignore[arg-type]
        connection.calls.append("work")

    assert connection.calls == ["begin", "work", "commit"]


def test_transaction_rolls_back_on_error() -> None:
    connection = FakeConnection()

    with pytest.raises(RuntimeError, match="failure"):
        with transaction(connection):  # type: ignore[arg-type]
            connection.calls.append("work")
            raise RuntimeError("failure")

    assert connection.calls == ["begin", "work", "rollback"]
