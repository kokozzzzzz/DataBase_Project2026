# D同学负责模块：用户会员运营与结算对账

> **2026-11-23更新**：D④核心、用户运营与退款补券事务已完成，D⑤结构、视图、过程和正式测试数据均已在 MySQL 8.0.46 验收。历史集成规则见[集成修正与交接](../集成修正_2026-11-21/README.md)。

## 1. 负责人

D同学

## 2. 负责业务线

- ④ 用户与会员运营
- ⑤ 结算与对账

## 3. 当前状态

| 业务线 | 状态 | 说明 |
| --- | --- | --- |
| ④ 用户与会员运营 | 12 张表及核心事务已实测 | 9 张核心表、3 张跨模块表、Python 持久层、会员/车队/优惠券事务和 20 项 B–D 集成检查均已通过 |
| ⑤ 结算与对账 | 核心数据库与 Python 事务服务已完成 | 结构、正式数据、复杂查询、差异调整、普通开票与红字冲销均通过单元测试和真实数据库回滚演示 |

运行环境：MySQL 8.0.46 / InnoDB / utf8mb4，开发语言 Python（PyMySQL + python-dotenv）。

## 4. 交付物位置

| 路径 | 内容 |
| --- | --- |
| `docs/d/D_04_05_data_dictionary.xlsx` | ④⑤ 业务线数据字典 |
| `docs/d/FINAL_ACCEPTANCE.md` | D④⑤最终 SQL/Python/真实事务验收清单及答辩演示顺序 |
| `sql/D/00_verify_d_all.sql` | D④⑤只读统一验收入口，最终输出 `DF01～DF10` |
| `docs/d/04_membership.md` | ④ 用户与会员运营 DDL 说明与执行顺序 |
| `docs/d/05_settlement.md` | ⑤ 结算与对账定稿设计、金额口径、状态流转、索引与实施计划 |
| `sql/D/05_settlement_preflight.sql` | ⑤ 建表前只读检查：B 依赖、编号类型、引擎排序规则和目标表不存在性 |
| `sql/D/05_settlement_schema.sql` | ⑤ 五张正式业务表 DDL，不含删除语句，依赖 B 的运营商、场站、订单、支付和退款表 |
| `sql/D/05_settlement_upgrade_signed_payable.sql` | ⑤ 已有库升级：允许只有跨期退款的账期形成负净结算额，不删除业务数据 |
| `sql/D/05_settlement_verify.sql` | ⑤ 表数量、字段、约束、外键、类型、生成列和引擎的只读验收脚本 |
| `sql/D/05_settlement_views.sql` | ⑤ 结算单汇总、逐订单结算、待处理差异三个 `SQL SECURITY INVOKER` 视图 |
| `sql/D/05_settlement_views_verify.sql` | ⑤ 视图数量、字段、调用者权限和敏感字段暴露检查 |
| `sql/D/05_settlement_procedure.sql` | ⑤ 生成账期结算单、足额支付基础明细和跨期退款调整的事务内存储过程 |
| `sql/D/05_settlement_procedure_verify.sql` | ⑤ 过程元数据、幂等生成、负向退款调整、视图读取和统一回滚验收 |
| `sql/D/05_settlement_seed_preflight.sql` | ⑤ 测试数据前只读检查：现有 B 订单、费用分段、成功支付、退款及可结算订单规模 |
| `sql/D/05_settlement_seed.sql` | ⑤ 正式联调种子：40 个账期、60 条明细、20 条差异、40 条确认和 40 条发票；由调用方控制提交 |
| `sql/D/05_settlement_seed_verify.sql` | ⑤ 正式数据只读验收：规模、唯一性、双方确认、红字发票及财务汇总 `SD01～SD07` |
| `sql/D/05_settlement_business_queries.sql` | ⑤ 六条连接至少 3 个关系的只读业务查询及 `Q07` 验收摘要 |
| `sql/D/05_settlement_explain.sql` | ⑤ 五条关键查询的 `EXPLAIN ANALYZE` 执行计划 |
| `app/database/settlement_repository.py` | ⑤ 结算汇总和未解决差异的只读分页持久层 |
| `app/services/settlement_service.py` | ⑤ 双方确认与后续账期 `OTHER_ADJUSTMENT` 事务服务 |
| `app/run_settlement_adjustment_demo.py` | ⑤ 追加确认、应用跨期调整和统一回滚的真实数据库演示 |
| `tests/test_settlement_repository.py` | ⑤ 持久层参数、分页、动作值域和敏感字段单元测试 |
| `tests/test_settlement_service.py` | ⑤ 确认状态、双方同意、目标账期与调整事务单元测试 |
| `app/services/settlement_invoice_service.py` | ⑤ 普通发票开具、净额上限与分次红字冲销事务服务 |
| `app/run_settlement_invoice_demo.py` | ⑤ 普通票→红字票→统一回滚的真实数据库演示 |
| `tests/test_settlement_invoice_service.py` | ⑤ 开票状态、金额上限、密文类型、红冲累计额和时间顺序单元测试 |
| `docs/d/evidence/05_b_formal_seed_local_20261122.json` | MySQL 8.0.46 本机 B-FORMAL-v1 提交结果及实际订单编号证据 |
| `sql/D/04_membership_core.sql` | 9 张核心表 DDL，不依赖 B 模块 |
| `sql/D/04_membership_integration.sql` | 3 张跨模块表 DDL，需 B 创建 `station`、`charging_order` 后执行 |
| `sql/D/04_membership_integration_verify.sql` | 跨模块表、B 外键、约束与类型的只读验收 |
| `sql/D/04_membership_integration_data_verify.sql` | B-FORMAL-v1 生成的活动场站、优惠券及核销数据只读验收 `DI01～DI06` |
| `sql/D/04_membership_verify.sql` | 只读 DDL 验证脚本 |
| `sql/D/04_membership_seed_core.sql` | 9 张核心表各 20 条虚构测试数据，需手动 COMMIT |
| `sql/D/04_membership_constraint_tests.sql` | 唯一、非负、外键、时间、状态等约束测试，测试后统一 ROLLBACK |
| `sql/D/04_membership_business_queries.sql` | 17 条只读业务查询，含车队月结、三级额度、目标人群、活动核销率、用户资金和结算开票追溯 |
| `sql/D/04_membership_views.sql` | 3 个核心业务视图，使用调用者权限且不暴露敏感检索字段 |
| `sql/D/04_membership_views_verify.sql` | 视图数量、敏感字段和结果行数的只读验收 |
| `sql/D/04_membership_procedure.sql` | 只读优惠试算存储过程，覆盖两类优惠、门槛和封顶 |
| `sql/D/04_membership_procedure_verify.sql` | 存储过程元数据、计算结果和表行数验收 |
| `sql/D/04_membership_final_verify.sql` | ④独立核心部分的只读综合回归脚本 |
| `app/database/` | 连接配置、连接上下文、只读持久层 |
| `app/services/membership_service.py` | 会员等级变更事务服务 |
| `app/services/fleet_service.py` | 车辆加入/退出车队事务服务 |
| `app/database/membership_repository.py` | 用户会员、充电资金、结算开票追溯，以及车队月结和三级额度持久层 |
| `app/run_fleet_monthly_demo.py` | 使用正式订单临时建立车队关系，验证月结与额度后统一回滚 |
| `app/services/promotion_service.py` | 固定减免、百分比折扣与最优活动计算服务 |
| `app/services/coupon_service.py` | 优惠券发放、锁定、释放、支付核销及全额退款审核补发事务服务 |
| `app/services/customer_service.py` | 注册实名绑车、用户/车辆逻辑CRUD和用户关闭事务服务 |
| `app/services/targeted_coupon_service.py` | 活动与用户行锁、总量/限领校验及 `executemany` 批量发券 |
| `app/run_customer_coupon_demo.py` | 注册绑车、新人券、两人批量发券、逻辑关闭和统一回滚演示 |
| `app/run_membership_demo.py` | 连接与持久层演示入口 |
| `app/run_membership_transaction_demo.py` | 真实数据库事务回滚演示入口 |
| `app/run_fleet_transaction_demo.py` | 真实数据库调车事务回滚演示入口 |
| `app/run_promotion_demo.py` | 全场活动筛选与最优优惠只读演示入口 |
| `app/run_coupon_transaction_demo.py` | 发券→锁券→支付→核销→全额退款补发的真实数据库回滚演示 |
| `tests/` | 配置、持久层、事务服务的单元测试（不连接真实数据库） |

