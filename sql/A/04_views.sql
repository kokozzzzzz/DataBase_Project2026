-- A ⑥⑧ 业务视图
-- 目标环境：MySQL 8.0.46。
-- 全部使用 SQL SECURITY INVOKER，视图不暴露手机号/车牌密文等敏感字段。
-- 可重复执行：CREATE OR REPLACE VIEW。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

-- ---------------------------------------------------------------------------
-- ⑥-视图 V01：充电枪预约看板
-- 面向场站运营：当前仍有效的预约、对应车辆、车位和迟到截止时间。
-- ---------------------------------------------------------------------------
CREATE OR REPLACE SQL SECURITY INVOKER
VIEW v_a_reservation_board AS
SELECT
    r.reservation_id,
    r.station_id,
    s.name AS station_name,
    r.gun_id,
    g.gun_no,
    g.gun_type,
    g.parking_space_id,
    ps.code AS space_code,
    r.user_id,
    u.real_name AS user_name,
    r.vehicle_id,
    v.model AS vehicle_model,
    r.starts_at,
    r.ends_at,
    r.late_grace_minutes,
    r.ends_at + INTERVAL r.late_grace_minutes MINUTE AS latest_checkin_at,
    r.status,
    r.source,
    r.created_at
FROM charging_reservation AS r
JOIN station AS s
    ON s.station_id = r.station_id
JOIN charging_gun AS g
    ON g.gun_id = r.gun_id
   AND g.station_id = r.station_id
JOIN parking_space AS ps
    ON ps.parking_space_id = g.parking_space_id
   AND ps.station_id = r.station_id
JOIN `user` AS u
    ON u.user_id = r.user_id
JOIN vehicle AS v
    ON v.vehicle_id = r.vehicle_id
WHERE r.status IN ('BOOKED', 'CHECKED_IN');

-- ---------------------------------------------------------------------------
-- ⑥-视图 V02：现场排队与叫号看板
-- 展示有效排队、优先级、已等待分钟数和叫号截止时间。
-- ---------------------------------------------------------------------------
CREATE OR REPLACE SQL SECURITY INVOKER
VIEW v_a_queue_board AS
SELECT
    q.queue_id,
    q.station_id,
    s.name AS station_name,
    q.gun_id,
    g.gun_no,
    q.ticket_no,
    q.queue_date,
    q.priority_class,
    q.priority_score,
    q.status,
    q.user_id,
    u.real_name AS user_name,
    q.vehicle_id,
    v.model AS vehicle_model,
    q.joined_at,
    q.called_at,
    q.call_expires_at,
    TIMESTAMPDIFF(MINUTE, q.joined_at, CURRENT_TIMESTAMP) AS waited_minutes,
    CASE
        WHEN q.status = 'CALLED'
         AND q.call_expires_at IS NOT NULL
         AND q.call_expires_at <= CURRENT_TIMESTAMP THEN 'CALL_EXPIRED'
        WHEN q.status = 'CALLED' THEN 'CALLING'
        WHEN q.status = 'CHECKED_IN' THEN 'ARRIVED'
        ELSE 'WAITING'
    END AS queue_state
FROM queue_record AS q
JOIN station AS s
    ON s.station_id = q.station_id
JOIN charging_gun AS g
    ON g.gun_id = q.gun_id
   AND g.station_id = q.station_id
JOIN `user` AS u
    ON u.user_id = q.user_id
JOIN vehicle AS v
    ON v.vehicle_id = q.vehicle_id
WHERE q.status IN ('WAITING', 'CALLED', 'CHECKED_IN');

