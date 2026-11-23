# D 模块最终验收清单

适用范围：④用户与会员运营、⑤结算与对账。目标环境为 MySQL 8.0.46、数据库 `charging_platform`、会话时区 `+08:00`。

## 1. 前置条件

- 已安装 A/B/C/D 当前结构；
- 已提交 D④核心种子、B-FORMAL-v1 和 D⑤正式结算数据；
- `.env` 指向本机 `charging_platform`，真实密码未提交 Git；
- 当前工作分支为 `koko`，工作区无无关改动。

## 2. 一次性 SQL 验收

在仓库根目录执行：

```powershell
.\.venv\Scripts\python.exe -m app.run_sql --file sql/D/00_verify_d_all.sql
```

脚本只读，覆盖：

- D④ 9 张核心表和 3 张跨模块表的结构、类型与约束；
- 活动场站、优惠券和券核销各 20 条正式数据；
- D④ 3 个视图和优惠试算过程；
- D⑤ 5 张表、3 个视图和结算生成过程元数据；
- D⑤ 40 个结算单、60 条明细、20 条差异、40 条确认和 40 条发票；
- 17 张 D 表均不少于 20 行；
- 视图调用者权限、敏感字段、车队唯一性、会员等级一致性和净开票金额。

最终 `DF01～DF10` 应全部为 `PASS`。

## 3. Python 单元测试

```powershell
.\.venv\Scripts\python.exe -m pytest -q
```

当前基线：`149 passed`。

## 4. 真实数据库回滚演示

以下命令都会在验证后回滚，不保留临时业务数据：

```powershell
.\.venv\Scripts\python.exe -m app.run_membership_transaction_demo
.\.venv\Scripts\python.exe -m app.run_fleet_transaction_demo
.\.venv\Scripts\python.exe -m app.run_fleet_monthly_demo
.\.venv\Scripts\python.exe -m app.run_customer_coupon_demo
.\.venv\Scripts\python.exe -m app.run_coupon_transaction_demo
.\.venv\Scripts\python.exe -m app.run_settlement_adjustment_demo
.\.venv\Scripts\python.exe -m app.run_settlement_invoice_demo
```

每个入口的“事务内验证”和“回滚后验证”均应为 `PASS`。车队月结演示还应显示至少 1 笔订单，且额度使用量与月结应付金额一致；用户运营演示应显示 3 组注册绑车、1 张新人券和 2 张批量券；优惠券演示应显示核销后全额退款补发 `REFUND-原券编号`，回滚后退款记录为 0。

## 5. 答辩建议演示顺序

1. 查询用户会员档案，说明非会员用户通过左连接保留，敏感检索字段不在视图中；
2. 演示优惠券发放、锁定、支付、核销和全额退款审核补发后整体回滚；
3. 展示 11 月正结算与 12 月跨期退款负调整；
4. 演示双方确认后在后续账期生成 `OTHER_ADJUSTMENT`；
5. 演示普通发票和红字票，说明净开票额上限与原票追溯；
6. 展示 `EXPLAIN ANALYZE` 使用账期、明细、确认和发票索引。

## 6. 最终通过标准

- SQL 综合验收没有 `FAIL`；
- 全仓单元测试全部通过；
- 七个真实数据库事务演示全部通过且回滚后无残留；
- `git diff --check` 无输出，工作区只包含本阶段预期文件；
- PR 目标为 `dev`，不直接修改 `main`，未经确认不合并。