## 5. 已完成验收

截至 2026-11-22，④业务线核心部分、B–D 跨模块结构和⑤正式结算数据已取得以下实测结果：

| 检查项 | 结果 |
| --- | --- |
| MySQL 环境 | 8.0.46，数据库 `charging_platform` |
| 核心 DDL | 9 张表创建成功，均为 InnoDB / `utf8mb4_0900_ai_ci` |
| 完整性约束 | 9 个主键、10 个外键、7 个唯一约束、28 个 CHECK 约束，检查全部 PASS |
| ID 类型 | 19 个主外键 ID 字段均为 `BIGINT UNSIGNED` |
| 测试数据 | 9 张核心表各 20 条，共 180 条，已 COMMIT |
| 约束与回滚 | T01～T08 全部 PASS，回滚后各表仍为 20 条 |
| 核心业务查询 | Q01～Q17 执行成功；覆盖会员、车辆、车队月结、额度、人群、核销率、用户资金和开票追溯 |
| Python 真实连接 | MySQL 8.0.46 / `charging_platform` / 会话时区 `+08:00` / 核心表 9/9 |
| 会员等级事务 | 事务内用户等级和历史同时变化，ROLLBACK 后恢复原值，PASS |
| 车队车辆事务 | 事务内退出 60001、加入 60002 且仅一条 ACTIVE；ROLLBACK 后恢复 60001，PASS |
| 车队月结与额度 | 2 笔正式订单动态汇总为 32.000 kWh、应付 23.20 元；额度使用与账单一致，回滚后临时关系和额度记录均为 0，PASS |
| 优惠计算 | 100 元订单匹配 20 个全场活动；最优活动 40019，优惠 24 元、实付 76 元 |
| 数据库对象 | 3 个业务视图、1 个 `READS SQL DATA` / `INVOKER` 存储过程，验收通过 |
| 最终综合回归 | F01～F08 全部 PASS；表、行数、约束、车队唯一性、等级一致性和敏感字段均正常 |
| Python 单元测试 | 全仓 149 passed（包含车队月结、用户车辆逻辑CRUD、目标筛选、批量发券、退款补券和用户资金查询测试） |
| 用户运营事务 | 3组注册实名绑车、1张新人券、2张批量定向券、资料更新和逻辑关闭均PASS；回滚后用户、车辆、券均为0 |
| 跨模块 DDL | `promotion_station`、`coupon`、`coupon_redemption` 创建成功，均为 InnoDB / `utf8mb4_0900_ai_ci` |
| 跨模块约束 | 3 个主键、7 个外键、4 个唯一约束、5 个 CHECK；I01～I06 全部 PASS |
| ④跨模块正式数据 | 活动场站、优惠券、券核销各 20 行；用户、订单、场站、金额和时间一致性 `DI01～DI06` 全部 PASS |
| B–D 联调 | B 16 张表、D 12 张表、7 个 B 触发器、6 个 B 视图及优惠券跨模块引用等共 20 项检查全部 PASS，测试事务已回滚 |
| 优惠券事务 | 发券、锁券、支付核销、全额退款和幂等补券均 PASS；回滚后券、订单、运营商、支付和退款记录均为 0 |
| ⑤核心 DDL | 5 张表创建成功，均为 InnoDB / `utf8mb4_0900_ai_ci`，共 83 个字段 |
| ⑤完整性约束 | 5 个主键、13 个外键、7 个唯一约束、20 个 CHECK，S01～S10 全部 PASS |
| ⑤跨模块接口 | 6 个 B 外键、7 个 D 内部外键、所有编号类型及 2 个生成列均验收通过 |
| ⑤正式交易输入 | B-FORMAL-v1 已提交；40 笔可结算订单、80 条成功支付和 20 笔次月退款，DP03/DP06 均 PASS |
| ⑤跨期退款约束 | 结算单净额允许为负；正数表示平台应付，负数表示运营商返还或结转；升级 U01/U02 与结构 S11 均 PASS |
| ⑤业务视图 | 3 个视图均为 `INVOKER`；字段数量 28/36/23，确认人姓名和纳税人识别号密文均未暴露 |
| ⑤结算生成过程 | 11月2条基础订单应结16.64元；相同参数复用结算单；12月退款3.00元形成-2.21元调整；P01～P06全部PASS并回滚 |
| ⑤正式测试数据 | 结算单 40、明细 60、差异 20、双方确认 40、发票 40；`SD01～SD07` 全部 PASS，净结算 288.60 元 |
| ⑤多表业务查询 | Q01～Q06 全部执行成功且均连接至少 3 个关系；Q07 为 40/40/20/20/20，PASS |
| ⑤执行计划 | E01～E05 均成功；账期、明细、订单追溯、差异确认和发票链路使用既有主键或复合索引，无需新增索引 |
| ⑤对账调整事务 | 事务内追加最新确认、生成 `OTHER_ADJUSTMENT=-0.50` 并把差异更新为 `RESOLVED`；回滚后正式数据完全恢复，PASS |
| ⑤开票红冲事务 | 事务内普通票 2.00 元、红字票 0.50 元，净开票 7.00→8.50 且原票变为 `RED_FLUSHED`；回滚后恢复 7.00，PASS |

