-- ⑤ 结算与对账：正式测试数据只读验收
-- 前置：已使用 --commit 成功执行 sql/D/05_settlement_seed.sql。
-- 本脚本只查询，不修改数据库对象或业务数据。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

-- SD01：五张表达到预定规模。
WITH expected_count AS (
    SELECT 'settlement_statement' AS table_name, 40 AS expected_count
    UNION ALL SELECT 'settlement_detail', 60
    UNION ALL SELECT 'reconciliation_difference', 20
    UNION ALL SELECT 'reconciliation_confirmation', 40
    UNION ALL SELECT 'invoice_record', 40
), actual_count AS (
    SELECT 'settlement_statement' AS table_name, COUNT(*) AS actual_count
    FROM settlement_statement
    UNION ALL SELECT 'settlement_detail', COUNT(*) FROM settlement_detail
    UNION ALL SELECT 'reconciliation_difference', COUNT(*) FROM reconciliation_difference
    UNION ALL SELECT 'reconciliation_confirmation', COUNT(*) FROM reconciliation_confirmation
    UNION ALL SELECT 'invoice_record', COUNT(*) FROM invoice_record
)
SELECT
    expected.table_name,
    actual.actual_count,
    expected.expected_count,
    IF(actual.actual_count = expected.expected_count, 'PASS', 'FAIL') AS result
FROM expected_count AS expected
JOIN actual_count AS actual
  ON actual.table_name = expected.table_name
ORDER BY expected.table_name;

-- SD02：20个场站各有11月正结算和12月负调整账期。
SELECT
    'SD02 statement_period_distribution' AS check_item,
    SUM(period_start = '2026-11-01' AND payable_amount > 0) AS november_positive,
    SUM(period_start = '2026-12-01' AND payable_amount < 0) AS december_negative,
    IF(
        SUM(period_start = '2026-11-01' AND payable_amount > 0) = 20
        AND SUM(period_start = '2026-12-01' AND payable_amount < 0) = 20,
        'PASS',
        'FAIL'
    ) AS result
FROM settlement_statement;

-- SD03：40条基础订单和20条退款流水均只进入一次。
SELECT
    'SD03 detail_type_and_uniqueness' AS check_item,
    SUM(detail_type = 'ORDER') AS order_detail_count,
    SUM(detail_type = 'REFUND_ADJUSTMENT') AS refund_detail_count,
    COUNT(DISTINCT base_order_id) AS distinct_base_order_count,
    COUNT(DISTINCT refund_id) AS distinct_refund_count,
    IF(
        SUM(detail_type = 'ORDER') = 40
        AND SUM(detail_type = 'REFUND_ADJUSTMENT') = 20
        AND COUNT(DISTINCT base_order_id) = 40
        AND COUNT(DISTINCT refund_id) = 20,
        'PASS',
        'FAIL'
    ) AS result
FROM settlement_detail;

-- SD04：每条差异均有平台和运营商最新AGREE确认。
SELECT
    'SD04 bilateral_confirmation' AS check_item,
    COUNT(*) AS difference_count,
    SUM(platform_result = 'AGREE' AND operator_result = 'AGREE') AS both_agreed_count,
    IF(
        COUNT(*) = 20
        AND SUM(platform_result = 'AGREE' AND operator_result = 'AGREE') = 20,
        'PASS',
        'FAIL'
    ) AS result
FROM v_reconciliation_pending;

-- SD05：普通票、红字票和净开票额满足规则，负结算单没有普通票。
SELECT
    'SD05 invoice_integrity' AS check_item,
    SUM(invoice_type = 'NORMAL' AND status = 'RED_FLUSHED') AS normal_flushed_count,
    SUM(invoice_type = 'RED_LETTER' AND status = 'ISSUED') AS red_issued_count,
    SUM(
        invoice_type = 'RED_LETTER'
        AND original_invoice_id IS NOT NULL
    ) AS valid_red_reference_count,
    IF(
        SUM(invoice_type = 'NORMAL' AND status = 'RED_FLUSHED') = 20
        AND SUM(invoice_type = 'RED_LETTER' AND status = 'ISSUED') = 20
        AND SUM(
            invoice_type = 'RED_LETTER'
            AND original_invoice_id IS NOT NULL
        ) = 20
        AND NOT EXISTS (
            SELECT 1
            FROM v_settlement_statement_summary
            WHERE net_invoice_amount < 0
               OR net_invoice_amount > GREATEST(payable_amount, 0)
        )
        AND NOT EXISTS (
            SELECT 1
            FROM invoice_record AS invoice
            JOIN settlement_statement AS statement
              ON statement.settlement_id = invoice.settlement_id
            WHERE statement.payable_amount <= 0
              AND invoice.invoice_type = 'NORMAL'
        ),
        'PASS',
        'FAIL'
    ) AS result
FROM invoice_record;

-- SD06：汇总金额与固定费率计算一致。
SELECT
    'SD06 financial_totals' AS check_item,
    SUM(payable_amount) AS total_net_settlement_amount,
    SUM(total_refund_amount) AS total_refund_amount,
    SUM(total_adjustment_amount) AS total_adjustment_amount,
    (SELECT SUM(net_invoice_amount)
       FROM v_settlement_statement_summary) AS total_net_invoice_amount,
    IF(
        SUM(payable_amount) = 288.60
        AND SUM(total_refund_amount) = 60.00
        AND SUM(total_adjustment_amount) = -44.20
        AND (SELECT SUM(net_invoice_amount)
               FROM v_settlement_statement_summary) = 140.00,
        'PASS',
        'FAIL'
    ) AS result
FROM settlement_statement;

-- SD07：视图行数与五张表业务状态一致。
SELECT
    'SD07 settlement_view_counts' AS check_item,
    (SELECT COUNT(*) FROM v_settlement_statement_summary) AS statement_rows,
    (SELECT COUNT(*) FROM v_settlement_order_detail) AS detail_rows,
    (SELECT COUNT(*) FROM v_reconciliation_pending) AS pending_rows,
    IF(
        (SELECT COUNT(*) FROM v_settlement_statement_summary) = 40
        AND (SELECT COUNT(*) FROM v_settlement_order_detail) = 60
        AND (SELECT COUNT(*) FROM v_reconciliation_pending) = 20,
        'PASS',
        'FAIL'
    ) AS result;

