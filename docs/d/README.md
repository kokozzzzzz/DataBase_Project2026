# D同学负责模块：用户会员运营与结算对账

## 1. 负责人

D同学

## 2. 负责业务线

- ④ 用户与会员运营
- ⑤ 结算与对账

## 3. 当前状态

| 业务线 | 状态 | 说明 |
| --- | --- | --- |
| ④ 用户与会员运营 | 12 张表及核心事务已实测 | 9 张核心表、3 张跨模块表、Python 持久层、会员/车队/优惠券事务和 20 项 B–D 集成检查均已通过 |
| ⑤ 结算与对账 | 5 张表已建并通过结构验收 | MySQL 8.0.46 实测 S01～S10 全部 PASS；5 主键、13 外键、7 唯一、20 CHECK、2 个生成列均符合定稿字典 |

运行环境：MySQL 8.0.46 / InnoDB / utf8mb4，开发语言 Python（PyMySQL + python-dotenv）。

## 4. 交付物位置

| 路径 | 内容 |
| --- | --- |
| `docs/d/D_04_05_data_dictionary.xlsx` | ④⑤ 业务线数据字典 |
| `docs/d/04_membership.md` | ④ 用户与会员运营 DDL 说明与执行顺序 |
| `docs/d/05_settlement.md` | ⑤ 结算与对账定稿设计、金额口径、状态流转、索引与实施计划 |
| `sql/D/05_settlement_preflight.sql` | ⑤ 建表前只读检查：B 依赖、编号类型、引擎排序规则和目标表不存在性 |
| `sql/D/05_settlement_schema.sql` | ⑤ 五张正式业务表 DDL，不含删除语句，依赖 B 的运营商、场站、订单、支付和退款表 |
| `sql/D/05_settlement_verify.sql` | ⑤ 表数量、字段、约束、外键、类型、生成列和引擎的只读验收脚本 |
| `sql/D/05_settlement_seed_preflight.sql` | ⑤ 测试数据前只读检查：现有 B 订单、费用分段、成功支付、退款及可结算订单规模 |
| `sql/D/04_membership_core.sql` | 9 张核心表 DDL，不依赖 B 模块 |
| `sql/D/04_membership_integration.sql` | 3 张跨模块表 DDL，需 B 创建 `station`、`charging_order` 后执行 |
| `sql/D/04_membership_integration_verify.sql` | 跨模块表、B 外键、约束与类型的只读验收 |
| `sql/D/04_membership_verify.sql` | 只读 DDL 验证脚本 |
| `sql/D/04_membership_seed_core.sql` | 9 张核心表各 20 条虚构测试数据，需手动 COMMIT |
| `sql/D/04_membership_constraint_tests.sql` | 唯一、非负、外键、时间、状态等约束测试，测试后统一 ROLLBACK |
| `sql/D/04_membership_business_queries.sql` | 9 条核心业务只读查询与验收摘要 |
| `sql/D/04_membership_views.sql` | 3 个核心业务视图，使用调用者权限且不暴露敏感检索字段 |
| `sql/D/04_membership_views_verify.sql` | 视图数量、敏感字段和结果行数的只读验收 |
| `sql/D/04_membership_procedure.sql` | 只读优惠试算存储过程，覆盖两类优惠、门槛和封顶 |
| `sql/D/04_membership_procedure_verify.sql` | 存储过程元数据、计算结果和表行数验收 |
| `sql/D/04_membership_final_verify.sql` | ④独立核心部分的只读综合回归脚本 |
| `app/database/` | 连接配置、连接上下文、只读持久层 |
| `app/services/membership_service.py` | 会员等级变更事务服务 |
| `app/services/fleet_service.py` | 车辆加入/退出车队事务服务 |
| `app/services/promotion_service.py` | 固定减免、百分比折扣与最优活动计算服务 |
| `app/services/coupon_service.py` | 优惠券发放、锁定、释放和成功支付核销事务服务 |
| `app/run_membership_demo.py` | 连接与持久层演示入口 |
| `app/run_membership_transaction_demo.py` | 真实数据库事务回滚演示入口 |
| `app/run_fleet_transaction_demo.py` | 真实数据库调车事务回滚演示入口 |
| `app/run_promotion_demo.py` | 全场活动筛选与最优优惠只读演示入口 |
| `app/run_coupon_transaction_demo.py` | 发券→锁券→支付→核销的真实数据库回滚演示 |
| `tests/` | 配置、持久层、事务服务的单元测试（不连接真实数据库） |

## 5. 已完成验收

截至当前提交前，④业务线核心部分及 B–D 跨模块结构已取得以下实测结果：

