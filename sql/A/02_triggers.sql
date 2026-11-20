-- A ⑥⑧ 数据库触发器
-- 目标环境：MySQL 8.0.46。
-- 首次执行成功后不要重复 SOURCE；重复创建会报 TRIGGER already exists。
-- 触发器是直接 SQL 写入时的兜底；正式业务入口仍是 03_procedures.sql 中的过程。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

DELIMITER $$

-- ---------------------------------------------------------------------------
-- ⑥ 预约
-- ---------------------------------------------------------------------------

-- 新建预约时检查同枪有效预约区间冲突，并阻止同一用户同一时段重复预约。
-- 正式入口 sp_create_reservation 会先锁定充电枪行，避免并发穿越；
-- 本触发器用于拦截绕过过程直接 INSERT 的写入。
CREATE TRIGGER a_reservation_overlap_bi
BEFORE INSERT ON charging_reservation
FOR EACH ROW
BEGIN
    DECLARE v_gun_conflict INT DEFAULT 0;
    DECLARE v_user_conflict INT DEFAULT 0;

    -- MySQL 不允许在触发器中对正在写入的同一张表做锁定读（错误 1442），
    -- 因此这里使用普通一致性读作为顺序写入兜底；
    -- 并发创建必须走 sp_create_reservation，其中用锁枪行 + 锁定读保证当前读。
    IF NEW.status IN ('BOOKED', 'CHECKED_IN') THEN
        SELECT COUNT(*)
          INTO v_gun_conflict
          FROM charging_reservation
         WHERE gun_id = NEW.gun_id
           AND status IN ('BOOKED', 'CHECKED_IN')
           AND starts_at < NEW.ends_at
           AND ends_at > NEW.starts_at;

        IF v_gun_conflict > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'RESERVATION_GUN_OVERLAP';
        END IF;

        SELECT COUNT(*)
          INTO v_user_conflict
          FROM charging_reservation
         WHERE user_id = NEW.user_id
           AND status IN ('BOOKED', 'CHECKED_IN')
           AND starts_at < NEW.ends_at
           AND ends_at > NEW.starts_at;

        IF v_user_conflict > 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'RESERVATION_USER_OVERLAP';
        END IF;
    END IF;
END$$

