# ⑥ 预约、排队与到站管理设计说明

## 1. 业务需求分析

### 1.1 业务目标

围绕“预约—到站—排队—占位—开单”的车主服务闭环，把车位、充电枪和用户资格在时间维度上管理起来：

- 车主可以按枪、按时间段预约，支持取消和改约；
- 未预约车主可以现场排队，系统按优先级叫号；
- 到站后核验预约/排队资格，核验成功即占用车位；
- 充电结束后车辆未驶离时，车位继续占用，不提前释放或叫下一位；
- 向 B 的充电订单模块提供“资格消费”原子入口，保证同一资格只能开一单。

### 1.2 角色与用例

| 角色 | 主要用例 |
| --- | --- |
| 车主用户 | 创建预约、取消预约、改约、现场排队、到站核验、查询预约/排队/占用 |
| 场站运维人员 | 叫下一号、协助到站核验、确认车辆驶离/释放车位、查询现场看板 |
| 平台运营管理员 | 查询预约压力、履约率、排队时长和车位占用 |
| B 充电订单模块 | 开单后消费预约/排队资格 |

用例图与鲁棒图见：

- `A/业务图/01_⑥预约排队_用例图.png`
- `A/业务图/03_⑥预约到站_鲁棒图.png`
- `A/业务图/05_⑥预约排队_局部ER图.png`

### 1.3 核心业务规则

| 编号 | 规则 | 数据库落实 |
| --- | --- | --- |
| R1 | 同一把枪的有效预约时段不能重叠 | `sp_create_reservation` 锁枪行 + 锁定读；`a_reservation_overlap_bi` 顺序写入兜底 |
| R2 | 同一用户在同一时段不能重复预约 | 预约过程锁定读检查；触发器兜底 |
| R3 | 预约/排队资格只能消费一次 | 状态机 `CHECKED_IN→CONSUMED` + 唯一 `consumed_order_id` + `sp_consume_admission` 行锁 |
| R4 | 到站核验必须且只能来自预约或排队之一 | `ck_checkin_one_qualification` + `a_checkin_qualification_bi` |
| R5 | 核验成功即生成车位占用 | `a_checkin_occupancy_ai` AFTER INSERT 自动插入 |
| R6 | 同一车位、同一车辆最多一条未释放占用 | 生成列 `active_space_id`/`active_vehicle_id` + 唯一约束 |
| R7 | 充电结束但车辆未驶离时车位仍占用 | 释放过程检查无 `ACTIVE` 订单；视图标记 `CHARGING_ENDED_VEHICLE_PRESENT` |
| R8 | 一个用户最多一条有效排队 | 生成列 `active_user_id` + 唯一约束；入队预检查 |
| R9 | 场站当日排队号唯一 | 生成列 `queue_date` + `(station_id, queue_date, ticket_no)` 唯一 |
| R10 | 叫号/等待超时自动过期 | `sp_expire_overdue_admissions` 批量置 `EXPIRED`，状态触发器留痕 |

### 1.4 状态机

**预约 `charging_reservation.status`**

```text
BOOKED ──到站核验──> CHECKED_IN ──开单消费──> CONSUMED
  │                      │
  ├──取消──> CANCELLED   ├──取消──> CANCELLED
  ├──迟到超保留期──> EXPIRED
  └──未到站──> NO_SHOW
```

**排队 `queue_record.status`**

```text
WAITING ──叫号──> CALLED ──到站核验──> CHECKED_IN ──开单消费──> CONSUMED
   │                 │                    │
   ├──取消──> CANCELLED                    ├──取消/超时──> CANCELLED/EXPIRED/NO_SHOW
   ├──等待超时──> EXPIRED
   └──未到站──> NO_SHOW
```

允许的状态迁移由 `a_reservation_status_bu`、`a_queue_status_bu` 校验；每次变化写入 `reservation_status_log`/`queue_status_log`，并记录 `@a_change_reason`。

### 1.5 非功能需求

