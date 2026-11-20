# A同学负责模块：预约排队与公告通知

## 1. 负责人

A同学

## 2. 负责业务线

- ⑥ 预约、排队与到站管理
- ⑧ 场站服务公告与通知

## 3. 当前状态

| 业务线 | 状态 | 说明 |
| --- | --- | --- |
| ⑥ 预约、排队与到站管理 | 已实现并实测 | 6 张表、4 个视图、9 个存储过程、7 个触发器；预约冲突、到站占位、排队叫号、资格消费、并发开单接口均已验证 |
| ⑧ 场站服务公告与通知 | 已实现并实测 | 4 张表、4 个视图、5 个存储过程、6 个触发器；公开公告、定向停运通知、版本留痕、发送状态机均已验证 |

运行环境：MySQL 8.0.46 / InnoDB / `utf8mb4_0900_ai_ci`，开发语言 Python（PyMySQL + python-dotenv）。

## 4. 交付物位置

| 路径 | 内容 |
| --- | --- |
| `docs/a/A_06_08_data_dictionary.xlsx` | ⑥⑧ 字段字典、实体清单、外键/唯一/CHECK 约束、业务规则、待确认事项、测试数据统计 |
| `docs/a/06_reservation_queue.md` | ⑥ 业务需求、概念/逻辑/物理结构、SQL、视图、测试与优化说明 |
| `docs/a/08_notice.md` | ⑧ 业务需求、概念/逻辑/物理结构、SQL、视图、测试与优化说明 |
| `A/业务图/01_⑥预约排队_用例图.png` | ⑥ 用例图（含 `.dot` 源文件） |
| `A/业务图/02_⑧公告通知_用例图.png` | ⑧ 用例图（含 `.dot` 源文件） |
| `A/业务图/03_⑥预约到站_鲁棒图.png` | ⑥ 预约到站鲁棒图（含 `.dot` 源文件） |
| `A/业务图/04_⑧公告通知_鲁棒图.png` | ⑧ 公告通知鲁棒图（含 `.dot` 源文件） |
| `A/业务图/05_⑥预约排队_局部ER图.png` | ⑥ 局部 E-R 图（含 `.dot` 源文件） |
| `A/业务图/06_⑧公告通知_局部ER图.png` | ⑧ 局部 E-R 图（含 `.dot` 源文件） |
| `sql/A/00_local_shared_fixtures.sql` | 本地联调夹具（仅测试用，B 正式种子到位后可替换） |
| `sql/A/01_schema.sql` | 10 张 A 表 DDL，含主键、复合外键、唯一、CHECK、生成列和索引 |
| `sql/A/02_triggers.sql` | 13 个触发器：区间冲突兜底、状态机、状态历史、核验占位、公告版本、通知状态机 |
| `sql/A/03_procedures.sql` | 14 个存储过程：预约/改约/取消、到站核验、排队叫号、资格消费、过期批处理、公告发布/撤回 |
| `sql/A/04_views.sql` | 8 个业务视图 |
| `sql/A/05_seed.sql` | 每张 A 表至少 20 条测试数据（触发器会生成更多历史行） |
| `sql/A/06_business_queries.sql` | 7 条连接 3 个及以上关系的业务查询 |
| `sql/A/07_verify.sql` | 只读结构与数据验收脚本 |
| `sql/A/08_constraint_tests.sql` | 16 项约束/触发器/过程测试，结束统一 ROLLBACK |
| `app/database/reservation_repository.py` | ⑥ 只读持久层（分页、看板、履约统计、状态历史） |
| `app/database/notice_repository.py` | ⑧ 只读持久层（公开公告、送达统计、受影响用户、待发送通知） |
| `app/database/procedure.py` | 存储过程 OUT 参数调用与 MySQL 错误中文化 |
| `app/services/reservation_service.py` | ⑥ 事务服务（创建/取消/改约/核验/排队/叫号/释放/消费资格） |
| `app/services/notice_service.py` | ⑧ 事务服务（创建/发布/撤回公告、通知状态、公告过期） |
| `app/run_reservation_demo.py` | ⑥ 只读看板演示 |
| `app/run_notice_demo.py` | ⑧ 只读看板演示 |
| `app/run_reservation_workflow_demo.py` | ⑥ 预约→核验→占位事务回滚演示 |
| `app/run_notice_workflow_demo.py` | ⑧ 定向公告→发送→撤回事务回滚演示 |
| `app/run_reservation_concurrency_demo.py` | 同枪并发预约演示（一个成功、一个被拒绝、自动清理） |
| `tests/test_reservation_repository.py` | ⑥ 持久层单元测试 |
| `tests/test_notice_repository.py` | ⑧ 持久层单元测试 |
| `tests/test_reservation_service.py` | ⑥ 服务层单元测试 |
| `tests/test_notice_service.py` | ⑧ 服务层单元测试 |
| `tests/test_procedure.py` | 存储过程调用与错误翻译单元测试 |
| `tests/verify_a_module.py` | 真实 MySQL 结构/数据/事务/并发验收，17 项 |
| `A/第三天材料/实测/verify_a_module.json` | 本机 MySQL 8.0.46 验收输出 |
| `A/工具/generate_data_dictionary.py` | 从 `information_schema` 生成数据字典 Excel |