-- 预约状态机与身份字段不可变。
-- 允许：BOOKED -> CHECKED_IN/CANCELLED/EXPIRED/NO_SHOW
--       CHECKED_IN -> CONSUMED/CANCELLED/EXPIRED/NO_SHOW
-- 改约通过“取消旧预约 + 新建预约”实现，不直接修改时段。
CREATE TRIGGER a_reservation_status_bu
BEFORE UPDATE ON charging_reservation
FOR EACH ROW
BEGIN
    IF NEW.status <> OLD.status THEN
        IF NOT (
            (OLD.status = 'BOOKED'
                AND NEW.status IN ('CHECKED_IN', 'CANCELLED', 'EXPIRED', 'NO_SHOW'))
            OR
            (OLD.status = 'CHECKED_IN'
                AND NEW.status IN ('CONSUMED', 'CANCELLED', 'EXPIRED', 'NO_SHOW'))
        ) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'RESERVATION_STATUS_TRANSITION';
        END IF;
    END IF;

    IF NEW.user_id <> OLD.user_id
       OR NEW.vehicle_id <> OLD.vehicle_id
       OR NEW.gun_id <> OLD.gun_id
       OR NEW.station_id <> OLD.station_id
       OR NEW.starts_at <> OLD.starts_at
       OR NEW.ends_at <> OLD.ends_at
       OR (
           NOT (NEW.rescheduled_from_id <=> OLD.rescheduled_from_id)
           AND NOT (
               OLD.rescheduled_from_id IS NULL
               AND OLD.status = 'BOOKED'
               AND NEW.rescheduled_from_id IS NOT NULL
           )
       ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'RESERVATION_IDENTITY_IMMUTABLE';
    END IF;
END$$

CREATE TRIGGER a_reservation_log_ai
AFTER INSERT ON charging_reservation
FOR EACH ROW
BEGIN
    INSERT INTO reservation_status_log (
        reservation_id, old_status, new_status, change_reason
    ) VALUES (
        NEW.reservation_id, NULL, NEW.status, @a_change_reason
    );
END$$

CREATE TRIGGER a_reservation_log_au
AFTER UPDATE ON charging_reservation
FOR EACH ROW
BEGIN
    IF NEW.status <> OLD.status THEN
        INSERT INTO reservation_status_log (
            reservation_id, old_status, new_status, change_reason
        ) VALUES (
            NEW.reservation_id, OLD.status, NEW.status, @a_change_reason
        );
    END IF;
END$$

-- ---------------------------------------------------------------------------
-- ⑥ 排队
-- ---------------------------------------------------------------------------

-- 排队状态机：
-- WAITING -> CALLED/CANCELLED/EXPIRED/NO_SHOW
-- CALLED -> CHECKED_IN/CANCELLED/EXPIRED/NO_SHOW
-- CHECKED_IN -> CONSUMED/CANCELLED/EXPIRED/NO_SHOW
CREATE TRIGGER a_queue_status_bu
BEFORE UPDATE ON queue_record
FOR EACH ROW
BEGIN
    IF NEW.status <> OLD.status THEN
        IF NOT (
            (OLD.status = 'WAITING'
                AND NEW.status IN ('CALLED', 'CANCELLED', 'EXPIRED', 'NO_SHOW'))
            OR
            (OLD.status = 'CALLED'
                AND NEW.status IN ('CHECKED_IN', 'CANCELLED', 'EXPIRED', 'NO_SHOW'))
            OR
            (OLD.status = 'CHECKED_IN'
                AND NEW.status IN ('CONSUMED', 'CANCELLED', 'EXPIRED', 'NO_SHOW'))
        ) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'QUEUE_STATUS_TRANSITION';
        END IF;
    END IF;

    IF NEW.station_id <> OLD.station_id
       OR NEW.user_id <> OLD.user_id
       OR NEW.vehicle_id <> OLD.vehicle_id
       OR NEW.gun_id <> OLD.gun_id
       OR NEW.ticket_no <> OLD.ticket_no
       OR NEW.joined_at <> OLD.joined_at
       OR NEW.priority_class <> OLD.priority_class
       OR NEW.priority_score <> OLD.priority_score THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'QUEUE_IDENTITY_IMMUTABLE';
    END IF;
END$$

CREATE TRIGGER a_queue_log_ai
AFTER INSERT ON queue_record
FOR EACH ROW
BEGIN
    INSERT INTO queue_status_log (
        queue_id, old_status, new_status, change_reason
    ) VALUES (
        NEW.queue_id, NULL, NEW.status, @a_change_reason
    );
END$$

CREATE TRIGGER a_queue_log_au
AFTER UPDATE ON queue_record
FOR EACH ROW
BEGIN
    IF NEW.status <> OLD.status THEN
        INSERT INTO queue_status_log (
            queue_id, old_status, new_status, change_reason
        ) VALUES (
            NEW.queue_id, OLD.status, NEW.status, @a_change_reason
        );
    END IF;
END$$

-- ---------------------------------------------------------------------------
-- ⑥ 到站核验与车位占用
-- ---------------------------------------------------------------------------

-- 核验写入前检查：
-- 1) 预约/排队资格二选一；
-- 2) 资格已由过程置为 CHECKED_IN，且用户、车辆、枪、场站完全一致；
-- 3) 车位必须是该枪绑定的车位；
-- 4) 车位和车辆当前没有未释放占用。
CREATE TRIGGER a_checkin_qualification_bi
BEFORE INSERT ON arrival_checkin
FOR EACH ROW
BEGIN
    DECLARE v_count INT DEFAULT 0;
    DECLARE v_user_id BIGINT UNSIGNED;
    DECLARE v_vehicle_id BIGINT UNSIGNED;
    DECLARE v_gun_id BIGINT UNSIGNED;
    DECLARE v_station_id BIGINT UNSIGNED;
    DECLARE v_status VARCHAR(20);
    DECLARE v_bound_space_id BIGINT UNSIGNED;

    IF (NEW.reservation_id IS NULL) = (NEW.queue_id IS NULL) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_ONE_QUALIFICATION_REQUIRED';
    END IF;

    IF NEW.reservation_id IS NOT NULL THEN
        SELECT COUNT(*)
          INTO v_count
          FROM charging_reservation
         WHERE reservation_id = NEW.reservation_id;

        IF v_count = 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'CHECKIN_RESERVATION_NOT_FOUND';
        END IF;

        SELECT user_id, vehicle_id, gun_id, station_id, status
          INTO v_user_id, v_vehicle_id, v_gun_id, v_station_id, v_status
          FROM charging_reservation
         WHERE reservation_id = NEW.reservation_id;

        IF v_status <> 'CHECKED_IN' THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'CHECKIN_RESERVATION_NOT_READY';
        END IF;

        IF v_user_id <> NEW.user_id
           OR v_vehicle_id <> NEW.vehicle_id
           OR v_gun_id <> NEW.gun_id
           OR v_station_id <> NEW.station_id THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'CHECKIN_RESERVATION_MISMATCH';
        END IF;
    ELSE
        SELECT COUNT(*)
          INTO v_count
          FROM queue_record
         WHERE queue_id = NEW.queue_id;

        IF v_count = 0 THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'CHECKIN_QUEUE_NOT_FOUND';
        END IF;

        SELECT user_id, vehicle_id, gun_id, station_id, status
          INTO v_user_id, v_vehicle_id, v_gun_id, v_station_id, v_status
          FROM queue_record
         WHERE queue_id = NEW.queue_id;

        IF v_status <> 'CHECKED_IN' THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'CHECKIN_QUEUE_NOT_READY';
        END IF;

        IF v_user_id <> NEW.user_id
           OR v_vehicle_id <> NEW.vehicle_id
           OR v_gun_id <> NEW.gun_id
           OR v_station_id <> NEW.station_id THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'CHECKIN_QUEUE_MISMATCH';
        END IF;
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM charging_gun
     WHERE gun_id = NEW.gun_id
       AND station_id = NEW.station_id;

    IF v_count = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_GUN_STATION_MISMATCH';
    END IF;

    SELECT parking_space_id
      INTO v_bound_space_id
      FROM charging_gun
     WHERE gun_id = NEW.gun_id
       AND station_id = NEW.station_id;

    IF v_bound_space_id IS NULL OR v_bound_space_id <> NEW.parking_space_id THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_SPACE_GUN_MISMATCH';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM parking_occupancy
     WHERE active_space_id = NEW.parking_space_id;

    IF v_count > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_SPACE_OCCUPIED';
    END IF;

    SELECT COUNT(*)
      INTO v_count
      FROM parking_occupancy
     WHERE active_vehicle_id = NEW.vehicle_id;

    IF v_count > 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'CHECKIN_VEHICLE_OCCUPIED';
    END IF;