| 检查项 | 结果 |
| --- | --- |
| MySQL 环境 | 8.0.46，数据库 `charging_platform` |
| 核心 DDL | 9 张表创建成功，均为 InnoDB / `utf8mb4_0900_ai_ci` |
| 完整性约束 | 9 个主键、10 个外键、7 个唯一约束、28 个 CHECK 约束，检查全部 PASS |
| ID 类型 | 19 个主外键 ID 字段均为 `BIGINT UNSIGNED` |
| 测试数据 | 9 张核心表各 20 条，共 180 条，已 COMMIT |
| 约束与回滚 | T01～T08 全部 PASS，回滚后各表仍为 20 条 |
| 核心业务查询 | Q01～Q09 执行成功；车辆有效车队冲突为 0，会员当前等级与最新历史全部 MATCH |
| Python 真实连接 | MySQL 8.0.46 / `charging_platform` / 会话时区 `+08:00` / 核心表 9/9 |
| 会员等级事务 | 事务内用户等级和历史同时变化，ROLLBACK 后恢复原值，PASS |
| 车队车辆事务 | 事务内退出 60001、加入 60002 且仅一条 ACTIVE；ROLLBACK 后恢复 60001，PASS |
| 优惠计算 | 100 元订单匹配 20 个全场活动；最优活动 40019，优惠 24 元、实付 76 元 |
| 数据库对象 | 3 个业务视图、1 个 `READS SQL DATA` / `INVOKER` 存储过程，验收通过 |
| 最终综合回归 | F01～F08 全部 PASS；表、行数、约束、车队唯一性、等级一致性和敏感字段均正常 |
| Python 单元测试 | 全仓 73 passed（新增 9 项优惠券事务测试） |
| 跨模块 DDL | `promotion_station`、`coupon`、`coupon_redemption` 创建成功，均为 InnoDB / `utf8mb4_0900_ai_ci` |
| 跨模块约束 | 3 个主键、7 个外键、4 个唯一约束、5 个 CHECK；I01～I06 全部 PASS |
| B–D 联调 | B 16 张表、D 12 张表、7 个 B 触发器、6 个 B 视图及优惠券跨模块引用等共 20 项检查全部 PASS，测试事务已回滚 |
| 优惠券事务 | 发券、锁券、订单优惠、成功支付和核销均 PASS；回滚后券、订单、运营商和支付记录均为 0 |
| ⑤核心 DDL | 5 张表创建成功，均为 InnoDB / `utf8mb4_0900_ai_ci`，共 83 个字段 |
| ⑤完整性约束 | 5 个主键、13 个外键、7 个唯一约束、20 个 CHECK，S01～S10 全部 PASS |
| ⑤跨模块接口 | 6 个 B 外键、7 个 D 内部外键、所有编号类型及 2 个生成列均验收通过 |
| ⑤初始数据状态 | 5 张新表均为 0 行，等待测试数据阶段 |

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
SOURCE sql/D/05_settlement_verify.sql;          -- 本机 S01～S10 已全部 PASS
```

> 执行 B 固定测试集后，`04_membership_final_verify.sql` 会因 `user`/`vehicle`/`promotion` 行数超过 20、B 测试用户无会员等级而按设计报 FAIL；该脚本只用于 D 核心种子阶段。全模块联调请使用仓库根目录的 `sql/00_verify_all.sql`。

Python 侧：

```powershell
python -m pip install -r requirements.txt
Copy-Item .env.example .env   # 首次运行时填写本机 MySQL 密码
.\.venv\Scripts\python.exe -m app.run_membership_demo
.\.venv\Scripts\python.exe -m app.run_membership_transaction_demo
.\.venv\Scripts\python.exe -m app.run_fleet_transaction_demo
.\.venv\Scripts\python.exe -m app.run_promotion_demo
.\.venv\Scripts\python.exe -m app.run_coupon_transaction_demo
.\.venv\Scripts\python.exe tests\verify_b_structure.py
.\.venv\Scripts\python.exe -m pytest -q
```

`.env` 已被 Git 忽略，不得提交真实数据库密码。事务演示会临时修改用户 10001，在验证后主动回滚，不保留演示记录。

## 9. 待确认事项

1. `operator`、`station`、`charging_order`、`payment_record`、`refund_record` 的正式字段和编号类型已经按 B 结构确认。
2. 订单、支付和退款统一使用 `+08:00` 会话时区；支付和退款分别按各自 `occurred_at` 进入半开账期。正式分成费率仍需由老师或合同参数确认。
3. 锁券、支付失败释放和支付成功核销已实现；取消订单可调用释放操作，退款后是否返券仍需确认。
4. 确认已发券是否保存优惠规则快照，以及是否增加按会员等级配置定向人群的关联表。
5. 确认企业车队额度的计量单位、周期和月结统计口径。
6. 确认会员等级及其权益的最终定义（当前仅字典表，无权益明细表）。
7. 3 张跨模块表尚未准备永久测试数据；需在 B 的正式测试数据编号稳定后各补足 20 条。
8. ⑤ 五表已在 MySQL 8.0.46 创建，S01～S10 全部 PASS；下一步准备每表至少 20 条测试数据及事务回滚测试。