## 5. 已完成验收

本机在 **MySQL 8.0.46 / charging_platform / utf8mb4_0900_ai_ci** 上完成以下实测：

| 检查项 | 结果 |
| --- | --- |
| A 表 | 10 张，InnoDB / `utf8mb4_0900_ai_ci`，116 个字段 |
| 外键 / CHECK | 34 个外键、40 个 CHECK 约束，全部创建成功 |
| 视图 / 过程 / 触发器 | 8 个视图、14 个存储过程、13 个触发器 |
| 测试数据 | 10 张表分别为 20/25/20/25/20/20/21/47/20/20 条，均 ≥20 |
| 约束测试 | T01～T16 全部 PASS（同枪/同用户冲突、重复排队、重复核验、重复消费、公告/通知状态机、CHECK 等） |
| 业务查询 | Q01～Q07 执行成功，Q07 冲突扫描 0 行 |
| Python 单元测试 | 61 passed |
| 真实数据库验收 | 17 PASS / 0 FAIL（结构、数据、预约核验、公告撤回、并发同枪预约） |
| 并发测试 | 两个连接同时预约同一枪同一时段，仅一个成功，另一个返回 `RESERVATION_GUN_OVERLAP`；清理后 0 残留 |
| 事务回滚演示 | 预约→核验→占位、公告→发送→撤回均在事务内完成并回滚，行数不变 |
| 数据字典 | 116 个字段逐字段生成，含类型、键、外键、NULL、唯一、默认值、CHECK、索引、示例值 |

复现命令见第 9 节。

## 6. 数据库实体

### ⑥ 预约、排队与到站管理（6 张表）

- `charging_reservation`：预约主表；同一枪有效预约区间不重叠，资格只能消费一次
- `reservation_status_log`：预约状态历史
- `queue_record`：现场排队；当日场站排队号唯一，一个用户最多一条有效排队
- `queue_status_log`：排队状态历史
- `arrival_checkin`：到站核验；预约/排队资格二选一，核验成功自动生成车位占用
- `parking_occupancy`：车位实际占用与释放；充电结束但车辆未驶离时保持占用

### ⑧ 场站服务公告与通知（4 张表）

- `station_notice`：公开公告与停运定向通知主表
- `notice_revision`：公告版本快照（CREATE/UPDATE/PUBLISH/WITHDRAW/EXPIRE）
- `notice_recipient`：定向公告接收对象快照（关联用户、车辆、预约/排队）
- `notification_record`：按接收对象与渠道记录通知发送、失败、阅读状态

## 7. 已确定的设计方案

