# ⑧ 场站服务公告与通知设计说明

## 1. 业务需求分析

### 1.1 业务目标

把场站的服务变化（入口改道、停运、排队高峰、会员活动等）可靠地告知车主，重点区分两类场景：

1. **公开公告**：所有车主可见，未预约车主也能看到入口改道、服务台变更、安全提示等；
2. **停运定向通知**：针对共享停运计划 `equipment_outage_plan` 影响范围内、仍然有效的预约/排队用户，生成接收人快照并发送通知；停运变化或恢复后再次通知原受影响用户。

同时保留公告的创建、修改、发布、撤回、过期全过程，以及每条通知的发送、失败、重试、阅读结果。

### 1.2 角色与用例

| 角色 | 主要用例 |
| --- | --- |
| 平台运营管理员 | 创建草稿、修改公告、发布、撤回、查看送达/阅读统计 |
| 场站运维人员 | 登记停运事实（由 B/C 共享计划承载），发起停运公告 |
| 车主用户 | 查看公开公告；接收定向停运通知 |
| 通知渠道 | 接收 `notification_record` 并回写 SENT/FAILED/READ |

用例图与鲁棒图见：

- `A/业务图/02_⑧公告通知_用例图.png`
- `A/业务图/04_⑧公告通知_鲁棒图.png`
- `A/业务图/06_⑧公告通知_局部ER图.png`

### 1.3 核心业务规则

| 编号 | 规则 | 数据库落实 |
| --- | --- | --- |
| R1 | 公开公告与定向通知共用主表，用 `notice_type` 区分 | `station_notice.notice_type` |
| R2 | 定向停运公告必须关联共享停运计划 | `ck_notice_target_plan` |
| R3 | 公告状态机 `DRAFT→PUBLISHED→WITHDRAWN/EXPIRED` | `a_notice_transition_bu` |
| R4 | 发布后场站、类型、关联停运计划、生效开始时间不可修改 | `NOTICE_IDENTITY_IMMUTABLE` |
| R5 | 新建/修改/发布/撤回/过期保留版本快照 | `a_notice_revision_ai/au` |
| R6 | 同一公告同一用户只保留一条接收记录 | `uk_notice_recipient_user` |
| R7 | 定向公告按停运范围筛选受影响预约/排队 | `sp_publish_notice` |
| R8 | 一个接收对象在一个渠道只有一条通知，失败重试累加 | `uk_notification_recipient_channel` |
| R9 | 通知状态机 `PENDING→SENT/FAILED`、`FAILED→PENDING/SENT`、`SENT→READ` | `a_notification_status_bu` |
| R10 | 通知状态与时间/失败原因必须一致 | CHECK + `sp_update_notification_status` |
| R11 | 撤回公告取消尚未发送的 PENDING 通知 | `sp_withdraw_notice` |
| R12 | 公告超过 `effective_to` 自动过期 | `sp_expire_notices` |

### 1.4 状态机

**公告 `station_notice.status`**

```text
DRAFT ──发布──> PUBLISHED ──撤回──> WITHDRAWN
                    │
                    └──到期──> EXPIRED
```

- `DRAFT`：无 `published_at`；
- `PUBLISHED`：有 `published_at`，无 `withdrawn_at`；
- `WITHDRAWN`：有 `published_at`、`withdrawn_at`、`withdraw_reason`；
- `EXPIRED`：有 `published_at`，无 `withdrawn_at`。

**通知 `notification_record.status`**

```text
PENDING ──发送成功──> SENT ──用户阅读──> READ
   │                   
   └──发送失败──> FAILED ──重试──> PENDING/SENT
```

- `PENDING/FAILED`：`sent_at` 为空；`FAILED` 必须有 `failure_reason`；
- `SENT`：`sent_at` 非空，`read_at` 为空；
- `READ`：`sent_at`、`read_at` 均非空。

### 1.5 非功能需求

- **一致性**：公告状态、接收人、待发送通知在同一事务内生成；撤回时未发送通知同步置失败。
- **可追溯**：每次公告变更保留版本快照；通知失败原因、重试次数、渠道消息号可查。
- **触达率**：按公告/场站/类型统计接收人、发送、阅读、失败和送达率。
- **权限**：公告管理仅运营角色可写；车主只读公开公告；视图使用 `SQL SECURITY INVOKER`。
- **安全**：不返回手机号/车牌；接收人只引用 `user_id`/`vehicle_id` 和资格编号。