- **并发**：同一枪的预约创建必须串行化；同一资格的开单消费必须只成功一次。
- **实时性**：车位看板和排队看板读取当前未释放占用/有效排队；充电结束但未驶离的状态必须可见。
- **完整性**：预约、到站、占用、订单之间不能出现“有核验无占位”“一车位两车”“一资格两单”。
- **可追溯**：预约/排队状态变化、车位释放、资格消费都保留历史或时间戳。
- **安全**：A 模块不保存手机号、车牌等敏感信息，只引用 D 的伪匿名编号；Python 全部参数化查询。
- **时间口径**：统一北京时间 `+08:00`，区间左闭右开 `[start, end)`。

## 2. 概念结构设计

### 2.1 实体与联系

| 实体 | 说明 | 主要联系 |
| --- | --- | --- |
| `charging_reservation` 预约 | 用户/车辆对某枪某时段的资格 | 用户 1:N、车辆 1:N、枪 1:N；到站 0..1:1；状态 1:N；订单 0..1:1 |
| `queue_record` 排队 | 现场排队与叫号资格 | 场站/用户/车辆/枪 1:N；到站 0..1:1；状态 1:N；订单 0..1:1 |
| `arrival_checkin` 到站核验 | 实际到站事实 | 预约/排队二选一；核验 1:1 占用 |
| `parking_occupancy` 车位占用 | 车辆实际入位与释放 | 核验 1:1；车位 1:N；枪 1:N |
| `reservation_status_log`/`queue_status_log` | 状态审计 | 预约/排队 1:N |
| `charging_gun`/`parking_space`/`station` | B 设施主数据 | 枪 N:1 车位；站 1:N 枪/车位 |
| `charging_order` | B 订单，消费资格 | 预约/排队 0..1:1 |
| `equipment_outage_plan` | B/C 共享停运计划 | 与预约时段做冲突校验 |

局部 E-R 图见 `A/业务图/05_⑥预约排队_局部ER图.png`（`.dot` 源文件可编辑）。

### 2.2 关键基数

- 用户 `1:N` 预约；车辆 `1:N` 预约；充电枪 `1:N` 预约。
- 用户/车辆/充电枪 `1:N` 排队；场站 `1:N` 排队。
- 预约 `0..1:1` 到站核验；排队 `0..1:1` 到站核验；到站核验 `1:1` 车位占用。
- 车位 `1:N` 占用（历史）；同一车位同时最多一条未释放占用。
- 预约/排队 `0..1:1` 充电订单（通过唯一 `consumed_order_id`）。
- 充电枪 `N:1` 车位（B 当前每枪必绑同站一车位、每位至多一枪）；实际占位由 A 维护。

## 3. 逻辑结构设计

### 3.1 关系模式

```text
charging_reservation(
  reservation_id PK, user_id FK, vehicle_id FK, gun_id FK, station_id FK,
  starts_at, ends_at, late_grace_minutes, status, source,
  rescheduled_from_id FK, created_at, updated_at,
  cancelled_at, cancel_reason, consumed_at, consumed_order_id FK UNIQUE
)

reservation_status_log(
  log_id PK, reservation_id FK, old_status, new_status, changed_at, change_reason
)

queue_record(
  queue_id PK, station_id FK, user_id FK, vehicle_id FK, gun_id FK,
  ticket_no, queue_date 生成列, priority_class, priority_score, status,
  joined_at, called_at, call_expires_at, hold_minutes,
  consumed_at, consumed_order_id FK UNIQUE,
  cancelled_at, cancel_reason, active_user_id 生成列 UNIQUE
)

queue_status_log(
  log_id PK, queue_id FK, old_status, new_status, changed_at, change_reason
)

arrival_checkin(
  checkin_id PK, reservation_id FK UNIQUE, queue_id FK UNIQUE,
  user_id FK, vehicle_id FK, station_id FK, gun_id FK,
  parking_space_id FK, checked_in_at, checkin_method, plate_verified
)

parking_occupancy(
  occupancy_id PK, checkin_id FK UNIQUE, parking_space_id FK, station_id FK,
  gun_id FK, user_id FK, vehicle_id FK, occupied_at, released_at,
  release_reason, active_space_id 生成列 UNIQUE, active_vehicle_id 生成列 UNIQUE
)
```

### 3.2 函数依赖与第三范式