1. **同枪预约冲突**：`sp_create_reservation` 先锁定 `charging_gun` 行，再用 `SELECT ... FOR UPDATE` 做当前读冲突检查；触发器作为直接 SQL 顺序写入兜底。MySQL 不允许触发器对同一张表做锁定读，因此并发创建必须走存储过程。
2. **同用户重复预约**：预约过程同时检查该用户在同一时段是否已有 `BOOKED/CHECKED_IN` 预约。
3. **资格只能消费一次**：预约/排队状态从 `CHECKED_IN` 转 `CONSUMED`，并写入唯一 `consumed_order_id`；`sp_consume_admission` 校验订单的 `channel + admission_id` 与资格归属一致。
4. **核验即占位**：`arrival_checkin` 的 AFTER INSERT 触发器自动写入 `parking_occupancy`，保证核验成功与入位在同一事务内。
5. **有效占用唯一**：`parking_occupancy` 使用生成列 `active_space_id`、`active_vehicle_id` 加唯一约束，同一车位/同一车辆最多一条未释放占用。
6. **充电结束不释放车位**：`sp_release_parking_space` 在正常驶离时检查该枪没有 `ACTIVE` 订单；充电结束但车辆未驶离时由视图标记为 `CHARGING_ENDED_VEHICLE_PRESENT`。
7. **排队唯一性**：`queue_record` 使用生成列 `active_user_id` 唯一约束 + `(station_id, queue_date, ticket_no)` 唯一约束；`sp_join_queue` 锁场站行分配当日排队号。
8. **排队优先级**：当前 `RESERVATION_LATE=100`、`WALK_IN=0`，按 `priority_score DESC, joined_at ASC, queue_id ASC` 叫号；具体口径待组会确认。
9. **超时处理**：`sp_expire_overdue_admissions` 批量处理预约迟到超保留期、叫号超时、排队等待超过 240 分钟；状态触发器保留历史。
10. **公告状态机**：`DRAFT → PUBLISHED → WITHDRAWN / EXPIRED`，由 `a_notice_transition_bu` 校验；发布后场站、类型、关联停运计划、生效开始时间不可修改。
11. **公告版本留痕**：新建、正文修改、发布、撤回、过期都由触发器追加 `notice_revision` 快照。
12. **定向通知**：`OUTAGE_TARGETED` 公告必须关联 `equipment_outage_plan`；发布时按停运范围筛选 `BOOKED/CHECKED_IN` 预约和当前有效排队，生成 `notice_recipient` 与 `IN_APP` 待发送通知。
13. **通知状态机**：`PENDING → SENT/FAILED`、`FAILED → PENDING/SENT`、`SENT → READ`；时间、失败原因与状态由 CHECK 和触发器共同约束。
14. **时间口径**：统一 `SET SESSION time_zone='+08:00'`，DATETIME 表示北京时间，预约/停运/有效期采用左闭右开 `[start, end)`。
15. **敏感字段**：A 模块不保存手机号、车牌、身份证等敏感信息，只引用 D 的用户/车辆伪匿名编号；视图不暴露敏感字段。
16. **Python 持久层**：使用 PyMySQL 参数化查询；服务层不自动提交，调用方用 `transaction()` 统一控制边界；存储过程错误码 1644/3819/1062/1452 统一翻译为中文业务错误。

## 8. 与其他模块的接口

### B：设施与订单

- A 引用 `station`、`charging_gun`、`parking_space`、`equipment_outage_plan`、`charging_order` 的正式主键，类型均为 `BIGINT UNSIGNED`。
- 枪位基数沿用 B 当前设计：每枪必绑同站一车位、每位至多一枪。实际入位/驶离由 A 维护。
- 订单 `channel=RESERVATION/QUEUE` 时，`admission_id` 分别映射 `reservation_id/queue_id`。
- B 开单事务中先创建订单，再调用 `sp_consume_admission(channel, admission_id, order_id)` 原子消费资格；失败时整体回滚。
- A 提供 `v_a_reservation_board`、`v_a_queue_board`、`v_a_parking_occupancy_live` 供 B 做开单前状态核对。

### C：设备状态与停运

- 停运计划只维护一份 `equipment_outage_plan`；A 的预约创建、到站核验和公告筛选读取同一份记录。
- 设备故障/离线/维修恢复由 C 写入；A 在预约和核验时校验 `charging_gun.status='READY'`、停运区间和无进行中订单。
- 停运计划登记方仍待 A/B/C 组会确认。

### D：用户与车辆

- A 引用 `user`、`vehicle` 主键；创建预约、排队、核验时校验用户 `ACTIVE`、车辆归属与 `vehicle_status='ACTIVE'`。
- A 不复制用户手机号/车牌，避免敏感信息扩散。

## 9. 执行与运行方式

### 9.1 SQL 执行顺序

在 MySQL 客户端中，按依赖顺序执行（`SOURCE` 路径相对仓库根目录）：

```sql
CREATE DATABASE charging_platform
  DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE charging_platform;
SET SESSION time_zone = '+08:00';

-- 1) D 核心表 + B 结构表
SOURCE sql/D/04_membership_core.sql;
SOURCE sql/B/01_schema.sql;
SOURCE sql/D/04_membership_integration.sql;   -- 可选，D 的跨模块表

-- 2) A 结构、触发器、过程、视图
SOURCE sql/A/01_schema.sql;
SOURCE sql/A/02_triggers.sql;
SOURCE sql/A/03_procedures.sql;
SOURCE sql/A/04_views.sql;

-- 3) 测试数据
SOURCE sql/D/04_membership_seed_core.sql;      -- 末尾检查后 COMMIT
SOURCE sql/A/00_local_shared_fixtures.sql;     -- 仅本地联调；B 正式种子到位后替换
SOURCE sql/A/05_seed.sql;                      -- 末尾检查后 COMMIT

-- 4) 验收
SOURCE sql/A/07_verify.sql;
SOURCE sql/A/08_constraint_tests.sql;          -- T01～T16
SOURCE sql/A/06_business_queries.sql;
```

