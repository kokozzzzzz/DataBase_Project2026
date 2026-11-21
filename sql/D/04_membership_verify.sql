-- ④ 用户与会员运营：核心 DDL 只读验证
-- 本脚本只查询 information_schema，不修改任何业务数据。

USE charging_platform;

SELECT
    'core_table_count' AS check_item,
    COUNT(*) AS actual_value,
    9 AS expected_value,
    IF(COUNT(*) = 9, 'PASS', 'FAIL') AS result
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_NAME IN (
      'membership_level',
      'user',
      'vehicle',
      'membership_record',
      'promotion',
      'enterprise_customer',
      'fleet',
      'fleet_vehicle',
      'fleet_quota_record'
  );

SELECT
    'invalid_engine_or_collation' AS check_item,
    COUNT(*) AS actual_value,
    0 AS expected_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_NAME IN (
      'membership_level',
      'user',
      'vehicle',
      'membership_record',
      'promotion',
      'enterprise_customer',
      'fleet',
      'fleet_vehicle',
      'fleet_quota_record'
  )
  AND (ENGINE <> 'InnoDB' OR TABLE_COLLATION <> 'utf8mb4_0900_ai_ci');

SELECT
    CONSTRAINT_TYPE,
    COUNT(*) AS constraint_count
FROM information_schema.TABLE_CONSTRAINTS
WHERE CONSTRAINT_SCHEMA = 'charging_platform'
  AND TABLE_NAME IN (
      'membership_level',
      'user',
      'vehicle',
      'membership_record',
      'promotion',
      'enterprise_customer',
      'fleet',
      'fleet_vehicle',
      'fleet_quota_record'
  )
GROUP BY CONSTRAINT_TYPE
ORDER BY CONSTRAINT_TYPE;

SELECT
    'primary_key_count' AS check_item,
    COUNT(*) AS actual_value,
    9 AS expected_value,
    IF(COUNT(*) = 9, 'PASS', 'FAIL') AS result
FROM information_schema.TABLE_CONSTRAINTS
WHERE CONSTRAINT_SCHEMA = 'charging_platform'
  AND CONSTRAINT_TYPE = 'PRIMARY KEY'
  AND TABLE_NAME IN (
      'membership_level', 'user', 'vehicle', 'membership_record',
      'promotion', 'enterprise_customer', 'fleet', 'fleet_vehicle',
      'fleet_quota_record'
  );

SELECT
    'foreign_key_count' AS check_item,
    COUNT(*) AS actual_value,
    10 AS expected_value,
    IF(COUNT(*) = 10, 'PASS', 'FAIL') AS result
FROM information_schema.TABLE_CONSTRAINTS
WHERE CONSTRAINT_SCHEMA = 'charging_platform'
  AND CONSTRAINT_TYPE = 'FOREIGN KEY'
  AND TABLE_NAME IN (
      'membership_level', 'user', 'vehicle', 'membership_record',
      'promotion', 'enterprise_customer', 'fleet', 'fleet_vehicle',
      'fleet_quota_record'
  );

SELECT
    'unique_constraint_count' AS check_item,
    COUNT(*) AS actual_value,
    7 AS expected_value,
    IF(COUNT(*) = 7, 'PASS', 'FAIL') AS result
FROM information_schema.TABLE_CONSTRAINTS
WHERE CONSTRAINT_SCHEMA = 'charging_platform'
  AND CONSTRAINT_TYPE = 'UNIQUE'
  AND TABLE_NAME IN (
      'membership_level', 'user', 'vehicle', 'membership_record',
      'promotion', 'enterprise_customer', 'fleet', 'fleet_vehicle',
      'fleet_quota_record'
  );

SELECT
    'check_constraint_count' AS check_item,
    COUNT(*) AS actual_value,
    28 AS expected_value,
    IF(COUNT(*) = 28, 'PASS', 'FAIL') AS result
FROM information_schema.TABLE_CONSTRAINTS
WHERE CONSTRAINT_SCHEMA = 'charging_platform'
  AND CONSTRAINT_TYPE = 'CHECK'
  AND TABLE_NAME IN (
      'membership_level', 'user', 'vehicle', 'membership_record',
      'promotion', 'enterprise_customer', 'fleet', 'fleet_vehicle',
      'fleet_quota_record'
  );

SELECT
    'invalid_id_column_type' AS check_item,
    COUNT(*) AS actual_value,
    0 AS expected_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_NAME IN (
      'membership_level',
      'user',
      'vehicle',
      'membership_record',
      'promotion',
      'enterprise_customer',
      'fleet',
      'fleet_vehicle',
      'fleet_quota_record'
  )
  AND COLUMN_NAME LIKE '%\_id' ESCAPE '\\'
  AND COLUMN_TYPE <> 'bigint unsigned';

SELECT
    TABLE_NAME,
    COLUMN_NAME,
    COLUMN_TYPE
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_NAME IN (
      'membership_level',
      'user',
      'vehicle',
      'membership_record',
      'promotion',
      'enterprise_customer',
      'fleet',
      'fleet_vehicle',
      'fleet_quota_record'
  )
  AND COLUMN_NAME LIKE '%\_id' ESCAPE '\\'
ORDER BY TABLE_NAME, ORDINAL_POSITION;

