-- A ⑥⑧ 核心存储过程
-- 目标环境：MySQL 8.0.46。
-- 过程统一使用 SQL SECURITY INVOKER，不修改调用者权限。
-- 首次执行成功后不要重复 SOURCE；重复创建会报 PROCEDURE already exists。
--
-- 约定：
--   * 时间区间统一左闭右开 [starts_at, ends_at)。
--   * 业务时间由调用方传入 p_now，便于测试和补跑；NULL 表示 NOW()。
--   * 过程只负责业务校验和 DML，事务提交/回滚由调用方控制。
--   * 通过 @a_change_reason 把本次业务原因写入状态历史触发器。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

DELIMITER $$

-- ---------------------------------------------------------------------------
-- ⑥ 预约：创建
-- 并发控制：先锁定目标充电枪行，再检查区间冲突；
-- 同一把枪的预约创建请求因此串行化，不会出现两个请求同时通过检查。
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_create_reservation(
    IN p_user_id BIGINT UNSIGNED,
    IN p_vehicle_id BIGINT UNSIGNED,
    IN p_gun_id BIGINT UNSIGNED,
    IN p_starts_at DATETIME,
    IN p_ends_at DATETIME,
    IN p_source VARCHAR(20),
    IN p_late_grace_minutes SMALLINT UNSIGNED,
    OUT p_reservation_id BIGINT UNSIGNED
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
COMMENT '创建预约：校验用户/车辆/枪/停运/区间冲突，锁枪后写入'
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_station_id BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_gun_status VARCHAR(20) DEFAULT NULL;
    DECLARE v_station_status VARCHAR(20) DEFAULT NULL;
    DECLARE v_opens_minute SMALLINT UNSIGNED DEFAULT 0;
    DECLARE v_closes_minute SMALLINT UNSIGNED DEFAULT 1440;
    DECLARE v_source VARCHAR(20) DEFAULT 'APP';
    DECLARE v_grace SMALLINT UNSIGNED DEFAULT 15;
    DECLARE v_minute_of_day SMALLINT UNSIGNED DEFAULT 0;
    DECLARE v_conflict_id BIGINT UNSIGNED DEFAULT NULL;

    SET p_reservation_id = 0;
    SET v_source = COALESCE(p_source, 'APP');
    SET v_grace = COALESCE(p_late_grace_minutes, 15);

    IF p_user_id IS NULL OR p_user_id = 0
       OR p_vehicle_id IS NULL OR p_vehicle_id = 0
       OR p_gun_id IS NULL OR p_gun_id = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_ID_INVALID';
    END IF;

    IF p_starts_at IS NULL OR p_ends_at IS NULL OR p_starts_at >= p_ends_at THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_TIME_INVALID';
    END IF;

    IF TIMESTAMPDIFF(MINUTE, p_starts_at, p_ends_at) < 5
       OR TIMESTAMPDIFF(MINUTE, p_starts_at, p_ends_at) > 1440 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_DURATION_INVALID';
    END IF;

    IF p_starts_at < NOW() - INTERVAL 1 MINUTE THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_IN_PAST';
    END IF;

    IF v_grace NOT BETWEEN 1 AND 120 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_GRACE_INVALID';
    END IF;

    IF v_source NOT IN ('APP', 'WEB', 'WECHAT', 'MINI_PROGRAM', 'STAFF') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_SOURCE_INVALID';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM `user`
     WHERE user_id = p_user_id
       AND user_status = 'ACTIVE';

    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_USER_NOT_ACTIVE';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM vehicle
     WHERE vehicle_id = p_vehicle_id
       AND user_id = p_user_id
       AND vehicle_status = 'ACTIVE';

    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_VEHICLE_NOT_OWNED_OR_INACTIVE';
    END IF;

    -- 锁枪：后续冲突检查和 INSERT 都在同一把枪的行锁保护下。
    SELECT station_id, status
      INTO v_station_id, v_gun_status
      FROM charging_gun
     WHERE gun_id = p_gun_id
     FOR UPDATE;

    IF v_station_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_GUN_NOT_FOUND';
    END IF;

    IF v_gun_status IN ('FAULT', 'DISABLED', 'OFFLINE') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_GUN_NOT_AVAILABLE';
    END IF;

    SELECT status, opens_minute, closes_minute
      INTO v_station_status, v_opens_minute, v_closes_minute
      FROM station
     WHERE station_id = v_station_id;

    IF v_station_status <> 'OPEN' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_STATION_CLOSED';
    END IF;

    SET v_minute_of_day = HOUR(p_starts_at) * 60 + MINUTE(p_starts_at);
    IF v_minute_of_day < v_opens_minute
       OR v_minute_of_day >= v_closes_minute THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_OUTSIDE_BUSINESS_HOURS';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM equipment_outage_plan
     WHERE station_id = v_station_id
       AND status = 'SCHEDULED'
       AND (gun_id IS NULL OR gun_id = p_gun_id)
       AND starts_at < p_ends_at
       AND ends_at > p_starts_at;

    IF v_count > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_GUN_OUTAGE';
    END IF;

    -- 必须是锁定读（当前读），否则 REPEATABLE READ 下可能看不到
    -- 另一个事务在等待行锁期间刚提交的预约。
    SET v_conflict_id = NULL;

    SELECT reservation_id
      INTO v_conflict_id
      FROM charging_reservation
     WHERE gun_id = p_gun_id
       AND status IN ('BOOKED', 'CHECKED_IN')
       AND starts_at < p_ends_at
       AND ends_at > p_starts_at
     LIMIT 1
     FOR UPDATE;

    IF v_conflict_id IS NOT NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_GUN_OVERLAP';
    END IF;

    SET v_conflict_id = NULL;

    SELECT reservation_id
      INTO v_conflict_id
      FROM charging_reservation
     WHERE user_id = p_user_id
       AND status IN ('BOOKED', 'CHECKED_IN')
       AND starts_at < p_ends_at
       AND ends_at > p_starts_at
     LIMIT 1
     FOR UPDATE;

    IF v_conflict_id IS NOT NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_USER_OVERLAP';
    END IF;

    SET @a_change_reason = 'CREATE_RESERVATION';

    INSERT INTO charging_reservation (
        user_id, vehicle_id, gun_id, station_id,
        starts_at, ends_at, late_grace_minutes, source, status
    ) VALUES (
        p_user_id, p_vehicle_id, p_gun_id, v_station_id,
        p_starts_at, p_ends_at, v_grace, v_source, 'BOOKED'
    );

    SET p_reservation_id = LAST_INSERT_ID();
END$$

-- ---------------------------------------------------------------------------
-- ⑥ 预约：取消
-- CHECKED_IN 取消时同时释放未驶离占用；已消费的预约不能取消。
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_cancel_reservation(
    IN p_reservation_id BIGINT UNSIGNED,
    IN p_reason VARCHAR(255),
    IN p_now DATETIME,
    OUT p_released_occupancy_id BIGINT UNSIGNED
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
COMMENT '取消预约；CHECKED_IN 时释放对应未释放车位占用'
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_status VARCHAR(20) DEFAULT NULL;
    DECLARE v_now DATETIME;
    DECLARE v_occupancy_id BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_reason VARCHAR(255);

    SET p_released_occupancy_id = 0;
    SET v_now = COALESCE(p_now, NOW());
    SET v_reason = TRIM(COALESCE(p_reason, ''));

    IF p_reservation_id IS NULL OR p_reservation_id = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_ID_INVALID';
    END IF;

    IF v_reason = '' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_CANCEL_REASON_REQUIRED';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM charging_reservation
     WHERE reservation_id = p_reservation_id;

    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_NOT_FOUND';
    END IF;

    SELECT status
      INTO v_status
      FROM charging_reservation
     WHERE reservation_id = p_reservation_id
     FOR UPDATE;

    IF v_status NOT IN ('BOOKED', 'CHECKED_IN') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_CANNOT_CANCEL';
    END IF;

    IF v_status = 'CHECKED_IN' THEN
        SELECT po.occupancy_id
          INTO v_occupancy_id
          FROM parking_occupancy AS po
          JOIN arrival_checkin AS ac
            ON ac.checkin_id = po.checkin_id
         WHERE ac.reservation_id = p_reservation_id
           AND po.released_at IS NULL
         LIMIT 1;

        IF v_occupancy_id IS NOT NULL THEN
            SET @a_change_reason = 'RESERVATION_CANCELLED';
            UPDATE parking_occupancy
               SET released_at = v_now,
                   release_reason = 'CHECKIN_CANCELLED'
             WHERE occupancy_id = v_occupancy_id
               AND released_at IS NULL;
            SET p_released_occupancy_id = v_occupancy_id;
        END IF;
    END IF;

    SET @a_change_reason = 'CANCEL_RESERVATION';

    UPDATE charging_reservation
       SET status = 'CANCELLED',
           cancelled_at = v_now,
           cancel_reason = v_reason
     WHERE reservation_id = p_reservation_id
       AND status = v_status;

    IF ROW_COUNT() <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_CANCEL_RACE';
    END IF;
END$$

-- ---------------------------------------------------------------------------
-- ⑥ 预约：改约
-- 取消旧预约后创建一条新预约，新预约通过 rescheduled_from_id 回指旧预约。
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_reschedule_reservation(
    IN p_reservation_id BIGINT UNSIGNED,
    IN p_starts_at DATETIME,
    IN p_ends_at DATETIME,
    IN p_source VARCHAR(20),
    IN p_late_grace_minutes SMALLINT UNSIGNED,
    IN p_now DATETIME,
    OUT p_new_reservation_id BIGINT UNSIGNED
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
COMMENT '改约：取消旧预约并创建新预约，保留改约链'
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_status VARCHAR(20) DEFAULT NULL;
    DECLARE v_user_id BIGINT UNSIGNED;
    DECLARE v_vehicle_id BIGINT UNSIGNED;
    DECLARE v_gun_id BIGINT UNSIGNED;
    DECLARE v_starts_at DATETIME;
    DECLARE v_now DATETIME;

    SET p_new_reservation_id = 0;
    SET v_now = COALESCE(p_now, NOW());

    IF p_reservation_id IS NULL OR p_reservation_id = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_ID_INVALID';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM charging_reservation
     WHERE reservation_id = p_reservation_id;

    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_NOT_FOUND';
    END IF;

    SELECT user_id, vehicle_id, gun_id, starts_at, status
      INTO v_user_id, v_vehicle_id, v_gun_id, v_starts_at, v_status
      FROM charging_reservation
     WHERE reservation_id = p_reservation_id
     FOR UPDATE;

    IF v_status <> 'BOOKED' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_CANNOT_RESCHEDULE';
    END IF;

    IF v_now >= v_starts_at THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_RESCHEDULE_TOO_LATE';
    END IF;

    SET @a_change_reason = 'RESCHEDULE_RESERVATION';

    UPDATE charging_reservation
       SET status = 'CANCELLED',
           cancelled_at = v_now,
           cancel_reason = 'RESCHEDULED'
     WHERE reservation_id = p_reservation_id
       AND status = 'BOOKED';

    IF ROW_COUNT() <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_RESCHEDULE_RACE';
    END IF;

    CALL sp_create_reservation(
        v_user_id, v_vehicle_id, v_gun_id,
        p_starts_at, p_ends_at, p_source, p_late_grace_minutes,
        p_new_reservation_id
    );

    UPDATE charging_reservation
       SET rescheduled_from_id = p_reservation_id
     WHERE reservation_id = p_new_reservation_id
       AND rescheduled_from_id IS NULL;
END$$

-- ---------------------------------------------------------------------------
-- ⑥ 到站核验：预约
-- 过程先锁定预约并校验到站窗口，再更新为 CHECKED_IN、写入核验；
-- 触发器自动生成车位占用。
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_check_in_reservation(
    IN p_reservation_id BIGINT UNSIGNED,
    IN p_checkin_method VARCHAR(20),
    IN p_now DATETIME,
    OUT p_checkin_id BIGINT UNSIGNED,
    OUT p_occupancy_id BIGINT UNSIGNED
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
COMMENT '预约到站核验：校验窗口/设备/车位后写入核验并自动占位'
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_user_id BIGINT UNSIGNED;
    DECLARE v_vehicle_id BIGINT UNSIGNED;
    DECLARE v_gun_id BIGINT UNSIGNED;
    DECLARE v_station_id BIGINT UNSIGNED;
    DECLARE v_starts_at DATETIME;
    DECLARE v_ends_at DATETIME;
    DECLARE v_grace SMALLINT UNSIGNED;
    DECLARE v_status VARCHAR(20);
    DECLARE v_space_id BIGINT UNSIGNED;
    DECLARE v_gun_status VARCHAR(20);
    DECLARE v_station_status VARCHAR(20);
    DECLARE v_opens_minute SMALLINT UNSIGNED;
    DECLARE v_closes_minute SMALLINT UNSIGNED;
    DECLARE v_minute_of_day SMALLINT UNSIGNED;
    DECLARE v_now DATETIME;
    DECLARE v_method VARCHAR(20);

    SET p_checkin_id = 0;
    SET p_occupancy_id = 0;
    SET v_now = COALESCE(p_now, NOW());
    SET v_method = COALESCE(p_checkin_method, 'QR_CODE');

    IF p_reservation_id IS NULL OR p_reservation_id = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_ID_INVALID';
    END IF;

    IF v_method NOT IN ('QR_CODE', 'STAFF', 'AUTO') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_METHOD_INVALID';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM charging_reservation
     WHERE reservation_id = p_reservation_id;

    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_NOT_FOUND';
    END IF;

    SELECT user_id, vehicle_id, gun_id, station_id,
           starts_at, ends_at, late_grace_minutes, status
      INTO v_user_id, v_vehicle_id, v_gun_id, v_station_id,
           v_starts_at, v_ends_at, v_grace, v_status
      FROM charging_reservation
     WHERE reservation_id = p_reservation_id
     FOR UPDATE;

    IF v_status <> 'BOOKED' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_NOT_BOOKED';
    END IF;

    IF v_now < v_starts_at - INTERVAL 30 MINUTE THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_TOO_EARLY';
    END IF;

    IF v_now >= v_ends_at + INTERVAL v_grace MINUTE THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_EXPIRED';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM `user`
     WHERE user_id = v_user_id
       AND user_status = 'ACTIVE';

    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_USER_NOT_ACTIVE';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM vehicle
     WHERE vehicle_id = v_vehicle_id
       AND user_id = v_user_id
       AND vehicle_status = 'ACTIVE';

    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_VEHICLE_NOT_ACTIVE';
    END IF;

    SELECT parking_space_id, status
      INTO v_space_id, v_gun_status
      FROM charging_gun
     WHERE gun_id = v_gun_id
       AND station_id = v_station_id
     FOR UPDATE;

    IF v_space_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_GUN_STATION_MISMATCH';
    END IF;

    IF v_gun_status <> 'READY' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_GUN_NOT_READY';
    END IF;

    SELECT status, opens_minute, closes_minute
      INTO v_station_status, v_opens_minute, v_closes_minute
      FROM station
     WHERE station_id = v_station_id;

    IF v_station_status <> 'OPEN' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_STATION_CLOSED';
    END IF;

    SET v_minute_of_day = HOUR(v_now) * 60 + MINUTE(v_now);
    IF v_minute_of_day < v_opens_minute
       OR v_minute_of_day >= v_closes_minute THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_OUTSIDE_BUSINESS_HOURS';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM equipment_outage_plan
     WHERE station_id = v_station_id
       AND status = 'SCHEDULED'
       AND (gun_id IS NULL OR gun_id = v_gun_id)
       AND starts_at <= v_now
       AND ends_at > v_now;

    IF v_count > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_GUN_OUTAGE';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM charging_order
     WHERE active_gun_id = v_gun_id;

    IF v_count > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_GUN_HAS_ACTIVE_ORDER';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM parking_occupancy
     WHERE active_space_id = v_space_id;

    IF v_count > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_SPACE_OCCUPIED';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM parking_occupancy
     WHERE active_vehicle_id = v_vehicle_id;

    IF v_count > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_VEHICLE_OCCUPIED';
    END IF;

    SET @a_change_reason = 'CHECKIN_RESERVATION';

    UPDATE charging_reservation
       SET status = 'CHECKED_IN'
     WHERE reservation_id = p_reservation_id
       AND status = 'BOOKED';

    IF ROW_COUNT() <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_RESERVATION_RACE';
    END IF;

    INSERT INTO arrival_checkin (
        reservation_id, queue_id, user_id, vehicle_id,
        station_id, gun_id, parking_space_id,
        checked_in_at, checkin_method, plate_verified
    ) VALUES (
        p_reservation_id, NULL, v_user_id, v_vehicle_id,
        v_station_id, v_gun_id, v_space_id,
        v_now, v_method, 1
    );

    SET p_checkin_id = LAST_INSERT_ID();

    SELECT occupancy_id
      INTO p_occupancy_id
      FROM parking_occupancy
     WHERE checkin_id = p_checkin_id;
END$$

-- ---------------------------------------------------------------------------
-- ⑥ 现场排队：入队
-- 锁场站行后分配当日排队号；active_user_id 唯一约束防止同一用户重复排队。
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_join_queue(
    IN p_station_id BIGINT UNSIGNED,
    IN p_user_id BIGINT UNSIGNED,
    IN p_vehicle_id BIGINT UNSIGNED,
    IN p_gun_id BIGINT UNSIGNED,
    IN p_priority_class VARCHAR(20),
    IN p_hold_minutes SMALLINT UNSIGNED,
    IN p_now DATETIME,
    OUT p_queue_id BIGINT UNSIGNED,
    OUT p_ticket_no INT UNSIGNED
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
COMMENT '现场排队入队：锁场站分配当日号，校验用户/车辆/枪'
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_station_status VARCHAR(20);
    DECLARE v_opens_minute SMALLINT UNSIGNED DEFAULT 0;
    DECLARE v_closes_minute SMALLINT UNSIGNED DEFAULT 1440;
    DECLARE v_minute_of_day SMALLINT UNSIGNED DEFAULT 0;
    DECLARE v_gun_status VARCHAR(20);
    DECLARE v_priority_class VARCHAR(20);
    DECLARE v_priority_score SMALLINT DEFAULT 0;
    DECLARE v_hold_minutes SMALLINT UNSIGNED DEFAULT 10;
    DECLARE v_now DATETIME;
    DECLARE v_queue_date DATE;
    DECLARE v_ticket_no INT UNSIGNED;

    SET p_queue_id = 0;
    SET p_ticket_no = 0;
    SET v_now = COALESCE(p_now, NOW());
    SET v_priority_class = COALESCE(p_priority_class, 'WALK_IN');
    SET v_hold_minutes = COALESCE(p_hold_minutes, 10);

    IF p_station_id IS NULL OR p_station_id = 0
       OR p_user_id IS NULL OR p_user_id = 0
       OR p_vehicle_id IS NULL OR p_vehicle_id = 0
       OR p_gun_id IS NULL OR p_gun_id = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'QUEUE_ID_INVALID';
    END IF;

    IF v_priority_class NOT IN ('WALK_IN', 'RESERVATION_LATE') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'QUEUE_PRIORITY_INVALID';
    END IF;

    IF v_hold_minutes NOT BETWEEN 1 AND 60 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'QUEUE_HOLD_INVALID';
    END IF;

    SET v_priority_score = IF(v_priority_class = 'RESERVATION_LATE', 100, 0);

    SELECT status, opens_minute, closes_minute
      INTO v_station_status, v_opens_minute, v_closes_minute
      FROM station
     WHERE station_id = p_station_id
     FOR UPDATE;

    IF v_station_status IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'QUEUE_STATION_NOT_FOUND';
    END IF;

    IF v_station_status <> 'OPEN' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'QUEUE_STATION_CLOSED';
    END IF;

    SET v_minute_of_day = HOUR(v_now) * 60 + MINUTE(v_now);
    IF v_minute_of_day < v_opens_minute
       OR v_minute_of_day >= v_closes_minute THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'QUEUE_OUTSIDE_BUSINESS_HOURS';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM `user`
     WHERE user_id = p_user_id
       AND user_status = 'ACTIVE';

    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'QUEUE_USER_NOT_ACTIVE';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM vehicle
     WHERE vehicle_id = p_vehicle_id
       AND user_id = p_user_id
       AND vehicle_status = 'ACTIVE';

    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'QUEUE_VEHICLE_NOT_OWNED_OR_INACTIVE';
    END IF;

    SELECT status
      INTO v_gun_status
      FROM charging_gun
     WHERE gun_id = p_gun_id
       AND station_id = p_station_id;

    IF v_gun_status IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'QUEUE_GUN_STATION_MISMATCH';
    END IF;

    IF v_gun_status = 'DISABLED' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'QUEUE_GUN_DISABLED';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM queue_record
     WHERE active_user_id = p_user_id;

    IF v_count > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'QUEUE_USER_ALREADY_ACTIVE';
    END IF;

    SET v_queue_date = DATE(v_now);

    SELECT COALESCE(MAX(ticket_no), 0) + 1
      INTO v_ticket_no
      FROM queue_record
     WHERE station_id = p_station_id
       AND queue_date = v_queue_date;

    SET @a_change_reason = 'JOIN_QUEUE';

    INSERT INTO queue_record (
        station_id, user_id, vehicle_id, gun_id, ticket_no,
        priority_class, priority_score, status,
        joined_at, hold_minutes
    ) VALUES (
        p_station_id, p_user_id, p_vehicle_id, p_gun_id, v_ticket_no,
        v_priority_class, v_priority_score, 'WAITING',
        v_now, v_hold_minutes
    );

    SET p_queue_id = LAST_INSERT_ID();
    SET p_ticket_no = v_ticket_no;
END$$

-- ---------------------------------------------------------------------------
-- ⑥ 现场排队：叫号
-- 先过期超时叫号，再按优先级和入队时间取下一号。
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_call_next_queue(
    IN p_station_id BIGINT UNSIGNED,
    IN p_now DATETIME,
    OUT p_queue_id BIGINT UNSIGNED,
    OUT p_user_id BIGINT UNSIGNED,
    OUT p_vehicle_id BIGINT UNSIGNED,
    OUT p_gun_id BIGINT UNSIGNED,
    OUT p_ticket_no INT UNSIGNED
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
COMMENT '叫下一号：过期超时叫号，按优先级/入队时间选取并置为 CALLED'
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_queue_id BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_user_id BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_vehicle_id BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_gun_id BIGINT UNSIGNED DEFAULT NULL;
    DECLARE v_ticket_no INT UNSIGNED DEFAULT NULL;
    DECLARE v_hold_minutes SMALLINT UNSIGNED;
    DECLARE v_now DATETIME;

    SET p_queue_id = 0;
    SET p_user_id = 0;
    SET p_vehicle_id = 0;
    SET p_gun_id = 0;
    SET p_ticket_no = 0;
    SET v_now = COALESCE(p_now, NOW());

    IF p_station_id IS NULL OR p_station_id = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'QUEUE_STATION_ID_INVALID';
    END IF;

    SELECT station_id
      INTO v_count
      FROM station
     WHERE station_id = p_station_id
     FOR UPDATE;

    IF v_count IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'QUEUE_STATION_NOT_FOUND';
    END IF;

    SET @a_change_reason = 'CALL_TIMEOUT';

    UPDATE queue_record
       SET status = 'EXPIRED'
     WHERE station_id = p_station_id
       AND status = 'CALLED'
       AND call_expires_at <= v_now;

    SELECT queue_id, user_id, vehicle_id, gun_id, ticket_no, hold_minutes
      INTO v_queue_id, v_user_id, v_vehicle_id, v_gun_id, v_ticket_no, v_hold_minutes
      FROM queue_record
     WHERE station_id = p_station_id
       AND status = 'WAITING'
     ORDER BY priority_score DESC, joined_at ASC, queue_id ASC
     LIMIT 1
     FOR UPDATE;

    IF v_queue_id IS NOT NULL THEN
        SET @a_change_reason = 'CALL_QUEUE';

        UPDATE queue_record
           SET status = 'CALLED',
               called_at = v_now,
               call_expires_at = v_now + INTERVAL v_hold_minutes MINUTE
         WHERE queue_id = v_queue_id
           AND status = 'WAITING';

        IF ROW_COUNT() <> 1 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'QUEUE_CALL_RACE';
        END IF;

        SET p_queue_id = v_queue_id;
        SET p_user_id = v_user_id;
        SET p_vehicle_id = v_vehicle_id;
        SET p_gun_id = v_gun_id;
        SET p_ticket_no = v_ticket_no;
    END IF;
END$$

-- ---------------------------------------------------------------------------
-- ⑥ 到站核验：现场排队
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_check_in_queue(
    IN p_queue_id BIGINT UNSIGNED,
    IN p_checkin_method VARCHAR(20),
    IN p_now DATETIME,
    OUT p_checkin_id BIGINT UNSIGNED,
    OUT p_occupancy_id BIGINT UNSIGNED
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
COMMENT '排队到站核验：校验叫号有效期/设备/车位后写入核验并自动占位'
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_user_id BIGINT UNSIGNED;
    DECLARE v_vehicle_id BIGINT UNSIGNED;
    DECLARE v_gun_id BIGINT UNSIGNED;
    DECLARE v_station_id BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(20);
    DECLARE v_call_expires_at DATETIME;
    DECLARE v_space_id BIGINT UNSIGNED;
    DECLARE v_gun_status VARCHAR(20);
    DECLARE v_station_status VARCHAR(20);
    DECLARE v_opens_minute SMALLINT UNSIGNED;
    DECLARE v_closes_minute SMALLINT UNSIGNED;
    DECLARE v_minute_of_day SMALLINT UNSIGNED;
    DECLARE v_now DATETIME;
    DECLARE v_method VARCHAR(20);

    SET p_checkin_id = 0;
    SET p_occupancy_id = 0;
    SET v_now = COALESCE(p_now, NOW());
    SET v_method = COALESCE(p_checkin_method, 'QR_CODE');

    IF p_queue_id IS NULL OR p_queue_id = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'QUEUE_ID_INVALID';
    END IF;

    IF v_method NOT IN ('QR_CODE', 'STAFF', 'AUTO') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_METHOD_INVALID';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM queue_record
     WHERE queue_id = p_queue_id;

    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'QUEUE_NOT_FOUND';
    END IF;

    SELECT user_id, vehicle_id, gun_id, station_id, status, call_expires_at
      INTO v_user_id, v_vehicle_id, v_gun_id, v_station_id, v_status, v_call_expires_at
      FROM queue_record
     WHERE queue_id = p_queue_id
     FOR UPDATE;

    IF v_status <> 'CALLED' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'QUEUE_NOT_CALLED';
    END IF;

    IF v_call_expires_at IS NULL OR v_now >= v_call_expires_at THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'QUEUE_CALL_EXPIRED';
    END IF;

    SELECT parking_space_id, status
      INTO v_space_id, v_gun_status
      FROM charging_gun
     WHERE gun_id = v_gun_id
       AND station_id = v_station_id
     FOR UPDATE;

    IF v_space_id IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_GUN_STATION_MISMATCH';
    END IF;

    IF v_gun_status <> 'READY' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_GUN_NOT_READY';
    END IF;

    SELECT status, opens_minute, closes_minute
      INTO v_station_status, v_opens_minute, v_closes_minute
      FROM station
     WHERE station_id = v_station_id;

    IF v_station_status <> 'OPEN' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_STATION_CLOSED';
    END IF;

    SET v_minute_of_day = HOUR(v_now) * 60 + MINUTE(v_now);
    IF v_minute_of_day < v_opens_minute
       OR v_minute_of_day >= v_closes_minute THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_OUTSIDE_BUSINESS_HOURS';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM equipment_outage_plan
     WHERE station_id = v_station_id
       AND status = 'SCHEDULED'
       AND (gun_id IS NULL OR gun_id = v_gun_id)
       AND starts_at <= v_now
       AND ends_at > v_now;

    IF v_count > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_GUN_OUTAGE';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM charging_order
     WHERE active_gun_id = v_gun_id;

    IF v_count > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_GUN_HAS_ACTIVE_ORDER';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM parking_occupancy
     WHERE active_space_id = v_space_id;

    IF v_count > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_SPACE_OCCUPIED';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM parking_occupancy
     WHERE active_vehicle_id = v_vehicle_id;

    IF v_count > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_VEHICLE_OCCUPIED';
    END IF;

    SET @a_change_reason = 'CHECKIN_QUEUE';

    UPDATE queue_record
       SET status = 'CHECKED_IN'
     WHERE queue_id = p_queue_id
       AND status = 'CALLED';

    IF ROW_COUNT() <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_QUEUE_RACE';
    END IF;

    INSERT INTO arrival_checkin (
        reservation_id, queue_id, user_id, vehicle_id,
        station_id, gun_id, parking_space_id,
        checked_in_at, checkin_method, plate_verified
    ) VALUES (
        NULL, p_queue_id, v_user_id, v_vehicle_id,
        v_station_id, v_gun_id, v_space_id,
        v_now, v_method, 1
    );

    SET p_checkin_id = LAST_INSERT_ID();

    SELECT occupancy_id
      INTO p_occupancy_id
      FROM parking_occupancy
     WHERE checkin_id = p_checkin_id;
END$$

-- ---------------------------------------------------------------------------
-- ⑥ 车位释放
-- 正常驶离要求该枪没有进行中订单；充电结束后才允许释放。
-- 若资格仍是 CHECKED_IN（未开单），同时取消资格。
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_release_parking_space(
    IN p_occupancy_id BIGINT UNSIGNED,
    IN p_release_reason VARCHAR(20),
    IN p_now DATETIME,
    OUT p_released TINYINT
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
COMMENT '释放车位占用；未开单的资格同时取消'
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_released_at DATETIME;
    DECLARE v_gun_id BIGINT UNSIGNED;
    DECLARE v_checkin_id BIGINT UNSIGNED;
    DECLARE v_reservation_id BIGINT UNSIGNED;
    DECLARE v_queue_id BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(20);
    DECLARE v_now DATETIME;
    DECLARE v_reason VARCHAR(20);

    SET p_released = 0;
    SET v_now = COALESCE(p_now, NOW());
    SET v_reason = COALESCE(p_release_reason, 'VEHICLE_LEFT');

    IF p_occupancy_id IS NULL OR p_occupancy_id = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'OCCUPANCY_ID_INVALID';
    END IF;

    IF v_reason NOT IN ('VEHICLE_LEFT', 'STAFF', 'CHECKIN_CANCELLED', 'OTHER') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'OCCUPANCY_RELEASE_REASON_INVALID';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM parking_occupancy
     WHERE occupancy_id = p_occupancy_id;

    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'OCCUPANCY_NOT_FOUND';
    END IF;

    SELECT released_at, gun_id, checkin_id
      INTO v_released_at, v_gun_id, v_checkin_id
      FROM parking_occupancy
     WHERE occupancy_id = p_occupancy_id
     FOR UPDATE;

    IF v_released_at IS NOT NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'OCCUPANCY_ALREADY_RELEASED';
    END IF;

    IF v_reason = 'VEHICLE_LEFT' THEN
        SELECT COUNT(*)
          INTO v_count
          FROM charging_order
         WHERE active_gun_id = v_gun_id;

        IF v_count > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'OCCUPANCY_VEHICLE_STILL_CHARGING';
        END IF;
    END IF;

    SET @a_change_reason = 'RELEASE_PARKING';

    UPDATE parking_occupancy
       SET released_at = v_now,
           release_reason = v_reason
     WHERE occupancy_id = p_occupancy_id
       AND released_at IS NULL;

    IF ROW_COUNT() <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'OCCUPANCY_RELEASE_RACE';
    END IF;

    SELECT reservation_id, queue_id
      INTO v_reservation_id, v_queue_id
      FROM arrival_checkin
     WHERE checkin_id = v_checkin_id;

    IF v_reservation_id IS NOT NULL THEN
        SELECT status
          INTO v_status
          FROM charging_reservation
         WHERE reservation_id = v_reservation_id
         FOR UPDATE;

        IF v_status = 'CHECKED_IN' THEN
            SET @a_change_reason = 'LEFT_WITHOUT_CHARGING';
            UPDATE charging_reservation
               SET status = 'CANCELLED',
                   cancelled_at = v_now,
                   cancel_reason = 'LEFT_WITHOUT_CHARGING'
             WHERE reservation_id = v_reservation_id
               AND status = 'CHECKED_IN';
        END IF;
    ELSEIF v_queue_id IS NOT NULL THEN
        SELECT status
          INTO v_status
          FROM queue_record
         WHERE queue_id = v_queue_id
         FOR UPDATE;

        IF v_status = 'CHECKED_IN' THEN
            SET @a_change_reason = 'LEFT_WITHOUT_CHARGING';
            UPDATE queue_record
               SET status = 'CANCELLED',
                   cancelled_at = v_now,
                   cancel_reason = 'LEFT_WITHOUT_CHARGING'
             WHERE queue_id = v_queue_id
               AND status = 'CHECKED_IN';
        END IF;
    END IF;

    SET p_released = 1;
END$$

-- ---------------------------------------------------------------------------
-- ⑥ 资格消费：供 B 的开单事务调用
-- B 先创建 charging_order（channel + admission_id），再调用本过程；
-- 本过程校验订单的资格映射，并把预约/排队资格置为 CONSUMED。
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_consume_admission(
    IN p_channel VARCHAR(20),
    IN p_admission_id BIGINT UNSIGNED,
    IN p_order_id BIGINT UNSIGNED,
    IN p_now DATETIME,
    OUT p_consumed TINYINT
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
COMMENT '开单后原子消费预约/排队资格，供 B 模块调用'
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_now DATETIME;
    DECLARE v_order_user BIGINT UNSIGNED;
    DECLARE v_order_vehicle BIGINT UNSIGNED;
    DECLARE v_order_gun BIGINT UNSIGNED;
    DECLARE v_order_channel VARCHAR(20);
    DECLARE v_order_admission BIGINT UNSIGNED;
    DECLARE v_user_id BIGINT UNSIGNED;
    DECLARE v_vehicle_id BIGINT UNSIGNED;
    DECLARE v_gun_id BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(20);
    DECLARE v_consumed_order BIGINT UNSIGNED;

    SET p_consumed = 0;
    SET v_now = COALESCE(p_now, NOW());

    IF p_channel NOT IN ('RESERVATION', 'QUEUE') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'ADMISSION_CHANNEL_INVALID';
    END IF;

    IF p_admission_id IS NULL OR p_admission_id = 0
       OR p_order_id IS NULL OR p_order_id = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'ADMISSION_ID_INVALID';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM charging_order
     WHERE order_id = p_order_id;

    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'ADMISSION_ORDER_NOT_FOUND';
    END IF;

    SELECT user_id, vehicle_id, gun_id, channel, admission_id
      INTO v_order_user, v_order_vehicle, v_order_gun,
           v_order_channel, v_order_admission
      FROM charging_order
     WHERE order_id = p_order_id
     FOR UPDATE;

    IF v_order_channel <> p_channel
       OR NOT (v_order_admission <=> p_admission_id) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'ADMISSION_ORDER_MISMATCH';
    END IF;

    IF p_channel = 'RESERVATION' THEN
        SELECT COUNT(*)
          INTO v_count
          FROM charging_reservation
         WHERE reservation_id = p_admission_id;

        IF v_count = 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'ADMISSION_RESERVATION_NOT_FOUND';
        END IF;

        SELECT user_id, vehicle_id, gun_id, status, consumed_order_id
          INTO v_user_id, v_vehicle_id, v_gun_id, v_status, v_consumed_order
          FROM charging_reservation
         WHERE reservation_id = p_admission_id
         FOR UPDATE;

        IF v_status <> 'CHECKED_IN' THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'ADMISSION_RESERVATION_NOT_CHECKED_IN';
        END IF;

        IF v_consumed_order IS NOT NULL THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'ADMISSION_RESERVATION_ALREADY_CONSUMED';
        END IF;

        IF v_user_id <> v_order_user
           OR v_vehicle_id <> v_order_vehicle
           OR v_gun_id <> v_order_gun THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'ADMISSION_RESERVATION_ORDER_MISMATCH';
        END IF;

        SET @a_change_reason = 'CONSUME_RESERVATION';

        UPDATE charging_reservation
           SET status = 'CONSUMED',
               consumed_at = v_now,
               consumed_order_id = p_order_id
         WHERE reservation_id = p_admission_id
           AND status = 'CHECKED_IN'
           AND consumed_order_id IS NULL;

        IF ROW_COUNT() <> 1 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'ADMISSION_RESERVATION_RACE';
        END IF;
    ELSE
        SELECT COUNT(*)
          INTO v_count
          FROM queue_record
         WHERE queue_id = p_admission_id;

        IF v_count = 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'ADMISSION_QUEUE_NOT_FOUND';
        END IF;

        SELECT user_id, vehicle_id, gun_id, status, consumed_order_id
          INTO v_user_id, v_vehicle_id, v_gun_id, v_status, v_consumed_order
          FROM queue_record
         WHERE queue_id = p_admission_id
         FOR UPDATE;

        IF v_status <> 'CHECKED_IN' THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'ADMISSION_QUEUE_NOT_CHECKED_IN';
        END IF;

        IF v_consumed_order IS NOT NULL THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'ADMISSION_QUEUE_ALREADY_CONSUMED';
        END IF;

        IF v_user_id <> v_order_user
           OR v_vehicle_id <> v_order_vehicle
           OR v_gun_id <> v_order_gun THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'ADMISSION_QUEUE_ORDER_MISMATCH';
        END IF;

        SET @a_change_reason = 'CONSUME_QUEUE';

        UPDATE queue_record
           SET status = 'CONSUMED',
               consumed_at = v_now,
               consumed_order_id = p_order_id
         WHERE queue_id = p_admission_id
           AND status = 'CHECKED_IN'
           AND consumed_order_id IS NULL;

        IF ROW_COUNT() <> 1 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'ADMISSION_QUEUE_RACE';
        END IF;
    END IF;

    SET p_consumed = 1;
END$$

-- ---------------------------------------------------------------------------
-- ⑥ 过期处理：预约迟到超保留期、叫号超时、排队等待过久
-- 建议由定时任务每 5 分钟调用一次；也可在演示前手动调用。
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_expire_overdue_admissions(
    IN p_now DATETIME,
    OUT p_expired_reservations INT,
    OUT p_expired_queues INT
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
COMMENT '批量过期：预约迟到超保留、叫号超时、排队等待超过240分钟'
BEGIN
    DECLARE v_now DATETIME;
    DECLARE v_queue_expired INT DEFAULT 0;
    DECLARE v_wait_expired INT DEFAULT 0;

    SET v_now = COALESCE(p_now, NOW());

    SET @a_change_reason = 'AUTO_EXPIRE_RESERVATION';

    UPDATE charging_reservation
       SET status = 'EXPIRED'
     WHERE status = 'BOOKED'
       AND ends_at + INTERVAL late_grace_minutes MINUTE <= v_now;

    SET p_expired_reservations = ROW_COUNT();

    SET @a_change_reason = 'CALL_TIMEOUT';

    UPDATE queue_record
       SET status = 'EXPIRED'
     WHERE status = 'CALLED'
       AND call_expires_at <= v_now;

    SET v_queue_expired = ROW_COUNT();

    SET @a_change_reason = 'QUEUE_WAIT_TIMEOUT';

    UPDATE queue_record
       SET status = 'EXPIRED'
     WHERE status = 'WAITING'
       AND joined_at <= v_now - INTERVAL 240 MINUTE;

    SET v_wait_expired = ROW_COUNT();
    SET p_expired_queues = v_queue_expired + v_wait_expired;
END$$

-- ---------------------------------------------------------------------------
-- ⑧ 公告：发布
-- 定向停运公告发布时，按共享停运计划筛选受影响的预约/排队资格，
-- 生成接收对象快照和 IN_APP 待发送通知。
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_publish_notice(
    IN p_notice_id BIGINT UNSIGNED,
    IN p_operator VARCHAR(64),
    IN p_now DATETIME,
    OUT p_recipient_count INT,
    OUT p_notification_count INT
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
COMMENT '发布公告；定向停运公告自动生成受影响用户与待发送通知'
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_status VARCHAR(20);
    DECLARE v_notice_type VARCHAR(20);
    DECLARE v_plan_id BIGINT UNSIGNED;
    DECLARE v_plan_station_id BIGINT UNSIGNED;
    DECLARE v_plan_gun_id BIGINT UNSIGNED;
    DECLARE v_plan_starts_at DATETIME;
    DECLARE v_plan_ends_at DATETIME;
    DECLARE v_now DATETIME;
    DECLARE v_operator VARCHAR(64);
    DECLARE v_recipients INT DEFAULT 0;
    DECLARE v_added INT DEFAULT 0;

    SET p_recipient_count = 0;
    SET p_notification_count = 0;
    SET v_now = COALESCE(p_now, NOW());
    SET v_operator = COALESCE(p_operator, 'SYSTEM');

    IF p_notice_id IS NULL OR p_notice_id = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'NOTICE_ID_INVALID';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM station_notice
     WHERE notice_id = p_notice_id;

    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'NOTICE_NOT_FOUND';
    END IF;

    SELECT status, notice_type, related_outage_plan_id
      INTO v_status, v_notice_type, v_plan_id
      FROM station_notice
     WHERE notice_id = p_notice_id
     FOR UPDATE;

    IF v_status <> 'DRAFT' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'NOTICE_NOT_DRAFT';
    END IF;

    UPDATE station_notice
       SET status = 'PUBLISHED',
           published_at = v_now,
           updated_by = v_operator
     WHERE notice_id = p_notice_id
       AND status = 'DRAFT';

    IF ROW_COUNT() <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'NOTICE_PUBLISH_RACE';
    END IF;

    IF v_notice_type = 'OUTAGE_TARGETED' THEN
        SELECT COUNT(*)
          INTO v_count
          FROM equipment_outage_plan
         WHERE outage_plan_id = v_plan_id;

        IF v_count = 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'NOTICE_OUTAGE_PLAN_NOT_FOUND';
        END IF;

        SELECT station_id, gun_id, starts_at, ends_at
          INTO v_plan_station_id, v_plan_gun_id, v_plan_starts_at, v_plan_ends_at
          FROM equipment_outage_plan
         WHERE outage_plan_id = v_plan_id;

        INSERT INTO notice_recipient (
            notice_id, user_id, vehicle_id, reservation_id,
            recipient_reason
        )
        SELECT p_notice_id, r.user_id, r.vehicle_id, r.reservation_id,
               'AFFECTED_RESERVATION'
          FROM charging_reservation AS r
         WHERE r.station_id = v_plan_station_id
           AND (v_plan_gun_id IS NULL OR r.gun_id = v_plan_gun_id)
           AND r.status IN ('BOOKED', 'CHECKED_IN')
           AND r.starts_at < v_plan_ends_at
           AND r.ends_at > v_plan_starts_at
        ON DUPLICATE KEY UPDATE recipient_id = recipient_id;

        SET v_added = ROW_COUNT();
        SET v_recipients = v_recipients + v_added;

        INSERT INTO notice_recipient (
            notice_id, user_id, vehicle_id, queue_id,
            recipient_reason
        )
        SELECT p_notice_id, q.user_id, q.vehicle_id, q.queue_id,
               'AFFECTED_QUEUE'
          FROM queue_record AS q
         WHERE q.station_id = v_plan_station_id
           AND (v_plan_gun_id IS NULL OR q.gun_id = v_plan_gun_id)
           AND q.status IN ('WAITING', 'CALLED', 'CHECKED_IN')
           AND v_plan_starts_at <= v_now
           AND v_plan_ends_at > v_now
        ON DUPLICATE KEY UPDATE recipient_id = recipient_id;

        SET v_added = ROW_COUNT();
        SET v_recipients = v_recipients + v_added;

        INSERT INTO notification_record (
            recipient_id, channel, status
        )
        SELECT nr.recipient_id, 'IN_APP', 'PENDING'
          FROM notice_recipient AS nr
         WHERE nr.notice_id = p_notice_id
        ON DUPLICATE KEY UPDATE notification_id = notification_id;

        SET p_notification_count = ROW_COUNT();
    END IF;

    SET p_recipient_count = v_recipients;
END$$

-- ---------------------------------------------------------------------------
-- ⑧ 公告：撤回
-- 已发送通知无法撤回；未发送的 PENDING 通知标记为 FAILED。
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_withdraw_notice(
    IN p_notice_id BIGINT UNSIGNED,
    IN p_operator VARCHAR(64),
    IN p_reason VARCHAR(255),
    IN p_now DATETIME,
    OUT p_cancelled_notifications INT
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
COMMENT '撤回已发布公告，取消尚未发送的通知'
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_status VARCHAR(20);
    DECLARE v_now DATETIME;
    DECLARE v_reason VARCHAR(255);
    DECLARE v_operator VARCHAR(64);

    SET p_cancelled_notifications = 0;
    SET v_now = COALESCE(p_now, NOW());
    SET v_reason = TRIM(COALESCE(p_reason, ''));
    SET v_operator = COALESCE(p_operator, 'SYSTEM');

    IF p_notice_id IS NULL OR p_notice_id = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'NOTICE_ID_INVALID';
    END IF;

    IF v_reason = '' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'NOTICE_WITHDRAW_REASON_REQUIRED';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM station_notice
     WHERE notice_id = p_notice_id;

    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'NOTICE_NOT_FOUND';
    END IF;

    SELECT status
      INTO v_status
      FROM station_notice
     WHERE notice_id = p_notice_id
     FOR UPDATE;

    IF v_status <> 'PUBLISHED' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'NOTICE_NOT_PUBLISHED';
    END IF;

    UPDATE station_notice
       SET status = 'WITHDRAWN',
           withdrawn_at = v_now,
           withdraw_reason = v_reason,
           updated_by = v_operator
     WHERE notice_id = p_notice_id
       AND status = 'PUBLISHED';

    IF ROW_COUNT() <> 1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'NOTICE_WITHDRAW_RACE';
    END IF;

    UPDATE notification_record AS nr
      JOIN notice_recipient AS rec
        ON rec.recipient_id = nr.recipient_id
       SET nr.status = 'FAILED',
           nr.failure_reason = 'NOTICE_WITHDRAWN'
     WHERE rec.notice_id = p_notice_id
       AND nr.status = 'PENDING';

    SET p_cancelled_notifications = ROW_COUNT();
END$$

-- ---------------------------------------------------------------------------
-- ⑧ 通知状态更新：发送成功、失败重试、阅读回执
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_update_notification_status(
    IN p_notification_id BIGINT UNSIGNED,
    IN p_status VARCHAR(20),
    IN p_provider_message_id VARCHAR(64),
    IN p_failure_reason VARCHAR(255),
    IN p_at DATETIME,
    OUT p_updated TINYINT
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
COMMENT '更新通知发送状态；校验状态机与时间/失败原因一致性'
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_old_status VARCHAR(20);
    DECLARE v_at DATETIME;
    DECLARE v_status VARCHAR(20);

    SET p_updated = 0;
    SET v_at = COALESCE(p_at, NOW());
    SET v_status = COALESCE(p_status, '');

    IF p_notification_id IS NULL OR p_notification_id = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'NOTIFICATION_ID_INVALID';
    END IF;

    IF v_status NOT IN ('PENDING', 'SENT', 'FAILED', 'READ') THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'NOTIFICATION_STATUS_INVALID';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM notification_record
     WHERE notification_id = p_notification_id;

    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'NOTIFICATION_NOT_FOUND';
    END IF;

    SELECT status
      INTO v_old_status
      FROM notification_record
     WHERE notification_id = p_notification_id
     FOR UPDATE;

    IF v_status = 'PENDING' THEN
        UPDATE notification_record
           SET status = 'PENDING',
               sent_at = NULL,
               read_at = NULL,
               failure_reason = NULL
         WHERE notification_id = p_notification_id;
    ELSEIF v_status = 'SENT' THEN
        UPDATE notification_record
           SET status = 'SENT',
               sent_at = v_at,
               read_at = NULL,
               failure_reason = NULL,
               provider_message_id = COALESCE(
                   p_provider_message_id,
                   provider_message_id
               )
         WHERE notification_id = p_notification_id;
    ELSEIF v_status = 'FAILED' THEN
        UPDATE notification_record
           SET status = 'FAILED',
               sent_at = NULL,
               read_at = NULL,
               failure_reason = COALESCE(
                   NULLIF(TRIM(p_failure_reason), ''),
                   'UNKNOWN_FAILURE'
               ),
               retry_count = retry_count + 1
         WHERE notification_id = p_notification_id;
    ELSE
        UPDATE notification_record
           SET status = 'READ',
               read_at = v_at,
               failure_reason = NULL
         WHERE notification_id = p_notification_id;
    END IF;

    -- 同一状态的幂等更新可能返回 ROW_COUNT()=0，这里以“行已锁定且存在”为准。
    SET p_updated = 1;
END$$

-- ---------------------------------------------------------------------------
-- ⑧ 公告过期批处理
-- ---------------------------------------------------------------------------
CREATE PROCEDURE sp_expire_notices(
    IN p_now DATETIME,
    OUT p_expired_count INT
)
SQL SECURITY INVOKER
MODIFIES SQL DATA
COMMENT '把已过 effective_to 的已发布公告置为 EXPIRED'
BEGIN
    DECLARE v_now DATETIME;

    SET v_now = COALESCE(p_now, NOW());

    UPDATE station_notice
       SET status = 'EXPIRED',
           updated_by = 'SYSTEM'
     WHERE status = 'PUBLISHED'
       AND effective_to IS NOT NULL
       AND effective_to <= v_now;

    SET p_expired_count = ROW_COUNT();
END$$

DELIMITER ;
