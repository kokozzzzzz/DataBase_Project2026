"""PyMySQL 连接生命周期管理。"""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager

import pymysql
from pymysql.connections import Connection

from .config import DatabaseConfig


SESSION_TIME_ZONE = "+08:00"


@contextmanager
def database_connection(
    config: DatabaseConfig | None = None,
) -> Iterator[Connection]:
    """创建东八区会话连接并可靠关闭；异常时回滚未提交事务。"""

    actual_config = config or DatabaseConfig.from_env()
    connection = pymysql.connect(
        host=actual_config.host,
        port=actual_config.port,
        user=actual_config.user,
        password=actual_config.password,
        database=actual_config.database,
        charset=actual_config.charset,
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=False,
        connect_timeout=5,
        init_command=f"SET SESSION time_zone = '{SESSION_TIME_ZONE}'",
    )

    try:
        yield connection
    except Exception:
        connection.rollback()
        raise
    finally:
        connection.close()


@contextmanager
def transaction(connection: Connection) -> Iterator[Connection]:
    """管理一个事务：成功提交，异常回滚。不要嵌套使用。"""

    connection.begin()
    try:
        yield connection
    except Exception:
        connection.rollback()
        raise
    else:
        connection.commit()