-- ---------------------------------------------------------------------------
-- ⑥-视图 V03：车位实时占用
-- 重点区分“充电中”“充电已结束但车辆未驶离”“已到站未开单”。
-- ---------------------------------------------------------------------------
CREATE OR REPLACE SQL SECURITY INVOKER
VIEW v_a_parking_occupancy_live AS
SELECT
    po.occupancy_id,
    po.station_id,
    s.name AS station_name,
    po.parking_space_id,
    ps.code AS space_code,
    po.gun_id,
    g.gun_no,
    po.user_id,
    u.real_name AS user_name,
    po.vehicle_id,
    v.model AS vehicle_model,
    ac.reservation_id,
    ac.queue_id,
    po.occupied_at,
    TIMESTAMPDIFF(MINUTE, po.occupied_at, CURRENT_TIMESTAMP) AS occupied_minutes,
    o.order_id AS latest_order_id,
    o.state AS latest_order_state,
    o.starts_at AS charging_started_at,
    o.ends_at AS charging_ended_at,
    CASE
        WHEN o.order_id IS NULL THEN 'ARRIVED_NOT_CHARGING'
        WHEN o.state = 'ACTIVE' THEN 'CHARGING'
        WHEN o.state = 'BILLED' THEN 'CHARGING_ENDED_VEHICLE_PRESENT'
        ELSE 'REVIEW'
    END AS occupancy_state
FROM parking_occupancy AS po
JOIN parking_space AS ps
    ON ps.parking_space_id = po.parking_space_id
   AND ps.station_id = po.station_id
JOIN charging_gun AS g
    ON g.gun_id = po.gun_id
   AND g.station_id = po.station_id
JOIN station AS s
    ON s.station_id = po.station_id
JOIN `user` AS u
    ON u.user_id = po.user_id
JOIN vehicle AS v
    ON v.vehicle_id = po.vehicle_id
JOIN arrival_checkin AS ac
    ON ac.checkin_id = po.checkin_id
LEFT JOIN charging_order AS o
    ON o.order_id = (
        SELECT o2.order_id
          FROM charging_order AS o2
         WHERE o2.gun_id = po.gun_id
           AND o2.user_id = po.user_id
           AND o2.vehicle_id = po.vehicle_id
           AND o2.starts_at >= po.occupied_at
         ORDER BY o2.starts_at DESC, o2.order_id DESC
         LIMIT 1
    )
WHERE po.released_at IS NULL;

-- ---------------------------------------------------------------------------
-- ⑥-视图 V04：预约履约日统计
-- 面向运营复盘：预约总量、到站、消费、取消、过期和履约率。
-- ---------------------------------------------------------------------------
CREATE OR REPLACE SQL SECURITY INVOKER
VIEW v_a_reservation_fulfillment AS
SELECT
    r.station_id,
    s.name AS station_name,
    DATE(r.starts_at) AS reservation_date,
    COUNT(*) AS total_reservations,
    SUM(r.status = 'BOOKED') AS booked_count,
    SUM(r.status = 'CHECKED_IN') AS checked_in_count,
    SUM(r.status = 'CONSUMED') AS consumed_count,
    SUM(r.status = 'CANCELLED') AS cancelled_count,
    SUM(r.status = 'EXPIRED') AS expired_count,
    SUM(r.status = 'NO_SHOW') AS no_show_count,
    ROUND(
        SUM(r.status = 'CONSUMED') / NULLIF(COUNT(*), 0) * 100,
        2
    ) AS fulfillment_rate_pct
FROM charging_reservation AS r
JOIN station AS s
    ON s.station_id = r.station_id
GROUP BY
    r.station_id,
    s.name,
    DATE(r.starts_at);

-- ---------------------------------------------------------------------------
-- ⑧-视图 V05：当前有效的公开公告
-- 未预约车主也能看到；只展示 PUBLISHED 且在有效期内的 PUBLIC 公告。
-- ---------------------------------------------------------------------------
CREATE OR REPLACE SQL SECURITY INVOKER
VIEW v_a_public_notice_active AS
SELECT
    n.notice_id,
    n.station_id,
    s.name AS station_name,
    n.severity,
    n.title,
    n.content,
    n.effective_from,
    n.effective_to,
    n.published_at
FROM station_notice AS n
JOIN station AS s
    ON s.station_id = n.station_id
WHERE n.notice_type = 'PUBLIC'
  AND n.status = 'PUBLISHED'
  AND n.effective_from <= CURRENT_TIMESTAMP
  AND (n.effective_to IS NULL OR n.effective_to > CURRENT_TIMESTAMP);

