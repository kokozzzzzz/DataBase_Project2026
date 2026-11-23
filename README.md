# 新能源汽车充电桩运营服务平台

> 《数据库系统》课程设计
>
> MySQL + Python｜4 名成员｜八条业务线

## 项目简介

随着新能源汽车保有量持续增长，“找桩—充电—支付”已成为高频刚需。一次充电背后涉及场站、充电桩、充电枪三级资产，峰平谷分时电价与服务费，以及设备状态、告警、工单、结算对账等一连串数据。运营方最怕三件事：桩显示空闲而实际故障、计费口径与账单对不上、故障响应慢导致用户流失。

本项目围绕“设备可用—用户充电—费用结算—故障处置”的运营闭环，设计并实现一个集场站设施、充电订单、设备监控、会员运营、结算对账于一体的充电桩运营服务平台数据库。在任务书原有 5 条业务线的基础上，小组新增 3 条业务线，共 **8 条业务线**，重点训练：

- 三级资产（场站—桩—枪）的外键与层级约束
- 按峰平谷时段分段的计费核价
- 告警到工单的状态流转闭环
- 平台与运营商之间的结算对账
- 预约排队、备件库存、公告通知等新增业务的跨模块协作

**当前阶段（2026-11-22）**：处于 Day 4 联调收口。51 张业务表已在 MySQL 8.0.46 安装，A/B/C/D 结构与跨模块关键流程已联调；D⑤已完成五表、三视图、结算生成、正式数据、多表查询、双方确认、跨期调整、普通开票和红字冲销。后续重点为最终全局图、统一字典、备份恢复和答辩材料收口。集成规则与历史交接见[本次集成与交接说明](docs/集成修正_2026-11-21/README.md)。

## 业务范围

| 编号 | 业务线 | 来源 | 负责人 | 核心内容 |
| --- | --- | --- | --- | --- |
| ① | 场站与充电设施 | 任务书 | B | 运营商、场站、充电桩、充电枪、车位档案；设备状态与状态历史 |
| ② | 充电订单与计费 | 任务书 | B | 开单、结束充电、峰平谷分段计费、支付、补缴、退款、异常复核 |
| ③ | 设备监控与故障工单 | 任务书 | C | 运行数据采集、告警生成与升级、派单、到场维修、修复复核 |
| ④ | 用户与会员运营 | 任务书 | D | 用户与车辆绑定、会员、优惠活动、优惠券发放核销、企业车队 |
| ⑤ | 结算与对账 | 任务书 | D | 运营商—场站—账期结算、逐单明细、对账差异、确认、开票与红冲 |
| ⑥ | 预约、排队与到站管理 | 小组新增 | A | 预约创建/取消/改约、现场排队、叫号、到站核验、车位占用与释放 |
| ⑦ | 备件库存与领用管理 | 小组新增 | C | 备件档案、分仓库存、入库、工单领用、退库、库存流水 |
| ⑧ | 场站服务公告与通知 | 小组新增 | A | 公开公告、停运定向通知、发布/修改/撤回、通知记录 |

八条业务线及跨模块交接关系见 [整体业务流程图](docs/新能源汽车充电桩平台_八条业务线整体业务流程图.png)：

![八条业务线整体业务流程图](docs/新能源汽车充电桩平台_八条业务线整体业务流程图.png)

## 团队分工

| 成员 | 业务组 | 负责业务线 | 重点交付 |
| --- | --- | --- | --- |
| A | 车主服务与信息发布 | ⑥ 预约、排队与到站管理；⑧ 场站服务公告与通知 | 预约/叫号/到站/车位释放；公告与定向通知 |
| B | 场站设施与交易实现 | ① 场站与充电设施；② 充电订单与计费 | 场站—桩—枪—车位模型；开单、分时计费、支付与退款 |
| C | 设备运维与备件管理 | ③ 设备监控与故障工单；⑦ 备件库存与领用管理 | 告警—维修闭环；库存、领用、退库与流水 |
| D | 会员运营与财务结算 | ④ 用户与会员运营；⑤ 结算与对账 | 用户、车辆、优惠与车队；结算、差异处理与开票 |

> 每位成员均参与数据库设计、SQL 实现与测试，并为负责业务线提供需求分析、数据字典、E-R 图、DDL、查询、视图、存储过程/触发器、持久层与测试证据。

