"""兼容旧验收入口，执行公共tests中的正式脚本。"""
from pathlib import Path
import runpy
if __name__ == '__main__':
    runpy.run_path(str(Path(__file__).resolve().parents[2]/'tests/verify_c_module.py'),run_name='__main__')
