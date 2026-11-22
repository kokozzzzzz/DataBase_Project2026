-- ⑤ 结算与对账：生成过程元数据与真实事务回滚验收
-- 前置：
--   1. 已执行 sql/D/05_settlement_procedure.sql；
--   2. B-FORMAL-v1 已提交，D 五张结算表尚为空；
--   3. 固定数据中 7200001 场站有 2 笔 11 月订单和 1 笔 12 月退款。
-- 本脚本生成 11 月基础结算和 12 月退款调整后统一 ROLLBACK。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

-- P01：过程元数据。
SELECT
    'P01 settlement_procedure' AS check_item,
    COUNT(*) AS actual_value,
    1 AS expected_value,
    IF(COUNT(*) = 1, 'PASS', 'FAIL') AS result
FROM information_schema.ROUTINES
WHERE ROUTINE_SCHEMA = 'charging_platform'
  AND ROUTINE_TYPE = 'PROCEDURE'
  AND ROUTINE_NAME = 'sp_generate_settlement_statement'
  AND SECURITY_TYPE = 'INVOKER'
  AND SQL_DATA_ACCESS = 'MODIFIES SQL DATA';

-- P02：9 个 IN 参数和 1 个 OUT 参数。
SELECT
    'P02 settlement_parameter_count' AS check_item,
    COUNT(*) AS actual_value,
    10 AS expected_value,
    IF(COUNT(*) = 10, 'PASS', 'FAIL') AS result
FROM information_schema.PARAMETERS
WHERE SPECIFIC_SCHEMA = 'charging_platform'
  AND SPECIFIC_NAME = 'sp_generate_settlement_statement';

START TRANSACTION;

CALL sp_generate_settlement_statement(
    7200001,
    7200001,
    '2026-11-01',
    '2026-12-01',
    0.800000,
    0.800000,
    0.100000,
    0.500000,
    '2026-12-02 09:00:00',
    @november_settlement_id
);

-- 相同参数重试必须复用原结算单，不增加明细。
CALL sp_generate_settlement_statement(
    7200001,
    7200001,
    '2026-11-01',
    '2026-12-01',
    0.800000,
    0.800000,
    0.100000,
    0.500000,
    '2026-12-02 09:00:00',
    @november_retry_id
);

-- P03：11 月两笔足额支付订单只生成一张结算单和两条基础明细。
SELECT
    'P03 november_generation_and_idempotency' AS check_item,
    @november_settlement_id AS settlement_id,
    @november_retry_id AS retry_id,
    COUNT(*) AS detail_count,
    statement.total_kwh,
    statement.total_electricity_fee,
    statement.total_service_fee,
    statement.total_discount_amount,
    statement.payable_amount,
    IF(
        @november_settlement_id = @november_retry_id
        AND COUNT(*) = 2
        AND statement.total_kwh = 32.000
        AND statement.total_electricity_fee = 18.80
        AND statement.total_service_fee = 6.40
        AND statement.total_discount_amount = 2.00
        AND statement.payable_amount = 16.64,
        'PASS',
        'FAIL'
    ) AS result
FROM settlement_statement AS statement
JOIN settlement_detail AS detail
  ON detail.settlement_id = statement.settlement_id
WHERE statement.settlement_id = @november_settlement_id
GROUP BY
    statement.settlement_id,
    statement.total_kwh,
    statement.total_electricity_fee,
    statement.total_service_fee,
    statement.total_discount_amount,
    statement.payable_amount;

CALL sp_generate_settlement_statement(
    7200001,
    7200001,
    '2026-12-01',
    '2027-01-01',
    0.800000,
    0.800000,
    0.100000,
    0.500000,
    '2027-01-02 09:00:00',
    @december_settlement_id
);

-- P04：12 月只有退款时生成一条可追溯负向调整，结算单净额为负。
SELECT
    'P04 december_refund_adjustment' AS check_item,
    statement.settlement_id,
    COUNT(*) AS detail_count,
    MIN(detail.detail_type) AS detail_type,
    statement.total_refund_amount,
    statement.total_adjustment_amount,
    statement.payable_amount,
    IF(
        COUNT(*) = 1
        AND MIN(detail.detail_type) = 'REFUND_ADJUSTMENT'
        AND MIN(detail.original_detail_id) IS NOT NULL
        AND MIN(detail.refund_id) IS NOT NULL
        AND statement.total_refund_amount = 3.00
        AND statement.total_adjustment_amount = -2.21
        AND statement.payable_amount = -2.21,
        'PASS',
        'FAIL'
    ) AS result
FROM settlement_statement AS statement
JOIN settlement_detail AS detail
  ON detail.settlement_id = statement.settlement_id
WHERE statement.settlement_id = @december_settlement_id
GROUP BY
    statement.settlement_id,
    statement.total_refund_amount,
    statement.total_adjustment_amount,
    statement.payable_amount;

-- P05：三个业务视图能读取事务内数据。
SELECT
    'P05 settlement_view_rows_in_transaction' AS check_item,
    (SELECT COUNT(*) FROM v_settlement_statement_summary) AS statement_rows,
    (SELECT COUNT(*) FROM v_settlement_order_detail) AS detail_rows,
    (SELECT COUNT(*) FROM v_reconciliation_pending) AS pending_rows,
    IF(
        (SELECT COUNT(*) FROM v_settlement_statement_summary) = 2
        AND (SELECT COUNT(*) FROM v_settlement_order_detail) = 3
        AND (SELECT COUNT(*) FROM v_reconciliation_pending) = 0,
        'PASS',
        'FAIL'
    ) AS result;

ROLLBACK;

-- P06：回滚后五张结算表仍为空。
SELECT
    'P06 rollback_cleanup' AS check_item,
    (SELECT COUNT(*) FROM settlement_statement) AS statement_count,
    (SELECT COUNT(*) FROM settlement_detail) AS detail_count,
    (SELECT COUNT(*) FROM reconciliation_difference) AS difference_count,
    (SELECT COUNT(*) FROM reconciliation_confirmation) AS confirmation_count,
    (SELECT COUNT(*) FROM invoice_record) AS invoice_count,
    IF(
        (SELECT COUNT(*) FROM settlement_statement) = 0
        AND (SELECT COUNT(*) FROM settlement_detail) = 0
        AND (SELECT COUNT(*) FROM reconciliation_difference) = 0
        AND (SELECT COUNT(*) FROM reconciliation_confirmation) = 0
        AND (SELECT COUNT(*) FROM invoice_record) = 0,
        'PASS',
        'FAIL'
    ) AS result;

