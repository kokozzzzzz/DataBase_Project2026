# A 车主服务与信息发布

> **2026-11-21更新**：最新全组进度、规则、升级步骤及分工见[集成修正与交接](../docs/集成修正_2026-11-21/README.md)。下文保留本模块历史记录，以最新交接说明为准。

A同学负责模块：**⑥ 预约、排队与到站管理** + **⑧ 场站服务公告与通知**。

本目录放置 A 的模块说明、业务图、测试证据和可复现工具；SQL 在 `sql/A/`，Python 在 `app/` 与 `tests/`，数据字典在 `docs/a/`。

## 1. 交付物导航

| 类别 | 路径 | 说明 |
| --- | --- | --- |
| 模块总说明 | `docs/a/README.md` | 状态、交付物、验收结果、接口、运行方式、待确认 |
| ⑥ 详细设计 | `docs/a/06_reservation_queue.md` | 需求、E-R、关系模式、3NF、DDL、过程/触发器、视图、查询、测试、优化 |
| ⑧ 详细设计 | `docs/a/08_notice.md` | 公开公告/定向通知、状态机、版本、接收人、通知、测试 |
| 数据字典 | `docs/a/A_06_08_data_dictionary.xlsx` | 10 表 116 字段，含类型、键、外键、NULL、唯一、默认值、CHECK、索引、示例值 |
| 业务图 | `A/业务图/*.png` + `*.dot` | ⑥⑧ 用例图、鲁棒图、局部 E-R 图，可用 Graphviz 重新渲染 |
| 安装检查 | `sql/A/00_preflight.sql` | 只读检查 D/B 依赖、编号类型与 A 当前对象数；定位 `07_verify` 全 0 |
| 补装脚本 | `sql/A/00_install_a.sql` | 已有 D/B、仅缺 A 时安装 01～04；带前置与重复建表守卫 |
| DDL | `sql/A/01_schema.sql` | 10 张表、复合外键、生成列、唯一、CHECK、索引 |
| 触发器 | `sql/A/02_triggers.sql` | 13 个：冲突兜底、状态机、状态历史、核验占位、公告版本、通知状态机 |
| 存储过程 | `sql/A/03_procedures.sql` | 14 个：预约/改约/取消、核验、排队/叫号、资格消费、过期批处理、公告发布/撤回 |
| 视图 | `sql/A/04_views.sql` | 8 个：预约/排队/占用看板、履约统计、公开公告、送达统计、受影响用户、版本历史 |
| 测试数据 | `sql/A/05_seed.sql` | 10 张 A 表每表 ≥20 条；触发器会生成更多历史行 |
| 业务查询 | `sql/A/06_business_queries.sql` | 7 条连接 3+ 关系的查询 |
| 结构验收 | `sql/A/07_verify.sql` | 只读检查：对象、行数、冲突、状态一致性 |
| 约束测试 | `sql/A/08_constraint_tests.sql` | 16 项，结束统一 ROLLBACK |
| 持久层 | `app/database/reservation_repository.py` / `notice_repository.py` | 分页、看板、统计、待发送通知 |
| 服务层 | `app/services/reservation_service.py` / `notice_service.py` | 事务服务，不自动提交 |
| 过程调用 | `app/database/procedure.py` | OUT 参数读取、MySQL 错误中文化 |
| 演示 | `app/run_*_demo.py` | 只读看板、预约工作流、公告工作流、同枪并发 |
| 单元测试 | `tests/test_reservation_*.py` / `test_notice_*.py` / `test_procedure.py` | 61 项，全部通过 |
| 真实验收 | `tests/verify_a_module.py` | 17 项结构/数据/事务/并发检查 |
| 测试证据 | `A/第三天材料/实测/` | 本机 MySQL 8.0.46 输出、JSON、业务查询结果、演示输出 |
| 字典生成器 | `A/工具/generate_data_dictionary.py` | 从 `information_schema` 重新生成 Excel |

## 2. 本机验收结果

环境：MySQL 8.0.46 / InnoDB / `utf8mb4_0900_ai_ci` / Python 3.12 + PyMySQL。

| 检查 | 结果 |
| --- | --- |
| 10 张 A 表 | 创建成功，116 字段 |
| 34 个外键 / 40 个 CHECK | 全部创建成功 |
| 8 视图 / 14 过程 / 13 触发器 | 全部创建成功 |
| 测试数据 | 20/25/20/25/20/20/21/47/20/20 行，均 ≥20 |
| `sql/A/08_constraint_tests.sql` | 16 PASS / 0 FAIL |
| `sql/A/07_verify.sql` | 全部 PASS |
| `sql/A/06_business_queries.sql` | Q01～Q07 执行成功，冲突扫描 0 行 |
| `pytest -q` | 61 passed |
| `tests/verify_a_module.py` | 17 PASS / 0 FAIL |
| 同枪并发 | 一个成功、一个 `RESERVATION_GUN_OVERLAP`，清理后 0 残留 |
| 事务回滚 | 预约→核验→占位、公告→发送→撤回均行数不变 |

## 3. 快速复现

### 3.1 SQL

空库优先使用仓库根目录的一键安装脚本：

```sql
SOURCE sql/00_install_all.sql;   -- D 核心 → B 结构 → D 跨模块 → A 结构 → D 结算表
SOURCE sql/00_seed_all.sql;      -- 可选：D/A 本地种子
SOURCE sql/A/07_verify.sql;
```

已有 D/B、仅缺 A 时（例如 `07_verify.sql` 显示 A 对象全为 0）：