END$$

-- 到站核验成功后自动生成车位占用，保证“核验即入位”。
CREATE TRIGGER a_checkin_occupancy_ai
AFTER INSERT ON arrival_checkin
FOR EACH ROW
BEGIN
    INSERT INTO parking_occupancy (
        checkin_id, parking_space_id, station_id, gun_id,
        user_id, vehicle_id, occupied_at
    ) VALUES (
        NEW.checkin_id, NEW.parking_space_id, NEW.station_id, NEW.gun_id,
        NEW.user_id, NEW.vehicle_id, NEW.checked_in_at
    );
END$$

-- ---------------------------------------------------------------------------
-- ⑧ 公告与通知
-- ---------------------------------------------------------------------------

-- 公告状态机：
-- DRAFT -> PUBLISHED
-- PUBLISHED -> WITHDRAWN/EXPIRED
-- 发布后场站、类型、关联停运计划、生效开始时间不可修改；正文可修改并留版本。
CREATE TRIGGER a_notice_transition_bu
BEFORE UPDATE ON station_notice
FOR EACH ROW
BEGIN
    IF NEW.status <> OLD.status THEN
        IF NOT (
            (OLD.status = 'DRAFT' AND NEW.status = 'PUBLISHED')
            OR
            (OLD.status = 'PUBLISHED' AND NEW.status IN ('WITHDRAWN', 'EXPIRED'))
        ) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'NOTICE_STATUS_TRANSITION';
        END IF;
    END IF;

    IF OLD.status <> 'DRAFT'
       AND (
           NEW.station_id <> OLD.station_id
           OR NEW.notice_type <> OLD.notice_type
           OR NOT (NEW.related_outage_plan_id <=> OLD.related_outage_plan_id)
           OR NEW.effective_from <> OLD.effective_from
       ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'NOTICE_IDENTITY_IMMUTABLE';
    END IF;

    IF OLD.published_at IS NOT NULL
       AND NOT (NEW.published_at <=> OLD.published_at) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'NOTICE_PUBLISHED_AT_IMMUTABLE';
    END IF;

    IF OLD.withdrawn_at IS NOT NULL
       AND NOT (NEW.withdrawn_at <=> OLD.withdrawn_at) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'NOTICE_WITHDRAWN_AT_IMMUTABLE';
    END IF;
END$$

-- 新建公告自动留下第 1 版快照。
CREATE TRIGGER a_notice_revision_ai
AFTER INSERT ON station_notice
FOR EACH ROW
BEGIN
    INSERT INTO notice_revision (
        notice_id, revision_no, action, title, content, changed_by
    ) VALUES (
        NEW.notice_id, 1, 'CREATE', NEW.title, NEW.content, NEW.created_by
    );
END$$

-- 正文修改、发布、撤回、过期时追加版本快照。
CREATE TRIGGER a_notice_revision_au
AFTER UPDATE ON station_notice
FOR EACH ROW
BEGIN
    DECLARE v_action VARCHAR(20) DEFAULT NULL;
    DECLARE v_next_no INT DEFAULT 0;

    IF NEW.status <> OLD.status THEN
        SET v_action = CASE NEW.status
            WHEN 'PUBLISHED' THEN 'PUBLISH'
            WHEN 'WITHDRAWN' THEN 'WITHDRAW'
            WHEN 'EXPIRED' THEN 'EXPIRE'
            ELSE 'UPDATE'
        END;
    ELSEIF NOT (NEW.title <=> OLD.title)
        OR NOT (NEW.content <=> OLD.content) THEN
        SET v_action = 'UPDATE';
    END IF;

    IF v_action IS NOT NULL THEN
        SELECT COALESCE(MAX(revision_no), 0) + 1
          INTO v_next_no
          FROM notice_revision
         WHERE notice_id = NEW.notice_id;

        INSERT INTO notice_revision (
            notice_id, revision_no, action, title, content, changed_by
        ) VALUES (
            NEW.notice_id, v_next_no, v_action,
            NEW.title, NEW.content, NEW.updated_by
        );
    END IF;
END$$

-- 通知状态机：
-- PENDING -> SENT/FAILED
-- FAILED -> PENDING/SENT（重试）
-- SENT -> READ
CREATE TRIGGER a_notification_status_bu
BEFORE UPDATE ON notification_record
FOR EACH ROW
BEGIN
    IF NEW.recipient_id <> OLD.recipient_id
       OR NEW.channel <> OLD.channel THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'NOTIFICATION_IDENTITY_IMMUTABLE';
    END IF;

    IF NEW.status <> OLD.status THEN
        IF NOT (
            (OLD.status = 'PENDING' AND NEW.status IN ('SENT', 'FAILED'))
            OR
            (OLD.status = 'FAILED' AND NEW.status IN ('PENDING', 'SENT'))
            OR
            (OLD.status = 'SENT' AND NEW.status = 'READ')
        ) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'NOTIFICATION_STATUS_TRANSITION';
        END IF;
    END IF;
END$$

DELIMITER ;