-- ---------------------------------------------------------------------------
-- ⑧-视图 V06：公告通知送达统计
-- 按公告汇总接收人数、发送数、阅读数、失败数和送达率/阅读率。
-- ---------------------------------------------------------------------------
CREATE OR REPLACE SQL SECURITY INVOKER
VIEW v_a_notice_delivery_stats AS
SELECT
    n.notice_id,
    n.station_id,
    s.name AS station_name,
    n.notice_type,
    n.severity,
    n.status AS notice_status,
    n.title,
    COUNT(DISTINCT nr.recipient_id) AS recipient_count,
    COUNT(nf.notification_id) AS notification_count,
    SUM(nf.status IN ('SENT', 'READ')) AS sent_count,
    SUM(nf.status = 'READ') AS read_count,
    SUM(nf.status = 'FAILED') AS failed_count,
    ROUND(
        SUM(nf.status IN ('SENT', 'READ'))
        / NULLIF(COUNT(nf.notification_id), 0) * 100,
        2
    ) AS delivery_rate_pct,
    ROUND(
        SUM(nf.status = 'READ')
        / NULLIF(COUNT(nf.notification_id), 0) * 100,
        2
    ) AS read_rate_pct
FROM station_notice AS n
JOIN station AS s
    ON s.station_id = n.station_id
LEFT JOIN notice_recipient AS nr
    ON nr.notice_id = n.notice_id
LEFT JOIN notification_record AS nf
    ON nf.recipient_id = nr.recipient_id
GROUP BY
    n.notice_id,
    n.station_id,
    s.name,
    n.notice_type,
    n.severity,
    n.status,
    n.title;

-- ---------------------------------------------------------------------------
-- ⑧-视图 V07：停运公告受影响用户
-- 连接公告、停运计划、接收人、预约/排队，支持客服逐人确认改约或取消。
-- ---------------------------------------------------------------------------
CREATE OR REPLACE SQL SECURITY INVOKER
VIEW v_a_outage_affected_users AS
SELECT
    n.notice_id,
    n.title,
    n.status AS notice_status,
    n.station_id,
    s.name AS station_name,
    n.related_outage_plan_id,
    op.starts_at AS outage_starts_at,
    op.ends_at AS outage_ends_at,
    nr.recipient_id,
    nr.recipient_reason,
    nr.user_id,
    u.real_name AS user_name,
    nr.vehicle_id,
    v.model AS vehicle_model,
    nr.reservation_id,
    r.starts_at AS reservation_starts_at,
    r.ends_at AS reservation_ends_at,
    r.status AS reservation_status,
    nr.queue_id,
    q.ticket_no,
    q.status AS queue_status
FROM station_notice AS n
JOIN station AS s
    ON s.station_id = n.station_id
JOIN equipment_outage_plan AS op
    ON op.outage_plan_id = n.related_outage_plan_id
JOIN notice_recipient AS nr
    ON nr.notice_id = n.notice_id
JOIN `user` AS u
    ON u.user_id = nr.user_id
LEFT JOIN vehicle AS v
    ON v.vehicle_id = nr.vehicle_id
LEFT JOIN charging_reservation AS r
    ON r.reservation_id = nr.reservation_id
LEFT JOIN queue_record AS q
    ON q.queue_id = nr.queue_id
WHERE n.notice_type = 'OUTAGE_TARGETED';

-- ---------------------------------------------------------------------------
-- ⑧-视图 V08：公告版本历史
-- 展示每次新建/修改/发布/撤回/过期的快照和操作人。
-- ---------------------------------------------------------------------------
CREATE OR REPLACE SQL SECURITY INVOKER
VIEW v_a_notice_revision_history AS
SELECT
    rev.revision_id,
    rev.notice_id,
    n.station_id,
    s.name AS station_name,
    n.notice_type,
    rev.revision_no,
    rev.action,
    rev.title,
    rev.content,
    rev.changed_at,
    rev.changed_by
FROM notice_revision AS rev
JOIN station_notice AS n
    ON n.notice_id = rev.notice_id
JOIN station AS s
    ON s.station_id = n.station_id;
