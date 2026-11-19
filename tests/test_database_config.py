"""数据库配置单元测试，不连接真实 MySQL。"""

import pytest

from app.database.config import DatabaseConfig, DatabaseConfigError


def test_database_config_reads_expected_values(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DB_PASSWORD", "test-password")
    monkeypatch.setenv("DB_PORT", "3307")
    monkeypatch.setenv("DB_NAME", "charging_platform")

    config = DatabaseConfig.from_env(load_env_file=False)

    assert config.host == "127.0.0.1"
    assert config.port == 3307
    assert config.password == "test-password"
    assert config.database == "charging_platform"


def test_database_config_rejects_missing_password(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.delenv("DB_PASSWORD", raising=False)

    with pytest.raises(DatabaseConfigError, match="DB_PASSWORD"):
        DatabaseConfig.from_env(load_env_file=False)


def test_database_config_rejects_other_database(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("DB_PASSWORD", "test-password")
    monkeypatch.setenv("DB_NAME", "wrong_database")

    with pytest.raises(DatabaseConfigError, match="charging_platform"):
        DatabaseConfig.from_env(load_env_file=False)
