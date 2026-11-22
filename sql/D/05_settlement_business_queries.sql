-- ⑤ 结算与对账：多表业务查询
-- 适用环境：MySQL 8.0.46。
-- 前置：已提交 B-FORMAL-v1 和 D ⑤ 正式测试数据，SD01～SD07 全部 PASS。
-- 安全：本脚本只执行 SELECT，不创建、修改或删除任何对象和业务数据。
-- 课程要求：Q01～Q06 每条均连接 3 个及以上关系。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

-- ---------------------------------------------------------------------------
-- Q01：运营商—场站—账期结算汇总
-- 关系：operator、station、settlement_statement、settlement_detail
-- 用途：财务按账期查看应结方向、明细数量和主要费用构成。
-- ---------------------------------------------------------------------------
SELECT
    op.operator_id,
    op.name AS operator_name,
    st.station_id,
    st.name AS station_name,
    ss.statement_no,
    ss.period_start,
    ss.period_end,
    ss.status,
    COUNT(sd.settlement_detail_id) AS detail_count,
    SUM(sd.detail_type = 'ORDER') AS order_detail_count,
    SUM(sd.detail_type = 'REFUND_ADJUSTMENT') AS refund_detail_count,
    ss.total_kwh,
    ss.total_electricity_fee,
    ss.total_service_fee,
    ss.total_refund_amount,
    ss.total_adjustment_amount,
    ss.payable_amount,
    CASE
        WHEN ss.payable_amount > 0 THEN 'PLATFORM_PAYS_OPERATOR'
        WHEN ss.payable_amount < 0 THEN 'OPERATOR_RETURNS_OR_CARRIES'
        ELSE 'SETTLED_ZERO'
    END AS settlement_direction
FROM settlement_statement AS ss
JOIN `operator` AS op
  ON op.operator_id = ss.operator_id
JOIN station AS st
  ON st.station_id = ss.station_id
LEFT JOIN settlement_detail AS sd
  ON sd.settlement_id = ss.settlement_id
GROUP BY
    op.operator_id,
    op.name,
    st.station_id,
    st.name,
    ss.settlement_id,
    ss.statement_no,
    ss.period_start,
    ss.period_end,
    ss.status,
    ss.total_kwh,
    ss.total_electricity_fee,
    ss.total_service_fee,
    ss.total_refund_amount,
    ss.total_adjustment_amount,
    ss.payable_amount
ORDER BY ss.period_start, op.operator_id, st.station_id;

-- ---------------------------------------------------------------------------
-- Q02：基础订单逐单结算与用户车辆追溯
-- 关系：settlement_detail、settlement_statement、station、charging_order、
--       user、vehicle
-- 用途：从一条结算明细追溯到订单、用户和车辆，核对分成计算结果。
-- ---------------------------------------------------------------------------
SELECT
    ss.statement_no,
    st.station_id,
    st.name AS station_name,
    sd.settlement_detail_id,
    o.order_id,
    u.user_id,
    u.user_status,
    v.vehicle_id,
    v.model AS vehicle_model,
    o.starts_at,
    o.ends_at,
    o.total_kwh AS order_kwh,
    o.gross_amount,
    o.discount_amount,
    sd.electricity_fee,
    sd.service_fee,
    sd.electricity_share_amount,
    sd.service_share_amount,
    sd.platform_service_fee,
    sd.payable_amount AS settlement_payable_amount
FROM settlement_detail AS sd
JOIN settlement_statement AS ss
  ON ss.settlement_id = sd.settlement_id
JOIN station AS st
  ON st.station_id = ss.station_id
JOIN charging_order AS o
  ON o.order_id = sd.order_id
JOIN `user` AS u
  ON u.user_id = o.user_id
JOIN vehicle AS v
  ON v.vehicle_id = o.vehicle_id
WHERE sd.detail_type = 'ORDER'
ORDER BY ss.statement_no, o.order_id;

-- ---------------------------------------------------------------------------
-- Q03：跨期退款调整的完整追溯链
-- 关系：退款明细、原基础明细、两期结算单、refund_record、payment_record、
--       charging_order
-- 用途：证明次月退款没有回写历史账单，而是新建可追溯的负向调整。
-- ---------------------------------------------------------------------------
SELECT
    refund_statement.statement_no AS refund_statement_no,
    refund_statement.period_start AS refund_period_start,
    refund_statement.period_end AS refund_period_end,
    original_statement.statement_no AS original_statement_no,
    original_statement.period_start AS original_period_start,
    original_statement.period_end AS original_period_end,
    refund_detail.order_id,
    refund_detail.refund_id,
    refund_record.refund_ref,
    refund_record.occurred_at AS refunded_at,
    refund_record.amount AS payment_refund_amount,
    original_detail.payable_amount AS original_settlement_amount,
    refund_detail.refund_amount,
    refund_detail.adjustment_amount,
    refund_detail.payable_amount AS settlement_reversal_amount,
    payment.payment_id,
    payment.trade_ref,
    charging_order.gross_amount,
    charging_order.discount_amount
