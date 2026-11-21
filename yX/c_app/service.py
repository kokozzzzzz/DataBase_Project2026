"""兼容旧导入路径，正式实现统一在 app.services.c_service。"""
import importlib
import sys
sys.modules[__name__] = importlib.import_module("app.services.c_service")