- 每张表的单列主键决定全部非主属性；`queue_record` 的候选键 `(station_id, queue_date, ticket_no)` 决定 `queue_id`。
- 所有表均满足 1NF（字段原子）和 2NF（无复合主键部分依赖）；非主属性之间不存在传递依赖。
- 有意保留的冗余及理由：
  1. `charging_reservation.station_id`、`queue_record.station_id` 可由 `gun_id` 推导，但保留用于复合外键 `(gun_id, station_id) → charging_gun(gun_id, station_id)`，在数据库层强制“枪与场站一致”，并减少联表。
  2. `arrival_checkin.user_id/vehicle_id`、`parking_occupancy.user_id/vehicle_id` 是**实际到站事实快照**：实际到站车辆可能与预约车辆不同（人工核验/换车），且需要历史留痕，因此不作为纯派生字段。
  3. 状态历史、公告版本、通知记录是审计表，保存业务事实快照，不参与主表函数依赖。
- 结论：核心表满足 3NF；上述冗余属于为完整性或历史追溯有意保留的物理设计例外，已在数据字典备注中标注。

## 4. 物理结构设计

### 4.1 表与对象

| 对象 | 数量 | 说明 |
| --- | --- | --- |
| A 表 | 10 | ⑥ 6 张 + ⑧ 4 张，均 InnoDB / `utf8mb4_0900_ai_ci` |
| 外键 | 34 | 含 `(gun_id, station_id)`、`(parking_space_id, station_id)` 复合外键 |
| CHECK | 40 | 时间区间、状态-时间一致性、取消/消费字段配对、通知状态-时间一致性 |
| 视图 | 8 | ⑥ 4 个 + ⑧ 4 个 |
| 存储过程 | 14 | ⑥ 9 个 + ⑧ 5 个 |
| 触发器 | 13 | 冲突兜底、状态机、状态历史、核验占位、公告版本、通知状态机 |

完整字段定义见 `docs/a/A_06_08_data_dictionary.xlsx` 的“⑥⑧字段字典”工作表。

### 4.2 关键约束与生成列

- `ck_reservation_time`：`starts_at < ends_at` 且时长 5 分钟～24 小时。
- `ck_reservation_cancelled`/`ck_reservation_consumed`：取消必须同时有 `cancelled_at` 和 `cancel_reason`；消费必须同时有 `consumed_at` 和 `consumed_order_id`。
- `ck_queue_called_time`：`CALLED/CHECKED_IN/CONSUMED` 必须有 `called_at` 和 `call_expires_at`。
- `ck_queue_call_pair`：叫号时间与截止时间同时存在；截止时间晚于叫号时间。
- `ck_checkin_one_qualification`：`(reservation_id IS NULL) <> (queue_id IS NULL)`。
- `ck_occupancy_release_pair`：`released_at` 与 `release_reason` 同时存在或同时为空。
- `queue_record.queue_date`：`DATE(joined_at)` 生成列，参与 `(station_id, queue_date, ticket_no)` 唯一。
- `queue_record.active_user_id`：有效状态时等于 `user_id`，否则 `NULL`，唯一约束保证一个用户最多一条有效排队。
- `parking_occupancy.active_space_id`/`active_vehicle_id`：未释放时等于车位/车辆，否则 `NULL`，唯一约束保证同车位/同车辆最多一条有效占用。

### 4.3 索引

| 索引 | 用途 |
| --- | --- |
| `ix_reservation_gun_status_time` | 同枪冲突检查、预约看板 |
| `ix_reservation_station_time` | 场站预约压力 |
| `ix_reservation_user_time` | 用户重复预约检查 |
| `ix_queue_station_status_priority` | 叫号按优先级取下一号 |
| `ix_queue_gun_status` | 按枪查看排队 |
| `uk_queue_station_date_ticket` | 当日排队号唯一 |
| `uk_occupancy_active_space` | 同车位有效占用唯一 |
| `uk_occupancy_active_vehicle` | 同车辆有效占用唯一 |
| `ix_checkin_station_time`/`ix_checkin_gun_time` | 到站核验查询 |

## 5. SQL 实现说明

### 5.1 执行顺序

```sql
SOURCE sql/A/01_schema.sql;
SOURCE sql/A/02_triggers.sql;
SOURCE sql/A/03_procedures.sql;
SOURCE sql/A/04_views.sql;
```