FROM settlement_detail AS refund_detail
JOIN settlement_statement AS refund_statement
  ON refund_statement.settlement_id = refund_detail.settlement_id
JOIN settlement_detail AS original_detail
  ON original_detail.settlement_detail_id = refund_detail.original_detail_id
JOIN settlement_statement AS original_statement
  ON original_statement.settlement_id = original_detail.settlement_id
JOIN refund_record
  ON refund_record.refund_id = refund_detail.refund_id
JOIN payment_record AS payment
  ON payment.payment_id = refund_record.payment_id
JOIN charging_order
  ON charging_order.order_id = refund_detail.order_id
WHERE refund_detail.detail_type = 'REFUND_ADJUSTMENT'
ORDER BY refund_record.occurred_at, refund_detail.refund_id;

-- ---------------------------------------------------------------------------
-- Q04：待应用调整的双方确认差异
-- 关系：reconciliation_difference、reconciliation_confirmation、
--       settlement_statement、operator、station
-- 用途：每方只取最新一次确认；双方同意且差异仍为 CONFIRMED 时进入调整队列。
-- 安全：不输出 confirmer_name。
-- ---------------------------------------------------------------------------
WITH ranked_confirmation AS (
    SELECT
        rc.confirmation_id,
        rc.difference_id,
        rc.confirming_party,
        rc.confirmation_result,
        rc.confirmed_at,
        ROW_NUMBER() OVER (
            PARTITION BY rc.difference_id, rc.confirming_party
            ORDER BY rc.confirmation_id DESC
        ) AS row_num
    FROM reconciliation_confirmation AS rc
)
SELECT
    rd.difference_id,
    ss.statement_no,
    op.operator_id,
    op.name AS operator_name,
    st.station_id,
    st.name AS station_name,
    rd.order_id,
    rd.difference_type,
    rd.expected_value,
    rd.actual_value,
    rd.difference_value,
    rd.difference_unit,
    rd.status,
    platform_confirmation.confirmation_result AS platform_result,
    platform_confirmation.confirmed_at AS platform_confirmed_at,
    operator_confirmation.confirmation_result AS operator_result,
    operator_confirmation.confirmed_at AS operator_confirmed_at,
    'CREATE_ADJUSTMENT' AS next_action
FROM reconciliation_difference AS rd
JOIN settlement_statement AS ss
  ON ss.settlement_id = rd.settlement_id
JOIN `operator` AS op
  ON op.operator_id = ss.operator_id
JOIN station AS st
  ON st.station_id = ss.station_id
JOIN ranked_confirmation AS platform_confirmation
  ON platform_confirmation.difference_id = rd.difference_id
 AND platform_confirmation.confirming_party = 'PLATFORM'
 AND platform_confirmation.row_num = 1
JOIN ranked_confirmation AS operator_confirmation
  ON operator_confirmation.difference_id = rd.difference_id
 AND operator_confirmation.confirming_party = 'OPERATOR'
 AND operator_confirmation.row_num = 1
WHERE rd.status = 'CONFIRMED'
  AND platform_confirmation.confirmation_result = 'AGREE'
  AND operator_confirmation.confirmation_result = 'AGREE'
  AND rd.adjustment_detail_id IS NULL
ORDER BY rd.discovered_at, rd.difference_id;

-- ---------------------------------------------------------------------------
-- Q05：普通票—红字票链路与净开票额
-- 关系：invoice_record（普通票）、invoice_record（红字票）、
--       settlement_statement、operator、station
-- 用途：检查原票红冲状态、红字票引用和结算单剩余可开票金额。
-- ---------------------------------------------------------------------------
SELECT
    ss.statement_no,
    op.name AS operator_name,
    st.name AS station_name,
    ss.payable_amount,
    normal_invoice.invoice_id AS normal_invoice_id,
    normal_invoice.invoice_number AS normal_invoice_number,
    normal_invoice.invoice_amount AS normal_invoice_amount,
    normal_invoice.status AS normal_invoice_status,
    red_invoice.invoice_id AS red_invoice_id,
    red_invoice.invoice_number AS red_invoice_number,
    red_invoice.invoice_amount AS red_invoice_amount,
    red_invoice.status AS red_invoice_status,
    normal_invoice.invoice_amount
      - COALESCE(red_invoice.invoice_amount, 0.00) AS net_invoice_amount,
    GREATEST(
        ss.payable_amount
        - normal_invoice.invoice_amount
        + COALESCE(red_invoice.invoice_amount, 0.00),
        0.00
    ) AS remaining_invoice_amount