## 技术栈与环境

| 项目 | 说明 |
| --- | --- |
| 数据库 | MySQL 8.0.46 / InnoDB / utf8mb4 |
| 开发语言 | Python 3.13（当前参考环境，建议 3.11+） |
| 持久层方案 | PyMySQL 1.2.4（已实现）+ SQLAlchemy 2.1.8（依赖已固定，按模块需要使用） |
| 依赖管理 | pip + `requirements.txt` |
| 版本管理 | Git + GitHub，一个公共仓库 |
| 设计工具 | E-R 图 / UML 类图（PowerDesigner、Visio、StarUML 等） |
| 数据字典 | Excel 主文件统一维护 |

统一约定：

- 表名、字段名使用英文小写 `snake_case`，如 `charging_order`、`parking_space_id`
- 金额字段使用 `DECIMAL` 等定点数类型，不使用 `FLOAT` / `DOUBLE` 直接存储金额
- 统一时间精度、时区和区间边界；计费时段明确起止边界
- 每个实体指定唯一主维护模块，其他模块通过统一编号与外键引用，不重复建表
- 公共编号：`station_id`、`pile_id`、`gun_id`、`parking_space_id`、`user_id`、`vehicle_id`、`reservation_id`、`queue_id`、`order_id`、`work_order_id`、`spare_part_id`、`settlement_id`

## 数据库设计要点

### 核心业务规则

- 场站、充电桩、充电枪构成三级层级，站对桩、桩对枪均为一对多；枪是订单与计费的最小对象，单枪最大功率不得超过所属桩的额定功率
- 同一把枪在同一时段只允许存在一笔进行中的订单（事务 + 锁/唯一约束保证并发安全）
- 电费按峰/平/谷分时电价分段累加，订单费用明细保存每段电量、单价与费用，新价格生效后历史账单仍可还原
- 支付记录与订单一对多，支持分次支付与补缴；退款需可追溯原支付流水
- 告警与工单一对多，同一告警允许多次派单并保留历史；工单闭环且设备复核通过后，告警方可恢复
- 优惠券核销与订单一一对应，不允许重复核销；支付失败、取消、退款时按约定释放或恢复
- 结算单按“运营商—场站—账期”唯一；差异明细必须回指具体订单，处理结论经双方确认后生效
- 支付与退款先分别按订单汇总，再关联结算明细，避免多笔支付/退款连接后金额重复累加
- 已确认账期后发生部分退款，在后续账期记录调整，并可追溯原订单与原结算单
- 开票金额不得超过结算单应结金额；红冲保留原票信息
- 库存数量更新与库存流水写入必须在同一事务中完成；两张工单争抢最后一件备件时只允许一笔成功
- 同一把枪的有效预约时间段不能重叠；预约/叫号资格只能消费一次，到站核验成功后才允许开单
- 充电结束但车辆未驶离时，车位仍保持占用，不提前释放或叫下一位
- 设备停运计划只能有一份共享数据源，预约校验、公告通知与开单校验读取同一份记录
- 手机号、车牌、税号等敏感字段脱敏展示、加密存储，并受 RBAC 与导出限制约束

### 核心表（初步）

> 下表保留早期概念设计；最终物理字段以各模块DDL及最新导出字典为准。

| 业务线 | 核心表（初步） |
| --- | --- |
| ① 场站与充电设施 | `operator`、`station`、`charging_pile`、`charging_gun`、`parking_space`、`equipment_status_log`、`equipment_outage_plan` |
| ② 充电订单与计费 | `charging_order`、`tariff_rule`、`order_fee_detail`、`payment_record`、`refund_record` |
| ③ 设备监控与故障工单 | `device_telemetry`、`alarm`、`maintenance_work_order` |
| ④ 用户与会员运营 | `membership_level`、`user`、`vehicle`、`membership_record`、`promotion`、`promotion_station`、`coupon`、`coupon_redemption`、`enterprise_customer`、`fleet`、`fleet_vehicle`、`fleet_quota_record` |
| ⑤ 结算与对账 | `settlement_statement`、`settlement_detail`、`reconciliation_difference`、`reconciliation_confirmation`、`invoice_record` |
| ⑥ 预约、排队与到站 | `charging_reservation`、`reservation_status_log`、`queue_record`、`queue_status_log`、`arrival_checkin`、`parking_occupancy` |
| ⑦ 备件库存与领用 | `spare_part`、`warehouse`、`inventory`、`inventory_transaction`、`work_order_part` |
| ⑧ 场站服务公告与通知 | `station_notice`、`notice_revision`、`notice_recipient`、`notification_record` |

