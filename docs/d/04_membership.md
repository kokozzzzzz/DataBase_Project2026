# ④ 用户与会员运营 DDL 说明

## 本阶段目标

把已确认的数据字典转换为 MySQL 8.0.46 可审查的建表脚本。本阶段只生成文件，不连接 MySQL、不创建数据库，也不执行 DDL。

## 文件位置与执行顺序

1. `sql/D/04_membership_core.sql`
   - 创建会员等级、用户、车辆、会员历史、活动、企业客户、车队、车队车辆历史和额度记录，共 9 张核心表。
   - 不依赖 B 模块，可在统一数据库创建后先执行。
2. `sql/D/04_membership_integration.sql`
   - 创建活动适用场站、优惠券实例和优惠券核销，共 3 张跨模块表。
   - 必须等 B 模块创建 `station` 和 `charging_order` 后执行。
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

待全组创建 `charging_platform` 且确认依赖表后，在仓库根目录登录 MySQL：

```powershell
mysql -u root -p
```

进入 MySQL 客户端后执行：

```sql
SOURCE sql/D/04_membership_core.sql;
SOURCE sql/D/04_membership_integration.sql;
SOURCE sql/D/04_membership_verify.sql;
```

预期结果：④业务线共创建 12 张表，且所有主键、外键、唯一约束与检查约束创建成功。首次执行前应先确认数据库中不存在同名表；脚本不会删除或覆盖已有表。
