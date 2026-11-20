# ⑤ 结算与对账设计说明

## 1. 本阶段目标

依据课程设计任务书、D 数据字典和 B 的正式订单/支付/退款结构，确定⑤的结算粒度、账期口径、跨期退款、差异确认和红字发票规则。本阶段只完成设计审核，不创建表、不执行 DDL，也不修改数据库数据。

## 2. 依赖与数据来源

⑤不重复建设交易事实，直接引用 B 模块：

- `operator.operator_id`：运营商主数据。
- `station.station_id`、`station.operator_id`：场站及所属运营商。
- `charging_order.order_id`：订单、充电电量、原价、优惠和确认时间。
- `order_fee_detail`：逐时段电费、服务费明细。
- `payment_record.payment_id`：成功/失败支付及支付发生时间。
- `refund_record.refund_id`：成功退款及退款发生时间。
- `v_b_order_funds`：订单累计资金概览，只用于当前汇总核查，不能直接作为某个月的支付/退款流水。

所有编号与 B 正式结构统一为 `BIGINT UNSIGNED`。Python 连接统一设置 `+08:00`。

## 3. 任务书硬性要求

⑤必须覆盖以下内容，不能因实现简化而删除：

1. 结算单按“运营商—场站—账期”唯一。
2. 结算数据包含充电电量、电费分成、服务费分成、平台服务费和应结金额。
3. 每条对账差异必须回指具体订单。
4. 差异处理结论必须经过平台和运营商双方确认后生效。
5. 开票累计净额不能超过结算单应结金额。
6. 红字发票必须关联并保留原发票信息。
7. 每月按场站汇总订单生成结算单，逐单核对并保留调整痕迹。

## 4. 对原数据字典的修正

原五张表总体合理，但存在以下不能直接实施的问题：

| 问题 | 修正方案 |
| --- | --- |
| `settlement_statement` 缺少任务书明确要求的充电电量、电费分成、服务费分成和平台服务费 | 增加 `total_kwh`、`electricity_share_amount`、`service_share_amount`、`platform_service_fee` |
| 分成金额无法复算 | 在结算单保存四个规则快照：电费分成率、服务费分成率、平台费率、运营商优惠承担率 |
| `settlement_detail` 只有 `order_id`，无法判断分次支付在哪个账期完成 | 增加 `payment_id`，记录使订单达到足额支付的那笔成功支付 |
| 明细没有业务发生时间 | 增加 `event_at`，所有账期筛选统一使用该字段 |
| 订单起步补差无法归入电费或服务费 | 增加 `minimum_fee_adjustment`，值为订单原价减去分段电费和服务费之和 |
| 同一订单可能重复生成基础结算明细 | 增加只对 `ORDER` 生效的生成列 `base_order_id`，并建立唯一索引 |
| 跨期退款只能记录原始退款金额，无法说明对运营商应结金额的影响 | 保留 `refund_amount`，同时使用负数 `payable_amount` 记录本次冲减，并关联 `original_detail_id`、`refund_id` |
| 差异表缺少最终处理结论和处理时间 | 增加 `resolution`、`resolved_at`、`adjustment_detail_id` |
| 结算单进入 `PAID` 后没有付款完成时间 | 增加 `paid_at` |
| 发票红冲只有类型，没有清晰的状态语义 | 红字票金额仍存正数，`invoice_type` 决定符号；原票更新为 `RED_FLUSHED`，红字票本身为 `ISSUED` |

`operator_id` 可由 `station_id` 推导，逻辑上属于冗余字段。但任务书明确要求按运营商和场站结算，且结算单需要保存生成时的业务归属，因此保留该字段作为受控快照。生成结算单时必须校验场站当前属于该运营商。

## 5. 统一时间和账期口径

1. 所有会话使用 `+08:00`。
2. 账期采用左闭右开区间 `[period_start, period_end)`。
3. `period_start`、`period_end` 使用 `DATE`；自然月示例为 `2026-11-01` 至 `2026-12-01`。
4. 基础订单明细以“首次达到足额支付”的成功支付时间作为 `event_at`。
5. 退款调整以 `refund_record.occurred_at` 作为 `event_at`。
6. 其他人工调整以实际批准生效时间作为 `event_at`。
7. 不使用 `23:59:59` 作为月末边界，避免毫秒/微秒精度产生漏单。

## 6. 结算入账规则

### 6.1 足额支付判定

订单必须满足：

- `charging_order.state = 'BILLED'`；
- `gross_amount`、`total_kwh` 已确定；
- 成功支付累计金额达到 `gross_amount - discount_amount`。

使用 MySQL 8 窗口函数按 `occurred_at, payment_id` 累加成功支付，第一笔使累计金额达到应付金额的支付记录称为“完成支付记录”。该记录的 `payment_id` 和 `occurred_at` 分别写入基础结算明细的 `payment_id`、`event_at`。

一笔订单只生成一条 `ORDER` 基础明细。失败支付不参与应结金额，只能形成支付类对账差异。

### 6.2 金额分解

对一笔基础订单：