## 三条端到端流程

1. **充电主流程**：预约/排队 → 到站核验 → 开单 → 分时计费 → 优惠券支付 → 结算对账
2. **运维闭环**：设备运行数据 → 故障告警 → 维修工单 → 备件领用/退库 → 修复复核 → 设备恢复
3. **停运通知**：计划停运 → 公告发布 → 通知受影响车主 → 预约取消/改约/换枪 → 恢复后再次通知

这三个场景是跨业务线联调与答辩演示的主线。

## 仓库结构

```text
.
├── A/               # A 模块说明、业务图、测试证据与字典生成工具
├── B/               # B 设施/订单数据字典、业务图与对接清单
├── app/             # Python 数据库连接、持久层、服务层和演示入口
├── docs/            # 数据字典、模块说明、任务分工、执行方案和业务流程图
├── sql/             # 各成员 DDL、测试数据、业务查询与验证脚本
├── target/          # 课程设计任务书与小组思路文档
├── tests/           # 持久层与事务单元测试
├── yX/              # C ③⑦ 数据字典与局部 E-R 图
├── requirements.txt # Python 依赖清单
└── README.md
```

## 文档索引

| 文档 | 说明 |
| --- | --- |
| [课程设计任务书](target/新能源汽车充电桩运营服务平台课程设计2026年任务书.pdf) | 学校下发的原始任务书，定义业务需求与验收要求 |
| [课设思路](target/DB课设思路_01.docx) | 五条原有业务线 + 三条新增业务线的方案与分工建议 |
| [八条业务线统一数据字典模板](docs/八条业务线统一数据字典模板_MySQL_Python.xlsx) | 数据字典、实体清单、关系清单、跨模块接口、业务规则（全组唯一来源） |
| [四人四天任务分工计划](docs/四人四天任务分工计划_八条业务线_MySQL_Python.docx) | 四天总览、逐日任务、验收清单与风险应对 |
| [第一天详细执行方案](docs/第一天详细执行方案_八条业务线_MySQL_Python.docx) | Day 1 时间安排、跨模块规则、公共编号与各成员任务 |
| [整体业务流程图](docs/新能源汽车充电桩平台_八条业务线整体业务流程图.png) | 八条业务线及跨模块交接关系 |
| [D 模块开发说明](docs/d/README.md) | ④用户会员、⑤结算对账的状态、交付物、运行方式和待确认接口 |
| [D 模块最终验收清单](docs/d/FINAL_ACCEPTANCE.md) | D④⑤统一 SQL 验收、Python 回归、事务回滚演示与答辩顺序 |
| [D 模块统一验收脚本](sql/D/00_verify_d_all.sql) | 一次检查 D 的 17 张表、6 个视图、2 个过程、正式数据与关键业务不变量 |
| [④业务线 DDL 说明](docs/d/04_membership.md) | ④核心表与跨模块表的设计说明、执行顺序和关键约束 |
| [④跨模块正式数据验收](sql/D/04_membership_integration_data_verify.sql) | 验证活动场站、已核销优惠券与订单用户、金额、时间的一致性，`DI01～DI06` |
| [⑤结算与对账设计说明](docs/d/05_settlement.md) | ⑤五表结构、金额与账期口径、状态流转、视图/过程及实施计划 |
| [⑤结算与对账建表前检查](sql/D/05_settlement_preflight.sql) | B 依赖、编号类型、引擎排序规则与目标表不存在性的只读检查 |
| [⑤结算与对账 DDL](sql/D/05_settlement_schema.sql) | 五张正式业务表、跨 B 外键、状态约束、生成列和索引 |
| [⑤结算与对账结构验收](sql/D/05_settlement_verify.sql) | 表、字段、约束、外键、类型、生成列和引擎的只读检查 |
| [⑤测试数据依赖检查](sql/D/05_settlement_seed_preflight.sql) | 只读统计现有 B 订单、费用分段、成功支付、退款和可结算订单规模 |
| [⑤正式测试数据](sql/D/05_settlement_seed.sql) | 基于 B-FORMAL-v1 生成 40 个账期、60 条结算明细及对账确认和发票数据；通过 `--commit` 控制提交 |
| [⑤正式数据验收](sql/D/05_settlement_seed_verify.sql) | 只读检查五表规模、跨期退款、双方确认、红字发票和财务汇总，`SD01～SD07` |
| [⑤多表业务查询](sql/D/05_settlement_business_queries.sql) | 6 条连接至少 3 个关系的只读查询，覆盖账期、逐单、退款、差异和发票追溯 |
| [⑤查询执行计划](sql/D/05_settlement_explain.sql) | 5 条 `EXPLAIN ANALYZE`，验证账期、明细、差异确认和发票索引路径 |
| [⑤结算持久层](app/database/settlement_repository.py) | 结算汇总与待处理差异的参数化分页查询，不暴露确认人和税号 |
| [⑤对账事务服务](app/services/settlement_service.py) | 追加双方确认，并将已同意差异安全写入后续账期调整明细 |
| [⑤开票事务服务](app/services/settlement_invoice_service.py) | 校验累计净开票上限，完成普通发票开具与可分次红字冲销 |
| [一键安装脚本](sql/00_install_all.sql) | 空库按 D→B→A→D 结算的依赖顺序安装结构，带空库守卫 |
| [A 安装前置检查](sql/A/00_preflight.sql) | 只读检查 D/B 依赖与 A 对象数量，定位 `07_verify.sql` 全 0 的原因 |
| [A 结构补装](sql/A/00_install_a.sql) | 已有 D/B、仅缺 A 时只安装 A 的 01～04，带重复建表守卫 |
| [综合验收](sql/00_verify_all.sql) | A/B/C/D 结构、D 结算对象、交易输入与正式结算数据综合验收 |
| [跨模块安装与 D 结算数据链复验](docs/跨模块安装与D结算数据链复验_2026-11-21.md) | 8.0.46 空库/补装 A 两条路径、B 固定交易集与 D DP03/DP06 实测记录 |
| [A 模块开发说明](docs/a/README.md) | ⑥预约排队、⑧公告通知的状态、交付物、接口、运行方式和实测结果 |
| [⑥预约排队设计说明](docs/a/06_reservation_queue.md) | ⑥需求、E-R、3NF、DDL、并发控制、视图、查询与测试 |
| [⑧公告通知设计说明](docs/a/08_notice.md) | ⑧公告状态机、版本、接收人、通知状态机、视图与测试 |
| [A 数据字典](docs/a/A_06_08_data_dictionary.xlsx) | 10 表 116 字段，含类型、键、约束、索引与待确认事项 |
| [A 模块说明与导航](A/README.md) | A 的 SQL/Python/图表/测试证据索引与快速复现 |