前置依赖：D 的 `user`、`vehicle`，B 的 `station`、`charging_gun`、`parking_space`、`equipment_outage_plan`、`charging_order`。

### 5.2 存储过程

| 过程 | 作用 |
| --- | --- |
| `sp_create_reservation` | 校验用户/车辆/枪/营业时间/停运/冲突，锁枪后创建 |
| `sp_cancel_reservation` | 取消预约；`CHECKED_IN` 时释放对应未驶离占用 |
| `sp_reschedule_reservation` | 取消旧预约并创建新预约，保留 `rescheduled_from_id` 改约链 |
| `sp_check_in_reservation` | 校验到站窗口/设备/车位后置 `CHECKED_IN`、写入核验、自动占位 |
| `sp_join_queue` | 锁场站行分配当日排队号，写入排队 |
| `sp_call_next_queue` | 过期超时叫号，按优先级取下一号并置 `CALLED` |
| `sp_check_in_queue` | 校验叫号有效期/设备/车位后置 `CHECKED_IN`、写入核验、自动占位 |
| `sp_release_parking_space` | 释放车位；正常驶离要求无 `ACTIVE` 订单；未开单资格同时取消 |
| `sp_consume_admission` | 供 B 开单后原子消费预约/排队资格，校验订单的 `channel+admission_id` 和用户/车辆/枪一致 |
| `sp_expire_overdue_admissions` | 批量过期迟到预约、超时叫号、等待超过 240 分钟的排队 |

### 5.3 并发控制

**同枪预约冲突（已实测）**

1. `sp_create_reservation` 首先 `SELECT station_id,status FROM charging_gun WHERE gun_id=? FOR UPDATE`，锁住目标枪行；
2. 同一枪的第二个事务在锁上等待；
3. 第一个事务提交后，第二个事务用 `SELECT reservation_id ... LIMIT 1 FOR UPDATE` 做**当前读**冲突检查，能看到刚提交的预约，返回 `RESERVATION_GUN_OVERLAP`；
4. 触发器 `a_reservation_overlap_bi` 使用普通一致性读，仅作为绕过过程的顺序写入兜底；MySQL 不允许触发器对同一张表做锁定读（错误 1442），因此并发入口必须是存储过程。

演示：`python -m app.run_reservation_concurrency_demo`，输出 `A=成功、B=被拒绝、剩余有效预约=0、PASS`。

**资格消费（设计）**

B 在开单事务中先插入 `charging_order(channel, admission_id)`，再调用 `sp_consume_admission`；过程锁定资格行，校验状态为 `CHECKED_IN`、`consumed_order_id IS NULL`、订单归属与资格一致，然后置 `CONSUMED`。若两个事务同时消费同一资格，第二个事务在行锁释放后看到 `status<>CHECKED_IN` 或 `consumed_order_id IS NOT NULL`，返回 `ADMISSION_*_ALREADY_CONSUMED`。

### 5.4 触发器

| 触发器 | 作用 |
| --- | --- |
| `a_reservation_overlap_bi` | 同枪/同用户有效预约冲突兜底 |
| `a_reservation_status_bu` | 预约状态机 + 身份字段不可变 + 改约链只写一次 |
| `a_reservation_log_ai/au` | 预约状态历史 |
| `a_queue_status_bu` | 排队状态机 + 身份字段不可变 |
| `a_queue_log_ai/au` | 排队状态历史 |
| `a_checkin_qualification_bi` | 核验资格二选一、状态/用户/车辆/枪/场站一致、车位为枪绑定车位、车位/车辆未被占用 |
| `a_checkin_occupancy_ai` | 核验成功自动生成车位占用 |

## 6. 视图与业务查询

### 6.1 视图

| 视图 | 用途 |
| --- | --- |
| `v_a_reservation_board` | 当前 `BOOKED/CHECKED_IN` 预约看板，含迟到截止时间 |
| `v_a_queue_board` | 当前有效排队，含优先级、等待分钟、叫号状态 |
| `v_a_parking_occupancy_live` | 当前未释放车位，区分充电中/充电结束未驶离/到站未开单 |
| `v_a_reservation_fulfillment` | 按场站/日期统计预约履约率 |

