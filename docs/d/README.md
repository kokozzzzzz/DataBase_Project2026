# D同学负责模块：用户会员运营与结算对账

## 1. 负责人

D同学

## 2. 负责业务线

- ④ 用户与会员运营
- ⑤ 结算与对账

## 3. 当前状态

| 业务线 | 状态 | 说明 |
| --- | --- | --- |
| ④ 用户与会员运营 | 核心部分已实现并实测 | 9 张独立核心表、测试数据、约束测试、业务查询、Python 持久层、会员等级事务和车队车辆事务已通过；3 张跨模块表等待 B 的依赖表后联调 |
| ⑤ 结算与对账 | 设计中 | 仅完成实体规划，DDL 与应用层未开始，依赖 B 的订单、支付和退款接口最终口径 |

运行环境：MySQL 8.0.46 / InnoDB / utf8mb4，开发语言 Python（PyMySQL + python-dotenv）。

## 4. 交付物位置

| 路径 | 内容 |
| --- | --- |
| `docs/d/D_04_05_data_dictionary.xlsx` | ④⑤ 业务线数据字典 |
| `docs/d/04_membership.md` | ④ 用户与会员运营 DDL 说明与执行顺序 |
| `docs/d/05_settlement.md` | ⑤ 结算与对账设计（待补充） |
| `sql/D/04_membership_core.sql` | 9 张核心表 DDL，不依赖 B 模块 |
| `sql/D/04_membership_integration.sql` | 3 张跨模块表 DDL，需 B 创建 `station`、`charging_order` 后执行 |
| `sql/D/04_membership_verify.sql` | 只读 DDL 验证脚本 |
| `sql/D/04_membership_seed_core.sql` | 9 张核心表各 20 条虚构测试数据，需手动 COMMIT |
| `sql/D/04_membership_constraint_tests.sql` | 唯一、非负、外键、时间、状态等约束测试，测试后统一 ROLLBACK |
| `sql/D/04_membership_business_queries.sql` | 9 条核心业务只读查询与验收摘要 |
| `app/database/` | 连接配置、连接上下文、只读持久层 |
| `app/services/membership_service.py` | 会员等级变更事务服务 |
| `app/services/fleet_service.py` | 车辆加入/退出车队事务服务 |
| `app/run_membership_demo.py` | 连接与持久层演示入口 |
| `app/run_membership_transaction_demo.py` | 真实数据库事务回滚演示入口 |
| `app/run_fleet_transaction_demo.py` | 真实数据库调车事务回滚演示入口 |
| `tests/` | 配置、持久层、事务服务的单元测试（不连接真实数据库） |

## 5. 已完成验收

截至当前提交前，④业务线独立核心部分已取得以下实测结果：

| 检查项 | 结果 |
| --- | --- |
| MySQL 环境 | 8.0.46，数据库 `charging_platform` |
| 核心 DDL | 9 张表创建成功，均为 InnoDB / `utf8mb4_0900_ai_ci` |
| 完整性约束 | 9 个主键、10 个外键、7 个唯一约束、28 个 CHECK 约束，检查全部 PASS |
| ID 类型 | 19 个主外键 ID 字段均为 `BIGINT UNSIGNED` |
| 测试数据 | 9 张核心表各 20 条，共 180 条，已 COMMIT |
| 约束与回滚 | T01～T08 全部 PASS，回滚后各表仍为 20 条 |
| 核心业务查询 | Q01～Q09 执行成功；车辆有效车队冲突为 0，会员当前等级与最新历史全部 MATCH |
| Python 真实连接 | MySQL 8.0.46 / `charging_platform` / 核心表 9/9 |
| 会员等级事务 | 事务内用户等级和历史同时变化，ROLLBACK 后恢复原值，PASS |
| 车队车辆事务 | 事务内退出 60001、加入 60002 且仅一条 ACTIVE；ROLLBACK 后恢复 60001，PASS |
| Python 单元测试 | 16 passed |

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

### ⑤ 结算与对账（规划 5 张表）

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
12. 跨表业务校验（活动为 `SELECTED` 时至少关联一个场站、券是否属于订单用户等）放在事务性业务代码或存储过程中。

## 8. 执行与运行方式

在仓库根目录登录 MySQL 后，核心部分按顺序执行：

```sql
SOURCE sql/D/04_membership_core.sql;
SOURCE sql/D/04_membership_verify.sql;          -- 预期 9 张核心表校验全部 PASS
SOURCE sql/D/04_membership_seed_core.sql;       -- 检查末尾统计后手动 COMMIT
SOURCE sql/D/04_membership_constraint_tests.sql;
SOURCE sql/D/04_membership_business_queries.sql;
```

跨模块表需等待 B 创建并确认依赖表后再执行：

```sql
SOURCE sql/D/04_membership_integration.sql;      -- 依赖 station、charging_order
```

Python 侧：

```powershell
python -m pip install -r requirements.txt
Copy-Item .env.example .env   # 首次运行时填写本机 MySQL 密码
.\.venv\Scripts\python.exe -m app.run_membership_demo
.\.venv\Scripts\python.exe -m app.run_membership_transaction_demo
.\.venv\Scripts\python.exe -m app.run_fleet_transaction_demo
.\.venv\Scripts\python.exe -m pytest -q
```

`.env` 已被 Git 忽略，不得提交真实数据库密码。事务演示会临时修改用户 10001，在验证后主动回滚，不保留演示记录。

## 9. 待确认事项

1. 与 B 统一 `station`、`charging_order`、`payment_record`、`refund_record` 的主键和字段类型（当前按 `BIGINT UNSIGNED` 假定）。
2. 统一订单、支付和退款的数据关联方式及账期口径（时区、跨账期退款调整、分成）。
3. 确认锁券与核销时点：支付成功时核销，支付失败、取消和退款后的恢复规则。
4. 确认已发券是否保存优惠规则快照，以及是否增加按会员等级配置定向人群的关联表。
5. 确认企业车队额度的计量单位、周期和月结统计口径。
6. 确认会员等级及其权益的最终定义（当前仅字典表，无权益明细表）。
7. ⑤ 结算与对账的实体设计尚未定稿，需在 1–3 确认后启动 DDL。
