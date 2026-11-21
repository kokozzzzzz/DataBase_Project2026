"""兼容C原只读入口。"""
from app.run_c_demo import main

if __name__ == "__main__":
    raise SystemExit(main())
