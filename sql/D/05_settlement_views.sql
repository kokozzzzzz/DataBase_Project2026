-- ⑤ 结算与对账：三个实用查询视图
-- 适用环境：MySQL 8.0.46 / InnoDB / utf8mb4
-- 前置：D 五张结算表及 B 的 v_b_order_funds 已存在。
-- 安全：CREATE OR REPLACE VIEW 只更新视图定义，不修改业务数据。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

-- V1：结算单汇总。
-- 差异和发票先分别按结算单聚合，再与结算单连接，避免两类一对多记录
-- 直接连接后形成笛卡尔乘积，导致金额和数量重复累计。
CREATE OR REPLACE
ALGORITHM = UNDEFINED
SQL SECURITY INVOKER
VIEW v_settlement_statement_summary AS
SELECT
    ss.settlement_id,
    ss.statement_no,
    ss.operator_id,
    op.name AS operator_name,
    ss.station_id,
    st.name AS station_name,
    ss.period_start,
    ss.period_end,
    ss.status,
    ss.total_kwh,
    ss.total_electricity_fee,
    ss.total_service_fee,
    ss.total_discount_amount,
    ss.total_refund_amount,
    ss.total_adjustment_amount,
    ss.electricity_share_amount,
    ss.service_share_amount,
    ss.platform_service_fee,
    ss.payable_amount,
    COALESCE(df.difference_count, 0) AS difference_count,
    COALESCE(df.unresolved_difference_count, 0) AS unresolved_difference_count,
    COALESCE(iv.issued_normal_amount, 0.00) AS issued_normal_amount,
    COALESCE(iv.issued_red_letter_amount, 0.00) AS issued_red_letter_amount,
    COALESCE(iv.net_invoice_amount, 0.00) AS net_invoice_amount,
    GREATEST(
        GREATEST(ss.payable_amount, 0.00)
        - COALESCE(iv.net_invoice_amount, 0.00),
        0.00
    ) AS invoice_available_amount,
    ss.generated_at,
    ss.confirmed_at,
    ss.paid_at
FROM settlement_statement AS ss
JOIN `operator` AS op
  ON op.operator_id = ss.operator_id
JOIN station AS st
  ON st.station_id = ss.station_id
LEFT JOIN (
    SELECT
        settlement_id,
        COUNT(*) AS difference_count,
        SUM(status <> 'RESOLVED') AS unresolved_difference_count
    FROM reconciliation_difference
    GROUP BY settlement_id
) AS df
  ON df.settlement_id = ss.settlement_id
LEFT JOIN (
    SELECT
        settlement_id,
        SUM(
            CASE
                WHEN invoice_type = 'NORMAL'
                 AND status IN ('ISSUED', 'RED_FLUSHED')
                THEN invoice_amount ELSE 0.00
            END
        ) AS issued_normal_amount,
        SUM(
            CASE
                WHEN invoice_type = 'RED_LETTER'
                 AND status = 'ISSUED'
                THEN invoice_amount ELSE 0.00
            END
        ) AS issued_red_letter_amount,
        SUM(
            CASE
                WHEN invoice_type = 'NORMAL'
                 AND status IN ('ISSUED', 'RED_FLUSHED')
                THEN invoice_amount
                WHEN invoice_type = 'RED_LETTER'
                 AND status = 'ISSUED'
                THEN -invoice_amount
                ELSE 0.00
            END
        ) AS net_invoice_amount
    FROM invoice_record
    GROUP BY settlement_id
) AS iv
  ON iv.settlement_id = ss.settlement_id;