## 6. 数据库实体

### ④ 用户与会员运营（12 张表）

核心表（9 张，`04_membership_core.sql`）：

- `membership_level`（新增）
- `user`
- `vehicle`
- `membership_record`
- `promotion`
- `enterprise_customer`
- `fleet`
- `fleet_vehicle`
- `fleet_quota_record`

跨模块表（3 张，`04_membership_integration.sql`）：

- `promotion_station`（新增，关联 B 的 `station`）
- `coupon`
- `coupon_redemption`（关联 B 的 `charging_order`）

### ⑤ 结算与对账（已建表并通过验收的 5 张表）

- `settlement_statement`
- `settlement_detail`
- `reconciliation_difference`
- `reconciliation_confirmation`
- `invoice_record`

## 7. 已确定的设计方案

1. 会员等级采用独立字典表 `membership_level`；等级变更同时更新 `user.level_id` 并写入 `membership_record` 历史。
2. 企业车队月结采用 SQL 动态汇总，不新增月结单表。
3. 优惠活动与场站采用多对多关联 `promotion_station`。
4. 金额字段统一采用 `DECIMAL`，不使用 `FLOAT`/`DOUBLE`。
5. 业务主键统一 `BIGINT UNSIGNED`，与 B 当前数据字典一致；`user` 表名在 SQL 中统一写作 `` `user` ``。
6. 手机号、车牌、统一社会信用代码保存密文，查重使用 HMAC-SHA256 摘要并建唯一约束。
7. 一个优惠券最多成功核销一次、一笔订单最多使用一张券，分别由两个唯一约束保证；券状态与时间字段由 CHECK 约束保持一致。
8. `fleet_vehicle` 使用代理主键保存加入/退出历史；同一车辆仅有一条 ACTIVE 关联的规则由业务事务或触发器保证。
9. `promotion.total_quantity` 用 `NULL` 表示不限量，避免与 `0` 语义混淆。
10. 会员等级变更事务使用 `SELECT ... FOR UPDATE` 锁定用户行，按等级 `sort_order` 自动判定 `UPGRADE`/`DOWNGRADE`/`ADJUST`，两步写入由调用方统一提交或回滚。
11. 车队车辆事务统一先锁定 `vehicle` 主记录，再检查或更新有效关系，保证同一车辆最多一条 `ACTIVE` 车队关系；退出只关闭关系，不删除历史。
12. `PERCENTAGE` 表示实付比例，例如 `0.80` 表示八折；优惠金额为订单金额的 20%，并受 `max_discount_amount` 封顶限制。
13. 跨表业务校验（活动为 `SELECTED` 时至少关联一个场站、券是否属于订单用户等）放在事务性业务代码或存储过程中。
14. Python 公共连接通过 `init_command` 在任何业务 SQL 执行前设置 `SET SESSION time_zone = '+08:00'`，统一优惠、订单与结算的时间口径。
15. 优惠券事务按订单行→券行的固定顺序加锁；锁券同时写入订单优惠，支付失败释放时清零，成功支付足额后才更新为 `USED` 并写核销记录。

