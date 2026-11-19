-- ④ 用户与会员运营：核心约束与事务测试
-- 适用环境：MySQL 8.0.46。
-- 测试过程中的有效或无效记录均位于事务内，过程结束前统一 ROLLBACK。
-- 脚本会创建临时测试过程，调用后立即删除；不会删除表或业务数据。

USE charging_platform;
SET NAMES utf8mb4;

DELIMITER $$

CREATE PROCEDURE sp_d_run_membership_constraint_tests()
BEGIN
    DECLARE v_errno INT DEFAULT 0;
    DECLARE v_message TEXT DEFAULT NULL;

    START TRANSACTION;

    -- T01：手机号检索摘要必须唯一，预期错误 1062。
    SET v_errno = 0;
    SET v_message = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        INSERT INTO `user` (
            user_id, phone_ciphertext, phone_hash, real_name,
            real_name_status, registration_channel, level_id, balance
        )
        SELECT
            990001,
            UNHEX(SHA2('constraint-test-phone', 512)),
            phone_hash,
            '约束测试用户',
            'VERIFIED',
            'OTHER',
            1,
            0.00
        FROM `user`
        WHERE user_id = 10001;
    END;
    SELECT
        'T01 duplicate phone_hash' AS test_name,
        1062 AS expected_error,
        v_errno AS actual_error,
        IF(v_errno = 1062, 'PASS', 'FAIL') AS result,
        v_message AS message;

    -- T02：账户余额不得为负数，预期 CHECK 错误 3819。
    SET v_errno = 0;
    SET v_message = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        INSERT INTO `user` (
            user_id, phone_ciphertext, phone_hash, real_name,
            real_name_status, registration_channel, level_id, balance
        ) VALUES (
            990002,
            UNHEX(SHA2('constraint-test-negative-balance', 512)),
            SHA2('constraint-test-negative-balance', 256),
            '负余额测试用户',
            'VERIFIED',
            'OTHER',
            1,
            -1.00
        );
    END;
    SELECT
        'T02 negative balance' AS test_name,
        3819 AS expected_error,
        v_errno AS actual_error,
        IF(v_errno = 3819, 'PASS', 'FAIL') AS result,
        v_message AS message;

    -- T03：车辆必须关联存在的用户，预期外键错误 1452。
    SET v_errno = 0;
    SET v_message = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        INSERT INTO vehicle (
            vehicle_id, user_id, plate_ciphertext, plate_hash,
            model, fast_charge_supported, vehicle_status
        ) VALUES (
            990003,
            999999999,
            UNHEX(SHA2('constraint-test-plate', 512)),
            SHA2('constraint-test-plate', 256),
            '无效用户外键测试车型',
            1,
            'ACTIVE'
        );
    END;
    SELECT
        'T03 invalid vehicle user FK' AS test_name,
        1452 AS expected_error,
        v_errno AS actual_error,
        IF(v_errno = 1452, 'PASS', 'FAIL') AS result,
        v_message AS message;

    -- T04：活动开始时间必须早于结束时间，预期 CHECK 错误 3819。
    SET v_errno = 0;
    SET v_message = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        INSERT INTO promotion (
            promotion_id, promotion_name, discount_type, discount_value,
            minimum_spend, applicability_scope, per_user_limit,
            valid_from, valid_to, status
        ) VALUES (
            990004,
            '非法活动时间测试',
            'FIXED',
            10.00,
            0.00,
            'ALL',
            1,
            '2026-12-31 00:00:00',
            '2026-12-01 00:00:00',
            'DRAFT'
        );
    END;
    SELECT
        'T04 invalid promotion time' AS test_name,
        3819 AS expected_error,
        v_errno AS actual_error,
        IF(v_errno = 3819, 'PASS', 'FAIL') AS result,
        v_message AS message;

    -- T05：LEFT 状态必须填写退出时间，预期 CHECK 错误 3819。
    SET v_errno = 0;
    SET v_message = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        INSERT INTO fleet_vehicle (
            fleet_vehicle_id, fleet_id, vehicle_id,
            joined_at, left_at, status
        ) VALUES (
            990005,
            60001,
            20001,
            '2026-11-25 08:00:00',
            NULL,
            'LEFT'
        );
    END;
    SELECT
        'T05 LEFT without left_at' AS test_name,
        3819 AS expected_error,
        v_errno AS actual_error,
        IF(v_errno = 3819, 'PASS', 'FAIL') AS result,
        v_message AS message;

    -- T06：额度范围与关联编号必须一致，预期 CHECK 错误 3819。
    SET v_errno = 0;
    SET v_message = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        INSERT INTO fleet_quota_record (
            quota_record_id, quota_scope, enterprise_id, fleet_id,
            vehicle_id, quota_type, quota_limit,
            period_start, period_end, change_reason
        ) VALUES (
            990006,
            'ENTERPRISE',
            NULL,
            60001,
            NULL,
            'AMOUNT',
            1000.00,
            '2026-11-01 00:00:00',
            '2026-12-01 00:00:00',
            '非法范围测试'
        );
    END;
    SELECT
        'T06 quota scope mismatch' AS test_name,
        3819 AS expected_error,
        v_errno AS actual_error,
        IF(v_errno = 3819, 'PASS', 'FAIL') AS result,
        v_message AS message;

    -- T07：有效会员历史记录应成功写入，但最终仍由 ROLLBACK 撤销。
    SET v_errno = 0;
    SET v_message = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        INSERT INTO membership_record (
            membership_record_id, user_id, level_id,
            change_type, effective_at, change_reason
        ) VALUES (
            990007,
            10001,
            2,
            'UPGRADE',
            '2026-11-25 09:00:00',
            '有效写入回滚测试'
        );
    END;
    SELECT
        'T07 valid insert before rollback' AS test_name,
        0 AS expected_error,
        v_errno AS actual_error,
        IF(v_errno = 0, 'PASS', 'FAIL') AS result,
        v_message AS message;

    ROLLBACK;

    SELECT
        'T08 rollback removed test row' AS test_name,
        0 AS expected_count,
        COUNT(*) AS actual_count,
        IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
    FROM membership_record
    WHERE membership_record_id = 990007;
END$$

DELIMITER ;

CALL sp_d_run_membership_constraint_tests();
DROP PROCEDURE sp_d_run_membership_constraint_tests;

SELECT
    'core_row_counts_after_tests' AS check_item,
    (SELECT COUNT(*) FROM membership_level) AS membership_level_count,
    (SELECT COUNT(*) FROM `user`) AS user_count,
    (SELECT COUNT(*) FROM vehicle) AS vehicle_count,
    (SELECT COUNT(*) FROM membership_record) AS membership_record_count,
    (SELECT COUNT(*) FROM promotion) AS promotion_count,
    (SELECT COUNT(*) FROM enterprise_customer) AS enterprise_count,
    (SELECT COUNT(*) FROM fleet) AS fleet_count,
    (SELECT COUNT(*) FROM fleet_vehicle) AS fleet_vehicle_count,
    (SELECT COUNT(*) FROM fleet_quota_record) AS quota_count;

