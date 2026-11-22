-- ⑤ 结算与对账：正式联调测试数据
-- 目标：五张结算表均不少于 20 行，并形成可演示的跨期业务状态。
-- 前置：
--   1. B-FORMAL-v1 已提交，DP03=40、DP06=20；
--   2. 已执行 05_settlement_upgrade_signed_payable.sql；
--   3. 已执行 05_settlement_views.sql 和 05_settlement_procedure.sql；
--   4. 五张结算表当前全部为 0 行。
--
-- 运行方式：
--   预演回滚：python -m app.run_sql --file sql/D/05_settlement_seed.sql
--   正式提交：python -m app.run_sql --file sql/D/05_settlement_seed.sql --commit
--
-- 本脚本只 INSERT/UPDATE 测试数据，不删除或覆盖其他模块数据。
-- 不带 --commit 时，批处理连接关闭后事务自动回滚。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

START TRANSACTION;

SET @d_seed_existing_rows := (
    (SELECT COUNT(*) FROM settlement_statement)
    + (SELECT COUNT(*) FROM settlement_detail)
    + (SELECT COUNT(*) FROM reconciliation_difference)
    + (SELECT COUNT(*) FROM reconciliation_confirmation)
    + (SELECT COUNT(*) FROM invoice_record)
);

SELECT
    'D01 settlement_seed_empty_target' AS check_item,
    @d_seed_existing_rows AS actual_value,
    0 AS expected_value,
    IF(@d_seed_existing_rows = 0, 'PASS', 'FAIL') AS result;

-- 20 个场站分别生成 11 月基础结算和 12 月跨期退款调整。
CALL sp_generate_settlement_statement(
    7200001, 7200001, '2026-11-01', '2026-12-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2026-12-02 09:00:00', @d_seed_settlement_id
);
CALL sp_generate_settlement_statement(
    7200001, 7200001, '2026-12-01', '2027-01-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2027-01-02 09:00:00', @d_seed_settlement_id
);

CALL sp_generate_settlement_statement(
    7200002, 7200002, '2026-11-01', '2026-12-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2026-12-02 09:00:00', @d_seed_settlement_id
);
CALL sp_generate_settlement_statement(
    7200002, 7200002, '2026-12-01', '2027-01-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2027-01-02 09:00:00', @d_seed_settlement_id
);

CALL sp_generate_settlement_statement(
    7200003, 7200003, '2026-11-01', '2026-12-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2026-12-02 09:00:00', @d_seed_settlement_id
);
CALL sp_generate_settlement_statement(
    7200003, 7200003, '2026-12-01', '2027-01-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2027-01-02 09:00:00', @d_seed_settlement_id
);

CALL sp_generate_settlement_statement(
    7200004, 7200004, '2026-11-01', '2026-12-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2026-12-02 09:00:00', @d_seed_settlement_id
);
CALL sp_generate_settlement_statement(
    7200004, 7200004, '2026-12-01', '2027-01-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2027-01-02 09:00:00', @d_seed_settlement_id
);

CALL sp_generate_settlement_statement(
    7200005, 7200005, '2026-11-01', '2026-12-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2026-12-02 09:00:00', @d_seed_settlement_id
);
CALL sp_generate_settlement_statement(
    7200005, 7200005, '2026-12-01', '2027-01-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2027-01-02 09:00:00', @d_seed_settlement_id
);

CALL sp_generate_settlement_statement(
    7200006, 7200006, '2026-11-01', '2026-12-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2026-12-02 09:00:00', @d_seed_settlement_id
);
CALL sp_generate_settlement_statement(
    7200006, 7200006, '2026-12-01', '2027-01-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2027-01-02 09:00:00', @d_seed_settlement_id
);

CALL sp_generate_settlement_statement(
    7200007, 7200007, '2026-11-01', '2026-12-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2026-12-02 09:00:00', @d_seed_settlement_id
);
CALL sp_generate_settlement_statement(
    7200007, 7200007, '2026-12-01', '2027-01-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2027-01-02 09:00:00', @d_seed_settlement_id
);

CALL sp_generate_settlement_statement(
    7200008, 7200008, '2026-11-01', '2026-12-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2026-12-02 09:00:00', @d_seed_settlement_id
);
CALL sp_generate_settlement_statement(
    7200008, 7200008, '2026-12-01', '2027-01-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2027-01-02 09:00:00', @d_seed_settlement_id
);

CALL sp_generate_settlement_statement(
    7200009, 7200009, '2026-11-01', '2026-12-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2026-12-02 09:00:00', @d_seed_settlement_id
);
CALL sp_generate_settlement_statement(
    7200009, 7200009, '2026-12-01', '2027-01-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2027-01-02 09:00:00', @d_seed_settlement_id
);

CALL sp_generate_settlement_statement(
    7200010, 7200010, '2026-11-01', '2026-12-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2026-12-02 09:00:00', @d_seed_settlement_id
);
CALL sp_generate_settlement_statement(
    7200010, 7200010, '2026-12-01', '2027-01-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2027-01-02 09:00:00', @d_seed_settlement_id
);