## 8. 执行与运行方式

> 全组空库优先使用仓库根目录的 `sql/00_install_all.sql`（含 D 核心、D 跨模块、D 结算五表，以及 B/A 结构）；D 模块也可按下述顺序单独安装。

在仓库根目录登录 MySQL 后，核心部分按顺序执行：

```sql
SOURCE sql/D/04_membership_core.sql;
SOURCE sql/D/04_membership_verify.sql;          -- 预期 9 张核心表校验全部 PASS
SOURCE sql/D/04_membership_seed_core.sql;       -- 检查末尾统计后手动 COMMIT
SOURCE sql/D/04_membership_constraint_tests.sql;
SOURCE sql/D/04_membership_business_queries.sql;
SOURCE sql/D/04_membership_views.sql;
SOURCE sql/D/04_membership_views_verify.sql;
SOURCE sql/D/04_membership_procedure.sql;        -- 首次成功后不要重复执行
SOURCE sql/D/04_membership_procedure_verify.sql;
SOURCE sql/D/04_membership_final_verify.sql;
```

B 的 `station`、`charging_order` 创建并确认后，执行跨模块表及只读验收：

```sql
SOURCE sql/D/04_membership_integration.sql;      -- 依赖 station、charging_order
SOURCE sql/D/04_membership_integration_verify.sql;
```

