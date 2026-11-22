-- ⑤ 结算与对账：五张表结构验收
-- 依赖 sql/D/05_settlement_schema.sql 已成功执行。
-- 本脚本只查询 information_schema 和各表行数，不修改数据库对象或业务数据。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

-- S01：五张结算与对账表全部存在。
SELECT
    'S01 settlement_table_count' AS check_item,
    COUNT(*) AS actual_value,
    5 AS expected_value,
    IF(COUNT(*) = 5, 'PASS', 'FAIL') AS result
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_TYPE = 'BASE TABLE'
  AND TABLE_NAME IN (
      'settlement_statement',
      'settlement_detail',
      'reconciliation_difference',
      'reconciliation_confirmation',
      'invoice_record'
  );

-- S02：引擎和排序规则必须统一。
SELECT
    'S02 invalid_engine_or_collation' AS check_item,
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
  )
  AND (
      ENGINE <> 'InnoDB'
      OR TABLE_COLLATION <> 'utf8mb4_0900_ai_ci'
  );

-- S03：约束数量应为 5 个主键、13 个外键、7 个唯一约束、20 个 CHECK。
WITH expected_constraint AS (
    SELECT 'PRIMARY KEY' AS constraint_type, 5 AS expected_count
    UNION ALL SELECT 'FOREIGN KEY', 13
    UNION ALL SELECT 'UNIQUE', 7
    UNION ALL SELECT 'CHECK', 20
), actual_constraint AS (
    SELECT CONSTRAINT_TYPE AS constraint_type, COUNT(*) AS actual_count
    FROM information_schema.TABLE_CONSTRAINTS
    WHERE TABLE_SCHEMA = 'charging_platform'
      AND TABLE_NAME IN (
          'settlement_statement',
          'settlement_detail',
          'reconciliation_difference',
          'reconciliation_confirmation',
          'invoice_record'
      )
    GROUP BY CONSTRAINT_TYPE
)
SELECT
    e.constraint_type,
    COALESCE(a.actual_count, 0) AS actual_count,
    e.expected_count,
    IF(COALESCE(a.actual_count, 0) = e.expected_count, 'PASS', 'FAIL') AS result
FROM expected_constraint e
LEFT JOIN actual_constraint a
  ON a.constraint_type = e.constraint_type
ORDER BY FIELD(e.constraint_type, 'PRIMARY KEY', 'FOREIGN KEY', 'UNIQUE', 'CHECK');

-- S04：六个跨 B 模块外键必须引用正式主表和主键。
SELECT
    'S04 b_cross_module_fk_count' AS check_item,
    COUNT(*) AS actual_value,
    6 AS expected_value,
    IF(COUNT(*) = 6, 'PASS', 'FAIL') AS result
FROM information_schema.KEY_COLUMN_USAGE
WHERE TABLE_SCHEMA = 'charging_platform'
  AND (
      (TABLE_NAME = 'settlement_statement'
       AND COLUMN_NAME = 'operator_id'
       AND REFERENCED_TABLE_NAME = 'operator'
       AND REFERENCED_COLUMN_NAME = 'operator_id')
      OR
      (TABLE_NAME = 'settlement_statement'
       AND COLUMN_NAME = 'station_id'
       AND REFERENCED_TABLE_NAME = 'station'
       AND REFERENCED_COLUMN_NAME = 'station_id')
      OR
      (TABLE_NAME = 'settlement_detail'
       AND COLUMN_NAME = 'order_id'
       AND REFERENCED_TABLE_NAME = 'charging_order'
       AND REFERENCED_COLUMN_NAME = 'order_id')
      OR
      (TABLE_NAME = 'settlement_detail'
       AND COLUMN_NAME = 'payment_id'
       AND REFERENCED_TABLE_NAME = 'payment_record'
       AND REFERENCED_COLUMN_NAME = 'payment_id')
      OR
      (TABLE_NAME = 'settlement_detail'
       AND COLUMN_NAME = 'refund_id'
       AND REFERENCED_TABLE_NAME = 'refund_record'
       AND REFERENCED_COLUMN_NAME = 'refund_id')
      OR
      (TABLE_NAME = 'reconciliation_difference'
       AND COLUMN_NAME = 'order_id'
       AND REFERENCED_TABLE_NAME = 'charging_order'
       AND REFERENCED_COLUMN_NAME = 'order_id')
  );

-- S05：七个 D 模块内部外键必须全部存在。
SELECT
    'S05 internal_fk_count' AS check_item,
    COUNT(*) AS actual_value,
    7 AS expected_value,
    IF(COUNT(*) = 7, 'PASS', 'FAIL') AS result
FROM information_schema.KEY_COLUMN_USAGE
WHERE TABLE_SCHEMA = 'charging_platform'
  AND REFERENCED_TABLE_SCHEMA = 'charging_platform'
  AND REFERENCED_TABLE_NAME IN (
      'settlement_statement',
      'settlement_detail',
      'reconciliation_difference',
      'invoice_record'
  )
  AND TABLE_NAME IN (
      'settlement_detail',
      'reconciliation_difference',
      'reconciliation_confirmation',
      'invoice_record'
  );