-- V2：逐订单结算明细。
-- B 的 v_b_order_funds 已分别聚合成功支付和退款，本视图不直接连接多笔
-- payment_record/refund_record，避免多支付 × 多退款造成金额重复。
CREATE OR REPLACE
ALGORITHM = UNDEFINED
SQL SECURITY INVOKER
VIEW v_settlement_order_detail AS
SELECT
    sd.settlement_detail_id,
    sd.settlement_id,
    ss.statement_no,
    ss.period_start,
    ss.period_end,
    ss.status AS settlement_status,
    ss.operator_id,
    ss.station_id,
    sd.order_id,
    sd.detail_type,
    sd.original_detail_id,
    sd.payment_id,
    sd.refund_id,
    sd.event_at,
    funds.state AS order_state,
    funds.starts_at AS order_started_at,
    funds.ends_at AS order_ended_at,
    funds.total_kwh AS order_kwh,
    funds.gross_amount AS order_gross_amount,
    funds.discount_amount AS order_discount_amount,
    funds.payable AS order_payable_amount,
    funds.paid AS success_paid_amount,
    funds.refunded AS total_refunded_amount,
    funds.net_received AS net_received_amount,
    sd.charging_kwh,
    sd.electricity_fee,
    sd.service_fee,
    sd.minimum_fee_adjustment,
    sd.discount_amount AS detail_discount_amount,
    sd.refund_amount,
    sd.adjustment_amount,
    sd.electricity_share_amount,
    sd.service_share_amount,
    sd.platform_service_fee,
    sd.payable_amount AS detail_payable_amount,
    sd.description
FROM settlement_detail AS sd
JOIN settlement_statement AS ss
  ON ss.settlement_id = sd.settlement_id
JOIN v_b_order_funds AS funds
  ON funds.order_id = sd.order_id;

-- V3：尚未解决的对账差异及双方最新结论。
-- 通过反连接只保留每一方 confirmation_id 最大的记录；不暴露 confirmer_name。
CREATE OR REPLACE
ALGORITHM = UNDEFINED
SQL SECURITY INVOKER
VIEW v_reconciliation_pending AS
SELECT
    rd.difference_id,
    rd.settlement_id,
    ss.statement_no,
    ss.operator_id,
    ss.station_id,
    ss.period_start,
    ss.period_end,
    rd.order_id,
    rd.difference_type,
    rd.expected_value,
    rd.actual_value,
    rd.difference_value,
    rd.difference_unit,
    rd.description,
    rd.status AS difference_status,
    rd.resolution,
    rd.discovered_at,
    platform_confirmation.confirmation_result AS platform_result,
    platform_confirmation.confirmed_at AS platform_confirmed_at,
    operator_confirmation.confirmation_result AS operator_result,
    operator_confirmation.confirmed_at AS operator_confirmed_at,
    IF(
        platform_confirmation.confirmation_result = 'AGREE'
        AND operator_confirmation.confirmation_result = 'AGREE',
        1,
        0
    ) AS both_agreed,
    CASE
        WHEN platform_confirmation.confirmation_id IS NULL
            THEN 'WAIT_PLATFORM'
        WHEN operator_confirmation.confirmation_id IS NULL
            THEN 'WAIT_OPERATOR'
        WHEN platform_confirmation.confirmation_result = 'REJECT'
          OR operator_confirmation.confirmation_result = 'REJECT'
            THEN 'REVIEW_REJECTION'
        WHEN rd.status = 'CONFIRMED'
            THEN 'CREATE_ADJUSTMENT'
        ELSE 'SYNC_STATUS'
    END AS next_action
FROM reconciliation_difference AS rd
JOIN settlement_statement AS ss
  ON ss.settlement_id = rd.settlement_id
LEFT JOIN reconciliation_confirmation AS platform_confirmation
  ON platform_confirmation.difference_id = rd.difference_id
 AND platform_confirmation.confirming_party = 'PLATFORM'
LEFT JOIN reconciliation_confirmation AS newer_platform_confirmation
  ON newer_platform_confirmation.difference_id = rd.difference_id
 AND newer_platform_confirmation.confirming_party = 'PLATFORM'
 AND newer_platform_confirmation.confirmation_id
     > platform_confirmation.confirmation_id
LEFT JOIN reconciliation_confirmation AS operator_confirmation
  ON operator_confirmation.difference_id = rd.difference_id
 AND operator_confirmation.confirming_party = 'OPERATOR'
LEFT JOIN reconciliation_confirmation AS newer_operator_confirmation
  ON newer_operator_confirmation.difference_id = rd.difference_id
 AND newer_operator_confirmation.confirming_party = 'OPERATOR'
 AND newer_operator_confirmation.confirmation_id
     > operator_confirmation.confirmation_id
WHERE rd.status <> 'RESOLVED'
  AND newer_platform_confirmation.confirmation_id IS NULL
  AND newer_operator_confirmation.confirmation_id IS NULL;