## B 模块第三阶段交付

B正式交易服务已接入A预约/排队资格、占位及D优惠券事务，提供开单、读数、分时核价、支付补缴和部分退款。B-FORMAL-v1测试集覆盖16张B表，每表至少20行，包括40笔已出账且足额支付订单、80条费用分段、100条支付及20条次月退款。D结算数据预检DP03/DP06均PASS。

历史第三天验证在独立MySQL8.4.13完成16项检查、87项单元测试；2026-11-21已补齐8.0.46复验并增加预约宽限边界检查，见最新集成说明。D券服务的两处支付判定改为当前读，释放券时清除旧账单确认，请D核对。运行顺序、已定规则和交接见[B开发说明](B/README.md)、[接口与交接决定](B/第三天材料/接口与交接决定.md)、[固定数据说明](B/第三天材料/固定测试数据说明.md)及[本次验证记录](B/第三天材料/验证记录.md)。
## A 模块第三阶段交付

A 已完成 ⑥ 预约、排队与到站管理，以及 ⑧ 场站服务公告与通知：

- 新增 10 张表、116 个字段、34 个外键、40 个 CHECK、8 个视图、14 个存储过程、13 个触发器；
- 同枪预约使用“锁枪行 + 锁定读”保证并发安全，两个连接同时预约同一枪同一时段时仅一个成功；
- 到站核验触发器自动生成车位占用；生成列唯一约束保证同车位/同车辆最多一条未释放占用；
- 预约/排队资格只能消费一次，B 开单后调用 `sp_consume_admission` 原子消费；
- 公开公告、定向停运通知、公告版本、接收人快照、通知发送/失败/阅读状态机均已实现；
- 10 张表各至少 20 条测试数据；16 项约束测试、17 项真实数据库验收、61 项 Python 单元测试全部通过。