### 6.2 业务查询

`sql/A/06_business_queries.sql`：

| 查询 | 关系数 | 用途 |
| --- | --- | --- |
| Q01 | 5 | 场站预约压力与履约率 |
| Q02 | 6 | 预约→到站→占位→开单转化漏斗 |
| Q03 | 5 | 排队等待、叫号超时与开单转化 |
| Q04 | 7 | 当前车位占用与“充电结束未驶离”明细 |
| Q07 | 4 | 同枪有效预约冲突扫描（预期 0 行） |

本机执行结果见 `A/第三天材料/实测/verify_a_module.json` 与 `06_business_queries.sql` 输出。

## 7. 测试与验收

### 7.1 SQL 约束测试

`sql/A/08_constraint_tests.sql` 共 16 项，全部 PASS：

- T01 同枪预约重叠 → 1644
- T02 同用户跨枪重叠 → 1644
- T03 重复有效排队 → 1062
- T04 重复到站核验 → 1644
- T05 车位已占用 → 1644
- T06 公告非法状态迁移 → 1644
- T07 通知非法状态迁移 → 1644
- T08 重复消费资格 → 1644
- T09 取消预约缺时间/原因 → 3819
- T10 定向公告缺停运计划 → 3819
- T11 取消排队缺时间/原因 → 3819
- T12 FAILED 通知带发送时间 → 3819
- T13 充电中按正常驶离释放 → 1644
- T14 发布/撤回定向公告 → 正向 PASS
- T15 过期批处理 → 正向 PASS
- T16 通知 PENDING→SENT→READ → 正向 PASS

### 7.2 真实数据库验收

`python tests/verify_a_module.py` 共 17 项，全部 PASS：

- 10 张 A 表、8 视图、14 过程、13 触发器、每表 ≥20 行；
- 无同枪预约重叠、无同车位/同车辆重复有效占用、无同用户重复有效排队；
- 预约→核验→占位事务回滚后行数不变；
- 定向公告发布生成接收人/通知，撤回取消未发送通知，回滚后行数不变；
- 同枪并发预约仅一个成功，清理后无残留。

### 7.3 Python 测试

`python -m pytest -q`：61 passed（含 A 的持久层、服务层、过程错误翻译测试，以及 D 原有测试）。

## 8. 运维与优化

- **过期批处理**：建议每 5 分钟调用 `sp_expire_overdue_admissions(NOW())`；公告过期调用 `sp_expire_notices(NOW())`。可用 MySQL Event Scheduler 或应用定时任务。
- **车位释放**：现场运维确认车辆驶离后调用 `sp_release_parking_space`；正常驶离受“无 ACTIVE 订单”保护，异常场景使用 `STAFF/OTHER` 原因人工处理并留痕。
- **排队优先级**：`priority_score` 当前由过程按 `RESERVATION_LATE/WALK_IN` 赋值；调整口径只需改过程，不改表结构。
- **索引复核**：Q04 的相关子查询在数据量增大后建议用 `EXPLAIN ANALYZE` 复核；必要时为 `charging_order(gun_id, user_id, vehicle_id, starts_at)` 增加复合索引（需与 B 协商）。
- **锁顺序**：预约创建锁枪行 → 检查预约；到站核验锁预约/排队行 → 锁枪行；资格消费锁订单行 → 锁资格行。跨模块调用时应保持同一顺序，避免死锁。
- **时区**：所有连接执行 `SET SESSION time_zone='+08:00'`；DATETIME 保存北京时间，区间左闭右开。

## 9. 待确认事项

1. 预约迟到保留时长（默认 15 分钟）。
2. 叫号保留时长（默认 10 分钟）。
3. 现场排队与即将开始预约的优先级（当前 `RESERVATION_LATE=100`、`WALK_IN=0`）。
4. 排队等待过期时长（当前 240 分钟）。
5. 预约提前核验窗口（当前最多提前 30 分钟）。
6. 停运计划唯一登记责任人（A/B/C）。
7. 枪位映射调整时，A 的核验/占位逻辑同步方式。
8. 新增⑥业务线的视图/过程数量考核口径。
