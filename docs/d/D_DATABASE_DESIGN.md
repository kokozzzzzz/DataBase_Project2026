# D 模块关系模式与规范化说明

## 1. 设计范围

D 负责④用户与会员运营和⑤结算与对账，共 17 张表。④包含 9 张独立核心表和 3 张依赖 B 模块的跨模块表；⑤包含 5 张结算对账表。完整字段、类型、默认值和约束以 `D_04_05_data_dictionary.xlsx` 与正式 DDL 为准。

已确定的设计口径：

- 会员等级使用独立表，不把等级名称和规则重复存入用户表。
- 企业车队月结使用订单、支付和退款动态聚合，不增加月结结果表。
- 活动与适用场站为多对多关系，通过 `promotion_station` 实现。
- 支付失败或取消订单释放锁券；部分退款不返券；全额退款经审核后补发新券，原核销记录保留。
- 已确认账期之后发生的退款进入后续账期调整，不修改历史结算单。

## 2. 关系模式摘要

PK 表示主键，FK 表示外键，UK 表示候选键或唯一业务键。可空唯一字段在 MySQL 中允许多行 `NULL`，只限制非空值重复。

| 关系 | 主键 | 外键 | 候选键或重要唯一约束 | 主要职责 |
| --- | --- | --- | --- | --- |
| `membership_level` | `level_id` | 无 | `level_code`、`level_name` | 会员等级字典及排序 |
| `user` | `user_id` | `level_id → membership_level` | `phone_hash` | 用户资料、当前等级和当前余额 |
| `vehicle` | `vehicle_id` | `user_id → user` | `plate_hash` | 用户车辆主数据 |
| `membership_record` | `membership_record_id` | `user_id → user`、`level_id → membership_level` | 无 | 会员等级变更历史 |
| `enterprise_customer` | `enterprise_id` | 无 | `credit_code_hash` | 企业客户主数据 |
| `fleet` | `fleet_id` | `enterprise_id → enterprise_customer` | `(enterprise_id, fleet_name)` | 企业下属车队 |
| `fleet_vehicle` | `fleet_vehicle_id` | `fleet_id → fleet`、`vehicle_id → vehicle` | `(fleet_id, vehicle_id, joined_at)` | 车辆加入和退出车队的历史 |
| `fleet_quota_record` | `quota_record_id` | 企业、车队、车辆目标三选一 | 无 | 金额、电量或订单次数额度 |
| `promotion` | `promotion_id` | 无 | 无 | 优惠活动规则 |
| `promotion_station` | `(promotion_id, station_id)` | 活动和 B 场站 | 复合主键 | 活动适用场站多对多关联 |
| `coupon` | `coupon_id` | 活动、用户、B 订单 | `coupon_code`、非空 `locked_order_id` | 用户持券、锁券和使用状态 |
| `coupon_redemption` | `redemption_id` | 券和 B 订单 | `coupon_id`、`order_id` | 不可重复的成功核销事实 |
| `settlement_statement` | `settlement_id` | B 运营商、B 场站 | `statement_no`、`(operator_id, station_id, period_start, period_end)` | 场站账期结算单及费率快照 |
| `settlement_detail` | `settlement_detail_id` | 结算单、B 订单、原明细、B 支付、B 退款 | 非空 `payment_id`、`refund_id`、生成列 `base_order_id` | 基础订单、退款冲减和其他调整 |
| `reconciliation_difference` | `difference_id` | 结算单、B 订单、调整明细 | 非空 `adjustment_detail_id` | 对账差异及处理状态 |
| `reconciliation_confirmation` | `confirmation_id` | `difference_id → reconciliation_difference` | 无 | 平台和运营商追加式确认历史 |
| `invoice_record` | `invoice_id` | 结算单、原发票自关联 | 非空 `invoice_number` | 普通票、红字票和原票追溯 |

## 3. 主要函数依赖

### 3.1 用户会员与车队

- `level_id → level_code, level_name, description, sort_order, status, ...`；`level_code` 和 `level_name` 也是候选键。
- `user_id → 用户全部非键属性`；`phone_hash → user_id`。
- `vehicle_id → 车辆全部非键属性`；`plate_hash → vehicle_id`。
- `membership_record_id → user_id, level_id, change_type, effective_at, ...`。
- `enterprise_id → 企业全部非键属性`；`credit_code_hash → enterprise_id`。
- `fleet_id → enterprise_id, fleet_name, status, ...`；`(enterprise_id, fleet_name) → fleet_id`。
- `fleet_vehicle_id → fleet_id, vehicle_id, joined_at, left_at, ...`；历史业务键为 `(fleet_id, vehicle_id, joined_at)`。
- `quota_record_id → quota_scope, 目标编号, quota_type, quota_limit, period_start, period_end, ...`。