> `sql/A/00_local_shared_fixtures.sql` 是 A 的本地联调夹具，不是正式业务数据。正式联调应使用 B 的正式场站/枪/车位种子，或由 B 提供已初始化的公共库。

### 9.2 Python 持久层

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

并发演示会短暂提交一条预约用于验证行锁，结束后自动删除该预约和状态日志；如不希望执行，可使用：

```powershell
.\.venv\Scripts\python.exe tests/verify_a_module.py --skip-concurrency
```

### 9.3 数据字典重新生成

```powershell
.\.venv\Scripts\python.exe A/工具/generate_data_dictionary.py
```

脚本读取 `information_schema` 和 A 表实际行数，输出 `docs/a/A_06_08_data_dictionary.xlsx`。修改 DDL 后应重新生成，保持字典与数据库一致。该工具需要 `openpyxl`（仅生成文档时使用，不进入运行时持久层）：

```powershell
python -m pip install openpyxl
```

## 10. 索引与查询优化

| 索引 | 用途 |
| --- | --- |
| `ix_reservation_gun_status_time (gun_id, status, starts_at, ends_at)` | 同枪冲突检查、预约看板 |
| `ix_reservation_station_time (station_id, starts_at)` | 场站预约压力统计 |
| `ix_reservation_user_time (user_id, starts_at)` | 用户重复预约检查 |
| `ix_queue_station_status_priority (station_id, status, priority_score, joined_at)` | 叫号按优先级取下一号 |
| `ix_queue_gun_status (gun_id, status, joined_at)` | 按枪查看排队 |
| `uk_queue_station_date_ticket (station_id, queue_date, ticket_no)` | 当日排队号唯一 |
| `uk_occupancy_active_space (active_space_id)` | 同一车位最多一条未释放占用 |
| `uk_occupancy_active_vehicle (active_vehicle_id)` | 同一车辆最多一条未释放占用 |
| `ix_notice_station_status_effective (station_id, status, effective_from, effective_to)` | 公开公告有效期筛选 |
| `ix_notification_status_created (status, created_at)` | 待发送通知轮询 |
| `uk_notice_recipient_user (notice_id, user_id)` | 同一公告同一用户只接收一次 |

`sql/A/06_business_queries.sql` 中的 Q01～Q07 覆盖预约压力、转化漏斗、排队等待、车位占用、停运公告触达和同枪冲突扫描。复杂查询的过滤列与上述索引前缀一致；在测试数据量下均走索引或小表扫描。正式数据量增大后建议用 `EXPLAIN ANALYZE` 复核 Q04 的相关子查询和 Q05 的多表聚合。

## 11. 安全与完整性

- **SQL 注入**：Python 全部使用 PyMySQL 参数化查询；存储过程参数使用 `%s` 占位，不拼接用户输入。
- **权限**：视图和过程均使用 `SQL SECURITY INVOKER`，不提升调用者权限；生产环境按 RBAC 只授予业务账号必要的 `SELECT/INSERT/UPDATE/EXECUTE`。
- **敏感数据**：A 不存储手机号、车牌等敏感字段；只引用 D 的伪匿名编号，视图不返回敏感列。
- **完整性**：主键、复合外键、唯一约束、CHECK、生成列唯一、触发器状态机、存储过程行锁共同保证；所有业务错误通过 `SIGNAL SQLSTATE '45000'` 返回可识别错误码。
- **事务**：服务层不自动提交；预约创建/核验/占位、公告发布/接收人/通知在同一事务中完成，异常由调用方回滚。
- **审计**：预约/排队状态历史、公告版本、通知发送记录均保留，不物理删除。

## 12. 待确认事项

1. 预约迟到保留时长（当前默认 15 分钟，字段可快照）。
2. 叫号保留时长（当前默认 10 分钟，字段可快照）。
3. 现场排队与即将开始预约的优先级（当前 `RESERVATION_LATE=100`、`WALK_IN=0`）。
4. 排队等待过期时长（当前 240 分钟）。
5. 预约提前核验窗口（当前最多提前 30 分钟）。
6. 车位与充电枪映射基数（沿用 B 当前一枪一位；若调整需同步 A 的核验/占位逻辑）。
7. 停运计划唯一登记责任人（A/B/C 组会确认）。
8. 新增⑥⑧业务线的视图/存储过程数量考核口径（当前交付 8 视图、14 过程，已超过任务书原有 5 条线的最低要求）。
9. 公开公告是否需要主动推送（当前 PUBLIC 只进入公开视图，定向公告生成 IN_APP 通知）。
10. 通知渠道优先级与重试策略（当前 `notification_record` 支持 IN_APP/SMS/PUSH/WECHAT/EMAIL 和最多 10 次重试，具体渠道由运营配置）。
