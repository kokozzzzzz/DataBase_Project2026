-- ⑤ 结算与对账：关键查询执行计划
-- 适用环境：MySQL 8.0.46；前置为已提交 D ⑤ 正式测试数据。
-- 安全：EXPLAIN ANALYZE 仅执行并分析 SELECT，不修改业务数据。
-- 说明：当前正式种子规模较小，优化器选择小表全表扫描属于合理结果；
--       重点检查关联键是否使用主键、唯一索引或已设计的普通索引。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

-- E01：账期查询应使用 idx_settlement_station_period，明细关联使用外键索引。
EXPLAIN ANALYZE
SELECT
    ss.statement_no,
    st.name AS station_name,
    COUNT(sd.settlement_detail_id) AS detail_count,
    SUM(sd.payable_amount) AS detail_payable_amount
FROM settlement_statement AS ss
JOIN station AS st
  ON st.station_id = ss.station_id
JOIN `operator` AS op
  ON op.operator_id = ss.operator_id
LEFT JOIN settlement_detail AS sd
  ON sd.settlement_id = ss.settlement_id
WHERE ss.station_id = 7200001
  AND ss.period_start >= '2026-11-01'
  AND ss.period_end <= '2027-01-01'
GROUP BY ss.settlement_id, ss.statement_no, st.name;

-- E02：基础明细按结算单和类型读取，观察 idx_detail_statement_type_event。
EXPLAIN ANALYZE
SELECT
    ss.statement_no,
    sd.settlement_detail_id,
    o.order_id,
    u.user_id,
    v.vehicle_id,
    sd.payable_amount
FROM settlement_statement AS ss
JOIN settlement_detail AS sd
  ON sd.settlement_id = ss.settlement_id
 AND sd.detail_type = 'ORDER'
JOIN charging_order AS o
  ON o.order_id = sd.order_id
JOIN `user` AS u
  ON u.user_id = o.user_id
JOIN vehicle AS v
  ON v.vehicle_id = o.vehicle_id
WHERE ss.operator_id = 7200001
  AND ss.station_id = 7200001
  AND ss.period_start = '2026-11-01'
  AND ss.period_end = '2026-12-01';

-- E03：跨期退款通过 refund_id、original_detail_id 和主键完成追溯。
EXPLAIN ANALYZE
SELECT
    refund_detail.refund_id,
    refund_statement.statement_no AS refund_statement_no,
    original_statement.statement_no AS original_statement_no,
    refund_record.amount,
    refund_detail.payable_amount
FROM settlement_detail AS refund_detail
JOIN settlement_statement AS refund_statement
  ON refund_statement.settlement_id = refund_detail.settlement_id
JOIN settlement_detail AS original_detail
  ON original_detail.settlement_detail_id = refund_detail.original_detail_id
JOIN settlement_statement AS original_statement
  ON original_statement.settlement_id = original_detail.settlement_id
JOIN refund_record
  ON refund_record.refund_id = refund_detail.refund_id
WHERE refund_detail.order_id = 45
  AND refund_detail.detail_type = 'REFUND_ADJUSTMENT';

-- E04：差异按结算单和状态筛选，确认历史使用 difference/party/id 复合索引。
EXPLAIN ANALYZE
SELECT
    rd.difference_id,
    ss.statement_no,
    platform_confirmation.confirmation_result AS platform_result,
    operator_confirmation.confirmation_result AS operator_result
FROM reconciliation_difference AS rd
JOIN settlement_statement AS ss
  ON ss.settlement_id = rd.settlement_id
JOIN reconciliation_confirmation AS platform_confirmation
  ON platform_confirmation.difference_id = rd.difference_id
 AND platform_confirmation.confirming_party = 'PLATFORM'
JOIN reconciliation_confirmation AS operator_confirmation
  ON operator_confirmation.difference_id = rd.difference_id
 AND operator_confirmation.confirming_party = 'OPERATOR'
WHERE rd.settlement_id = (
    SELECT settlement_id
    FROM settlement_statement
    WHERE operator_id = 7200001
      AND station_id = 7200001
      AND period_start = '2026-12-01'
      AND period_end = '2027-01-01'
)
  AND rd.status = 'CONFIRMED';

-- E05：普通票按结算单关联，红字票使用 idx_invoice_original 回指原票。
EXPLAIN ANALYZE
SELECT
    ss.statement_no,
    normal_invoice.invoice_number,
    red_invoice.invoice_number AS red_invoice_number,
    normal_invoice.invoice_amount - COALESCE(red_invoice.invoice_amount, 0.00)
        AS net_invoice_amount
FROM settlement_statement AS ss
JOIN invoice_record AS normal_invoice
  ON normal_invoice.settlement_id = ss.settlement_id
 AND normal_invoice.invoice_type = 'NORMAL'
LEFT JOIN invoice_record AS red_invoice
  ON red_invoice.original_invoice_id = normal_invoice.invoice_id
 AND red_invoice.invoice_type = 'RED_LETTER'
WHERE ss.operator_id = 7200001
  AND ss.station_id = 7200001
  AND ss.period_start = '2026-11-01'
  AND ss.period_end = '2026-12-01';