详情见 [A 模块开发说明](docs/a/README.md)、[A 模块说明与导航](A/README.md)、[⑥预约排队设计说明](docs/a/06_reservation_queue.md)、[⑧公告通知设计说明](docs/a/08_notice.md)和[A 本机实测记录](A/第三天材料/实测/README.md)。

> A 的 `sql/A/00_local_shared_fixtures.sql` 仅用于本地联调，提供 B 场站/枪/车位/停运计划的测试夹具；B 正式种子到位后应替换，不影响 A 的表结构和业务规则。

## 当前可验证成果

④用户与会员运营已完成可独立开发部分：

- 9 张核心表均已在 `charging_platform` 创建，使用 InnoDB 与 `utf8mb4_0900_ai_ci`
- 9 张核心表各提交 20 条虚构测试数据，共 180 条
- 主键、外键、唯一约束、CHECK 约束及 ID 类型检查全部通过
- 约束测试 T01～T08 全部 PASS，9 条核心业务查询结果符合预期
- Python 可连接 MySQL 8.0.46 并识别 9/9 张核心表
- 会员等级变更使用行锁和事务，同时更新当前等级与历史记录；真实数据库回滚演示 PASS
- 车辆加入/退出车队使用车辆行锁串行化并发请求；调车事务及回滚演示 PASS
- 优惠活动使用 `Decimal` 计算固定减免和百分比折扣；100 元订单最优活动实测优惠 24 元
- ④业务线已创建 3 个实用视图和 1 个只读优惠试算存储过程，数据库验收通过
- ④最终综合回归 F01～F08 全部 PASS，核心表、约束、业务一致性和敏感字段检查正常
- 3 张跨模块表已创建；3 个主键、7 个外键、4 个唯一约束和 5 个 CHECK 均通过 I01～I06 验收
- B 的 16 张表、7 个触发器、6 个视图及 D 的 12 张表已完成 20 项集成检查，全部 PASS 且测试数据已回滚
- Python 公共连接自动执行 `SET SESSION time_zone = '+08:00'`，真实连接返回 `+08:00`
- 优惠券发放、锁定、释放和支付核销使用行锁与同一事务；真实数据库完整链路及回滚均 PASS
- D 已补齐车队月结、三级额度、用户车辆逻辑 CRUD、注册实名绑车、目标发券、全额退款审核补券和用户资金追溯；当前全仓 149 项单元测试全部通过

快速验证：

```powershell
Copy-Item .env.example .env   # 首次运行时填写本机 MySQL 密码
.\.venv\Scripts\python.exe -m app.run_membership_demo
.\.venv\Scripts\python.exe -m app.run_membership_transaction_demo
.\.venv\Scripts\python.exe -m app.run_fleet_transaction_demo
.\.venv\Scripts\python.exe -m app.run_promotion_demo
.\.venv\Scripts\python.exe -m app.run_coupon_transaction_demo
.\.venv\Scripts\python.exe tests\verify_b_structure.py
.\.venv\Scripts\python.exe -m pytest -q
```

详细说明见 [D 模块开发说明](docs/d/README.md)。

A 模块当前可验证成果：

- 10 张表均已在 `charging_platform` 创建，使用 InnoDB 与 `utf8mb4_0900_ai_ci`
- 10 张表测试数据为 20/25/20/25/20/20/21/47/20/20 条，均 ≥20
- 34 个外键、40 个 CHECK、8 个视图、14 个存储过程、13 个触发器全部创建成功
- 16 项约束/状态机/过程测试全部 PASS，7 条业务查询执行成功
- 真实数据库验收 17 项全部 PASS：结构、数据、预约→核验→占位、定向公告→发送→撤回、同枪并发
- 同枪并发演示：两个连接同时预约同一时段，一个成功、一个 `RESERVATION_GUN_OVERLAP`，清理后 0 残留
- A 模块合入时全仓 Python 单元测试共 61 项，全部通过（含 A 的持久层、服务层与错误翻译测试）；加入公共连接时区和 D 优惠券事务测试后当前全仓为 73 项

