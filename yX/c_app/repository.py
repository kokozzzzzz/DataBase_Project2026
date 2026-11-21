"""兼容旧导入路径，正式实现统一在 app.database.c_repository。"""
import importlib
import sys
sys.modules[__name__] = importlib.import_module("app.database.c_repository")