B 的 `operator`、`station`、`charging_order`、`payment_record`、`refund_record` 已建好后，⑤首次建表按顺序执行：

```sql
SOURCE sql/D/05_settlement_preflight.sql;       -- P01～P04 必须 PASS，P05 必须为空
SOURCE sql/D/05_settlement_schema.sql;          -- 首次创建五张表，不可重复执行；本机已完成
SOURCE sql/D/05_settlement_verify.sql;          -- 本机 S01～S11 已全部 PASS
SOURCE sql/D/05_settlement_views.sql;           -- 可重复执行，创建或更新 3 个 INVOKER 视图
SOURCE sql/D/05_settlement_views_verify.sql;    -- V01～V04 PASS，并显示当前视图行数
SOURCE sql/D/05_settlement_procedure.sql;       -- 创建或更新结算生成过程，不自动提交业务事务
SOURCE sql/D/05_settlement_procedure_verify.sql; -- P01～P06 PASS，测试数据最终 ROLLBACK
```

B-FORMAL-v1 已提交且 `DP03=40`、`DP06=20` 后，在仓库根目录生成并验收⑤正式数据：

```powershell
.\.venv\Scripts\python.exe -m app.run_sql --file sql/D/05_settlement_seed_preflight.sql
.\.venv\Scripts\python.exe -m app.run_sql --file sql/D/05_settlement_seed.sql --commit
.\.venv\Scripts\python.exe -m app.run_sql --file sql/D/05_settlement_seed_verify.sql
.\.venv\Scripts\python.exe -m app.run_sql --file sql/D/05_settlement_business_queries.sql
.\.venv\Scripts\python.exe -m app.run_sql --file sql/D/05_settlement_explain.sql
```

