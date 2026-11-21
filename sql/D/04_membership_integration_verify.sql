-- ④ 用户与会员运营：跨模块表结构验收
-- 依赖 B 的 station、charging_order 已创建。
-- 本脚本只读，不修改数据库对象或业务数据。

USE charging_platform;
SET NAMES utf8mb4;

-- I01：三张跨模块表全部存在。
SELECT
    'I01 integration_table_count' AS check_item,
    COUNT(*) AS actual_value,
    3 AS expected_value,
    IF(COUNT(*) = 3, 'PASS', 'FAIL') AS result
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_TYPE = 'BASE TABLE'
  AND TABLE_NAME IN (
      'promotion_station',
      'coupon',
      'coupon_redemption'
  );

-- I02：引擎和排序规则必须统一。
SELECT
    'I02 invalid_engine_or_collation' AS check_item,
    COUNT(*) AS actual_value,
    0 AS expected_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_NAME IN (
      'promotion_station',
      'coupon',
      'coupon_redemption'
  )
  AND (
      ENGINE <> 'InnoDB'
      OR TABLE_COLLATION <> 'utf8mb4_0900_ai_ci'
  );

-- I03：3 个主键、7 个外键、4 个唯一约束和 5 个 CHECK 约束。
SELECT
    CONSTRAINT_TYPE AS constraint_type,
    COUNT(*) AS actual_count,
    CASE CONSTRAINT_TYPE
        WHEN 'PRIMARY KEY' THEN 3
        WHEN 'FOREIGN KEY' THEN 7
        WHEN 'UNIQUE' THEN 4
        WHEN 'CHECK' THEN 5
    END AS expected_count,
    IF(
        COUNT(*) = CASE CONSTRAINT_TYPE
            WHEN 'PRIMARY KEY' THEN 3
            WHEN 'FOREIGN KEY' THEN 7
            WHEN 'UNIQUE' THEN 4
            WHEN 'CHECK' THEN 5
        END,
        'PASS',
        'FAIL'
    ) AS result
FROM information_schema.TABLE_CONSTRAINTS
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_NAME IN (
      'promotion_station',
      'coupon',
      'coupon_redemption'
  )
GROUP BY CONSTRAINT_TYPE
ORDER BY FIELD(
    CONSTRAINT_TYPE,
    'PRIMARY KEY',
    'FOREIGN KEY',
    'UNIQUE',
    'CHECK'
);

-- I04：跨模块外键必须指向 B 的正式场站和订单表。
SELECT
    'I04 b_cross_module_fk_count' AS check_item,
    COUNT(*) AS actual_value,
    3 AS expected_value,
    IF(COUNT(*) = 3, 'PASS', 'FAIL') AS result
FROM information_schema.KEY_COLUMN_USAGE
WHERE TABLE_SCHEMA = 'charging_platform'
  AND (
      (TABLE_NAME = 'promotion_station'
       AND COLUMN_NAME = 'station_id'
       AND REFERENCED_TABLE_NAME = 'station'
       AND REFERENCED_COLUMN_NAME = 'station_id')
      OR
      (TABLE_NAME = 'coupon'
       AND COLUMN_NAME = 'locked_order_id'
       AND REFERENCED_TABLE_NAME = 'charging_order'
       AND REFERENCED_COLUMN_NAME = 'order_id')
      OR
      (TABLE_NAME = 'coupon_redemption'
       AND COLUMN_NAME = 'order_id'
       AND REFERENCED_TABLE_NAME = 'charging_order'
       AND REFERENCED_COLUMN_NAME = 'order_id')
  );

-- I05：所有主外键编号都必须是 BIGINT UNSIGNED。
SELECT
    'I05 invalid_id_column_type' AS check_item,
    COUNT(*) AS actual_value,
    0 AS expected_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM information_schema.COLUMNS
WHERE TABLE_SCHEMA = 'charging_platform'
  AND TABLE_NAME IN (
      'promotion_station',
      'coupon',
      'coupon_redemption'
  )
  AND COLUMN_NAME LIKE '%\_id'
  AND COLUMN_TYPE <> 'bigint unsigned';

-- I06：同一订单锁券与核销均必须具有唯一约束。
SELECT
    'I06 order_coupon_uniqueness' AS check_item,
    COUNT(*) AS actual_value,
    2 AS expected_value,
    IF(COUNT(*) = 2, 'PASS', 'FAIL') AS result
FROM information_schema.TABLE_CONSTRAINTS
WHERE TABLE_SCHEMA = 'charging_platform'
  AND CONSTRAINT_TYPE = 'UNIQUE'
  AND (
      (TABLE_NAME = 'coupon'
       AND CONSTRAINT_NAME = 'uk_coupon_locked_order')
      OR
      (TABLE_NAME = 'coupon_redemption'
       AND CONSTRAINT_NAME = 'uk_redemption_order')
  );

-- I07：首次创建后，三张表应为空，等待正式测试数据阶段。
SELECT 'promotion_station' AS table_name, COUNT(*) AS row_count FROM promotion_station
UNION ALL SELECT 'coupon', COUNT(*) FROM coupon
UNION ALL SELECT 'coupon_redemption', COUNT(*) FROM coupon_redemption
ORDER BY table_name;
