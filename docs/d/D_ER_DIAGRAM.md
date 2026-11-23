# D 模块局部 E-R 图

适用范围：④用户与会员运营、⑤结算与对账。`station`、`charging_order`、`payment_record`、`refund_record` 和 `operator` 为 B 模块实体，D 只通过正式外键引用，不修改其结构。

## ④ 用户与会员运营

```mermaid
erDiagram
    membership_level ||--o{ user : "当前等级"
    membership_level ||--o{ membership_record : "变更后等级"
    user ||--o{ membership_record : "等级历史"
    user ||--o{ vehicle : "拥有"

    enterprise_customer ||--o{ fleet : "下设"
    fleet ||--o{ fleet_vehicle : "包含历史车辆"
    vehicle ||--o{ fleet_vehicle : "加入历史车队"
    enterprise_customer o|--o{ fleet_quota_record : "企业额度"
    fleet o|--o{ fleet_quota_record : "车队额度"
    vehicle o|--o{ fleet_quota_record : "车辆额度"

    promotion ||--o{ promotion_station : "配置适用场站"
    station ||--o{ promotion_station : "被活动覆盖"
    promotion ||--o{ coupon : "发放"
    user ||--o{ coupon : "持有"
    charging_order o|--o| coupon : "支付前锁定"
    coupon ||--o| coupon_redemption : "成功核销"
    charging_order ||--o| coupon_redemption : "使用一张券"

    membership_level {
        BIGINT level_id PK
        VARCHAR level_code UK
        VARCHAR level_name UK
        INT sort_order
    }
    user {
        BIGINT user_id PK
        CHAR phone_hash UK
        BIGINT level_id FK
        DECIMAL balance
        VARCHAR user_status
    }
    vehicle {
        BIGINT vehicle_id PK
        BIGINT user_id FK
        CHAR plate_hash UK
        VARCHAR vehicle_status
    }
    membership_record {
        BIGINT membership_record_id PK
        BIGINT user_id FK
        BIGINT level_id FK
        VARCHAR change_type
        DATETIME effective_at
    }
    enterprise_customer {
        BIGINT enterprise_id PK
        CHAR credit_code_hash UK
        VARCHAR status
    }
    fleet {
        BIGINT fleet_id PK
        BIGINT enterprise_id FK
        VARCHAR fleet_name
        VARCHAR fleet_status
    }
    fleet_vehicle {
        BIGINT fleet_vehicle_id PK
        BIGINT fleet_id FK
        BIGINT vehicle_id FK
        DATETIME joined_at
        DATETIME left_at
    }
    fleet_quota_record {
        BIGINT quota_record_id PK
        BIGINT enterprise_id FK
        BIGINT fleet_id FK
        BIGINT vehicle_id FK
        VARCHAR quota_scope
        VARCHAR quota_type
        DECIMAL quota_limit
    }
    promotion {
        BIGINT promotion_id PK
        VARCHAR discount_type
        DECIMAL discount_value
        VARCHAR applicability_scope
        VARCHAR status
    }
    promotion_station {
        BIGINT promotion_id PK, FK
        BIGINT station_id PK, FK
    }
    coupon {
        BIGINT coupon_id PK
        VARCHAR coupon_code UK
        BIGINT promotion_id FK
        BIGINT user_id FK
        BIGINT locked_order_id FK, UK
        VARCHAR status
    }
    coupon_redemption {
        BIGINT redemption_id PK
        BIGINT coupon_id FK, UK
        BIGINT order_id FK, UK
        DECIMAL discount_amount
    }
    station {
        BIGINT station_id PK
    }
    charging_order {
        BIGINT order_id PK
        BIGINT user_id FK
        BIGINT vehicle_id FK
    }
```

`fleet_quota_record` 的三个目标外键不是同时生效。`quota_scope` 与 CHECK 约束保证每行只引用企业、车队或车辆中的一个目标。

## ⑤ 结算与对账

```mermaid
erDiagram
    operator ||--o{ settlement_statement : "运营商账期"
    station ||--o{ settlement_statement : "场站账期"
    settlement_statement ||--o{ settlement_detail : "包含明细"
    charging_order ||--o{ settlement_detail : "结算与调整追溯"
    payment_record ||--o| settlement_detail : "足额支付依据"
    refund_record ||--o| settlement_detail : "跨期退款依据"
    settlement_detail o|--o{ settlement_detail : "退款回指原明细"

    settlement_statement ||--o{ reconciliation_difference : "产生差异"
    charging_order ||--o{ reconciliation_difference : "差异订单"
    reconciliation_difference ||--o{ reconciliation_confirmation : "双方确认历史"
    settlement_detail o|--o| reconciliation_difference : "确认后调整"

    settlement_statement ||--o{ invoice_record : "开票"
    invoice_record o|--o{ invoice_record : "红字票回指原票"

    settlement_statement {
        BIGINT settlement_id PK
        VARCHAR statement_no UK
        BIGINT operator_id FK
        BIGINT station_id FK
        DATE period_start
        DATE period_end
        DECIMAL payable_amount
        VARCHAR status
    }
    settlement_detail {
        BIGINT settlement_detail_id PK
        BIGINT settlement_id FK
        BIGINT order_id FK
        BIGINT original_detail_id FK
        BIGINT payment_id FK, UK
        BIGINT refund_id FK, UK
        VARCHAR detail_type
        DECIMAL payable_amount
    }
    reconciliation_difference {
        BIGINT difference_id PK
        BIGINT settlement_id FK
        BIGINT order_id FK
        BIGINT adjustment_detail_id FK, UK
        VARCHAR difference_type
        VARCHAR status
    }
    reconciliation_confirmation {
        BIGINT confirmation_id PK
        BIGINT difference_id FK
        VARCHAR confirming_party
        VARCHAR confirmation_result
        DATETIME confirmed_at
    }
    invoice_record {
        BIGINT invoice_id PK
        BIGINT settlement_id FK
        VARCHAR invoice_number UK
        BIGINT original_invoice_id FK
        VARCHAR invoice_type
        DECIMAL invoice_amount
        VARCHAR status
    }
    operator {
        BIGINT operator_id PK
    }
    station {
        BIGINT station_id PK
    }
    charging_order {
        BIGINT order_id PK
    }
    payment_record {
        BIGINT payment_id PK
        BIGINT order_id FK
    }
    refund_record {
        BIGINT refund_id PK
        BIGINT payment_id FK
    }
```

## 基数和历史保留说明

- 用户、车辆、企业、车队、活动等主数据采用逻辑状态，不物理删除历史引用。
- `fleet_vehicle` 保存加入和退出时间，同一车辆只能有一条未退出的有效关系。
- 一张券最多核销一次，一笔订单最多核销一张券；锁券与核销分别由唯一约束保证。
- 同一运营商、场站和半开账期只能生成一张结算单。
- 退款和差异调整不覆盖原结算明细，而是追加可回溯的新明细。
- 红字发票保留原普通发票，通过 `original_invoice_id` 形成自关联。