A 快速验证：

```powershell
Copy-Item .env.example .env   # 首次运行时填写本机 MySQL 密码
.\.venv\Scripts\python.exe -m app.run_reservation_demo
.\.venv\Scripts\python.exe -m app.run_notice_demo
.\.venv\Scripts\python.exe -m app.run_reservation_workflow_demo
.\.venv\Scripts\python.exe -m app.run_notice_workflow_demo
.\.venv\Scripts\python.exe -m app.run_reservation_concurrency_demo
.\.venv\Scripts\python.exe -m pytest -q
.\.venv\Scripts\python.exe tests/verify_a_module.py
```

详细说明见 [A 模块开发说明](docs/a/README.md)。

## 开发计划

| 阶段 | 目标 | 主要产出 |
| --- | --- | --- |
| Day 1 | 需求分析与概念设计 | 整体流程图、八条业务线需求说明、统一数据字典、实体/关系清单、跨模块规则、全局 E-R 图初稿 |
| Day 2 | 逻辑结构与 MySQL 建表 | 关系模式、第三范式分析、统一字段类型与约束、全部可执行 DDL、成功创建的数据库 |
| Day 3 | Python 持久层与数据库功能 | DAO/CRUD、分页与批量写入、复杂 SQL、视图、存储过程/触发器、事务与并发测试、安全设计 |
| Day 4 | 联调、报告与答辩 | 三条端到端流程联调、执行计划与优化、备份恢复说明、小组报告、个人报告、PPT、5 分钟录像 |

## 验收指标

依据课程设计任务书：

- 每张表至少 **20 条测试数据**，外键引用有效
- 编写 **5 条连接 3 个及以上关系**的复杂 SQL，覆盖多表关联、聚合与条件筛选，查看执行计划并优化
- 原有 5 条业务线每条至少设计 **3 个实用视图**
- 原有 5 条业务线每条编写 **1 个存储过程或触发器**
- 完成 RBAC、密码加盐哈希、登录失败次数限制、会话超时、敏感字段脱敏/加密与 SQL 注入防护
- 设计数据备份与恢复策略（全量/增量备份周期、恢复目标、演练方式）
- 提交小组材料（任务书、代码、完整性机制文件、答辩 PPT 与录像）及个人材料

> 待确认：新增 ⑥⑦⑧ 三条业务线是否沿用原有 5 条线的视图、存储过程/触发器数量要求，需向指导教师确认后再定稿。

## 待确认事项

以下事项需组内讨论或向指导教师确认，确认后更新数据字典与本文档：

- C 模块的最终表结构、DDL 执行顺序及 A/B/D 跨模块联调时间；A/B 结构已接入并验证
- 新增三条业务线的考核口径（视图、存储过程/触发器数量）
- 设备停运计划的唯一登记责任人（B 或 C）
- 预约迟到保留时长、叫号保留时长、排队等待过期时长与现场排队优先级
- 预约提前核验窗口（当前最多提前 30 分钟）
- 公开公告是否需要主动推送，以及通知渠道优先级与重试策略
- 车位与充电枪的映射基数
- 优惠券已按“锁券时写订单优惠、支付失败时释放、支付成功后核销”实现；部分退款不返券，全额退款经审核后补发新券且保留原核销记录；优惠规则快照仍需确认
- 应付、优惠、实收、退款、净收的金额口径及跨账期调整规则

## 协作规范

- 全组使用一个 Git 仓库，每天结束提交代码、图表与文档，保留提交记录和会议纪要
- 数据字典为字段定义的唯一来源；变更先更新字典，再改表结构和代码
- 每个实体只有一个主维护模块；跨模块通过统一编号、外键或约定接口引用
- 文档字段标注来源：任务书明确要求标“任务书”，小组设计标“小组补充”，未确认内容标“待讨论”
- 禁止抄袭；答辩时每位成员需能讲清自己负责的两条业务线、核心表、关键 SQL、约束/事务与测试结果

