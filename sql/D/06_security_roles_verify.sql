-- D 模块角色与最小权限只读验收
-- 前置：管理员已执行 sql/D/06_security_roles.sql。
-- 本脚本只读取 mysql / information_schema 元数据，不修改账号或业务数据。

USE charging_platform;
SET NAMES utf8mb4;

SET @reporting_role = '''cp_d_reporting''@''%''';
SET @membership_role = '''cp_d_membership_operator''@''%''';
SET @settlement_role = '''cp_d_settlement_operator''@''%''';

-- R01：三个D角色均存在且为锁定角色账号。
SELECT
    'R01 role_count' AS check_item,
    COUNT(*) AS actual_value,
    3 AS expected_value,
    IF(COUNT(*) = 3, 'PASS', 'FAIL') AS result
FROM mysql.user
WHERE User IN (
        'cp_d_reporting',
        'cp_d_membership_operator',
        'cp_d_settlement_operator'
      )
  AND Host = '%'
  AND account_locked = 'Y';

-- R02：任何D角色都不能获得破坏结构、删除数据或转授权权限。
WITH all_privileges AS (
    SELECT GRANTEE, PRIVILEGE_TYPE, IS_GRANTABLE
    FROM information_schema.USER_PRIVILEGES
    UNION ALL
    SELECT GRANTEE, PRIVILEGE_TYPE, IS_GRANTABLE
    FROM information_schema.SCHEMA_PRIVILEGES
    WHERE TABLE_SCHEMA = 'charging_platform'
    UNION ALL
    SELECT GRANTEE, PRIVILEGE_TYPE, IS_GRANTABLE
    FROM information_schema.TABLE_PRIVILEGES
    WHERE TABLE_SCHEMA = 'charging_platform'
    UNION ALL
    SELECT GRANTEE, PRIVILEGE_TYPE, IS_GRANTABLE
    FROM information_schema.COLUMN_PRIVILEGES
    WHERE TABLE_SCHEMA = 'charging_platform'
    UNION ALL
    SELECT
        CONCAT('''', User, '''@''', Host, '''') AS GRANTEE,
        'EXECUTE' AS PRIVILEGE_TYPE,
        IF(FIND_IN_SET('Grant', Proc_priv) > 0, 'YES', 'NO') AS IS_GRANTABLE
    FROM mysql.procs_priv
    WHERE Db = 'charging_platform'
      AND FIND_IN_SET('Execute', Proc_priv) > 0
    UNION ALL
    SELECT
        CONCAT('''', User, '''@''', Host, '''') AS GRANTEE,
        'ALTER ROUTINE' AS PRIVILEGE_TYPE,
        IF(FIND_IN_SET('Grant', Proc_priv) > 0, 'YES', 'NO') AS IS_GRANTABLE
    FROM mysql.procs_priv
    WHERE Db = 'charging_platform'
      AND FIND_IN_SET('Alter Routine', Proc_priv) > 0
)
SELECT
    'R02 forbidden_or_grantable_privilege' AS check_item,
    COUNT(*) AS actual_value,
    0 AS expected_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM all_privileges
WHERE GRANTEE IN (@reporting_role, @membership_role, @settlement_role)
  AND (
      PRIVILEGE_TYPE IN (
          'DELETE', 'DROP', 'ALTER', 'ALTER ROUTINE', 'CREATE', 'INDEX', 'TRIGGER',
          'REFERENCES', 'FILE', 'PROCESS', 'SUPER'
      )
      OR IS_GRANTABLE = 'YES'
  );

-- R03：只读报表角色没有任何表级、列级或库级写权限。
WITH reporting_write_privileges AS (
    SELECT PRIVILEGE_TYPE
    FROM information_schema.SCHEMA_PRIVILEGES
    WHERE GRANTEE = @reporting_role
      AND TABLE_SCHEMA = 'charging_platform'
      AND PRIVILEGE_TYPE IN ('INSERT', 'UPDATE', 'DELETE')
    UNION ALL
    SELECT PRIVILEGE_TYPE
    FROM information_schema.TABLE_PRIVILEGES
    WHERE GRANTEE = @reporting_role
      AND TABLE_SCHEMA = 'charging_platform'
      AND PRIVILEGE_TYPE IN ('INSERT', 'UPDATE', 'DELETE')
    UNION ALL
    SELECT PRIVILEGE_TYPE
    FROM information_schema.COLUMN_PRIVILEGES
    WHERE GRANTEE = @reporting_role
      AND TABLE_SCHEMA = 'charging_platform'
      AND PRIVILEGE_TYPE IN ('INSERT', 'UPDATE')
)
SELECT
    'R03 reporting_write_privilege' AS check_item,
    COUNT(*) AS actual_value,
    0 AS expected_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM reporting_write_privileges;

-- R04：只读报表角色拥有六个D安全视图的读取权限。
SELECT
    'R04 reporting_view_select_count' AS check_item,
    COUNT(*) AS actual_value,
    6 AS expected_value,
    IF(COUNT(*) = 6, 'PASS', 'FAIL') AS result
FROM information_schema.TABLE_PRIVILEGES
WHERE GRANTEE = @reporting_role
  AND TABLE_SCHEMA = 'charging_platform'
  AND TABLE_NAME IN (
      'v_user_membership_profile',
      'v_fleet_active_vehicle',
      'v_active_global_promotion',
      'v_settlement_statement_summary',
      'v_settlement_order_detail',
      'v_reconciliation_pending'
  )
  AND PRIVILEGE_TYPE = 'SELECT';

-- R05：报表角色不能通过整表或列级授权读取敏感字段。
WITH reporting_sensitive_privileges AS (
    SELECT TABLE_NAME, '*' AS COLUMN_NAME
    FROM information_schema.TABLE_PRIVILEGES
    WHERE GRANTEE = @reporting_role
      AND TABLE_SCHEMA = 'charging_platform'
      AND PRIVILEGE_TYPE = 'SELECT'
      AND TABLE_NAME IN (
          'user', 'vehicle', 'enterprise_customer',
          'invoice_record', 'reconciliation_confirmation'
      )
    UNION ALL
    SELECT TABLE_NAME, COLUMN_NAME
    FROM information_schema.COLUMN_PRIVILEGES
    WHERE GRANTEE = @reporting_role
      AND TABLE_SCHEMA = 'charging_platform'
      AND PRIVILEGE_TYPE = 'SELECT'
      AND (
          (TABLE_NAME = 'user'
           AND COLUMN_NAME IN ('phone_ciphertext', 'phone_hash'))
          OR
          (TABLE_NAME = 'vehicle'
           AND COLUMN_NAME IN ('plate_ciphertext', 'plate_hash'))
          OR
          (TABLE_NAME = 'enterprise_customer'
           AND COLUMN_NAME IN (
               'credit_code_ciphertext', 'credit_code_hash',
               'contact_phone_ciphertext'
           ))
          OR
          (TABLE_NAME = 'invoice_record'
           AND COLUMN_NAME = 'tax_number_ciphertext')
          OR
          (TABLE_NAME = 'reconciliation_confirmation'
           AND COLUMN_NAME = 'confirmer_name')
      )
)
SELECT
    'R05 reporting_sensitive_column_privilege' AS check_item,
    COUNT(*) AS actual_value,
    0 AS expected_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM reporting_sensitive_privileges;

-- R06：职责分离；④角色不能写⑤表，⑤角色不能写④表。
WITH invalid_cross_write AS (
    SELECT GRANTEE, TABLE_NAME, PRIVILEGE_TYPE
    FROM information_schema.TABLE_PRIVILEGES
    WHERE TABLE_SCHEMA = 'charging_platform'
      AND PRIVILEGE_TYPE IN ('INSERT', 'UPDATE', 'DELETE')
      AND (
          (GRANTEE = @membership_role
           AND TABLE_NAME IN (
               'settlement_statement', 'settlement_detail',
               'reconciliation_difference', 'reconciliation_confirmation',
               'invoice_record'
           ))
          OR
          (GRANTEE = @settlement_role
           AND TABLE_NAME IN (
               'membership_level', 'user', 'vehicle', 'membership_record',
               'enterprise_customer', 'fleet', 'fleet_vehicle',
               'fleet_quota_record', 'promotion', 'promotion_station',
               'coupon', 'coupon_redemption'
           ))
      )
)
SELECT
    'R06 invalid_cross_module_write' AS check_item,
    COUNT(*) AS actual_value,
    0 AS expected_value,
    IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM invalid_cross_write;

-- R07：两个业务角色恰好各自拥有一个本职责过程，不能交叉执行。
WITH role_execute_privileges AS (
    SELECT
        CONCAT('''', User, '''@''', Host, '''') AS GRANTEE,
        Routine_name AS ROUTINE_NAME
    FROM mysql.procs_priv
    WHERE Db = 'charging_platform'
      AND Routine_type = 'PROCEDURE'
      AND FIND_IN_SET('Execute', Proc_priv) > 0
      AND (
          (User = 'cp_d_membership_operator' AND Host = '%')
          OR
          (User = 'cp_d_settlement_operator' AND Host = '%')
      )
)
SELECT
    'R07 expected_execute_privilege' AS check_item,
    COUNT(*) AS actual_value,
    2 AS expected_value,
    IF(
        COUNT(*) = 2
        AND SUM(
            (GRANTEE = @membership_role
             AND ROUTINE_NAME = 'sp_calculate_promotion_quote')
            OR
            (GRANTEE = @settlement_role
             AND ROUTINE_NAME = 'sp_generate_settlement_statement')
        ) = 2,
        'PASS',
        'FAIL'
    ) AS result
FROM role_execute_privileges;

SHOW GRANTS FOR 'cp_d_reporting'@'%';
SHOW GRANTS FOR 'cp_d_membership_operator'@'%';
SHOW GRANTS FOR 'cp_d_settlement_operator'@'%';