## 2. 概念结构设计

### 2.1 实体与联系

| 实体 | 说明 | 主要联系 |
| --- | --- | --- |
| `station_notice` 公告 | 公开/定向公告主表 | 场站 1:N；停运计划 1:N；接收人 1:N；版本 1:N |
| `notice_revision` 公告版本 | 变更快照 | 公告 1:N |
| `notice_recipient` 接收对象 | 定向公告的接收人快照 | 公告 1:N；用户 1:N；车辆 1:N；预约/排队 0..1:1 |
| `notification_record` 发送记录 | 按渠道记录发送结果 | 接收对象 1:N（按渠道唯一） |
| `station` | B 场站主数据 | 1:N 公告 |
| `equipment_outage_plan` | B/C 共享停运计划 | 1:N 公告 |
| `user`/`vehicle` | D 用户/车辆 | 1:N 接收对象 |
| `charging_reservation`/`queue_record` | A 资格 | 0..1:1 接收对象 |

局部 E-R 图见 `A/业务图/06_⑧公告通知_局部ER图.png`。

### 2.2 关键基数

- 场站 `1:N` 公告；停运计划 `1:N` 公告（一个计划可产生多张公告）。
- 公告 `1:N` 版本；公告 `1:N` 接收对象；同一公告同一用户唯一。
- 接收对象 `1:N` 通知记录，按渠道唯一。
- 预约/排队 `0..1:1` 接收对象（一个资格可被多张公告分别通知，但在单张公告内只出现一次）。

## 3. 逻辑结构设计

### 3.1 关系模式

```text
station_notice(
  notice_id PK, station_id FK, notice_type, severity, title, content,
  status, effective_from, effective_to, published_at,
  withdrawn_at, withdraw_reason, created_by, updated_by,
  related_outage_plan_id FK, created_at, updated_at
)

notice_revision(
  revision_id PK, notice_id FK, revision_no, action,
  title, content, changed_at, changed_by,
  UNIQUE(notice_id, revision_no)
)

notice_recipient(
  recipient_id PK, notice_id FK, user_id FK, vehicle_id FK,
  reservation_id FK, queue_id FK, recipient_reason, created_at,
  UNIQUE(notice_id, user_id)
)

notification_record(
  notification_id PK, recipient_id FK, channel, status,
  sent_at, read_at, failure_reason, retry_count,
  provider_message_id, created_at, updated_at,
  UNIQUE(recipient_id, channel)
)
```

### 3.2 函数依赖与第三范式

- `notice_id` 决定公告全部属性；`(notice_id, revision_no)` 决定版本属性；`recipient_id` 决定接收对象属性；`notification_id` 决定通知属性。
- `notification_record` **不保存** `notice_id`、`user_id`、`vehicle_id`：这些由 `recipient_id → notice_recipient` 决定，保存会形成传递依赖。视图 `v_a_notice_delivery_stats` 通过连接 `notice_recipient` 获取公告维度。
- `notice_recipient` 保存 `vehicle_id`、`reservation_id`、`queue_id` 是定向通知的**接收对象快照**：公告发布后原预约/排队可能变更，接收快照必须保留当时受影响对象，因此属于有意保留的业务事实。
- 结论：四张表满足 3NF；接收对象快照属于历史留痕，不是冗余。

## 4. 物理结构设计

### 4.1 表与对象

| 对象 | 数量 | 说明 |
| --- | --- | --- |
| ⑧ 表 | 4 | `station_notice`、`notice_revision`、`notice_recipient`、`notification_record` |
| 外键 | 10 | 连接场站、停运计划、用户、车辆、预约、排队 |
| CHECK | 16 | 公告状态-时间、定向-计划、接收人-资格、通知状态-时间/失败原因 |
| 视图 | 4 | 公开公告、送达统计、受影响用户、版本历史 |
| 存储过程 | 5 | 发布、撤回、通知状态更新、公告过期（另含通用过程） |
| 触发器 | 6 | 公告状态机、版本创建/更新、通知状态机 |

完整字段定义见 `docs/a/A_06_08_data_dictionary.xlsx`。