CALL sp_generate_settlement_statement(
    7200011, 7200011, '2026-11-01', '2026-12-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2026-12-02 09:00:00', @d_seed_settlement_id
);
CALL sp_generate_settlement_statement(
    7200011, 7200011, '2026-12-01', '2027-01-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2027-01-02 09:00:00', @d_seed_settlement_id
);

CALL sp_generate_settlement_statement(
    7200012, 7200012, '2026-11-01', '2026-12-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2026-12-02 09:00:00', @d_seed_settlement_id
);
CALL sp_generate_settlement_statement(
    7200012, 7200012, '2026-12-01', '2027-01-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2027-01-02 09:00:00', @d_seed_settlement_id
);

CALL sp_generate_settlement_statement(
    7200013, 7200013, '2026-11-01', '2026-12-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2026-12-02 09:00:00', @d_seed_settlement_id
);
CALL sp_generate_settlement_statement(
    7200013, 7200013, '2026-12-01', '2027-01-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2027-01-02 09:00:00', @d_seed_settlement_id
);

CALL sp_generate_settlement_statement(
    7200014, 7200014, '2026-11-01', '2026-12-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2026-12-02 09:00:00', @d_seed_settlement_id
);
CALL sp_generate_settlement_statement(
    7200014, 7200014, '2026-12-01', '2027-01-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2027-01-02 09:00:00', @d_seed_settlement_id
);

CALL sp_generate_settlement_statement(
    7200015, 7200015, '2026-11-01', '2026-12-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2026-12-02 09:00:00', @d_seed_settlement_id
);
CALL sp_generate_settlement_statement(
    7200015, 7200015, '2026-12-01', '2027-01-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2027-01-02 09:00:00', @d_seed_settlement_id
);

CALL sp_generate_settlement_statement(
    7200016, 7200016, '2026-11-01', '2026-12-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2026-12-02 09:00:00', @d_seed_settlement_id
);
CALL sp_generate_settlement_statement(
    7200016, 7200016, '2026-12-01', '2027-01-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2027-01-02 09:00:00', @d_seed_settlement_id
);

CALL sp_generate_settlement_statement(
    7200017, 7200017, '2026-11-01', '2026-12-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2026-12-02 09:00:00', @d_seed_settlement_id
);
CALL sp_generate_settlement_statement(
    7200017, 7200017, '2026-12-01', '2027-01-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2027-01-02 09:00:00', @d_seed_settlement_id
);

CALL sp_generate_settlement_statement(
    7200018, 7200018, '2026-11-01', '2026-12-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2026-12-02 09:00:00', @d_seed_settlement_id
);
CALL sp_generate_settlement_statement(
    7200018, 7200018, '2026-12-01', '2027-01-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2027-01-02 09:00:00', @d_seed_settlement_id
);

CALL sp_generate_settlement_statement(
    7200019, 7200019, '2026-11-01', '2026-12-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2026-12-02 09:00:00', @d_seed_settlement_id
);
CALL sp_generate_settlement_statement(
    7200019, 7200019, '2026-12-01', '2027-01-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2027-01-02 09:00:00', @d_seed_settlement_id
);

CALL sp_generate_settlement_statement(
    7200020, 7200020, '2026-11-01', '2026-12-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2026-12-02 09:00:00', @d_seed_settlement_id
);
CALL sp_generate_settlement_statement(
    7200020, 7200020, '2026-12-01', '2027-01-01',
    0.800000, 0.800000, 0.100000, 0.500000,
    '2027-01-02 09:00:00', @d_seed_settlement_id
);

-- 11 月结算没有待处理差异，先进入 CONFIRMED，供普通票和红字票测试。
UPDATE settlement_statement
   SET status = 'CONFIRMED',
       confirmed_at = '2026-12-03 09:00:00'
 WHERE period_start = '2026-11-01'
   AND period_end = '2026-12-01'
   AND operator_id BETWEEN 7200001 AND 7200020
   AND station_id = operator_id
   AND status = 'GENERATED';

-- 每个 12 月负结算单建立一条退款差异，回指实际发生退款的订单。
INSERT INTO reconciliation_difference (
    settlement_id,
    order_id,
    difference_type,
    expected_value,
    actual_value,
    difference_unit,
    description,
    status,
    resolution,
    discovered_at
)
SELECT
    december_statement.settlement_id,
    refund_detail.order_id,
    'REFUND',
    refund_detail.refund_amount,
    refund_detail.refund_amount + 0.5000,
    'CNY',
    '课程设计测试：运营商退款对账值比平台流水多0.50元',
    'CONFIRMED',
    '平台与运营商已同意差异，等待生成OTHER_ADJUSTMENT',
    '2027-01-03 09:00:00'
FROM settlement_statement AS december_statement
JOIN settlement_detail AS refund_detail
  ON refund_detail.settlement_id = december_statement.settlement_id
 AND refund_detail.detail_type = 'REFUND_ADJUSTMENT'