```text
electricity_fee = SUM(order_fee_detail.energy_amount)
service_fee = SUM(order_fee_detail.service_amount)
minimum_fee_adjustment = gross_amount - electricity_fee - service_fee
electricity_share_amount = electricity_fee × electricity_share_rate
service_share_amount = (service_fee + minimum_fee_adjustment) × service_share_rate
platform_service_fee = gross_amount × platform_fee_rate
operator_discount_burden = discount_amount × operator_discount_rate
payable_amount = electricity_share_amount
               + service_share_amount
               - platform_service_fee
               - operator_discount_burden
               + adjustment_amount
```

所有中间金额使用 `DECIMAL`，最终金额统一按人民币分四舍五入。分成率必须在 `[0, 1]` 范围，并保存在结算单中作为规则快照，避免以后修改规则导致历史账单无法复算。

### 6.3 跨期退款

退款不回写已确认的历史结算单。每条新退款在退款发生账期生成一条 `REFUND_ADJUSTMENT`：

- `order_id` 指向原订单；
- `refund_id` 唯一指向 B 的退款流水；
- `original_detail_id` 指向原 `ORDER` 结算明细；
- `refund_amount` 存正数原始退款金额；
- `payable_amount` 存负数，表示本期对运营商应结金额的冲减。

默认按原明细应结比例计算冲减：

```text
refund_settlement_amount
  = original_detail.payable_amount
    × refund_amount
    ÷ original_order_payable_amount

REFUND_ADJUSTMENT.payable_amount = -refund_settlement_amount
```

累计退款不得超过原订单成功支付金额，累计结算冲减不得超过原基础明细的应结金额。若教师或运营商合同给出其他规则，只替换退款冲减公式，不改变追溯结构。

## 7. 五张表的定稿结构

### 7.1 `settlement_statement`

结算单头，按运营商、场站、账期唯一。

关键字段：

- 主键与编号：`settlement_id`、`statement_no`。
- 归属与账期：`operator_id`、`station_id`、`period_start`、`period_end`。
- 规则快照：`electricity_share_rate`、`service_share_rate`、`platform_fee_rate`、`operator_discount_rate`。
- 事实汇总：`total_kwh`、`total_electricity_fee`、`total_service_fee`、`total_discount_amount`、`total_refund_amount`、`total_adjustment_amount`。
- 分成结果：`electricity_share_amount`、`service_share_amount`、`platform_service_fee`、`payable_amount`。
- 状态时间：`status`、`generated_at`、`confirmed_at`、`paid_at`、`created_at`、`updated_at`。

状态：`DRAFT / GENERATED / CONFIRMED / PAID / VOID`。

唯一约束：

- `UNIQUE(statement_no)`；
- `UNIQUE(operator_id, station_id, period_start, period_end)`。

### 7.2 `settlement_detail`

结算明细，记录基础订单、退款冲减或其他调整。

关键字段：

- `settlement_detail_id`、`settlement_id`、`order_id`；
- `detail_type`：`ORDER / REFUND_ADJUSTMENT / OTHER_ADJUSTMENT`；
- `payment_id`、`refund_id`、`original_detail_id`、`event_at`；
- `charging_kwh`、`electricity_fee`、`service_fee`、`minimum_fee_adjustment`；
- `discount_amount`、`refund_amount`、`adjustment_amount`；
- `electricity_share_amount`、`service_share_amount`、`platform_service_fee`、`payable_amount`；
- `description`、`created_at`；
- 生成列 `base_order_id = IF(detail_type = 'ORDER', order_id, NULL)`。

约束：

- `UNIQUE(base_order_id)`：一笔订单最多一条基础结算明细；
- `UNIQUE(payment_id)`：完成支付记录最多进入一条明细；
- `UNIQUE(refund_id)`：退款流水最多冲减一次；
- `ORDER` 必须有 `payment_id`，不得有 `refund_id`、`original_detail_id`；
- `REFUND_ADJUSTMENT` 必须有 `refund_id`、`original_detail_id`，且 `payable_amount < 0`；
- `OTHER_ADJUSTMENT` 必须填写说明，`adjustment_amount` 和 `payable_amount` 可正可负但不能同时为 0。

### 7.3 `reconciliation_difference`

逐单记录系统与运营商账单差异。

关键字段：

- `difference_id`、`settlement_id`、`order_id`；
- `difference_type`：`ENERGY / PRICE / PAYMENT / REFUND / OTHER`；
- `expected_value`、`actual_value`；
- 生成列 `difference_value = actual_value - expected_value`；
- `difference_unit`：如 `CNY / kWh / CNY_per_kWh`；
- `description`、`status`、`resolution`；
- `adjustment_detail_id`、`discovered_at`、`resolved_at`、`created_at`。

状态：`PENDING / CONFIRMED / REJECTED / RESOLVED`。

只有平台和运营商双方最新确认均为 `AGREE` 时，差异才能进入 `CONFIRMED`；产生调整明细后进入 `RESOLVED`。

### 7.4 `reconciliation_confirmation`

追加写入双方确认历史，不覆盖旧记录。

字段：`confirmation_id`、`difference_id`、`confirming_party`、`confirmer_name`、`confirmation_result`、`confirmation_note`、`confirmed_at`、`created_at`。

