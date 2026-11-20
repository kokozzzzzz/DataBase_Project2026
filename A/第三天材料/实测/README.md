# A 模块本机实测记录

- 时间：2026-11-20
- 环境：MySQL 8.0.46 / InnoDB / `utf8mb4_0900_ai_ci`；Python 3.12 + PyMySQL
- 数据库：`charging_platform`
- 数据来源：D 核心种子（20 用户/20 车辆）+ A 本地共享夹具（4 场站/20 枪/20 车位/20 停运计划）+ A 种子（10 表 ≥20 行）
- 说明：`sql/A/00_local_shared_fixtures.sql` 仅用于本地联调；B 正式场站种子到位后应替换，不影响 A 表结构和业务规则。

## 文件说明

| 文件 | 内容 | 结果 |
| --- | --- | --- |
| `verify_a_module.txt` | `tests/verify_a_module.py` 结构/数据/事务/并发验收 | 17 PASS / 0 FAIL |
| `verify_a_module.json` | 上述验收的机器可读结果、行数、环境 | 17 PASS |
| `schema_verify.txt` | `sql/A/07_verify.sql` 只读结构与数据检查 | 全部 PASS |
| `constraint_tests.txt` | `sql/A/08_constraint_tests.sql` 16 项约束/触发器/过程测试 | 16 PASS / 0 FAIL |
| `business_queries.txt` | `sql/A/06_business_queries.sql` Q01～Q07 输出 | 执行成功；Q07 冲突 0 行 |
| `unit_tests.txt` | `pytest -q` | 61 passed |
| `demo_reservation.txt` | ⑥ 预约/排队/车位只读看板 | 正常输出 |
| `demo_notice.txt` | ⑧ 公开公告/送达统计/受影响用户只读看板 | 正常输出 |
| `demo_reservation_workflow.txt` | 预约→核验→占位事务回滚 | PASS，行数不变 |
| `demo_notice_workflow.txt` | 定向停运公告→发送→撤回事务回滚 | PASS，行数不变 |
| `demo_concurrency.txt` | 两个连接同枪同时段预约 | A 成功、B `RESERVATION_GUN_OVERLAP`、清理 0 残留 |

## 关键数字

| 项目 | 数量 |
| --- | --- |
| A 表 | 10 |
| 字段 | 116 |
| 外键 | 34 |
| CHECK | 40 |
| 视图 | 8 |
| 存储过程 | 14 |
| 触发器 | 13 |
| 业务查询 | 7 |
| 约束测试 | 16 |
| Python 单元测试 | 61 |
| 真实数据库验收 | 17 |

## 复现

```powershell
Copy-Item .env.example .env   # 填写本机 MySQL 密码
.\.venv\Scripts\python.exe tests/verify_a_module.py --output A/第三天材料/实测
.\.venv\Scripts\python.exe -m pytest -q
```

SQL 脚本在仓库根目录按 `docs/a/README.md` 第 9 节顺序执行。并发演示会短暂提交一条预约用于验证行锁，脚本结束自动清理。
