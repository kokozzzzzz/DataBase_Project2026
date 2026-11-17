
# D同学负责模块：用户会员运营与结算对账

## 1. 负责人

D同学

## 2. 负责业务线

- ④ 用户与会员运营
- ⑤ 结算与对账

## 3. 当前设计状态

版本：v0.1

状态：初步设计，等待跨模块接口确认。

数据库：MySQL 8.0

开发语言：Python

## 4. 数据库实体

### ④ 用户与会员运营

Excel原有实体：
- user
- vehicle
- membership_record
- promotion
- coupon
- coupon_redemption
- enterprise_customer
- fleet
- fleet_vehicle
- fleet_quota_record

新增设计：
- membership_level
- promotion_station

### ⑤ 结算与对账

- settlement_statement
- settlement_detail
- reconciliation_difference
- reconciliation_confirmation
- invoice_record

## 5. 已确定的设计方案

1. 会员等级采用独立等级表。
2. 企业车队月结采用SQL动态汇总，不新增月结单表。
3. 优惠活动与场站采用多对多关联。
4. 金额字段统一采用DECIMAL。
5. 会员等级变更通过membership_record保存历史。

## 6. 待确认事项

1. 与B同学统一operator、station、charging_order等表的主键和字段类型。
2. 统一订单、支付和退款的数据关联方式。
3. 确认企业车队额度的计量单位。
4. 确认优惠券核销和退款规则。
5. 确认会员等级及其权益。


