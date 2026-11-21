-- ④ 用户与会员运营：核心表测试数据
-- 每张核心表插入 20 条虚构测试数据。
-- 本脚本故意不执行 COMMIT：请先检查末尾统计结果，再手动 COMMIT 或 ROLLBACK。
-- 若任意语句报错，不要提交事务，应立即执行 ROLLBACK。

USE charging_platform;
SET NAMES utf8mb4;
START TRANSACTION;

INSERT INTO membership_level (
    level_id, level_code, level_name, description, sort_order, status
)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 20
)
SELECT
    n,
    CONCAT('TEST_LEVEL_', LPAD(n, 2, '0')),
    CONCAT('测试等级', LPAD(n, 2, '0')),
    CONCAT('课程设计测试会员等级', LPAD(n, 2, '0')),
    n,
    'ACTIVE'
FROM seq;

INSERT INTO `user` (
    user_id, phone_ciphertext, phone_hash, real_name, real_name_status,
    registration_channel, registered_at, level_id, balance, user_status
)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 20
)
SELECT
    10000 + n,
    UNHEX(SHA2(CONCAT('test-phone-cipher-', n), 512)),
    SHA2(CONCAT('test-phone-search-', n), 256),
    CONCAT('测试用户', LPAD(n, 2, '0')),
    IF(MOD(n, 5) = 0, 'PENDING', 'VERIFIED'),
    CASE MOD(n, 4)
        WHEN 0 THEN 'APP'
        WHEN 1 THEN 'WEB'
        WHEN 2 THEN 'WECHAT'
        ELSE 'OTHER'
    END,
    TIMESTAMP('2026-11-01 09:00:00') + INTERVAL n DAY,
    n,
    CAST(n * 10 AS DECIMAL(12,2)),
    'ACTIVE'
FROM seq;

INSERT INTO vehicle (
    vehicle_id, user_id, plate_ciphertext, plate_hash, model,
    battery_capacity_kwh, max_charging_power_kw,
    fast_charge_supported, vehicle_status
)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 20
)
SELECT
    20000 + n,
    10000 + n,
    UNHEX(SHA2(CONCAT('test-plate-cipher-', n), 512)),
    SHA2(CONCAT('test-plate-search-', n), 256),
    CONCAT('测试车型', LPAD(n, 2, '0')),
    CAST(50 + n AS DECIMAL(8,2)),
    CAST(60 + n AS DECIMAL(8,2)),
    MOD(n, 2),
    'ACTIVE'
FROM seq;

INSERT INTO membership_record (
    membership_record_id, user_id, level_id, change_type,
    effective_at, change_reason
)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 20
)
SELECT
    30000 + n,
    10000 + n,
    n,
    'INITIAL',
    TIMESTAMP('2026-11-01 10:00:00') + INTERVAL n DAY,
    '测试用户初始会员等级'
FROM seq;

INSERT INTO promotion (
    promotion_id, promotion_name, description, discount_type,
    discount_value, minimum_spend, max_discount_amount,
    applicability_scope, total_quantity, per_user_limit,
    valid_from, valid_to, status
)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 20
)
SELECT
    40000 + n,
    CONCAT('测试优惠活动', LPAD(n, 2, '0')),
    CONCAT('课程设计测试活动', LPAD(n, 2, '0')),
    IF(MOD(n, 2) = 0, 'PERCENTAGE', 'FIXED'),
    IF(MOD(n, 2) = 0, CAST(0.80 + n / 1000 AS DECIMAL(10,4)), CAST(5 + n AS DECIMAL(10,4))),
    CAST(20 + n AS DECIMAL(12,2)),
    IF(MOD(n, 2) = 0, CAST(30 + n AS DECIMAL(12,2)), NULL),
    'ALL',
    IF(MOD(n, 3) = 0, NULL, 100 + n),
    1 + MOD(n, 3),
    TIMESTAMP('2026-11-01 00:00:00'),
    TIMESTAMP('2026-12-31 23:59:59'),
    'ACTIVE'
