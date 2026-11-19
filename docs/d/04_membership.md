# ④ 用户与会员运营 DDL 说明

## 本阶段目标

把已确认的数据字典转换为 MySQL 8.0.46 可执行、可验收的建表脚本，并完成核心表与 B 模块正式表结构的跨模块联调。

## 文件位置与执行顺序

1. `sql/D/04_membership_core.sql`
   - 创建会员等级、用户、车辆、会员历史、活动、企业客户、车队、车队车辆历史和额度记录，共 9 张核心表。
   - 不依赖 B 模块，可在统一数据库创建后先执行。
2. `sql/D/04_membership_integration.sql`
   - 创建活动适用场站、优惠券实例和优惠券核销，共 3 张跨模块表。
   - 必须等 B 模块创建 `station` 和 `charging_order` 后执行。
   - 同一订单最多锁定一张券、最多成功核销一张券，分别由唯一约束保证。
3. `sql/D/04_membership_verify.sql`
   - 只读检查表数量、引擎、字符集、主键、外键、检查约束和 ID 类型。
   - 可在执行核心脚本后重复运行，不修改数据。
4. `sql/D/04_membership_seed_core.sql`
   - 为 9 张核心表分别准备 20 条虚构测试数据。
   - 脚本开启事务但不自动提交；全部行数正确后手动 `COMMIT`，出现错误则 `ROLLBACK`。
5. `sql/D/04_membership_constraint_tests.sql`
   - 验证唯一、非负余额、外键、活动时间、车队状态和额度范围等约束。
   - 测试记录统一回滚，完成后 9 张核心表仍应各有 20 条数据。
6. `sql/D/04_membership_business_queries.sql`
   - 提供用户会员档案、等级历史、企业车队、额度和活动等核心业务查询。
   - 全部为只读查询，不依赖 B 模块的场站和订单表。
7. `app/database/`
   - 从 `.env` 读取连接参数，并提供自动关闭、异常回滚的 PyMySQL 连接上下文。
   - `membership_repository.py` 提供参数化的用户会员档案查询和健康检查。
8. `app/run_membership_demo.py`
   - 验证 Python 能连接 `charging_platform`，并展示前 5 名有效用户。
9. `tests/`
   - 对配置校验和查询参数化进行单元测试，不连接真实数据库。
10. `app/services/membership_service.py`
    - 使用 `SELECT ... FOR UPDATE` 锁定用户，原子完成当前等级更新和会员历史写入。
    - 依据等级 `sort_order` 自动判断 `UPGRADE`、`DOWNGRADE` 或 `ADJUST`。
11. `app/run_membership_transaction_demo.py`
    - 在真实数据库内验证两张表同时变更，然后主动 `ROLLBACK`，不保留演示记录。
12. `app/services/fleet_service.py`
    - 通过锁定车辆主记录串行化同一车辆的并发请求，保证最多一条 `ACTIVE` 车队关系。
    - 退出时保留历史关联并填写 `left_at`，加入时校验车辆、车队和企业状态。
13. `app/run_fleet_transaction_demo.py`
    - 在同一事务中退出原车队、加入目标车队并验证，完成后主动 `ROLLBACK`。
14. `app/services/promotion_service.py`
    - 使用 `Decimal` 计算固定减免和百分比折扣，支持最低消费门槛与优惠封顶。
    - `PERCENTAGE` 表示实付比例，例如 `0.80` 表示八折，优惠金额为订单金额的 20%。
15. `app/run_promotion_demo.py`
    - 只读筛选指定时点可用的 `ALL` 全场活动，并计算订单的最优优惠。
16. `sql/D/04_membership_views.sql`
    - 创建用户会员档案、企业车队有效车辆和当前全场活动 3 个实用视图。
    - 使用 `SQL SECURITY INVOKER`，且不暴露手机号、车牌等密文或检索摘要。
17. `sql/D/04_membership_views_verify.sql`
    - 只读检查视图数量、敏感字段暴露、视图行数和样例结果。
18. `sql/D/04_membership_procedure.sql`
    - 创建只读优惠试算过程 `sp_calculate_promotion_quote`，覆盖固定减免、实付比例、门槛和封顶。
    - 使用 `SQL SECURITY INVOKER` 和 `READS SQL DATA`，不修改任何业务表。
