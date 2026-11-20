"""数据库连接工厂单元测试，不连接真实 MySQL。"""

from unittest.mock import Mock

import pytest

from app.database.config import DatabaseConfig
from app.database.connection import SESSION_TIME_ZONE, database_connection


def _test_config() -> DatabaseConfig:
    """构造不包含真实密码的测试配置。"""

    return DatabaseConfig(
        host="127.0.0.1",
        port=3306,
        user="test_user",
        password="test_password",
        database="charging_platform",
    )


def test_database_connection_sets_session_time_zone(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """连接建立后，任何业务 SQL 执行前都应使用东八区会话时区。"""

    fake_connection = Mock()
    connect_mock = Mock(return_value=fake_connection)
    monkeypatch.setattr("app.database.connection.pymysql.connect", connect_mock)

    with database_connection(_test_config()) as connection:
        assert connection is fake_connection

    assert connect_mock.call_args.kwargs["init_command"] == (
        f"SET SESSION time_zone = '{SESSION_TIME_ZONE}'"
    )
    assert connect_mock.call_args.kwargs["autocommit"] is False
    fake_connection.close.assert_called_once_with()


def test_database_connection_rolls_back_and_closes_on_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """业务代码异常时必须回滚未提交事务并关闭连接。"""

    fake_connection = Mock()
    monkeypatch.setattr(
        "app.database.connection.pymysql.connect",
        Mock(return_value=fake_connection),
    )

    with pytest.raises(RuntimeError, match="test failure"):
        with database_connection(_test_config()):
            raise RuntimeError("test failure")

    fake_connection.rollback.assert_called_once_with()
    fake_connection.close.assert_called_once_with()
