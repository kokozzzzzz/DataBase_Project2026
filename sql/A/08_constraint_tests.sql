-- A ⑥⑧ 约束、触发器、存储过程测试
-- 目标环境：MySQL 8.0.46。
-- 所有测试在一个事务内执行，结束统一 ROLLBACK，不保留测试数据。
-- 通过临时 MEMORY 表汇总结果，避免逐条人工比对。
-- 预期错误码：
--   1062 唯一键冲突；1452 外键冲突；3819 CHECK 约束；1644 自定义 SIGNAL。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

DROP PROCEDURE IF EXISTS sp_a_run_constraint_tests;

DELIMITER $$

CREATE PROCEDURE sp_a_run_constraint_tests()
SQL SECURITY INVOKER
MODIFIES SQL DATA
COMMENT 'A 模块约束与过程测试，结束时回滚'
BEGIN
    DECLARE v_errno INT DEFAULT 0;
    DECLARE v_message TEXT DEFAULT NULL;
    DECLARE v_pending_notification_id BIGINT UNSIGNED;
    DECLARE v_occupancy_id BIGINT UNSIGNED;
    DECLARE v_notice_id BIGINT UNSIGNED;
    DECLARE v_checkin_id BIGINT UNSIGNED;
    DECLARE v_occupancy_out BIGINT UNSIGNED;
    DECLARE v_consumed TINYINT;
    DECLARE v_released TINYINT;
    DECLARE v_updated TINYINT;
    DECLARE v_reservation_id BIGINT UNSIGNED;
    DECLARE v_new_reservation_id BIGINT UNSIGNED;
    DECLARE v_recipient_count INT;
    DECLARE v_notification_count INT;
    DECLARE v_cancelled_count INT;
    DECLARE v_expired_reservations INT;
    DECLARE v_expired_queues INT;
    DECLARE v_status VARCHAR(20);

    DROP TEMPORARY TABLE IF EXISTS tmp_a_test_results;

    CREATE TEMPORARY TABLE tmp_a_test_results (
        test_id VARCHAR(10) NOT NULL,
        test_name VARCHAR(100) NOT NULL,
        expected INT NOT NULL,
        actual INT NOT NULL,
        result VARCHAR(10) NOT NULL,
        message VARCHAR(500) NULL
    ) ENGINE=MEMORY;

    START TRANSACTION;

    -- T01 同枪有效预约区间冲突，预期 1644。
    SET v_errno = 0;
    SET v_message = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        INSERT INTO charging_reservation (
            reservation_id, user_id, vehicle_id, gun_id, station_id,
            starts_at, ends_at, status
        ) VALUES (
            1901, 10003, 20003, 9401, 9101,
            '2026-11-24 09:30:00', '2026-11-24 10:30:00', 'BOOKED'
        );
    END;
    INSERT INTO tmp_a_test_results
    VALUES ('T01', 'same gun reservation overlap', 1644, v_errno,
            IF(v_errno = 1644, 'PASS', 'FAIL'), v_message);

    -- T02 同用户同时段跨枪重复预约，预期 1644。
    SET v_errno = 0;
    SET v_message = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        INSERT INTO charging_reservation (
            reservation_id, user_id, vehicle_id, gun_id, station_id,
            starts_at, ends_at, status
        ) VALUES (
            1902, 10001, 20001, 9403, 9101,
            '2026-11-24 09:30:00', '2026-11-24 10:30:00', 'BOOKED'
        );
    END;
    INSERT INTO tmp_a_test_results
    VALUES ('T02', 'same user overlap on another gun', 1644, v_errno,
            IF(v_errno = 1644, 'PASS', 'FAIL'), v_message);

    -- T03 同一用户已有有效排队，再入队，预期唯一键 1062。
    SET v_errno = 0;
    SET v_message = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        INSERT INTO queue_record (
            queue_id, station_id, user_id, vehicle_id, gun_id, ticket_no,
            status, joined_at
        ) VALUES (
            2901, 9101, 10007, 20007, 9402, 91,
            'WAITING', '2026-11-20 09:00:00'
        );
    END;
    INSERT INTO tmp_a_test_results
    VALUES ('T03', 'duplicate active queue per user', 1062, v_errno,
            IF(v_errno = 1062, 'PASS', 'FAIL'), v_message);

    -- T04 已核验预约再次核验，预期 1644。
    SET v_errno = 0;
    SET v_message = NULL;
    SET v_checkin_id = 0;
    SET v_occupancy_out = 0;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        CALL sp_check_in_reservation(
            1007, 'QR_CODE', '2026-11-20 08:10:00',
            v_checkin_id, v_occupancy_out
        );
    END;
    INSERT INTO tmp_a_test_results
    VALUES ('T04', 'check in an already checked-in reservation', 1644, v_errno,
            IF(v_errno = 1644, 'PASS', 'FAIL'), v_message);

    -- T05 到站核验目标车位已被占用，预期 1644。
    SET v_errno = 0;
    SET v_message = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        INSERT INTO queue_record (
            queue_id, station_id, user_id, vehicle_id, gun_id, ticket_no,
            status, joined_at, called_at, call_expires_at
        ) VALUES (
            2902, 9101, 10016, 20016, 9401, 92,
            'CHECKED_IN', '2026-11-20 09:10:00',
            '2026-11-20 09:11:00', '2026-11-20 09:21:00'
        );

        INSERT INTO arrival_checkin (
            reservation_id, queue_id, user_id, vehicle_id,
            station_id, gun_id, parking_space_id, checked_in_at
        ) VALUES (
            NULL, 2902, 10016, 20016, 9101, 9401, 9301,
            '2026-11-20 09:12:00'
        );
    END;
    INSERT INTO tmp_a_test_results
    VALUES ('T05', 'check in when parking space is occupied', 1644, v_errno,
            IF(v_errno = 1644, 'PASS', 'FAIL'), v_message);

    -- T06 公告 DRAFT 直接撤回，跳过发布，预期状态机 1644。
    SET v_errno = 0;
    SET v_message = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        INSERT INTO station_notice (
            notice_id, station_id, notice_type, severity, title, content,
            status, effective_from, created_by, updated_by
        ) VALUES (
            3901, 9101, 'PUBLIC', 'INFO', '状态机测试', '状态机测试正文',
            'DRAFT', '2026-11-20 00:00:00', 'test', 'test'
        );

        UPDATE station_notice
           SET status = 'WITHDRAWN'
         WHERE notice_id = 3901;
    END;
    INSERT INTO tmp_a_test_results
    VALUES ('T06', 'notice DRAFT to WITHDRAWN is rejected', 1644, v_errno,
            IF(v_errno = 1644, 'PASS', 'FAIL'), v_message);

    -- T07 通知 PENDING 直接置为 READ，预期状态机 1644。
    SELECT notification_id
      INTO v_pending_notification_id
      FROM notification_record
     WHERE status = 'PENDING'
     ORDER BY notification_id
     LIMIT 1;

    SET v_errno = 0;
    SET v_message = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        UPDATE notification_record
           SET status = 'READ',
               read_at = '2026-11-20 10:00:00'
         WHERE notification_id = v_pending_notification_id;
    END;
    INSERT INTO tmp_a_test_results
    VALUES ('T07', 'notification PENDING to READ is rejected', 1644, v_errno,
            IF(v_errno = 1644, 'PASS', 'FAIL'), v_message);

    -- T08 已消费的预约再次消费，预期 1644。
    SET v_errno = 0;
    SET v_message = NULL;
    SET v_consumed = 0;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        CALL sp_consume_admission(
            'RESERVATION', 1012, 8001, NULL, v_consumed
        );
    END;
    INSERT INTO tmp_a_test_results
    VALUES ('T08', 'consume an already consumed reservation', 1644, v_errno,
            IF(v_errno = 1644, 'PASS', 'FAIL'), v_message);

    -- T09 取消预约缺少取消时间和原因，预期 CHECK 3819。
    SET v_errno = 0;
    SET v_message = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        INSERT INTO charging_reservation (
            reservation_id, user_id, vehicle_id, gun_id, station_id,
            starts_at, ends_at, status
        ) VALUES (
            1911, 10005, 20005, 9405, 9101,
            '2026-11-25 09:00:00', '2026-11-25 10:00:00', 'CANCELLED'
        );
    END;
    INSERT INTO tmp_a_test_results
    VALUES ('T09', 'cancelled reservation without timestamp', 3819, v_errno,
            IF(v_errno = 3819, 'PASS', 'FAIL'), v_message);

    -- T10 定向公告缺少停运计划，预期 CHECK 3819。
    SET v_errno = 0;
    SET v_message = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        INSERT INTO station_notice (
            notice_id, station_id, notice_type, severity, title, content,
            status, effective_from, created_by, updated_by,
            related_outage_plan_id
        ) VALUES (
            3902, 9101, 'OUTAGE_TARGETED', 'WARNING', '缺计划', '缺计划',
            'DRAFT', '2026-11-20 00:00:00', 'test', 'test', NULL
        );
    END;
    INSERT INTO tmp_a_test_results
    VALUES ('T10', 'targeted notice without outage plan', 3819, v_errno,
            IF(v_errno = 3819, 'PASS', 'FAIL'), v_message);

    -- T11 取消排队缺少取消时间和原因，预期 CHECK 3819。
    SET v_errno = 0;
    SET v_message = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        INSERT INTO queue_record (
            queue_id, station_id, user_id, vehicle_id, gun_id, ticket_no,
            status, joined_at
        ) VALUES (
            2903, 9101, 10019, 20019, 9402, 93,
            'CANCELLED', '2026-11-20 09:20:00'
        );
    END;
    INSERT INTO tmp_a_test_results
    VALUES ('T11', 'cancelled queue without timestamp', 3819, v_errno,
            IF(v_errno = 3819, 'PASS', 'FAIL'), v_message);

    -- T12 FAILED 通知却带发送时间，预期 CHECK 3819。
    SET v_errno = 0;
    SET v_message = NULL;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        INSERT INTO notification_record (
            recipient_id, channel, status, sent_at, failure_reason
        ) VALUES (
            7001, 'WECHAT', 'FAILED', '2026-11-20 09:00:00', 'TEST'
        );
    END;
    INSERT INTO tmp_a_test_results
    VALUES ('T12', 'FAILED notification with sent_at', 3819, v_errno,
            IF(v_errno = 3819, 'PASS', 'FAIL'), v_message);

    -- T13 充电进行中按正常驶离释放车位，预期 1644。
    SELECT po.occupancy_id
      INTO v_occupancy_id
      FROM parking_occupancy AS po
      JOIN arrival_checkin AS ac
        ON ac.checkin_id = po.checkin_id
     WHERE ac.reservation_id = 1012
       AND po.released_at IS NULL
     LIMIT 1;

    SET v_errno = 0;
    SET v_message = NULL;
    SET v_released = 0;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        CALL sp_release_parking_space(
            v_occupancy_id, 'VEHICLE_LEFT', '2026-11-20 10:00:00', v_released
        );
    END;
    INSERT INTO tmp_a_test_results
    VALUES ('T13', 'release parking while charging', 1644, v_errno,
            IF(v_errno = 1644, 'PASS', 'FAIL'), v_message);

    -- T14 发布定向停运公告并撤回，正向验证接收人和待发送通知。
    INSERT INTO charging_reservation (
        reservation_id, user_id, vehicle_id, gun_id, station_id,
        starts_at, ends_at, status
    ) VALUES (
        1912, 10003, 20003, 9401, 9101,
        '2026-12-01 09:00:00', '2026-12-01 10:00:00', 'BOOKED'
    );

    INSERT INTO station_notice (
        notice_id, station_id, notice_type, severity, title, content,
        status, effective_from, created_by, updated_by,
        related_outage_plan_id
    ) VALUES (
        3903, 9101, 'OUTAGE_TARGETED', 'WARNING', '发布测试', '发布测试',
        'DRAFT', '2026-11-20 00:00:00', 'test', 'test', 9501
    );

    SET v_errno = 0;
    SET v_message = NULL;
    SET v_recipient_count = 0;
    SET v_notification_count = 0;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        CALL sp_publish_notice(
            3903, 'test', '2026-11-20 09:00:00',
            v_recipient_count, v_notification_count
        );
    END;

    SET v_cancelled_count = 0;
    IF v_errno = 0 THEN
        BEGIN
            DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
            BEGIN
                GET DIAGNOSTICS CONDITION 1
                    v_errno = MYSQL_ERRNO,
                    v_message = MESSAGE_TEXT;
            END;

            CALL sp_withdraw_notice(
                3903, 'test', '测试撤回', '2026-11-20 09:05:00',
                v_cancelled_count
            );
        END;
    END IF;

    INSERT INTO tmp_a_test_results
    VALUES (
        'T14', 'publish and withdraw targeted notice', 0, v_errno,
        IF(v_errno = 0 AND v_recipient_count >= 1
           AND v_notification_count >= 1 AND v_cancelled_count >= 1,
           'PASS', 'FAIL'),
        CONCAT('recipients=', v_recipient_count,
               ', notifications=', v_notification_count,
               ', cancelled=', v_cancelled_count,
               ', message=', COALESCE(v_message, 'OK'))
    );

    -- T15 过期批处理：迟到超保留期的预约应转 EXPIRED。
    INSERT INTO charging_reservation (
        reservation_id, user_id, vehicle_id, gun_id, station_id,
        starts_at, ends_at, status
    ) VALUES (
        1913, 10004, 20004, 9405, 9101,
        '2026-11-10 09:00:00', '2026-11-10 10:00:00', 'BOOKED'
    );

    SET v_errno = 0;
    SET v_message = NULL;
    SET v_expired_reservations = 0;
    SET v_expired_queues = 0;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        CALL sp_expire_overdue_admissions(
            '2026-11-20 12:00:00',
            v_expired_reservations, v_expired_queues
        );
    END;
    INSERT INTO tmp_a_test_results
    VALUES (
        'T15', 'expire overdue reservations', 0, v_errno,
        IF(v_errno = 0 AND v_expired_reservations >= 1, 'PASS', 'FAIL'),
        CONCAT('expired_reservations=', v_expired_reservations,
               ', expired_queues=', v_expired_queues,
               ', message=', COALESCE(v_message, 'OK'))
    );

    -- T16 通知状态正向流转 PENDING -> SENT -> READ。
    SET v_errno = 0;
    SET v_message = NULL;
    SET v_updated = 0;
    BEGIN
        DECLARE CONTINUE HANDLER FOR SQLEXCEPTION
        BEGIN
            GET DIAGNOSTICS CONDITION 1
                v_errno = MYSQL_ERRNO,
                v_message = MESSAGE_TEXT;
        END;

        CALL sp_update_notification_status(
            v_pending_notification_id, 'SENT', 'TEST-MSG-1', NULL,
            '2026-11-20 10:10:00', v_updated
        );

        CALL sp_update_notification_status(
            v_pending_notification_id, 'READ', NULL, NULL,
            '2026-11-20 10:15:00', v_updated
        );
    END;

    SELECT status
      INTO v_status
      FROM notification_record
     WHERE notification_id = v_pending_notification_id;

    INSERT INTO tmp_a_test_results
    VALUES (
        'T16', 'notification PENDING to SENT to READ', 0, v_errno,
        IF(v_errno = 0 AND v_status = 'READ', 'PASS', 'FAIL'),
        CONCAT('final_status=', v_status,
               ', message=', COALESCE(v_message, 'OK'))
    );

    ROLLBACK;

    SELECT test_id, test_name, expected, actual, result, message
      FROM tmp_a_test_results
     ORDER BY test_id;

    SELECT
        SUM(result = 'PASS') AS passed,
        SUM(result = 'FAIL') AS failed,
        COUNT(*) AS total
      FROM tmp_a_test_results;

    DROP TEMPORARY TABLE tmp_a_test_results;
END$$

DELIMITER ;

CALL sp_a_run_constraint_tests();
DROP PROCEDURE sp_a_run_constraint_tests;
