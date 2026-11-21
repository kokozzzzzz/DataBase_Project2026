"""从仓库根目录运行SQL；展开SOURCE后交给MySQL批处理，首错停止。"""
from __future__ import annotations
import argparse
from getpass import getpass
import os
from pathlib import Path
import re
import subprocess
from app.database.config import DatabaseConfig

ROOT = Path(__file__).resolve().parents[1]

def expand_sources(path: Path, stack: tuple[Path, ...] = ()) -> str:
    path = path.resolve()
    if not path.is_relative_to(ROOT) or path in stack:
        raise ValueError('SQL路径越界或SOURCE循环引用')
    source = path.read_text(encoding='utf-8-sig')
    return re.sub(r'^\s*SOURCE\s+([^;\r\n]+);[ \t]*$',
        lambda m: expand_sources(ROOT / m.group(1).strip(), (*stack, path)),
        source, flags=re.M | re.I)

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--file', required=True, type=Path)
    parser.add_argument('--mysql', default='mysql', help='mysql.exe完整路径，或PATH中的mysql')
    parser.add_argument('--admin', action='store_true', help='使用root，交互输入密码')
    parser.add_argument('--commit', action='store_true', help='在脚本成功后提交其尚未提交的数据事务')
    args = parser.parse_args()
    config = DatabaseConfig.from_env()
    sql = expand_sources(ROOT / args.file)
    if args.commit:
        sql += '\nCOMMIT;\n'
    env = dict(os.environ)
    env['MYSQL_PWD'] = getpass('本机root密码：') if args.admin else config.password
    command = [args.mysql, '--no-defaults', '--protocol=TCP', '-h'+config.host,
        '-P'+str(config.port), '-u'+('root' if args.admin else config.user),
        '--default-character-set=utf8mb4']
    if config.ssl_ca:
        command += ['--ssl-mode=VERIFY_CA', '--ssl-ca='+config.ssl_ca]
    result = subprocess.run(command, input=sql, encoding='utf-8', env=env, cwd=ROOT)
    if result.returncode:
        print('执行失败，后续语句已停止。DDL不会自动回滚；按错误位置核对已建对象。')
    return result.returncode

if __name__ == '__main__':
    raise SystemExit(main())