### 4.2 关键约束

- `ck_notice_effective`：`effective_to` 为空或晚于 `effective_from`。
- `ck_notice_draft_published`/`ck_notice_published_time`：DRAFT 无发布时间；非 DRAFT 必须有发布时间。
- `ck_notice_withdrawn`/`ck_notice_not_withdrawn`：撤回必须有 `withdrawn_at` 和 `withdraw_reason`，非撤回不能带撤回信息。
- `ck_notice_target_plan`：`OUTAGE_TARGETED` 必须关联 `related_outage_plan_id`。
- `ck_notice_public_plan`：公开公告不能关联停运计划。
- `ck_notice_recipient_reservation`/`ck_notice_recipient_queue`：接收原因与资格字段配对。
- `ck_notification_sent_pair`：`PENDING/FAILED` 不能有 `sent_at`，`SENT/READ` 必须有。
- `ck_notification_failed`：`FAILED` 必须有失败原因；非 `FAILED` 不能有失败原因。
- `ck_notification_retry`：重试次数 ≤10。

### 4.3 索引

| 索引 | 用途 |
| --- | --- |
| `ix_notice_station_status_effective` | 公开公告按场站/状态/有效期筛选 |
| `ix_notice_outage_plan` | 按停运计划查公告 |
| `ix_notice_type_status` | 按类型/状态查公告 |
| `uk_notice_revision_no` | 公告版本号唯一 |
| `uk_notice_recipient_user` | 同一公告同一用户只接收一次 |
| `ix_notice_recipient_reservation`/`queue` | 按资格查接收对象 |
| `uk_notification_recipient_channel` | 同一接收对象同一渠道唯一 |
| `ix_notification_status_created` | 待发送通知轮询 |

## 5. SQL 实现说明

### 5.1 存储过程

| 过程 | 作用 |
| --- | --- |
| `sp_publish_notice` | 发布公告；定向公告按停运计划筛选 `BOOKED/CHECKED_IN` 预约和有效排队，生成接收人与 `IN_APP` 待发送通知 |
| `sp_withdraw_notice` | 撤回已发布公告；未发送 `PENDING` 通知置 `FAILED`，原因 `NOTICE_WITHDRAWN` |
| `sp_update_notification_status` | 统一发送/失败/重试/阅读入口，校验状态机和时间字段 |
| `sp_expire_notices` | 把超过 `effective_to` 的已发布公告置 `EXPIRED` |
| `sp_a_run_constraint_tests`（测试过程） | 16 项约束/状态机测试，结束回滚，不属于生产过程 |

### 5.2 触发器

| 触发器 | 作用 |
| --- | --- |
| `a_notice_transition_bu` | 公告状态机；发布后身份字段不可变；发布时间/撤回时间不可改写 |
| `a_notice_revision_ai` | 新建公告自动写入第 1 版 `CREATE` 快照 |
| `a_notice_revision_au` | 正文修改、发布、撤回、过期自动追加版本快照 |
| `a_notification_status_bu` | 通知状态机；接收对象/渠道不可修改 |

### 5.3 发布与撤回流程

**发布定向公告**

1. `sp_publish_notice` 锁定公告行，校验 `DRAFT`；
2. 更新 `PUBLISHED`、`published_at`、`updated_by`；触发器写 `PUBLISH` 版本；
3. 读取 `equipment_outage_plan` 的场站、枪、起止时间；
4. 筛选 `charging_reservation`：同场站、枪范围匹配、`BOOKED/CHECKED_IN`、时间与停运区间重叠；
5. 筛选 `queue_record`：同场站、枪范围匹配、`WAITING/CALLED/CHECKED_IN`，且停运当前生效；
6. 插入 `notice_recipient`（`ON DUPLICATE KEY` 保证同一公告同一用户唯一）；
7. 插入 `notification_record(channel='IN_APP', status='PENDING')`；
8. 返回接收人数和通知数。

**撤回公告**

1. 锁定公告行，校验 `PUBLISHED`；
2. 置 `WITHDRAWN`、`withdrawn_at`、`withdraw_reason`；触发器写 `WITHDRAW` 版本；
3. 把该公告下仍为 `PENDING` 的通知置 `FAILED`、`failure_reason='NOTICE_WITHDRAWN'`；已 `SENT/READ` 的通知无法撤回，保留事实。

