-- A ⑥⑧ 业务查询（只读）
-- 目标环境：MySQL 8.0.46。
-- 每条查询均连接 3 个及以上关系，覆盖预约、到站、排队、车位、公告、通知。
-- 结果用于课程设计验收、运营复盘和答辩演示。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

-- ---------------------------------------------------------------------------
-- Q01 场站预约压力与履约率
-- 关系：charging_reservation、station、charging_gun、user、vehicle
-- 索引：ix_reservation_station_time、ix_reservation_user_time
-- ---------------------------------------------------------------------------
SELECT
    s.station_id,
    s.name AS station_name,
    DATE(r.starts_at) AS reservation_date,
    COUNT(*) AS total_reservations,
    SUM(r.status IN ('BOOKED', 'CHECKED_IN')) AS active_reservations,
    SUM(r.status = 'CONSUMED') AS consumed_reservations,
    SUM(r.status = 'CANCELLED') AS cancelled_reservations,
    SUM(r.status = 'EXPIRED') AS expired_reservations,
    ROUND(
        SUM(r.status = 'CONSUMED') / NULLIF(COUNT(*), 0) * 100,
        2
    ) AS fulfillment_rate_pct,
    COUNT(DISTINCT r.user_id) AS unique_users,
    COUNT(DISTINCT r.vehicle_id) AS unique_vehicles
FROM charging_reservation AS r
JOIN station AS s
    ON s.station_id = r.station_id
JOIN charging_gun AS g
    ON g.gun_id = r.gun_id
   AND g.station_id = r.station_id
JOIN `user` AS u
    ON u.user_id = r.user_id
JOIN vehicle AS v
    ON v.vehicle_id = r.vehicle_id
WHERE r.starts_at >= '2026-11-18 00:00:00'
  AND r.starts_at < '2026-11-27 00:00:00'
GROUP BY
    s.station_id,
    s.name,
    DATE(r.starts_at)
ORDER BY
    reservation_date,
    s.station_id;

-- ---------------------------------------------------------------------------
-- Q02 预约→到站→占位→开单转化漏斗
-- 关系：charging_reservation、arrival_checkin、parking_occupancy、
--       charging_order、station、charging_gun
-- ---------------------------------------------------------------------------
SELECT
    s.station_id,
    s.name AS station_name,
    COUNT(*) AS reservations,
    SUM(ac.checkin_id IS NOT NULL) AS arrived_checkins,
    SUM(po.occupancy_id IS NOT NULL) AS parking_occupancies,
    SUM(o.order_id IS NOT NULL) AS created_orders,
    ROUND(
        SUM(ac.checkin_id IS NOT NULL) / NULLIF(COUNT(*), 0) * 100,
        2
    ) AS arrival_rate_pct,
    ROUND(
        SUM(o.order_id IS NOT NULL) / NULLIF(COUNT(*), 0) * 100,
        2
    ) AS order_rate_pct
FROM charging_reservation AS r
JOIN station AS s
    ON s.station_id = r.station_id
JOIN charging_gun AS g
    ON g.gun_id = r.gun_id
   AND g.station_id = r.station_id
LEFT JOIN arrival_checkin AS ac
    ON ac.reservation_id = r.reservation_id
LEFT JOIN parking_occupancy AS po
    ON po.checkin_id = ac.checkin_id
LEFT JOIN charging_order AS o
    ON o.order_id = r.consumed_order_id
WHERE r.starts_at >= '2026-11-18 00:00:00'
  AND r.starts_at < '2026-11-27 00:00:00'
GROUP BY
    s.station_id,
    s.name
ORDER BY s.station_id;

-- ---------------------------------------------------------------------------
-- Q03 现场排队等待、叫号超时与开单转化
-- 关系：queue_record、station、charging_gun、arrival_checkin、charging_order
-- 索引：ix_queue_station_status_priority、ix_queue_gun_status
-- ---------------------------------------------------------------------------
SELECT
    s.station_id,
    s.name AS station_name,
    q.status,
    COUNT(*) AS ticket_count,
    ROUND(
        AVG(
            TIMESTAMPDIFF(
                MINUTE,
                q.joined_at,
                COALESCE(q.called_at, CURRENT_TIMESTAMP)
            )
        ),
        2
    ) AS avg_wait_minutes,
    SUM(q.status = 'EXPIRED') AS expired_count,
    SUM(ac.checkin_id IS NOT NULL) AS arrived_count,
    SUM(o.order_id IS NOT NULL) AS ordered_count,
    ROUND(
        SUM(o.order_id IS NOT NULL) / NULLIF(COUNT(*), 0) * 100,
        2
    ) AS conversion_rate_pct
FROM queue_record AS q
JOIN station AS s
    ON s.station_id = q.station_id
JOIN charging_gun AS g
    ON g.gun_id = q.gun_id
   AND g.station_id = q.station_id
LEFT JOIN arrival_checkin AS ac
    ON ac.queue_id = q.queue_id
LEFT JOIN charging_order AS o
    ON o.order_id = q.consumed_order_id
WHERE q.joined_at >= '2026-11-20 00:00:00'
  AND q.joined_at < '2026-11-21 00:00:00'