- `confirming_party`：`PLATFORM / OPERATOR`；
- `confirmation_result`：`AGREE / REJECT`；
- 某一方的当前结论取该差异下 `confirmation_id` 最大的一条；
- `confirmer_name` 属于一般敏感信息，查询视图默认不暴露。

### 7.5 `invoice_record`

记录普通发票和红字发票。

关键字段：`invoice_id`、`settlement_id`、`invoice_number`、`invoice_type`、`invoice_title`、`tax_number_ciphertext`、`invoice_amount`、`issued_at`、`status`、`original_invoice_id`、`created_at`、`updated_at`。

规则：

- `invoice_amount` 始终存正数；
- `NORMAL` 发票的 `original_invoice_id` 必须为空；
- `RED_LETTER` 发票必须关联同一结算单下已开具的普通发票；
- 红字票开具后，原普通发票状态更新为 `RED_FLUSHED`；
- 有效开票净额为“已开普通票金额 - 已开红字票金额”；
- 有效开票净额不得小于 0，也不得超过结算单 `payable_amount`；
- 只有 `CONFIRMED` 或 `PAID` 结算单允许开票。

## 8. 状态流转与事务边界

```text
结算单：DRAFT → GENERATED → CONFIRMED → PAID
                         ↘ VOID（仅未确认时）

差异：PENDING → CONFIRMED → RESOLVED
             ↘ REJECTED → PENDING（补充材料后重新发起）

发票：PENDING → ISSUED → RED_FLUSHED
             ↘ CANCELLED（未正式开具前取消）
```

核心事务：

1. 生成结算：锁定“运营商—场站—账期”唯一键，创建结算单和全部明细，汇总金额后统一提交。
2. 确认差异：锁定差异行，追加确认历史，读取双方最新结论并更新差异状态。
3. 应用调整：锁定已双方确认的差异，创建 `OTHER_ADJUSTMENT`，回写 `adjustment_detail_id` 和 `RESOLVED`。
4. 开票：锁定结算单及已有发票，校验累计净开票金额后写入新发票。
5. 红冲：锁定原票，创建红字票并更新原票状态，两步必须同一事务完成。

## 9. 视图、过程和查询计划

课程任务书要求⑤至少提供 3 个实用视图和 1 个存储过程或触发器：

1. `v_settlement_statement_summary`：结算单、场站、运营商、差异数量和净开票金额。
2. `v_settlement_order_detail`：逐订单显示原价、优惠、支付、退款和本次应结金额。
3. `v_reconciliation_pending`：待处理差异及平台/运营商最新确认结果，不暴露确认人姓名。
4. `sp_generate_settlement_statement`：按运营商、场站、半开账期和分成率生成结算单及基础明细。

后续业务 SQL 至少覆盖：

- 各运营商账期内应结金额、已开票净额和差异笔数；
- 某场站账期内逐单电量、电费、服务费和分成；
- 成功支付与退款分别按发生时间汇总后的净资金；
- 跨期退款对原结算明细的追溯；
- 双方未完成确认的差异列表。

## 10. 索引计划

- `settlement_statement(operator_id, station_id, period_start, period_end)` 唯一索引。
- `settlement_statement(status, period_end)`。
- `settlement_detail(settlement_id, detail_type, event_at)`。
- `settlement_detail(order_id, event_at)`。
- `reconciliation_difference(settlement_id, status, discovered_at)`。
- `reconciliation_difference(order_id, difference_type)`。
- `reconciliation_confirmation(difference_id, confirming_party, confirmation_id)`。
- `invoice_record(settlement_id, status, issued_at)`。
- `invoice_record(invoice_number)` 唯一索引，允许未开具时为 `NULL`。

DDL 完成后使用 `EXPLAIN ANALYZE` 记录复杂查询执行计划，确认没有对大表进行不必要的全表扫描。

## 11. 仍需确认但不阻塞建表的事项

以下规则通过字段和参数保留扩展空间，不阻塞五张表建表：

1. 正式电费分成率、服务费分成率和平台费率，由生成结算单时传入并固化快照。
2. 优惠由平台或运营商承担的比例，通过 `operator_discount_rate` 表达。
3. 若合同规定不同的退款冲减方式，仅替换生成退款调整的公式。
4. 当前没有统一员工账号表，确认人暂存姓名/业务标识；接入账号系统后再增加账号编号。
5. 税号继续使用应用层加密，密钥不得写入仓库。

## 12. 下一步实施顺序

1. 已按本说明修订 D 数据字典中的⑤字段和待确认状态。
2. 已编写 `sql/D/05_settlement_schema.sql`，只创建五张表，不包含删除语句。
3. 已编写只读结构验收脚本，验证表、外键、类型、唯一和 CHECK 约束。
4. 已在 MySQL 8.0.46 执行 DDL；S01～S10 全部 PASS，五张表初始均为 0 行。
5. 下一阶段准备每表至少 20 条测试数据及事务回滚测试。
6. 后续完成 3 个视图、生成过程、5 条以上多表业务查询和执行计划。
7. 最后实现 Python 持久层、差异确认/调整与开票事务服务。