### 5.4 通知状态更新

`sp_update_notification_status` 是唯一写入口：

- `SENT`：写 `sent_at`、清 `failure_reason`、可写 `provider_message_id`；
- `FAILED`：清 `sent_at`、写 `failure_reason`、`retry_count+1`；
- `PENDING`：重试前置，清发送/阅读/失败字段；
- `READ`：写 `read_at`，要求之前为 `SENT`。

触发器 `a_notification_status_bu` 与 CHECK 约束共同保证非法状态迁移和时间字段不一致时失败。

## 6. 视图与业务查询

### 6.1 视图

| 视图 | 用途 |
| --- | --- |
| `v_a_public_notice_active` | 当前有效的公开公告，未预约车主可见 |
| `v_a_notice_delivery_stats` | 按公告统计接收/发送/阅读/失败与送达率 |
| `v_a_outage_affected_users` | 定向停运公告的受影响用户、预约/排队资格与处理状态 |
| `v_a_notice_revision_history` | 公告版本历史与操作人 |

### 6.2 业务查询

`sql/A/06_business_queries.sql`：

| 查询 | 关系数 | 用途 |
| --- | --- | --- |
| Q05 | 6 | 停运公告触达与受影响预约处理结果 |
| Q06 | 4 | 公告送达率/阅读率按场站、类型、级别统计 |

## 7. 测试与验收

### 7.1 SQL 约束测试

`sql/A/08_constraint_tests.sql` 中与 ⑧ 相关的测试：

- T06 公告 DRAFT 直接撤回 → 1644；
- T07 通知 PENDING 直接 READ → 1644；
- T10 定向公告缺停运计划 → 3819；
- T12 FAILED 通知带发送时间 → 3819；
- T14 发布定向停运公告并撤回 → 正向 PASS（接收人=1、通知=1、取消未发送=1）；
- T16 通知 PENDING→SENT→READ → 正向 PASS。

### 7.2 真实数据库验收

`python tests/verify_a_module.py`：

- 定向公告发布生成接收人与待发送通知；
- 撤回公告取消未发送通知，通知终态 `FAILED`、原因 `NOTICE_WITHDRAWN`；
- 回滚后公告/接收人/通知行数不变。

### 7.3 演示

- `python -m app.run_notice_demo`：公开公告、送达统计、受影响用户只读看板；
- `python -m app.run_notice_workflow_demo`：模拟“先预约、后登记停运”→发布定向公告→发送→撤回，事务回滚后行数不变。

## 8. 运维与优化

- **公告过期**：建议每 10 分钟调用 `sp_expire_notices(NOW())`，或由应用定时任务触发；过期会追加 `EXPIRE` 版本。
- **待发送轮询**：使用 `ix_notification_status_created` 按 `status='PENDING'` 取通知；失败重试通过 `sp_update_notification_status` 递增 `retry_count`，超过 10 次由运营人工处理。
- **送达统计**：`v_a_notice_delivery_stats` 使用 `COUNT(DISTINCT recipient_id)` 避免多渠道通知重复计数；`NULLIF` 防止零接收人除零。
- **大表**：`notification_record` 按状态/时间索引；数据量增大后可按月分区或归档 `SENT/READ` 历史。
- **权限**：运营账号授予 `station_notice`、`notice_recipient` 的写权限和过程 `EXECUTE`；车主账号只授予公开公告视图 `SELECT`；通知渠道只授予 `notification_record` 的状态更新过程。
- **审计**：公告版本和通知记录不物理删除；撤回保留原发布时间和撤回原因。

## 9. 待确认事项

1. 公开公告是否需要主动推送（当前只进入公开视图，不生成通知记录）。
2. 通知渠道优先级与降级策略（当前支持 IN_APP/SMS/PUSH/WECHAT/EMAIL，具体渠道由运营配置）。
3. 定向停运公告的筛选是否覆盖“停运登记时预约已过期但用户仍到场”的场景。
4. 停运计划变更/恢复后的二次通知触发方式（当前由运营再次发布公告）。
5. 公告是否需要审批流（当前创建即可发布，审批由运营流程控制）。
6. 新增⑧业务线的视图/过程数量考核口径。
