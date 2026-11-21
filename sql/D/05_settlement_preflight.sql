-- ⑤ 结算与对账：首次建表前置检查
-- 本脚本只读，不创建、修改或删除任何数据库对象和业务数据。
-- 只有 P01～P04 全部 PASS，且 P05 列出的目标表为空时，才执行 05_settlement_schema.sql。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

SELECT VERSION() AS mysql_version,
       DATABASE() AS database_name,
       @@session.time_zone AS session_time_zone;

-- P01：DDL 直接依赖的五张 B 表必须存在。
SELECT
    'P01 dependency_table_count' AS check_item,
    COUNT(*) AS actual_value,
    5 AS expected_value,
    IF(COUNT(*) = 5, 'PASS', 'FAIL') AS result
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_TYPE = 'BASE TABLE'
  AND TABLE_NAME IN (
      'operator',
      'station',
      'charging_order',
      'payment_record',
      'refund_record'
  );

-- P02：五个被引用编号字段必须存在且均为 BIGINT UNSIGNED。
SELECT
    'P02 valid_dependency_id_count' AS check_item,
    COUNT(*) AS actual_value,
    5 AS expected_value,
    IF(COUNT(*) = 5, 'PASS', 'FAIL') AS result
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = 'charging_platform'
  AND COLUMN_TYPE = 'bigint unsigned'
  AND (
      (TABLE_NAME = 'operator' AND COLUMN_NAME = 'operator_id')
      OR (TABLE_NAME = 'station' AND COLUMN_NAME = 'station_id')
      OR (TABLE_NAME = 'charging_order' AND COLUMN_NAME = 'order_id')
      OR (TABLE_NAME = 'payment_record' AND COLUMN_NAME = 'payment_id')
      OR (TABLE_NAME = 'refund_record' AND COLUMN_NAME = 'refund_id')
  );

-- P03：B 依赖表必须使用统一引擎和排序规则。
SELECT
    'P03 invalid_dependency_engine_or_collation' AS check_item,
    COUNT(*) AS actual_value,
    0 AS expected_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_NAME IN (
      'operator',
      'station',
      'charging_order',
      'payment_record',
      'refund_record'
  )
  AND (
      ENGINE <> 'InnoDB'
      OR TABLE_COLLATION <> 'utf8mb4_0900_ai_ci'
  );

-- P04：五张目标表必须全部尚未创建，避免 CREATE TABLE 中途失败留下部分结构。
SELECT
    'P04 existing_target_object_count' AS check_item,
    COUNT(*) AS actual_value,
    0 AS expected_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_NAME IN (
      'settlement_statement',
      'settlement_detail',
      'reconciliation_difference',
      'reconciliation_confirmation',
      'invoice_record'
  );

-- P05：若出现任何行，请停止执行 DDL 并先核对已有对象；不要直接删除。
SELECT TABLE_NAME, TABLE_TYPE, ENGINE, TABLE_COLLATION
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_NAME IN (
      'settlement_statement',
      'settlement_detail',
      'reconciliation_difference',
      'reconciliation_confirmation',
      'invoice_record'
  )
ORDER BY TABLE_NAME;