WHERE december_statement.period_start = '2026-12-01'
  AND december_statement.period_end = '2027-01-01'
  AND december_statement.operator_id BETWEEN 7200001 AND 7200020
ORDER BY december_statement.station_id;

-- 双方确认历史必须追加保存，不覆盖另一方或早期结论。
INSERT INTO reconciliation_confirmation (
    difference_id,
    confirming_party,
    confirmer_name,
    confirmation_result,
    confirmation_note,
    confirmed_at
)
SELECT
    difference.difference_id,
    party.confirming_party,
    CONCAT(
        IF(party.confirming_party = 'PLATFORM', '测试平台确认员-', '测试运营商确认员-'),
        difference.difference_id
    ),
    'AGREE',
    '课程设计虚构确认记录',
    CASE party.confirming_party
        WHEN 'PLATFORM' THEN '2027-01-03 10:00:00'
        ELSE '2027-01-03 11:00:00'
    END
FROM reconciliation_difference AS difference
JOIN settlement_statement AS statement
  ON statement.settlement_id = difference.settlement_id
JOIN (
    SELECT 'PLATFORM' AS confirming_party
    UNION ALL
    SELECT 'OPERATOR'
) AS party
WHERE statement.period_start = '2026-12-01'
  AND statement.period_end = '2027-01-01'
  AND statement.operator_id BETWEEN 7200001 AND 7200020
ORDER BY difference.difference_id, party.confirming_party;

-- 仅正净额且已确认的 11 月结算单开普通票。
INSERT INTO invoice_record (
    settlement_id,
    invoice_number,
    invoice_type,
    invoice_title,
    invoice_amount,
    issued_at,
    status
)
SELECT
    statement.settlement_id,
    CONCAT('D-NORMAL-', statement.station_id),
    'NORMAL',
    CONCAT('测试运营商', statement.operator_id),
    8.00,
    '2026-12-04 09:00:00',
    'ISSUED'
FROM settlement_statement AS statement
WHERE statement.period_start = '2026-11-01'
  AND statement.period_end = '2026-12-01'
  AND statement.operator_id BETWEEN 7200001 AND 7200020
  AND statement.status = 'CONFIRMED'
  AND statement.payable_amount > 0
ORDER BY statement.station_id;

-- 每张普通票开 1.00 元红字票；净开票额仍为正且不超过应结金额。
INSERT INTO invoice_record (
    settlement_id,
    invoice_number,
    invoice_type,
    invoice_title,
    invoice_amount,
    issued_at,
    status,
    original_invoice_id
)
SELECT
    normal_invoice.settlement_id,
    CONCAT('D-RED-', statement.station_id),
    'RED_LETTER',
    normal_invoice.invoice_title,
    1.00,
    '2026-12-05 09:00:00',
    'ISSUED',
    normal_invoice.invoice_id
FROM invoice_record AS normal_invoice
JOIN settlement_statement AS statement
  ON statement.settlement_id = normal_invoice.settlement_id
WHERE normal_invoice.invoice_type = 'NORMAL'
  AND normal_invoice.status = 'ISSUED'
  AND normal_invoice.invoice_number LIKE 'D-NORMAL-%'
ORDER BY statement.station_id;

UPDATE invoice_record AS normal_invoice
JOIN invoice_record AS red_invoice
  ON red_invoice.original_invoice_id = normal_invoice.invoice_id
 AND red_invoice.invoice_type = 'RED_LETTER'
 AND red_invoice.status = 'ISSUED'
   SET normal_invoice.status = 'RED_FLUSHED'
 WHERE normal_invoice.invoice_type = 'NORMAL'
   AND normal_invoice.status = 'ISSUED'
   AND normal_invoice.invoice_number LIKE 'D-NORMAL-%';

-- 事务内数量与金额摘要。
SELECT 'invoice_record' AS table_name, COUNT(*) AS row_count FROM invoice_record
UNION ALL SELECT 'reconciliation_confirmation', COUNT(*) FROM reconciliation_confirmation
UNION ALL SELECT 'reconciliation_difference', COUNT(*) FROM reconciliation_difference
UNION ALL SELECT 'settlement_detail', COUNT(*) FROM settlement_detail
UNION ALL SELECT 'settlement_statement', COUNT(*) FROM settlement_statement
ORDER BY table_name;

SELECT
    SUM(period_start = '2026-11-01') AS november_statement_count,
    SUM(period_start = '2026-12-01') AS december_statement_count,
    SUM(payable_amount) AS total_net_settlement_amount
FROM settlement_statement;

SELECT
    (SELECT COUNT(*) FROM v_settlement_statement_summary) AS statement_view_rows,
    (SELECT COUNT(*) FROM v_settlement_order_detail) AS detail_view_rows,
    (SELECT COUNT(*) FROM v_reconciliation_pending) AS pending_view_rows,
    (SELECT COALESCE(SUM(net_invoice_amount), 0)
       FROM v_settlement_statement_summary) AS total_net_invoice_amount;

SELECT
    'TRANSACTION IS OPEN: preview without --commit rolls back on exit; rerun with --commit only after all counts and totals pass.'
    AS next_action;