-- S06：五张表所有 *_id 编号都必须使用 BIGINT UNSIGNED。
SELECT
    'S06 invalid_id_column_type' AS check_item,
    COUNT(*) AS actual_value,
    0 AS expected_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_NAME IN (
      'settlement_statement',
      'settlement_detail',
      'reconciliation_difference',
      'reconciliation_confirmation',
      'invoice_record'
  )
  AND COLUMN_NAME LIKE '%\_id'
  AND COLUMN_TYPE <> 'bigint unsigned';

-- S07：七个防重/业务唯一约束必须按约定名称存在。
SELECT
    'S07 named_unique_constraint_count' AS check_item,
    COUNT(*) AS actual_value,
    7 AS expected_value,
    IF(COUNT(*) = 7, 'PASS', 'FAIL') AS result
FROM information_schema.TABLE_CONSTRAINTS
WHERE TABLE_SCHEMA = 'charging_platform'
  AND CONSTRAINT_TYPE = 'UNIQUE'
  AND CONSTRAINT_NAME IN (
      'uk_settlement_statement_no',
      'uk_settlement_period',
      'uk_detail_payment',
      'uk_detail_refund',
      'uk_detail_base_order',
      'uk_difference_adjustment_detail',
      'uk_invoice_number'
  );

-- S08：基础订单防重编号和差异值必须是 STORED 生成列。
SELECT
    'S08 stored_generated_column_count' AS check_item,
    COUNT(*) AS actual_value,
    2 AS expected_value,
    IF(COUNT(*) = 2, 'PASS', 'FAIL') AS result
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = 'charging_platform'
  AND (
      (TABLE_NAME = 'settlement_detail' AND COLUMN_NAME = 'base_order_id')
      OR
      (TABLE_NAME = 'reconciliation_difference' AND COLUMN_NAME = 'difference_value')
  )
  AND EXTRA LIKE '%STORED GENERATED%';

-- S09：五张表字段总数和各表字段数必须与定稿数据字典一致。
WITH expected_column AS (
    SELECT 'settlement_statement' AS table_name, 26 AS expected_count
    UNION ALL SELECT 'settlement_detail', 22
    UNION ALL SELECT 'reconciliation_difference', 15
    UNION ALL SELECT 'reconciliation_confirmation', 8
    UNION ALL SELECT 'invoice_record', 12
), actual_column AS (
    SELECT TABLE_NAME AS table_name, COUNT(*) AS actual_count
    FROM information_schema.COLUMNS
    WHERE TABLE_SCHEMA = 'charging_platform'
      AND TABLE_NAME IN (
          'settlement_statement',
          'settlement_detail',
          'reconciliation_difference',
          'reconciliation_confirmation',
          'invoice_record'
      )
    GROUP BY TABLE_NAME
)
SELECT
    e.table_name,
    COALESCE(a.actual_count, 0) AS actual_count,
    e.expected_count,
    IF(COALESCE(a.actual_count, 0) = e.expected_count, 'PASS', 'FAIL') AS result
FROM expected_column e
LEFT JOIN actual_column a
  ON a.table_name = e.table_name
ORDER BY e.table_name;

-- S10：所有外键的删除、更新策略必须为 RESTRICT。
SELECT
    'S10 invalid_fk_rule_count' AS check_item,
    COUNT(*) AS actual_value,
    0 AS expected_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM information_schema.REFERENTIAL_CONSTRAINTS
WHERE CONSTRAINT_SCHEMA = 'charging_platform'
  AND TABLE_NAME IN (
      'settlement_statement',
      'settlement_detail',
      'reconciliation_difference',
      'reconciliation_confirmation',
      'invoice_record'
  )
  AND (
      DELETE_RULE <> 'RESTRICT'
      OR UPDATE_RULE <> 'RESTRICT'
  );

-- S11：结算单净额必须允许为负，以支持只有跨期退款、没有正向订单的账期。
SELECT
    'S11 signed_payable_constraint' AS check_item,
    COUNT(*) AS actual_value,
    1 AS expected_value,
    IF(COUNT(*) = 1, 'PASS', 'FAIL') AS result
FROM information_schema.CHECK_CONSTRAINTS
WHERE CONSTRAINT_SCHEMA = 'charging_platform'
  AND CONSTRAINT_NAME = 'ck_settlement_totals_valid'
  AND CHECK_CLAUSE NOT LIKE '%payable_amount%';

-- S12：首次建表后可查看行数；本查询不要求后续始终为空。
SELECT 'settlement_statement' AS table_name, COUNT(*) AS row_count FROM settlement_statement
UNION ALL SELECT 'settlement_detail', COUNT(*) FROM settlement_detail
UNION ALL SELECT 'reconciliation_difference', COUNT(*) FROM reconciliation_difference
UNION ALL SELECT 'reconciliation_confirmation', COUNT(*) FROM reconciliation_confirmation
UNION ALL SELECT 'invoice_record', COUNT(*) FROM invoice_record
ORDER BY table_name;