## 其他成员克隆与启动指南

> 面向首次加入项目的组员。以下命令均在仓库根目录执行；Windows 可使用 PowerShell 或 Git Bash，macOS / Linux 使用系统终端。

### 1. 前置环境

| 软件 | 要求 | 用途 |
| --- | --- | --- |
| Git | 任意较新版本 | 拉取代码与日常提交 |
| Python | 3.13（参考环境，建议 3.11+） | 运行持久层与测试 |
| MySQL | 8.0.46 | 本地数据库服务 |

### 2. 克隆仓库

已配置 GitHub SSH Key 时使用 SSH：

```bash
git clone git@github.com:kokozzzzzz/DataBase_Project2026.git
cd DataBase_Project2026
```

未配置 SSH 时改用 HTTPS：

```bash
git clone https://github.com/kokozzzzzz/DataBase_Project2026.git
cd DataBase_Project2026
```

### 3. 创建并激活虚拟环境

Windows PowerShell：

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
```

若提示“禁止运行脚本”，仅对当前终端会话放行：

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\.venv\Scripts\Activate.ps1
```

Windows CMD：

```bat
python -m venv .venv
.venv\Scripts\activate.bat
```

Git Bash（Windows）：

```bash
python -m venv .venv
source .venv/Scripts/activate
```

macOS / Linux：

```bash
python3 -m venv .venv
source .venv/bin/activate
```

激活成功后，终端提示符前会出现 `(.venv)`。

### 4. 安装依赖

```bash
python -m pip install --upgrade pip
pip install -r requirements.txt
```

验证依赖可导入：

```bash
python -c "import sqlalchemy, pymysql, dotenv, pytest; print('dependencies ok')"
```

### 5. 配置数据库连接

1. 启动本地 MySQL，创建全组统一数据库：

   ```sql
   CREATE DATABASE charging_platform
     DEFAULT CHARACTER SET utf8mb4
     COLLATE utf8mb4_0900_ai_ci;
   ```

2. 在仓库根目录复制示例配置，并填写本机密码：

   ```powershell
   Copy-Item .env.example .env
   ```

   `.env` 内容如下：

   ```dotenv
   DB_HOST=127.0.0.1
   DB_PORT=3306
   DB_USER=root
   DB_PASSWORD=你的密码
   DB_NAME=charging_platform
   ```

3. `.env` 已被 `.gitignore` 忽略，**不要提交**，也不要把密码写进代码或文档。变量名由 `app/database/config.py` 统一读取。公共连接建立时会自动设置会话时区为 `+08:00`，不依赖 MySQL 服务器的 `SYSTEM` 默认时区。

### 6. 初始化数据库结构

> `sql/A/07_verify.sql` 是**只读验收脚本**，不会创建表、视图、过程或触发器。执行后 A 的对象数为 0，说明 A 的结构脚本尚未执行或在前置依赖处失败，不是 `07_verify.sql` 的问题。

**首次空库（推荐，一条命令）**：在仓库根目录执行

```powershell
cmd /c "mysql -h127.0.0.1 -P3306 -uroot -p --default-character-set=utf8mb4 < sql\00_install_all.sql"
```

或在 MySQL 客户端（当前目录为仓库根目录）中执行 `SOURCE sql/00_install_all.sql;`。脚本固定了以下依赖顺序，并带空库守卫（检测到已有表会中止，避免重复建表）：

1. D ④ 核心表；
2. B ① ② 结构、设施触发器、视图、交易保护触发器；
3. D ④ 跨模块表；
4. A ⑥ ⑧ 结构、触发器、存储过程、视图；
5. D ④ 视图/过程、D ⑤ 结算五表。

**已有部分模块的库（只补装缺失模块）**：

- 若 A 的表、视图、过程、触发器均为 0：先确认 D 的 `user`/`vehicle` 与 B 的 `station`/`charging_gun`/`parking_space`/`equipment_outage_plan`/`charging_order` 已存在，然后执行：

  ```sql
  SOURCE sql/A/00_preflight.sql;     -- 定位缺项；A03～A06 为 0 时给出明确提示
  SOURCE sql/A/00_install_a.sql;     -- 只装 A 结构，不重复安装 D/B
  SOURCE sql/A/07_verify.sql;        -- 未装 A 种子时 A07 行数项会 FAIL，结构与对象项应 PASS
  ```