19. `sql/D/04_membership_procedure_verify.sql`
    - 验证过程元数据、固定减免、百分比折扣、最低门槛和执行后行数。
20. `sql/D/04_membership_final_verify.sql`
    - 对核心表、行数、约束、视图、存储过程、车队唯一性、等级一致性和敏感字段进行只读综合回归。
21. `sql/D/04_membership_integration_verify.sql`
    - 检查三张跨模块表、B 正式外键、ID 类型、约束数量和订单锁券/核销唯一性。

## 已完成验收

- 核心表 9/9 创建成功，每表 20 条测试数据并已提交。
- DDL 结构检查、约束测试 T01～T08、业务查询 Q01～Q09 均通过。
- Python 连接验证识别 MySQL 8.0.46、`charging_platform` 和 9/9 张核心表。
- 会员等级事务演示在回滚后恢复原等级且不保留历史记录，PASS。
- 车队调车事务演示保证事务内仅一条 `ACTIVE` 关系，回滚后恢复原车队，PASS。
- 100 元订单筛选出 20 个全场活动，最优活动 40019 优惠 24 元、实付 76 元，PASS。
- 3 个实用视图创建成功，敏感字段暴露为 0，当前测试数据均返回 20 行，PASS。
- 只读优惠试算存储过程创建成功，固定减免、八折比例和门槛不足场景均通过。
- Python 单元测试共 23 项，全部通过。
- 3 张跨模块表已在 MySQL 8.0.46 创建成功：3 个主键、7 个外键、4 个唯一约束和 5 个 CHECK 约束全部通过验收。
- `promotion_station.station_id`、`coupon.locked_order_id` 和 `coupon_redemption.order_id` 已连接 B 的正式场站、订单结构，3 个跨模块外键均通过。
- `tests/verify_b_structure.py` 的 20 项 B–D 集成检查全部 PASS，测试事务已回滚，未留下样例数据。

两份脚本合计对应④业务线规划的 12 张表。

## 关键设计说明

- 所有业务主键统一使用 `BIGINT UNSIGNED`，与 B 当前数据字典一致。
- 金额使用 `DECIMAL`，不使用 `FLOAT` 或 `DOUBLE`。
- 手机号、车牌和企业信用代码保存密文；查重使用 HMAC-SHA256 摘要。
- `user` 在 SQL 中统一写成 `` `user` ``，避免与 MySQL 内置对象混淆。
- `fleet_vehicle` 使用代理主键保存历史加入/退出记录；同一车辆只能有一条有效关联的规则后续由事务或触发器实现。
- `promotion.total_quantity` 使用 `NULL` 表示不限量，避免把 `0` 同时解释为未发放或不限量。
- 一张优惠券最多成功核销一次，一笔订单最多使用一张优惠券，由两个唯一约束保证。
- 跨表业务校验，例如活动为 `SELECTED` 时至少关联一个场站、券是否属于订单用户，必须在事务性业务代码或存储过程中完成。

## 尚未定稿的规则

- 优惠券在支付成功时核销；支付失败、取消和退款后的恢复规则仍需与 B 确认。
- 已发券是否保存优惠规则快照尚未确认。
- 是否增加按会员等级配置定向人群的关联表尚未确认。
- 车队额度单位、周期和企业月结统计口径尚未确认。

## 后续运行方式

在仓库根目录登录 MySQL：

```powershell
mysql -u root -p
```

进入 MySQL 客户端后执行：

```sql
SOURCE sql/D/04_membership_core.sql;
SOURCE sql/D/04_membership_verify.sql;
-- B 的 station、charging_order 创建完成后：
SOURCE sql/D/04_membership_integration.sql;
SOURCE sql/D/04_membership_integration_verify.sql;
```

预期结果：④业务线共创建 12 张表，跨模块验收 I01～I06 全部 PASS。首次执行前应先确认数据库中不存在同名表；脚本不会删除或覆盖已有表。B–D 综合结构与事务回滚验证可在 PowerShell 中执行：

```powershell
.\.venv\Scripts\python.exe tests\verify_b_structure.py
```
