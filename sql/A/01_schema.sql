-- A ⑥ 预约、排队与到站管理 / ⑧ 场站服务公告与通知：正式表结构
-- 目标环境：MySQL 8.0.46 / InnoDB / utf8mb4_0900_ai_ci
-- 前置条件（按组内建表顺序）：
--   1) D 核心表：user、vehicle
--   2) B 结构表：station、charging_pile、charging_gun、parking_space、
--      equipment_outage_plan、charging_order
--   3) D 跨模块表（如 coupon 等，可选，不影响 A 的 FK）
-- 本脚本只创建 A 模块的表，不包含 DROP/TRUNCATE/DELETE。
-- 首次执行成功后不要重复 SOURCE；重复 CREATE TABLE 会报 already exists。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

-- ---------------------------------------------------------------------------
-- ⑥ 预约、排队与到站管理
-- ---------------------------------------------------------------------------

-- ⑥-1 预约主表
-- 同一把枪的有效预约时段（BOOKED/CHECKED_IN）不能重叠：
--   写入入口为 sp_create_reservation（锁枪行 + 区间检查），
--   触发器 a_reservation_overlap_bi/bu 作为直接 SQL 写入的兜底。
CREATE TABLE charging_reservation (
    reservation_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '预约编号',
    user_id BIGINT UNSIGNED NOT NULL COMMENT '预约用户编号',
    vehicle_id BIGINT UNSIGNED NOT NULL COMMENT '预约车辆编号',
    gun_id BIGINT UNSIGNED NOT NULL COMMENT '预约充电枪编号',
    station_id BIGINT UNSIGNED NOT NULL COMMENT '所属场站，用于复合外键保证枪与站一致',
    starts_at DATETIME NOT NULL COMMENT '预约时段开始，左闭',
    ends_at DATETIME NOT NULL COMMENT '预约时段结束，右开',
    late_grace_minutes SMALLINT UNSIGNED NOT NULL DEFAULT 15 COMMENT '迟到保留分钟数快照',
    status ENUM('BOOKED', 'CHECKED_IN', 'CONSUMED', 'CANCELLED', 'EXPIRED', 'NO_SHOW')
        NOT NULL DEFAULT 'BOOKED' COMMENT '预约状态',
    source ENUM('APP', 'WEB', 'WECHAT', 'MINI_PROGRAM', 'STAFF')
        NOT NULL DEFAULT 'APP' COMMENT '预约来源',
    rescheduled_from_id BIGINT UNSIGNED NULL COMMENT '改约前预约编号，用于追踪改约链',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
    cancelled_at DATETIME NULL COMMENT '取消时间',
    cancel_reason VARCHAR(255) NULL COMMENT '取消原因',
    consumed_at DATETIME NULL COMMENT '资格被订单消费的时间',
    consumed_order_id BIGINT UNSIGNED NULL COMMENT '消费资格后生成的充电订单编号',
    PRIMARY KEY (reservation_id),
    UNIQUE KEY uk_reservation_consumed_order (consumed_order_id),
    UNIQUE KEY uk_reservation_reschedule_source (rescheduled_from_id),
    KEY ix_reservation_gun_status_time (gun_id, status, starts_at, ends_at),
    KEY ix_reservation_station_time (station_id, starts_at),
    KEY ix_reservation_user_time (user_id, starts_at),
    KEY ix_reservation_vehicle_time (vehicle_id, starts_at),
    CONSTRAINT fk_reservation_user
        FOREIGN KEY (user_id) REFERENCES `user` (user_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_reservation_vehicle
        FOREIGN KEY (vehicle_id) REFERENCES vehicle (vehicle_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_reservation_gun_station
        FOREIGN KEY (gun_id, station_id)
        REFERENCES charging_gun (gun_id, station_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_reservation_station
        FOREIGN KEY (station_id) REFERENCES station (station_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_reservation_rescheduled_from
        FOREIGN KEY (rescheduled_from_id) REFERENCES charging_reservation (reservation_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_reservation_consumed_order
        FOREIGN KEY (consumed_order_id) REFERENCES charging_order (order_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT ck_reservation_time
        CHECK (starts_at < ends_at
           AND TIMESTAMPDIFF(MINUTE, starts_at, ends_at) BETWEEN 5 AND 1440),
    CONSTRAINT ck_reservation_grace
        CHECK (late_grace_minutes BETWEEN 1 AND 120),
    CONSTRAINT ck_reservation_cancelled
        CHECK (status <> 'CANCELLED'
            OR (cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL)),
    CONSTRAINT ck_reservation_not_cancelled
        CHECK (status = 'CANCELLED'
            OR (cancelled_at IS NULL AND cancel_reason IS NULL)),
    CONSTRAINT ck_reservation_consumed
        CHECK (status <> 'CONSUMED'
            OR (consumed_at IS NOT NULL AND consumed_order_id IS NOT NULL)),
    CONSTRAINT ck_reservation_not_consumed
        CHECK (status = 'CONSUMED'
            OR (consumed_at IS NULL AND consumed_order_id IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='充电预约。同一枪有效预约区间不重叠，资格只能被消费一次';

-- ⑥-2 预约状态历史
CREATE TABLE reservation_status_log (
    log_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '日志编号',
    reservation_id BIGINT UNSIGNED NOT NULL COMMENT '预约编号',
    old_status ENUM('BOOKED', 'CHECKED_IN', 'CONSUMED', 'CANCELLED', 'EXPIRED', 'NO_SHOW')
        NULL COMMENT '变更前状态，新建时为空',
    new_status ENUM('BOOKED', 'CHECKED_IN', 'CONSUMED', 'CANCELLED', 'EXPIRED', 'NO_SHOW')
        NOT NULL COMMENT '变更后状态',
    changed_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) COMMENT '状态变更时间',
    change_reason VARCHAR(255) NULL COMMENT '业务变更原因',
    PRIMARY KEY (log_id),
    KEY ix_reservation_log_reservation_time (reservation_id, changed_at),
    CONSTRAINT fk_reservation_log_reservation
        FOREIGN KEY (reservation_id) REFERENCES charging_reservation (reservation_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='预约状态变化历史，由触发器自动写入';

-- ⑥-3 现场排队记录
-- active_user_id 为生成列：WAITING/CALLED/CHECKED_IN 时等于 user_id，否则为 NULL。
-- 唯一约束保证一个用户同一时刻最多只有一条有效排队资格。
CREATE TABLE queue_record (
    queue_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '排队编号',
    station_id BIGINT UNSIGNED NOT NULL COMMENT '场站编号',
    user_id BIGINT UNSIGNED NOT NULL COMMENT '排队用户编号',
    vehicle_id BIGINT UNSIGNED NOT NULL COMMENT '排队车辆编号',
    gun_id BIGINT UNSIGNED NOT NULL COMMENT '排队目标充电枪编号',
    ticket_no INT UNSIGNED NOT NULL COMMENT '当日场站排队号',
    queue_date DATE GENERATED ALWAYS AS (DATE(joined_at)) STORED COMMENT '排队日期，由入队时间生成',
    priority_class ENUM('WALK_IN', 'RESERVATION_LATE')
        NOT NULL DEFAULT 'WALK_IN' COMMENT '排队优先级类别',
    priority_score SMALLINT NOT NULL DEFAULT 0 COMMENT '优先级分值，越大越优先',
    status ENUM('WAITING', 'CALLED', 'CHECKED_IN', 'CONSUMED', 'CANCELLED', 'EXPIRED', 'NO_SHOW')
        NOT NULL DEFAULT 'WAITING' COMMENT '排队状态',
    joined_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '入队时间',
    called_at DATETIME NULL COMMENT '叫号时间',
    call_expires_at DATETIME NULL COMMENT '叫号保留截止时间',
    hold_minutes SMALLINT UNSIGNED NOT NULL DEFAULT 10 COMMENT '叫号保留分钟数快照',
    consumed_at DATETIME NULL COMMENT '资格被订单消费的时间',
    consumed_order_id BIGINT UNSIGNED NULL COMMENT '消费资格后生成的充电订单编号',
    cancelled_at DATETIME NULL COMMENT '取消时间',
    cancel_reason VARCHAR(255) NULL COMMENT '取消原因',
    active_user_id BIGINT UNSIGNED
        GENERATED ALWAYS AS (
            IF(status IN ('WAITING', 'CALLED', 'CHECKED_IN'), user_id, NULL)
        ) STORED COMMENT '有效排队用户，用于唯一约束',
    PRIMARY KEY (queue_id),
    UNIQUE KEY uk_queue_station_date_ticket (station_id, queue_date, ticket_no),
    UNIQUE KEY uk_queue_consumed_order (consumed_order_id),
    UNIQUE KEY uk_queue_active_user (active_user_id),
    KEY ix_queue_station_status_priority (station_id, status, priority_score, joined_at),
    KEY ix_queue_gun_status (gun_id, status, joined_at),
    KEY ix_queue_user_time (user_id, joined_at),
    CONSTRAINT fk_queue_station
        FOREIGN KEY (station_id) REFERENCES station (station_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_queue_user
        FOREIGN KEY (user_id) REFERENCES `user` (user_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_queue_vehicle
        FOREIGN KEY (vehicle_id) REFERENCES vehicle (vehicle_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_queue_gun_station
        FOREIGN KEY (gun_id, station_id)
        REFERENCES charging_gun (gun_id, station_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_queue_consumed_order
        FOREIGN KEY (consumed_order_id) REFERENCES charging_order (order_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT ck_queue_ticket CHECK (ticket_no > 0),
    CONSTRAINT ck_queue_hold CHECK (hold_minutes BETWEEN 1 AND 60),
    CONSTRAINT ck_queue_priority CHECK (priority_score BETWEEN 0 AND 100),
    CONSTRAINT ck_queue_waiting_not_called
        CHECK (status <> 'WAITING' OR called_at IS NULL),
    CONSTRAINT ck_queue_called_time
        CHECK (status NOT IN ('CALLED', 'CHECKED_IN', 'CONSUMED')
            OR (called_at IS NOT NULL AND call_expires_at IS NOT NULL)),
    CONSTRAINT ck_queue_call_pair
        CHECK ((called_at IS NULL) = (call_expires_at IS NULL)),
    CONSTRAINT ck_queue_call_order
        CHECK (call_expires_at IS NULL OR call_expires_at > called_at),
    CONSTRAINT ck_queue_cancelled
        CHECK (status <> 'CANCELLED'
            OR (cancelled_at IS NOT NULL AND cancel_reason IS NOT NULL)),
    CONSTRAINT ck_queue_not_cancelled
        CHECK (status = 'CANCELLED'
            OR (cancelled_at IS NULL AND cancel_reason IS NULL)),
    CONSTRAINT ck_queue_consumed
        CHECK (status <> 'CONSUMED'
            OR (consumed_at IS NOT NULL AND consumed_order_id IS NOT NULL)),
    CONSTRAINT ck_queue_not_consumed
        CHECK (status = 'CONSUMED'
            OR (consumed_at IS NULL AND consumed_order_id IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='现场排队与叫号。当日场站排队号唯一，一个用户最多一条有效排队';

-- ⑥-4 排队状态历史
CREATE TABLE queue_status_log (
    log_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '日志编号',
    queue_id BIGINT UNSIGNED NOT NULL COMMENT '排队编号',
    old_status ENUM('WAITING', 'CALLED', 'CHECKED_IN', 'CONSUMED', 'CANCELLED', 'EXPIRED', 'NO_SHOW')
        NULL COMMENT '变更前状态，新建时为空',
    new_status ENUM('WAITING', 'CALLED', 'CHECKED_IN', 'CONSUMED', 'CANCELLED', 'EXPIRED', 'NO_SHOW')
        NOT NULL COMMENT '变更后状态',
    changed_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) COMMENT '状态变更时间',
    change_reason VARCHAR(255) NULL COMMENT '业务变更原因',
    PRIMARY KEY (log_id),
    KEY ix_queue_log_queue_time (queue_id, changed_at),
    CONSTRAINT fk_queue_log_queue
        FOREIGN KEY (queue_id) REFERENCES queue_record (queue_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='排队状态变化历史，由触发器自动写入';

-- ⑥-5 到站核验
-- 一条到站核验必须且只能来自一条预约或一条排队资格；
-- 到站后由触发器自动生成一条 parking_occupancy，保证“核验即入位”。
CREATE TABLE arrival_checkin (
    checkin_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '到站核验编号',
    reservation_id BIGINT UNSIGNED NULL COMMENT '来源预约编号',
    queue_id BIGINT UNSIGNED NULL COMMENT '来源排队编号',
    user_id BIGINT UNSIGNED NOT NULL COMMENT '实际到站用户编号',
    vehicle_id BIGINT UNSIGNED NOT NULL COMMENT '实际到站车辆编号',
    station_id BIGINT UNSIGNED NOT NULL COMMENT '场站编号',
    gun_id BIGINT UNSIGNED NOT NULL COMMENT '到站使用的充电枪编号',
    parking_space_id BIGINT UNSIGNED NOT NULL COMMENT '实际分配车位编号',
    checked_in_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '核验时间',
    checkin_method ENUM('QR_CODE', 'STAFF', 'AUTO')
        NOT NULL DEFAULT 'QR_CODE' COMMENT '核验方式',
    plate_verified TINYINT(1) NOT NULL DEFAULT 1 COMMENT '车牌是否核验通过：1是0否',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '记录创建时间',
    PRIMARY KEY (checkin_id),
    UNIQUE KEY uk_checkin_reservation (reservation_id),
    UNIQUE KEY uk_checkin_queue (queue_id),
    KEY ix_checkin_station_time (station_id, checked_in_at),
    KEY ix_checkin_user_time (user_id, checked_in_at),
    KEY ix_checkin_gun_time (gun_id, checked_in_at),
    CONSTRAINT fk_checkin_reservation
        FOREIGN KEY (reservation_id) REFERENCES charging_reservation (reservation_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_checkin_queue
        FOREIGN KEY (queue_id) REFERENCES queue_record (queue_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_checkin_user
        FOREIGN KEY (user_id) REFERENCES `user` (user_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_checkin_vehicle
        FOREIGN KEY (vehicle_id) REFERENCES vehicle (vehicle_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_checkin_station
        FOREIGN KEY (station_id) REFERENCES station (station_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_checkin_gun_station
        FOREIGN KEY (gun_id, station_id)
        REFERENCES charging_gun (gun_id, station_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_checkin_space_station
        FOREIGN KEY (parking_space_id, station_id)
        REFERENCES parking_space (parking_space_id, station_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT ck_checkin_one_qualification
        CHECK ((reservation_id IS NULL) <> (queue_id IS NULL)),
    CONSTRAINT ck_checkin_plate CHECK (plate_verified IN (0, 1))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='到站核验。预约/排队资格二选一，核验成功后自动生成车位占用';

-- ⑥-6 车位占用
-- 释放只发生在“车辆实际驶离”或人工处理；充电结束不等于车位释放。
-- active_space_id / active_vehicle_id 唯一约束保证同一车位、同一车辆
-- 同一时刻最多一条未释放占用。
CREATE TABLE parking_occupancy (
    occupancy_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '占用编号',
    checkin_id BIGINT UNSIGNED NOT NULL COMMENT '到站核验编号',
    parking_space_id BIGINT UNSIGNED NOT NULL COMMENT '车位编号',
    station_id BIGINT UNSIGNED NOT NULL COMMENT '场站编号',
    gun_id BIGINT UNSIGNED NOT NULL COMMENT '充电枪编号',
    user_id BIGINT UNSIGNED NOT NULL COMMENT '占用用户编号',
    vehicle_id BIGINT UNSIGNED NOT NULL COMMENT '占用车辆编号',
    occupied_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '入位时间',
    released_at DATETIME NULL COMMENT '驶离/释放时间',
    release_reason ENUM('VEHICLE_LEFT', 'STAFF', 'CHECKIN_CANCELLED', 'OTHER')
        NULL COMMENT '释放原因',
    active_space_id BIGINT UNSIGNED
        GENERATED ALWAYS AS (IF(released_at IS NULL, parking_space_id, NULL)) STORED
        COMMENT '未释放车位，用于唯一约束',
    active_vehicle_id BIGINT UNSIGNED
        GENERATED ALWAYS AS (IF(released_at IS NULL, vehicle_id, NULL)) STORED
        COMMENT '未释放车辆，用于唯一约束',
    PRIMARY KEY (occupancy_id),
    UNIQUE KEY uk_occupancy_checkin (checkin_id),
    UNIQUE KEY uk_occupancy_active_space (active_space_id),
    UNIQUE KEY uk_occupancy_active_vehicle (active_vehicle_id),
    KEY ix_occupancy_station_time (station_id, occupied_at),
    KEY ix_occupancy_gun_time (gun_id, occupied_at),
    KEY ix_occupancy_user_time (user_id, occupied_at),
    CONSTRAINT fk_occupancy_checkin
        FOREIGN KEY (checkin_id) REFERENCES arrival_checkin (checkin_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_occupancy_space_station
        FOREIGN KEY (parking_space_id, station_id)
        REFERENCES parking_space (parking_space_id, station_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_occupancy_gun_station
        FOREIGN KEY (gun_id, station_id)
        REFERENCES charging_gun (gun_id, station_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_occupancy_user
        FOREIGN KEY (user_id) REFERENCES `user` (user_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_occupancy_vehicle
        FOREIGN KEY (vehicle_id) REFERENCES vehicle (vehicle_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT ck_occupancy_release_time
        CHECK (released_at IS NULL OR released_at >= occupied_at),
    CONSTRAINT ck_occupancy_release_pair
        CHECK ((released_at IS NULL) = (release_reason IS NULL))
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='车位实际占用与释放。充电结束但车辆未驶离时保持占用';

-- ---------------------------------------------------------------------------
-- ⑧ 场站服务公告与通知
-- ---------------------------------------------------------------------------

-- ⑧-1 公告主表
-- PUBLIC：所有车主可见的公开公告；OUTAGE_TARGETED：针对停运计划影响用户的定向通知。
CREATE TABLE station_notice (
    notice_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '公告编号',
    station_id BIGINT UNSIGNED NOT NULL COMMENT '场站编号',
    notice_type ENUM('PUBLIC', 'OUTAGE_TARGETED')
        NOT NULL DEFAULT 'PUBLIC' COMMENT '公告类型',
    severity ENUM('INFO', 'WARNING', 'EMERGENCY')
        NOT NULL DEFAULT 'INFO' COMMENT '公告级别',
    title VARCHAR(200) NOT NULL COMMENT '公告标题',
    content TEXT NOT NULL COMMENT '公告正文',
    status ENUM('DRAFT', 'PUBLISHED', 'WITHDRAWN', 'EXPIRED')
        NOT NULL DEFAULT 'DRAFT' COMMENT '公告状态',
    effective_from DATETIME NOT NULL COMMENT '生效时间，左闭',
    effective_to DATETIME NULL COMMENT '失效时间，右开，NULL表示长期有效',
    published_at DATETIME NULL COMMENT '发布时间',
    withdrawn_at DATETIME NULL COMMENT '撤回时间',
    withdraw_reason VARCHAR(255) NULL COMMENT '撤回原因',
    created_by VARCHAR(64) NOT NULL COMMENT '创建人标识',
    updated_by VARCHAR(64) NOT NULL DEFAULT 'SYSTEM' COMMENT '最后修改人标识',
    related_outage_plan_id BIGINT UNSIGNED NULL COMMENT '关联的共享停运计划编号',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
    PRIMARY KEY (notice_id),
    KEY ix_notice_station_status_effective
        (station_id, status, effective_from, effective_to),
    KEY ix_notice_outage_plan (related_outage_plan_id),
    KEY ix_notice_type_status (notice_type, status),
    CONSTRAINT fk_notice_station
        FOREIGN KEY (station_id) REFERENCES station (station_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_notice_outage_plan
        FOREIGN KEY (related_outage_plan_id)
        REFERENCES equipment_outage_plan (outage_plan_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT ck_notice_effective
        CHECK (effective_to IS NULL OR effective_to > effective_from),
    CONSTRAINT ck_notice_draft_published
        CHECK (status <> 'DRAFT' OR published_at IS NULL),
    CONSTRAINT ck_notice_published_time
        CHECK (status = 'DRAFT' OR published_at IS NOT NULL),
    CONSTRAINT ck_notice_withdrawn
        CHECK (status <> 'WITHDRAWN'
            OR (withdrawn_at IS NOT NULL AND withdraw_reason IS NOT NULL)),
    CONSTRAINT ck_notice_not_withdrawn
        CHECK (status = 'WITHDRAWN'
            OR (withdrawn_at IS NULL AND withdraw_reason IS NULL)),
    CONSTRAINT ck_notice_target_plan
        CHECK (notice_type <> 'OUTAGE_TARGETED' OR related_outage_plan_id IS NOT NULL),
    CONSTRAINT ck_notice_public_plan
        CHECK (notice_type = 'OUTAGE_TARGETED' OR related_outage_plan_id IS NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='场站服务公告。公开公告与停运定向通知共用主表';

-- ⑧-2 公告修改历史
-- 每次新建、正文修改、发布、撤回、过期都由触发器追加一条快照。
CREATE TABLE notice_revision (
    revision_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '版本编号',
    notice_id BIGINT UNSIGNED NOT NULL COMMENT '公告编号',
    revision_no INT UNSIGNED NOT NULL COMMENT '公告内版本序号，从1开始',
    action ENUM('CREATE', 'UPDATE', 'PUBLISH', 'WITHDRAW', 'EXPIRE')
        NOT NULL COMMENT '本次操作类型',
    title VARCHAR(200) NOT NULL COMMENT '操作后的标题快照',
    content TEXT NOT NULL COMMENT '操作后的正文快照',
    changed_at DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6) COMMENT '操作时间',
    changed_by VARCHAR(64) NOT NULL COMMENT '操作人标识',
    PRIMARY KEY (revision_id),
    UNIQUE KEY uk_notice_revision_no (notice_id, revision_no),
    CONSTRAINT fk_notice_revision_notice
        FOREIGN KEY (notice_id) REFERENCES station_notice (notice_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='公告版本快照，保留发布、修改和撤回痕迹';

-- ⑧-3 公告接收对象
-- 定向公告发布时按受影响的预约/排队资格生成接收人快照；
-- 公开公告不强制生成接收人记录。同一公告同一用户只保留一条。
CREATE TABLE notice_recipient (
    recipient_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '接收对象编号',
    notice_id BIGINT UNSIGNED NOT NULL COMMENT '公告编号',
    user_id BIGINT UNSIGNED NOT NULL COMMENT '接收用户编号',
    vehicle_id BIGINT UNSIGNED NULL COMMENT '关联车辆编号',
    reservation_id BIGINT UNSIGNED NULL COMMENT '受影响预约编号',
    queue_id BIGINT UNSIGNED NULL COMMENT '受影响排队编号',
    recipient_reason ENUM('AFFECTED_RESERVATION', 'AFFECTED_QUEUE', 'MANUAL')
        NOT NULL COMMENT '接收原因',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '生成时间',
    PRIMARY KEY (recipient_id),
    UNIQUE KEY uk_notice_recipient_user (notice_id, user_id),
    KEY ix_notice_recipient_notice (notice_id),
    KEY ix_notice_recipient_user (user_id),
    KEY ix_notice_recipient_reservation (reservation_id),
    KEY ix_notice_recipient_queue (queue_id),
    CONSTRAINT fk_notice_recipient_notice
        FOREIGN KEY (notice_id) REFERENCES station_notice (notice_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_notice_recipient_user
        FOREIGN KEY (user_id) REFERENCES `user` (user_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_notice_recipient_vehicle
        FOREIGN KEY (vehicle_id) REFERENCES vehicle (vehicle_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_notice_recipient_reservation
        FOREIGN KEY (reservation_id) REFERENCES charging_reservation (reservation_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT fk_notice_recipient_queue
        FOREIGN KEY (queue_id) REFERENCES queue_record (queue_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT ck_notice_recipient_reservation
        CHECK (recipient_reason <> 'AFFECTED_RESERVATION' OR reservation_id IS NOT NULL),
    CONSTRAINT ck_notice_recipient_not_reservation
        CHECK (recipient_reason = 'AFFECTED_RESERVATION' OR reservation_id IS NULL),
    CONSTRAINT ck_notice_recipient_queue
        CHECK (recipient_reason <> 'AFFECTED_QUEUE' OR queue_id IS NOT NULL),
    CONSTRAINT ck_notice_recipient_not_queue
        CHECK (recipient_reason = 'AFFECTED_QUEUE' OR queue_id IS NULL),
    CONSTRAINT ck_notice_recipient_vehicle
        CHECK (recipient_reason = 'MANUAL' OR vehicle_id IS NOT NULL)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='公告接收对象快照，定向通知与预约/排队资格关联';

-- ⑧-4 通知发送记录
-- 一个接收对象在一个渠道上只有一条记录，失败重试通过 retry_count 累加。
-- 不重复保存 notice_id/user_id：它们由 notice_recipient 决定，避免传递依赖。
CREATE TABLE notification_record (
    notification_id BIGINT UNSIGNED NOT NULL AUTO_INCREMENT COMMENT '通知编号',
    recipient_id BIGINT UNSIGNED NOT NULL COMMENT '接收对象编号',
    channel ENUM('IN_APP', 'SMS', 'PUSH', 'WECHAT', 'EMAIL')
        NOT NULL DEFAULT 'IN_APP' COMMENT '通知渠道',
    status ENUM('PENDING', 'SENT', 'FAILED', 'READ')
        NOT NULL DEFAULT 'PENDING' COMMENT '发送状态',
    sent_at DATETIME NULL COMMENT '发送成功时间',
    read_at DATETIME NULL COMMENT '用户阅读时间',
    failure_reason VARCHAR(255) NULL COMMENT '失败原因，仅 FAILED 时存在',
    retry_count TINYINT UNSIGNED NOT NULL DEFAULT 0 COMMENT '已重试次数',
    provider_message_id VARCHAR(64) NULL COMMENT '渠道侧消息编号',
    created_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP COMMENT '创建时间',
    updated_at DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
        ON UPDATE CURRENT_TIMESTAMP COMMENT '更新时间',
    PRIMARY KEY (notification_id),
    UNIQUE KEY uk_notification_recipient_channel (recipient_id, channel),
    KEY ix_notification_status_created (status, created_at),
    CONSTRAINT fk_notification_recipient
        FOREIGN KEY (recipient_id) REFERENCES notice_recipient (recipient_id)
        ON DELETE RESTRICT ON UPDATE RESTRICT,
    CONSTRAINT ck_notification_sent_pair
        CHECK ((status IN ('PENDING', 'FAILED')) = (sent_at IS NULL)),
    CONSTRAINT ck_notification_read_time
        CHECK (status <> 'READ' OR read_at IS NOT NULL),
    CONSTRAINT ck_notification_not_read
        CHECK (status = 'READ' OR read_at IS NULL),
    CONSTRAINT ck_notification_read_after_sent
        CHECK (read_at IS NULL OR sent_at IS NOT NULL),
    CONSTRAINT ck_notification_failed
        CHECK (status <> 'FAILED' OR failure_reason IS NOT NULL),
    CONSTRAINT ck_notification_not_failed
        CHECK (status = 'FAILED' OR failure_reason IS NULL),
    CONSTRAINT ck_notification_retry CHECK (retry_count <= 10)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_0900_ai_ci
  COMMENT='公告通知发送记录，按接收对象与渠道唯一';
