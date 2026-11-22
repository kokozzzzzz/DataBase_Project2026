-- ⑤ 结算与对账：三个业务视图只读验收
-- 前置：已执行 sql/D/05_settlement_views.sql。
-- 本脚本只查询元数据和视图，不修改数据库对象或业务数据。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

-- V01：三个指定视图必须全部存在。
SELECT
    'V01 settlement_view_count' AS check_item,
    COUNT(*) AS actual_value,
    3 AS expected_value,
    IF(COUNT(*) = 3, 'PASS', 'FAIL') AS result
FROM information_schema.VIEWS
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_NAME IN (
      'v_settlement_statement_summary',
      'v_settlement_order_detail',
      'v_reconciliation_pending'
  );

-- V02：视图必须使用调用者权限，避免以定义者权限扩大数据访问范围。
SELECT
    'V02 invalid_security_type' AS check_item,
    COUNT(*) AS actual_value,
    0 AS expected_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM information_schema.VIEWS
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_NAME IN (
      'v_settlement_statement_summary',
      'v_settlement_order_detail',
      'v_reconciliation_pending'
  )
  AND SECURITY_TYPE <> 'INVOKER';

-- V03：各视图字段数量与接口定义一致。
WITH expected_column AS (
    SELECT 'v_settlement_statement_summary' AS table_name, 28 AS expected_count
    UNION ALL SELECT 'v_settlement_order_detail', 36
    UNION ALL SELECT 'v_reconciliation_pending', 23
), actual_column AS (
    SELECT TABLE_NAME AS table_name, COUNT(*) AS actual_count
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = 'charging_platform'
      AND TABLE_NAME IN (
          'v_settlement_statement_summary',
          'v_settlement_order_detail',
          'v_reconciliation_pending'
      )
    GROUP BY TABLE_NAME
)
SELECT
    expected.table_name,
    COALESCE(actual.actual_count, 0) AS actual_count,
    expected.expected_count,
    IF(
        COALESCE(actual.actual_count, 0) = expected.expected_count,
        'PASS',
        'FAIL'
    ) AS result
FROM expected_column AS expected
LEFT JOIN actual_column AS actual
  ON actual.table_name = expected.table_name
ORDER BY expected.table_name;

-- V04：公开视图不得暴露确认人姓名或纳税人识别号密文。
SELECT
    'V04 sensitive_column_exposure' AS check_item,
    COUNT(*) AS actual_value,
    0 AS expected_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_NAME IN (
      'v_settlement_statement_summary',
      'v_settlement_order_detail',
      'v_reconciliation_pending'
  )
  AND COLUMN_NAME IN ('confirmer_name', 'tax_number_ciphertext');

-- V05：当前结算表尚未生成数据，因此三个视图均应为 0 行。
-- 后续正式种子完成后，本检查只用于展示实际行数，不再要求为 0。
SELECT 'v_settlement_statement_summary' AS view_name, COUNT(*) AS row_count
FROM v_settlement_statement_summary
UNION ALL
SELECT 'v_settlement_order_detail', COUNT(*)
FROM v_settlement_order_detail
UNION ALL
SELECT 'v_reconciliation_pending', COUNT(*)
FROM v_reconciliation_pending
ORDER BY view_name;