`05_settlement_seed.sql` 只允许在五张结算表均为空时正式执行一次。不带 `--commit` 可用于预演并在连接关闭后回滚；确认预演统计正确后再带 `--commit` 持久化。

已按旧版 DDL 建表的数据库需在生成结算数据前执行一次：

```sql
SOURCE sql/D/05_settlement_upgrade_signed_payable.sql; -- U01/U02 PASS；不可重复执行
SOURCE sql/D/05_settlement_verify.sql;                  -- S01～S11 PASS
```

> 执行 B 固定测试集后，`04_membership_final_verify.sql` 会因 `user`/`vehicle`/`promotion` 行数超过 20、B 测试用户无会员等级而按设计报 FAIL；该脚本只用于 D 核心种子阶段。全模块联调请使用仓库根目录的 `sql/00_verify_all.sql`。

Python 侧：

```powershell
python -m pip install -r requirements.txt
Copy-Item .env.example .env   # 首次运行时填写本机 MySQL 密码
.\.venv\Scripts\python.exe -m app.run_membership_demo
.\.venv\Scripts\python.exe -m app.run_membership_transaction_demo
.\.venv\Scripts\python.exe -m app.run_fleet_transaction_demo
.\.venv\Scripts\python.exe -m app.run_fleet_monthly_demo
.\.venv\Scripts\python.exe -m app.run_customer_coupon_demo
.\.venv\Scripts\python.exe -m app.run_promotion_demo
.\.venv\Scripts\python.exe -m app.run_coupon_transaction_demo
.\.venv\Scripts\python.exe -m app.run_settlement_adjustment_demo
.\.venv\Scripts\python.exe -m app.run_settlement_invoice_demo
.\.venv\Scripts\python.exe tests\verify_b_structure.py
.\.venv\Scripts\python.exe -m pytest -q
```

`.env` 已被 Git 忽略，不得提交真实数据库密码。事务演示会临时修改用户 10001，在验证后主动回滚，不保留演示记录。

## 9. 待确认事项

1. `operator`、`station`、`charging_order`、`payment_record`、`refund_record` 的正式字段和编号类型已经按 B 结构确认。
2. 订单、支付和退款统一使用 `+08:00` 会话时区；支付和退款分别按各自 `occurred_at` 进入半开账期。正式分成费率仍需由老师或合同参数确认。
3. 锁券、支付失败释放和支付成功核销已实现；取消订单可调用释放操作。部分退款不返券；全额退款经人工审核后补发新券，原券及核销记录不修改。
4. `user.balance` 是当前余额而非流水；当前结构提供订单支付退款聚合，不提供虚构的余额明细。`invoice_record` 属于运营商结算发票，仅提供订单到结算开票的管理追溯。
5. 确认已发券是否保存优惠规则快照，以及是否增加按会员等级配置定向人群的关联表。
6. 企业车队已支持金额、电量和订单次数额度；账期按订单 `confirmed_at`、历史车队归属按订单 `starts_at` 统计。合同实际采用的额度类型和上限仍由业务配置决定。
7. 确认会员等级及其权益的最终定义（当前仅字典表，无权益明细表）。
8. 3 张跨模块表已由 B-FORMAL-v1 各生成 20 条正式联调数据，`DI01～DI06` 全部 PASS。
9. ⑤差异确认、后续账期调整、普通开票和红字冲销事务服务已通过 20 项单元测试及两条真实数据库回滚演示；⑤核心开发完成。