FROM invoice_record AS normal_invoice
JOIN settlement_statement AS ss
  ON ss.settlement_id = normal_invoice.settlement_id
JOIN `operator` AS op
  ON op.operator_id = ss.operator_id
JOIN station AS st
  ON st.station_id = ss.station_id
LEFT JOIN invoice_record AS red_invoice
  ON red_invoice.original_invoice_id = normal_invoice.invoice_id
 AND red_invoice.invoice_type = 'RED_LETTER'
 AND red_invoice.status = 'ISSUED'
WHERE normal_invoice.invoice_type = 'NORMAL'
  AND normal_invoice.status IN ('ISSUED', 'RED_FLUSHED')
ORDER BY ss.statement_no, normal_invoice.invoice_id;

-- ---------------------------------------------------------------------------
-- Q06：订单资金与结算金额复核
-- 关系：charging_order、payment_record、refund_record、settlement_detail、
--       settlement_statement、station
-- 用途：支付和退款分别预聚合，避免多支付 × 多退款造成金额重复。
-- ---------------------------------------------------------------------------
WITH successful_payment AS (
    SELECT
        pr.order_id,
        SUM(pr.amount) AS successful_paid_amount
    FROM payment_record AS pr
    WHERE pr.status = 'SUCCESS'
    GROUP BY pr.order_id
), successful_refund AS (
    SELECT
        pr.order_id,
        SUM(rr.amount) AS refunded_amount
    FROM refund_record AS rr
    JOIN payment_record AS pr
      ON pr.payment_id = rr.payment_id
     AND pr.status = 'SUCCESS'
    GROUP BY pr.order_id
)
SELECT
    ss.statement_no,
    st.station_id,
    st.name AS station_name,
    o.order_id,
    o.gross_amount,
    o.discount_amount,
    o.gross_amount - o.discount_amount AS order_payable_amount,
    COALESCE(sp.successful_paid_amount, 0.00) AS successful_paid_amount,
    COALESCE(sr.refunded_amount, 0.00) AS refunded_amount,
    COALESCE(sp.successful_paid_amount, 0.00)
      - COALESCE(sr.refunded_amount, 0.00) AS net_received_amount,
    sd.payable_amount AS original_settlement_amount,
    COALESCE(refund_adjustment.refund_settlement_amount, 0.00)
        AS later_refund_settlement_amount,
    sd.payable_amount
      + COALESCE(refund_adjustment.refund_settlement_amount, 0.00)
        AS settlement_amount_after_refund
FROM settlement_detail AS sd
JOIN settlement_statement AS ss
  ON ss.settlement_id = sd.settlement_id
JOIN station AS st
  ON st.station_id = ss.station_id
JOIN charging_order AS o
  ON o.order_id = sd.order_id
LEFT JOIN successful_payment AS sp
  ON sp.order_id = o.order_id
LEFT JOIN successful_refund AS sr
  ON sr.order_id = o.order_id
LEFT JOIN (
    SELECT
        original_detail_id,
        SUM(payable_amount) AS refund_settlement_amount
    FROM settlement_detail
    WHERE detail_type = 'REFUND_ADJUSTMENT'
    GROUP BY original_detail_id
) AS refund_adjustment
  ON refund_adjustment.original_detail_id = sd.settlement_detail_id
WHERE sd.detail_type = 'ORDER'
ORDER BY ss.statement_no, o.order_id;

-- Q07：业务查询验收摘要。正式种子下所有结果均应 PASS。
SELECT
    'Q07 settlement_business_query_summary' AS check_item,
    (SELECT COUNT(*) FROM settlement_statement) AS statement_count,
    (SELECT COUNT(*) FROM settlement_detail WHERE detail_type = 'ORDER')
        AS order_detail_count,
    (SELECT COUNT(*) FROM settlement_detail WHERE detail_type = 'REFUND_ADJUSTMENT')
        AS refund_detail_count,
    (SELECT COUNT(*) FROM v_reconciliation_pending WHERE next_action = 'CREATE_ADJUSTMENT')
        AS adjustment_queue_count,
    (SELECT COUNT(*) FROM invoice_record WHERE invoice_type = 'RED_LETTER')
        AS red_invoice_count,
    IF(
        (SELECT COUNT(*) FROM settlement_statement) = 40
        AND (SELECT COUNT(*) FROM settlement_detail WHERE detail_type = 'ORDER') = 40
        AND (SELECT COUNT(*) FROM settlement_detail WHERE detail_type = 'REFUND_ADJUSTMENT') = 20
        AND (SELECT COUNT(*) FROM v_reconciliation_pending WHERE next_action = 'CREATE_ADJUSTMENT') = 20
        AND (SELECT COUNT(*) FROM invoice_record WHERE invoice_type = 'RED_LETTER') = 20,
        'PASS',
        'FAIL'
    ) AS result;
