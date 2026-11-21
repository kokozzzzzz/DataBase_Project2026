"""从环境变量读取数据库连接配置。"""

from __future__ import annotations

import os
from dataclasses import dataclass

from dotenv import load_dotenv


class DatabaseConfigError(ValueError):
    """数据库配置缺失或格式错误。"""


@dataclass(frozen=True, slots=True)
class DatabaseConfig:
    """数据库连接参数，不在代码中保存真实密码。"""

    host: str
    port: int
    user: str
    password: str
    database: str
    charset: str = "utf8mb4"
    ssl_ca: str | None = None

    @classmethod
    def from_env(cls, *, load_env_file: bool = True) -> "DatabaseConfig":
        """读取 .env/环境变量，并尽早报告可理解的配置错误。"""

        if load_env_file:
            load_dotenv()

        password = os.getenv("DB_PASSWORD")
        if password is None or password == "" or password == "请填写本机MySQL密码":
            raise DatabaseConfigError(
                "未配置 DB_PASSWORD：请把 .env.example 复制为 .env，并填写本机 MySQL 密码。"
            )

        raw_port = os.getenv("DB_PORT", "3306")
        try:
            port = int(raw_port)
        except ValueError as exc:
            raise DatabaseConfigError("DB_PORT 必须是整数。") from exc

        if not 1 <= port <= 65535:
            raise DatabaseConfigError("DB_PORT 必须在 1 到 65535 之间。")

        database = os.getenv("DB_NAME", "charging_platform")
        if database != "charging_platform":
            raise DatabaseConfigError("本项目统一数据库名称必须是 charging_platform。")

        return cls(
            host=os.getenv("DB_HOST", "127.0.0.1"),
            port=port,
            user=os.getenv("DB_USER", "root"),
            password=password,
            database=database,
            charset=os.getenv("DB_CHARSET", "utf8mb4"),
            ssl_ca=os.getenv("DB_SSL_CA") or None,
        )