```sql
SOURCE sql/A/00_preflight.sql;   -- 只读检查 D/B 依赖与 A 对象数量
SOURCE sql/A/00_install_a.sql;   -- 仅补装 A 的 01～04，不重复安装 D/B
SOURCE sql/A/07_verify.sql;      -- 结构、对象应 PASS；未装 A 种子时 A07 行数项会 FAIL
```

需要理解依赖顺序时，等价的手工执行顺序如下（在仓库根目录登录 MySQL 后执行）：

```sql
USE charging_platform;
SET SESSION time_zone = '+08:00';

SOURCE sql/D/04_membership_core.sql;      -- D 用户/车辆
SOURCE sql/B/01_schema.sql;               -- B 场站/枪/车位/订单/停运
SOURCE sql/D/04_membership_integration.sql; -- 可选

SOURCE sql/A/01_schema.sql;
SOURCE sql/A/02_triggers.sql;
SOURCE sql/A/03_procedures.sql;
SOURCE sql/A/04_views.sql;

SOURCE sql/D/04_membership_seed_core.sql; -- 末尾检查后 COMMIT
SOURCE sql/A/00_local_shared_fixtures.sql; -- 仅本地联调，正式联调换 B 正式种子
SOURCE sql/A/05_seed.sql;                 -- 末尾检查后 COMMIT

SOURCE sql/A/07_verify.sql;
SOURCE sql/A/08_constraint_tests.sql;
SOURCE sql/A/06_business_queries.sql;
```

> `07_verify.sql` 只读，不会创建任何对象。若 A03～A06 为 0，先执行 `sql/A/00_preflight.sql` 查看是否缺少 D/B 前置表，再执行 `sql/A/00_install_a.sql`。

### 3.2 Python

```powershell
python -m pip install -r requirements.txt
Copy-Item .env.example .env      # 填写本机 MySQL 密码

.\.venv\Scripts\python.exe -m app.run_reservation_demo
.\.venv\Scripts\python.exe -m app.run_notice_demo
.\.venv\Scripts\python.exe -m app.run_reservation_workflow_demo
.\.venv\Scripts\python.exe -m app.run_notice_workflow_demo
.\.venv\Scripts\python.exe -m app.run_reservation_concurrency_demo
.\.venv\Scripts\python.exe -m pytest -q
.\.venv\Scripts\python.exe tests/verify_a_module.py
```

并发演示会短暂提交一条预约以验证行锁，结束后自动清理；如不需要：

```powershell
.\.venv\Scripts\python.exe tests/verify_a_module.py --skip-concurrency
```

### 3.3 重新生成数据字典

```powershell
python -m pip install openpyxl   # 仅生成文档时需要
.\.venv\Scripts\python.exe A/工具/generate_data_dictionary.py
```

### 3.4 重新渲染业务图

安装 Graphviz 后，在 `A/业务图/` 下执行：

```powershell
dot -Tpng -Gdpi=150 "05_⑥预约排队_局部ER图.dot" -o "05_⑥预约排队_局部ER图.png"
```

## 4. 设计亮点

1. **同枪预约并发安全**：锁枪行 + 锁定读（当前读），解决 REPEATABLE READ 下普通一致性读看不到刚提交预约的问题；并发演示已实测一个成功、一个被拒绝。
2. **资格只消费一次**：状态机 + 唯一 `consumed_order_id` + `sp_consume_admission` 行锁；B 开单事务可直接调用。
3. **核验即占位**：到站核验触发器自动写 `parking_occupancy`，避免“核验成功但没占位”。
4. **有效占用唯一**：生成列唯一约束保证同车位/同车辆最多一条未释放占用。
5. **充电结束不释放车位**：正常驶离检查无 `ACTIVE` 订单；视图区分 `CHARGING`、`CHARGING_ENDED_VEHICLE_PRESENT`、`ARRIVED_NOT_CHARGING`。
6. **公告版本留痕**：新建/修改/发布/撤回/过期全部追加 `notice_revision` 快照。
7. **定向通知闭环**：停运计划 → 受影响预约/排队 → 接收人快照 → 待发送通知 → 发送/失败/阅读，撤回时取消未发送通知。
8. **数据字典可再生成**：从 `information_schema` 直接生成，DDL 变更后不会出现文档与数据库不一致。

## 5. 与其他成员的交接

- **B**：A 引用 `station`、`charging_gun`、`parking_space`、`equipment_outage_plan`、`charging_order`；B 开单后用 `sp_consume_admission` 消费资格；A 提供预约/排队/占用视图供 B 核对。
- **C**：停运计划唯一共享表 `equipment_outage_plan`；A 的预约、核验、公告筛选读取同一份记录。
- **D**：A 引用 `user`、`vehicle`，校验用户/车辆有效性与归属；不复制手机号/车牌。
- 详细接口见 `docs/a/README.md` 第 8 节。

## 6. 待确认事项

1. 预约迟到保留时长（默认 15 分钟）。
2. 叫号保留时长（默认 10 分钟）。
3. 现场排队与即将开始预约的优先级（当前 `RESERVATION_LATE=100`、`WALK_IN=0`）。
4. 排队等待过期时长（默认 240 分钟）。
5. 预约提前核验窗口（默认最多提前 30 分钟）。
6. 停运计划唯一登记责任人（A/B/C）。
7. 枪位映射调整时 A 的核验/占位同步方式。
8. 新增⑥⑧业务线的视图/过程数量考核口径。
9. 公开公告是否需要主动推送。
10. 通知渠道优先级与重试策略。

以上事项已在 `docs/a/A_06_08_data_dictionary.xlsx` 的“待确认事项”工作表和 `docs/a/README.md` 中列出，答辩前由组会确认并回填。