- 不要重复执行 `sql/D/04_membership_core.sql`、`sql/B/01_schema.sql` 或 `sql/A/01_schema.sql`；重复 `CREATE TABLE` 会报 already exists。

**可选的本地联调种子**（D 核心 20 行 + A 夹具 + A 每表 ≥20 行）：

```sql
SOURCE sql/00_seed_all.sql;
```

**生成 B 固定交易数据（D ⑤ 结算实测依赖）**：

```powershell
.\.venv\Scripts\python.exe -m app.seed_b_integration --commit --output ..\B_本机实测\固定测试集.json
```

预期生成 40 笔已出账且足额支付订单、100 条支付、20 条次月退款。随后执行 D 的结算数据预检，`DP03` 应为 40（PASS），`DP06` 应为 20（PASS）：

```powershell
cmd /c "mysql -h127.0.0.1 -P3306 -uroot -p --default-character-set=utf8mb4 charging_platform < sql\D\05_settlement_seed_preflight.sql"
```

**生成 D⑤正式结算数据**（仅限五张结算表为空时执行一次）：

```powershell
.\.venv\Scripts\python.exe -m app.run_sql --file sql/D/05_settlement_seed.sql --commit
.\.venv\Scripts\python.exe -m app.run_sql --file sql/D/05_settlement_seed_verify.sql
```

预期生成 40 个结算单、60 条结算明细、20 条差异、40 条双方确认和 40 条发票记录；`SD01～SD07` 全部 `PASS`，净结算总额为 `288.60`。

**综合验收**：

```sql
SOURCE sql/00_verify_all.sql;
```

> `sql/D/04_membership_final_verify.sql` 只适用于“仅 D 核心种子”的阶段；执行 B 固定测试集后 `user`/`vehicle`/`promotion` 行数会超过 20，该脚本会按设计报 FAIL。全模块联调后请使用 `sql/00_verify_all.sql`。

### 7. 设置 Git 身份并同步代码

首次克隆后设置提交身份：

```bash
git config user.name "你的姓名"
git config user.email "你的邮箱"
```

每天开始工作前拉取最新代码，结束前提交并推送：

```bash
git pull
# 开发与测试
git add .
git commit -m "feat: 完成 XXX"
git push
```

### 8. 完成检查

- [ ] 仓库克隆成功，`docs/`、`target/`、`requirements.txt` 均已拉取
- [ ] 虚拟环境已激活，终端提示符前有 `(.venv)`
- [ ] `pip install -r requirements.txt` 无报错
- [ ] `sqlalchemy`、`pymysql`、`dotenv`、`pytest` 均可正常导入
- [ ] 本地 MySQL 已启动，`.env` 已配置且未被 Git 跟踪
- [ ] `git config user.name` 与 `user.email` 已设置

> 依赖版本变更需全组确认后统一修改 `requirements.txt` 并提交，不要各自在本地升级；遇到环境报错先在群里同步完整错误信息。

```bash
#简化版流程（部分）
python -m venv .venv #创建venv虚拟环境
.\. venv\Scripts\Activate.ps1 #进入venv虚拟环境
pip install -r requirements.txt #下载requirements.txt中的依赖

如果你pip了其他依赖，请执行：
pip freeze > requirements.txt #将它们覆盖写入到 requirements.txt 文件中
```

```bash
#简化版github合作流程
git switch dev #切换至dev分支
git pull origin dev #拉取最新代码
git switch -c xxx(例如：koko) #创建并切换到你的新分支

……进行开发

git add . #添加修改
git commit -m "feat:完成xxx功能的具体描述" #提交
git push -u origin koko #推送到远程github

通过pull request合并分支到dev上，
写标题：例如 feat: 完成xxx功能。
写描述：简单写两句改了什么，怎么测试的。
选 Reviewer：选择你的队友或组长来审查代码。

合并完成后，页面上会出现一个 "Delete branch" 按钮，点它，删除github上这个功能分支，保持仓库干净。

回到你的电脑终端：
git switch dev
git pull origin dev

git branch -d koko #删除该功能分支

循环回第一步

```