GROUP BY
    s.station_id,
    s.name,
    q.status
ORDER BY
    s.station_id,
    q.status;

-- ---------------------------------------------------------------------------
-- Q04 当前占用车位中“充电已结束但车辆未驶离”的明细
-- 关系：parking_occupancy、parking_space、charging_gun、station、user、
--       vehicle、charging_order
-- 用途：现场调度优先处理停留最久的车辆，不能提前释放车位或叫下一位。
-- ---------------------------------------------------------------------------
SELECT
    s.station_id,
    s.name AS station_name,
    ps.code AS space_code,
    u.real_name AS user_name,
    v.model AS vehicle_model,
    g.gun_no,
    po.occupied_at,
    TIMESTAMPDIFF(MINUTE, po.occupied_at, CURRENT_TIMESTAMP) AS occupied_minutes,
    o.order_id,
    o.state AS order_state,
    o.ends_at AS charging_ended_at,
    TIMESTAMPDIFF(MINUTE, o.ends_at, CURRENT_TIMESTAMP) AS minutes_since_charge_end
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
WHERE po.released_at IS NULL
  AND o.state = 'BILLED'
ORDER BY
    minutes_since_charge_end DESC,
    po.occupied_at ASC;

-- ---------------------------------------------------------------------------
-- Q05 停运公告触达与受影响预约处理结果
-- 关系：station_notice、station、equipment_outage_plan、notice_recipient、
--       notification_record、charging_reservation
-- ---------------------------------------------------------------------------
SELECT
    n.notice_id,
    n.title,
    s.station_id,
    s.name AS station_name,
    op.starts_at AS outage_starts_at,
    op.ends_at AS outage_ends_at,
    COUNT(DISTINCT nr.recipient_id) AS recipient_count,
    SUM(nf.status IN ('SENT', 'READ')) AS delivered_count,
    SUM(nf.status = 'READ') AS read_count,
    SUM(nf.status = 'FAILED') AS failed_count,
    COUNT(DISTINCT r.reservation_id) AS affected_reservations,
    SUM(r.status = 'CANCELLED') AS affected_cancelled,
    SUM(r.status = 'EXPIRED') AS affected_expired,
    SUM(r.status = 'CONSUMED') AS affected_consumed
FROM station_notice AS n
JOIN station AS s
    ON s.station_id = n.station_id
JOIN equipment_outage_plan AS op
    ON op.outage_plan_id = n.related_outage_plan_id
LEFT JOIN notice_recipient AS nr
    ON nr.notice_id = n.notice_id
LEFT JOIN notification_record AS nf
    ON nf.recipient_id = nr.recipient_id
LEFT JOIN charging_reservation AS r
    ON r.reservation_id = nr.reservation_id
WHERE n.notice_type = 'OUTAGE_TARGETED'
GROUP BY
    n.notice_id,
    n.title,
    s.station_id,
    s.name,
    op.starts_at,
    op.ends_at
ORDER BY n.notice_id;

-- ---------------------------------------------------------------------------
-- Q06 公告送达率与阅读率：按场站、公告类型、级别
-- 关系：station_notice、station、notice_recipient、notification_record
-- ---------------------------------------------------------------------------
SELECT
    s.station_id,
    s.name AS station_name,
    n.notice_type,
    n.severity,
    COUNT(DISTINCT n.notice_id) AS notice_count,
    COUNT(DISTINCT nr.recipient_id) AS recipient_count,
    COUNT(nf.notification_id) AS notification_count,
    SUM(nf.status IN ('SENT', 'READ')) AS delivered_count,
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
WHERE n.status IN ('PUBLISHED', 'WITHDRAWN', 'EXPIRED')
GROUP BY
    s.station_id,
    s.name,
    n.notice_type,
    n.severity
ORDER BY
    s.station_id,
    n.notice_type,
    n.severity;

-- ---------------------------------------------------------------------------
-- Q07 同枪有效预约冲突扫描（数据质量检查，预期 0 行）
-- 关系：charging_reservation（自连接）、charging_gun、station
-- 即使绕过存储过程直接写入，触发器也应阻止冲突；本查询用于验收复核。
-- ---------------------------------------------------------------------------
SELECT
    a.reservation_id AS first_reservation_id,
    b.reservation_id AS second_reservation_id,
    a.gun_id,
    g.gun_no,
    s.name AS station_name,
    a.starts_at AS first_starts_at,
    a.ends_at AS first_ends_at,
    b.starts_at AS second_starts_at,
    b.ends_at AS second_ends_at
FROM charging_reservation AS a
JOIN charging_reservation AS b
    ON b.gun_id = a.gun_id
   AND b.reservation_id > a.reservation_id
   AND a.status IN ('BOOKED', 'CHECKED_IN')
   AND b.status IN ('BOOKED', 'CHECKED_IN')
   AND a.starts_at < b.ends_at
   AND b.starts_at < a.ends_at
JOIN charging_gun AS g
    ON g.gun_id = a.gun_id
JOIN station AS s
    ON s.station_id = a.station_id
ORDER BY
    a.gun_id,
    a.starts_at;