### 3.2 活动与优惠券

- `promotion_id → 活动规则、有效期、适用范围和状态`。
- `(promotion_id, station_id) → created_at`，关联表不存在只依赖复合键一部分的非键属性。
- `coupon_id → coupon_code, promotion_id, user_id, 有效期和状态字段`；`coupon_code → coupon_id`；非空 `locked_order_id → coupon_id`。
- `redemption_id → coupon_id, order_id, discount_amount, redeemed_at`；`coupon_id → redemption_id`；`order_id → redemption_id`。

### 3.3 结算与对账

- `settlement_id → 账期、费率快照、汇总金额、状态和时间`；`statement_no → settlement_id`；`(operator_id, station_id, period_start, period_end) → settlement_id`。
- `settlement_detail_id → 明细类型、追溯编号、金额快照和说明`。非空 `payment_id`、`refund_id` 和 `base_order_id` 分别唯一确定对应明细。
- `difference_id → settlement_id, order_id, 差异值、状态和处理结果`；非空 `adjustment_detail_id → difference_id`。
- `confirmation_id → difference_id, confirming_party, confirmation_result, confirmed_at, ...`。同一方可以多次追加确认，因此不把 `(difference_id, confirming_party)` 设为唯一键。
- `invoice_id → settlement_id, invoice_type, invoice_title, invoice_amount, status, ...`；非空 `invoice_number → invoice_id`。

## 4. 第三范式分析

### 4.1 满足第一范式

所有字段均保存原子值。场站集合、车队车辆集合、等级历史、确认历史和发票红冲关系均拆成独立关系，没有在单元格中保存逗号分隔列表或重复字段组。

### 4.2 满足第二范式

绝大多数表使用单列代理主键，不存在复合主键的部分依赖。唯一使用复合主键的 `promotion_station` 只有 `created_at` 一个非键属性，它依赖完整的 `(promotion_id, station_id)`，因此满足第二范式。

### 4.3 满足第三范式

- 用户表只保存 `level_id`，等级名称、折扣率和排序保存在 `membership_level`，消除“用户编号→等级编号→等级属性”的传递依赖。
- 车辆、车队和企业分别建表；`fleet_vehicle` 只保存关联及有效期，不重复保存企业名、车队名、车型或车主姓名。
- 活动、活动场站、券实例和核销事实分离，避免把一项活动的规则复制到每个场站或每条核销记录。
- 结算单、结算明细、差异、确认和发票分离。确认人和确认结果不重复写入差异主记录，红字票通过自关联保留原票。
- 所有非键属性依赖本表候选键，不依赖其他非键描述字段，因此核心逻辑关系满足第三范式。

## 5. 快照、汇总和生成列说明

以下字段是为审计和性能保留的受控冗余，不用于替代规范化事实表：

- `settlement_statement` 保存费率和汇总金额快照，保证历史结算单不会因合同费率变化而改变。结算过程在同一事务内从明细生成汇总。
- `settlement_detail` 保存订单费用和分成快照，便于对账时还原当时口径；原始订单、支付和退款仍通过外键追溯。
- `difference_value` 由 `actual_value - expected_value` 生成，`base_order_id` 由明细类型和订单编号生成，均由 MySQL 维护，应用不能独立写入。
- `user.balance` 是当前余额，不是余额流水。当前任务书和已确认的 17 表没有要求余额流水实体，因此文档和查询不把订单聚合伪装成余额变动历史。

## 6. 数据字典一致性检查

2026-11-23 已将 Excel 数据字典与 MySQL 8.0.46 中的正式结构逐项核对：

- 表数量：17 对 17；
- 字段数量：191 对 191；
- 缺失字段和多余字段：均为 0；
- 字段类型、主键、外键、可空性、单列唯一约束和默认值差异：均为 0；
- 修正 `vehicle.fast_charge_supported` 类型为 `TINYINT UNSIGNED`；
- 标记 `coupon.locked_order_id` 为唯一字段；
- 补充 `coupon.locked_order_id → charging_order.order_id` 关系；
- 将退款补券、适用场站、三级额度、车队月结和动态目标用户筛选更新为已实现。

## 7. 仍需业务确认的内容

- 会员等级最终名称、升级条件和权益内容；当前数据库只提供等级字典和变更机制。
- 已发券是否需要保存活动规则快照；当前核销使用活动现行规则，正式运营时应禁止随意修改已发券活动的核心计算字段，或在后续版本增加快照。
- 正式结算分成率和优惠承担率；当前结构和过程支持费率快照，但课程演示使用测试参数。
- 敏感信息的生产密钥托管方式；当前数据库已使用密文列和检索摘要列，测试数据全部为虚构值。