FROM seq;

INSERT INTO enterprise_customer (
    enterprise_id, enterprise_name, credit_code_ciphertext,
    credit_code_hash, contact_name, contact_phone_ciphertext, status
)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 20
)
SELECT
    50000 + n,
    CONCAT('测试企业', LPAD(n, 2, '0')),
    IF(MOD(n, 2) = 0, NULL, UNHEX(SHA2(CONCAT('test-credit-cipher-', n), 512))),
    IF(MOD(n, 2) = 0, NULL, SHA2(CONCAT('test-credit-search-', n), 256)),
    CONCAT('测试联系人', LPAD(n, 2, '0')),
    UNHEX(SHA2(CONCAT('test-contact-phone-', n), 512)),
    'ACTIVE'
FROM seq;

INSERT INTO fleet (
    fleet_id, enterprise_id, fleet_name, contact_name,
    contact_phone_ciphertext, status
)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 20
)
SELECT
    60000 + n,
    50000 + n,
    CONCAT('测试车队', LPAD(n, 2, '0')),
    CONCAT('车队联系人', LPAD(n, 2, '0')),
    UNHEX(SHA2(CONCAT('test-fleet-phone-', n), 512)),
    'ACTIVE'
FROM seq;

INSERT INTO fleet_vehicle (
    fleet_vehicle_id, fleet_id, vehicle_id, joined_at, left_at, status
)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 20
)
SELECT
    70000 + n,
    60000 + n,
    20000 + n,
    TIMESTAMP('2026-11-01 08:00:00') + INTERVAL n DAY,
    NULL,
    'ACTIVE'
FROM seq;

INSERT INTO fleet_quota_record (
    quota_record_id, quota_scope, enterprise_id, fleet_id, vehicle_id,
    quota_type, quota_limit, period_start, period_end, change_reason
)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 20
)
SELECT
    80000 + n,
    CASE MOD(n, 3)
        WHEN 1 THEN 'ENTERPRISE'
        WHEN 2 THEN 'FLEET'
        ELSE 'VEHICLE'
    END,
    IF(MOD(n, 3) = 1, 50000 + n, NULL),
    IF(MOD(n, 3) = 2, 60000 + n, NULL),
    IF(MOD(n, 3) = 0, 20000 + n, NULL),
    CASE MOD(n, 3)
        WHEN 1 THEN 'AMOUNT'
        WHEN 2 THEN 'ENERGY'
        ELSE 'ORDER_COUNT'
    END,
    CASE MOD(n, 3)
        WHEN 1 THEN CAST(1000 + n * 10 AS DECIMAL(14,2))
        WHEN 2 THEN CAST(500 + n * 5 AS DECIMAL(14,2))
        ELSE CAST(10 + n AS DECIMAL(14,2))
    END,
    TIMESTAMP('2026-11-01 00:00:00'),
    TIMESTAMP('2026-12-01 00:00:00'),
    '课程设计测试额度'
FROM seq;

SELECT 'enterprise_customer' AS table_name, COUNT(*) AS row_count FROM enterprise_customer
UNION ALL SELECT 'fleet', COUNT(*) FROM fleet
UNION ALL SELECT 'fleet_quota_record', COUNT(*) FROM fleet_quota_record
UNION ALL SELECT 'fleet_vehicle', COUNT(*) FROM fleet_vehicle
UNION ALL SELECT 'membership_level', COUNT(*) FROM membership_level
UNION ALL SELECT 'membership_record', COUNT(*) FROM membership_record
UNION ALL SELECT 'promotion', COUNT(*) FROM promotion
UNION ALL SELECT 'user', COUNT(*) FROM `user`
UNION ALL SELECT 'vehicle', COUNT(*) FROM vehicle
ORDER BY table_name;

SELECT
    'TRANSACTION IS STILL OPEN: verify all row_count values are 20, then run COMMIT; otherwise run ROLLBACK;'
    AS next_action;

