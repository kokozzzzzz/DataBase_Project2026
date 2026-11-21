-- A ⑥⑧ 测试数据：每张 A 表至少 20 条（触发器和更新会生成更多历史行）
-- 前置：
--   1) 已执行 sql/D/04_membership_core.sql
--   2) 已执行 sql/B/01_schema.sql
--   3) 已执行 sql/A/01_schema.sql / 02_triggers.sql / 03_procedures.sql
--   4) 已提交 D 核心种子（user 10001-10020、vehicle 20001-20020）
--   5) 已提交 sql/A/00_local_shared_fixtures.sql
-- 本脚本故意不执行 COMMIT：先检查末尾统计，再手动 COMMIT 或 ROLLBACK。
-- 若任意语句报错，不要提交事务，应立即 ROLLBACK。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

START TRANSACTION;

-- ---------------------------------------------------------------------------
-- 20 条预约：6 BOOKED、10 CHECKED_IN（其中 5 条稍后转 CONSUMED）、
-- 3 CANCELLED、1 EXPIRED。
-- 每行使用不同枪、不同用户，避免有效区间冲突。
-- ---------------------------------------------------------------------------
INSERT INTO charging_reservation (
    reservation_id, user_id, vehicle_id, gun_id, station_id,
    starts_at, ends_at, late_grace_minutes, status, source,
    cancelled_at, cancel_reason
) VALUES
    (1001, 10001, 20001, 9401, 9101, '2026-11-24 09:00:00', '2026-11-24 10:00:00', 15, 'BOOKED', 'APP', NULL, NULL),
    (1002, 10002, 20002, 9402, 9101, '2026-11-24 10:00:00', '2026-11-24 11:00:00', 15, 'BOOKED', 'WECHAT', NULL, NULL),
    (1003, 10003, 20003, 9403, 9101, '2026-11-24 11:00:00', '2026-11-24 12:00:00', 20, 'BOOKED', 'APP', NULL, NULL),
    (1004, 10004, 20004, 9404, 9101, '2026-11-24 12:00:00', '2026-11-24 13:00:00', 15, 'BOOKED', 'WEB', NULL, NULL),
    (1005, 10005, 20005, 9405, 9101, '2026-11-24 13:00:00', '2026-11-24 14:00:00', 15, 'BOOKED', 'MINI_PROGRAM', NULL, NULL),
    (1006, 10006, 20006, 9406, 9102, '2026-11-24 14:00:00', '2026-11-24 15:00:00', 15, 'BOOKED', 'APP', NULL, NULL),
    (1007, 10007, 20007, 9407, 9102, '2026-11-20 08:00:00', '2026-11-20 09:00:00', 15, 'CHECKED_IN', 'APP', NULL, NULL),
    (1008, 10008, 20008, 9408, 9102, '2026-11-20 09:00:00', '2026-11-20 10:00:00', 15, 'CHECKED_IN', 'WECHAT', NULL, NULL),
    (1009, 10009, 20009, 9409, 9102, '2026-11-20 10:00:00', '2026-11-20 11:00:00', 15, 'CHECKED_IN', 'APP', NULL, NULL),
    (1010, 10010, 20010, 9410, 9102, '2026-11-20 11:00:00', '2026-11-20 12:00:00', 20, 'CHECKED_IN', 'WEB', NULL, NULL),
    (1011, 10011, 20011, 9411, 9103, '2026-11-20 12:00:00', '2026-11-20 13:00:00', 15, 'CHECKED_IN', 'APP', NULL, NULL),
    (1012, 10012, 20012, 9412, 9103, '2026-11-18 08:00:00', '2026-11-18 09:00:00', 15, 'CHECKED_IN', 'APP', NULL, NULL),
    (1013, 10013, 20013, 9413, 9103, '2026-11-18 09:00:00', '2026-11-18 10:00:00', 15, 'CHECKED_IN', 'WECHAT', NULL, NULL),
    (1014, 10014, 20014, 9414, 9103, '2026-11-18 10:00:00', '2026-11-18 11:00:00', 15, 'CHECKED_IN', 'APP', NULL, NULL),
    (1015, 10015, 20015, 9415, 9103, '2026-11-18 11:00:00', '2026-11-18 12:00:00', 15, 'CHECKED_IN', 'WEB', NULL, NULL),
    (1016, 10016, 20016, 9416, 9104, '2026-11-18 12:00:00', '2026-11-18 13:00:00', 15, 'CHECKED_IN', 'APP', NULL, NULL),
    (1017, 10017, 20017, 9417, 9104, '2026-11-21 09:00:00', '2026-11-21 10:00:00', 15, 'CANCELLED', 'APP', '2026-11-20 07:00:00', '用户取消'),
    (1018, 10018, 20018, 9418, 9104, '2026-11-21 10:00:00', '2026-11-21 11:00:00', 15, 'CANCELLED', 'WECHAT', '2026-11-20 07:05:00', '行程变更'),
    (1019, 10019, 20019, 9419, 9104, '2026-11-21 11:00:00', '2026-11-21 12:00:00', 15, 'CANCELLED', 'APP', '2026-11-20 07:10:00', '重复预约'),
    (1020, 10020, 20020, 9420, 9104, '2026-11-19 09:00:00', '2026-11-19 10:00:00', 15, 'EXPIRED', 'APP', NULL, NULL);

-- ---------------------------------------------------------------------------
-- 20 条排队：4 WAITING、3 CALLED、10 CHECKED_IN（其中 5 条稍后转 CONSUMED）、
-- 2 CANCELLED、1 EXPIRED。
-- 枪、车位、车辆互不冲突，避免有效占用唯一约束冲突。
-- ---------------------------------------------------------------------------
INSERT INTO queue_record (
    queue_id, station_id, user_id, vehicle_id, gun_id, ticket_no,
    priority_class, priority_score, status, joined_at,
    called_at, call_expires_at, hold_minutes,
    cancelled_at, cancel_reason
) VALUES
    (2001, 9101, 10007, 20007, 9401, 1,  'WALK_IN', 0,   'WAITING', '2026-11-20 08:01:00', NULL, NULL, 10, NULL, NULL),
    (2002, 9101, 10008, 20008, 9402, 2,  'WALK_IN', 0,   'WAITING', '2026-11-20 08:02:00', NULL, NULL, 10, NULL, NULL),
    (2003, 9101, 10009, 20009, 9403, 3,  'WALK_IN', 0,   'WAITING', '2026-11-20 08:03:00', NULL, NULL, 10, NULL, NULL),
    (2004, 9101, 10010, 20010, 9404, 4,  'WALK_IN', 0,   'WAITING', '2026-11-20 08:04:00', NULL, NULL, 10, NULL, NULL),
    (2005, 9101, 10011, 20011, 9405, 5,  'RESERVATION_LATE', 100, 'CALLED', '2026-11-20 08:05:00', '2026-11-20 08:10:00', '2026-11-20 08:20:00', 10, NULL, NULL),
    (2006, 9102, 10012, 20012, 9406, 6,  'RESERVATION_LATE', 100, 'CALLED', '2026-11-20 08:06:00', '2026-11-20 08:11:00', '2026-11-20 08:21:00', 10, NULL, NULL),
    (2007, 9102, 10013, 20013, 9407, 7,  'RESERVATION_LATE', 100, 'CALLED', '2026-11-20 08:07:00', '2026-11-20 08:12:00', '2026-11-20 08:22:00', 10, NULL, NULL),
    (2008, 9101, 10001, 20001, 9401, 8,  'WALK_IN', 0,   'CHECKED_IN', '2026-11-20 08:08:00', '2026-11-20 08:13:00', '2026-11-20 08:23:00', 10, NULL, NULL),
    (2009, 9101, 10002, 20002, 9402, 9,  'WALK_IN', 0,   'CHECKED_IN', '2026-11-20 08:09:00', '2026-11-20 08:14:00', '2026-11-20 08:24:00', 10, NULL, NULL),
    (2010, 9101, 10003, 20003, 9403, 10, 'WALK_IN', 0,   'CHECKED_IN', '2026-11-20 08:10:00', '2026-11-20 08:15:00', '2026-11-20 08:25:00', 10, NULL, NULL),
    (2011, 9101, 10004, 20004, 9404, 11, 'WALK_IN', 0,   'CHECKED_IN', '2026-11-20 08:11:00', '2026-11-20 08:16:00', '2026-11-20 08:26:00', 10, NULL, NULL),
    (2012, 9101, 10005, 20005, 9405, 12, 'WALK_IN', 0,   'CHECKED_IN', '2026-11-20 08:12:00', '2026-11-20 08:17:00', '2026-11-20 08:27:00', 10, NULL, NULL),
    (2013, 9102, 10006, 20006, 9406, 13, 'WALK_IN', 0,   'CHECKED_IN', '2026-11-20 08:13:00', '2026-11-20 08:18:00', '2026-11-20 08:28:00', 10, NULL, NULL),
    (2014, 9104, 10017, 20017, 9417, 14, 'WALK_IN', 0,   'CHECKED_IN', '2026-11-20 08:14:00', '2026-11-20 08:19:00', '2026-11-20 08:29:00', 10, NULL, NULL),
    (2015, 9104, 10018, 20018, 9418, 15, 'WALK_IN', 0,   'CHECKED_IN', '2026-11-20 08:15:00', '2026-11-20 08:20:00', '2026-11-20 08:30:00', 10, NULL, NULL),
    (2016, 9104, 10019, 20019, 9419, 16, 'WALK_IN', 0,   'CHECKED_IN', '2026-11-20 08:16:00', '2026-11-20 08:21:00', '2026-11-20 08:31:00', 10, NULL, NULL),
    (2017, 9104, 10020, 20020, 9420, 17, 'WALK_IN', 0,   'CHECKED_IN', '2026-11-20 08:17:00', '2026-11-20 08:22:00', '2026-11-20 08:32:00', 10, NULL, NULL),
    (2018, 9101, 10014, 20014, 9401, 18, 'WALK_IN', 0,   'CANCELLED', '2026-11-20 08:18:00', NULL, NULL, 10, '2026-11-20 08:20:00', '用户离开'),
    (2019, 9101, 10015, 20015, 9402, 19, 'WALK_IN', 0,   'CANCELLED', '2026-11-20 08:19:00', NULL, NULL, 10, '2026-11-20 08:21:00', '改去其他场站'),
    (2020, 9101, 10016, 20016, 9403, 20, 'WALK_IN', 0,   'EXPIRED', '2026-11-20 08:20:00', NULL, NULL, 10, NULL, NULL);

-- ---------------------------------------------------------------------------
-- 20 条到站核验：10 条来自预约，10 条来自排队。
-- 触发 a_checkin_occupancy_ai 会自动生成 20 条 parking_occupancy。
-- ---------------------------------------------------------------------------
INSERT INTO arrival_checkin (
    checkin_id, reservation_id, queue_id, user_id, vehicle_id,
    station_id, gun_id, parking_space_id, checked_in_at,
    checkin_method, plate_verified
) VALUES
    (5001, 1007, NULL, 10007, 20007, 9102, 9407, 9307, '2026-11-20 08:05:00', 'QR_CODE', 1),
    (5002, 1008, NULL, 10008, 20008, 9102, 9408, 9308, '2026-11-20 09:05:00', 'QR_CODE', 1),
    (5003, 1009, NULL, 10009, 20009, 9102, 9409, 9309, '2026-11-20 10:05:00', 'STAFF', 1),
    (5004, 1010, NULL, 10010, 20010, 9102, 9410, 9310, '2026-11-20 11:05:00', 'QR_CODE', 1),
    (5005, 1011, NULL, 10011, 20011, 9103, 9411, 9311, '2026-11-20 12:05:00', 'AUTO', 1),
    (5006, 1012, NULL, 10012, 20012, 9103, 9412, 9312, '2026-11-18 08:05:00', 'QR_CODE', 1),
    (5007, 1013, NULL, 10013, 20013, 9103, 9413, 9313, '2026-11-18 09:05:00', 'QR_CODE', 1),
    (5008, 1014, NULL, 10014, 20014, 9103, 9414, 9314, '2026-11-18 10:05:00', 'STAFF', 1),
    (5009, 1015, NULL, 10015, 20015, 9103, 9415, 9315, '2026-11-18 11:05:00', 'QR_CODE', 1),
    (5010, 1016, NULL, 10016, 20016, 9104, 9416, 9316, '2026-11-18 12:05:00', 'QR_CODE', 1),
    (5011, NULL, 2008, 10001, 20001, 9101, 9401, 9301, '2026-11-20 08:13:30', 'QR_CODE', 1),
    (5012, NULL, 2009, 10002, 20002, 9101, 9402, 9302, '2026-11-20 08:14:30', 'QR_CODE', 1),
    (5013, NULL, 2010, 10003, 20003, 9101, 9403, 9303, '2026-11-20 08:15:30', 'STAFF', 1),
    (5014, NULL, 2011, 10004, 20004, 9101, 9404, 9304, '2026-11-20 08:16:30', 'QR_CODE', 1),
    (5015, NULL, 2012, 10005, 20005, 9101, 9405, 9305, '2026-11-20 08:17:30', 'AUTO', 1),
    (5016, NULL, 2013, 10006, 20006, 9102, 9406, 9306, '2026-11-20 08:18:30', 'QR_CODE', 1),
    (5017, NULL, 2014, 10017, 20017, 9104, 9417, 9317, '2026-11-20 08:19:30', 'QR_CODE', 1),
    (5018, NULL, 2015, 10018, 20018, 9104, 9418, 9318, '2026-11-20 08:20:30', 'STAFF', 1),
    (5019, NULL, 2016, 10019, 20019, 9104, 9419, 9319, '2026-11-20 08:21:30', 'QR_CODE', 1),
    (5020, NULL, 2017, 10020, 20020, 9104, 9420, 9320, '2026-11-20 08:22:30', 'QR_CODE', 1);

-- ---------------------------------------------------------------------------
-- 10 条充电订单：5 条来自预约、5 条来自排队；其中 5 条 ACTIVE、5 条 BILLED。
-- BILLED 订单用于演示“充电结束但车辆未驶离”和“已驶离释放车位”。
-- ---------------------------------------------------------------------------
INSERT INTO charging_order (
    order_id, gun_id, user_id, vehicle_id, channel, admission_id,
    starts_at, ends_at, start_soc, end_soc, state,
    total_kwh, gross_amount, discount_amount
) VALUES
    (8001, 9412, 10012, 20012, 'RESERVATION', 1012, '2026-11-18 08:05:00', NULL, 20, NULL, 'ACTIVE', NULL, NULL, 0.00),
    (8002, 9413, 10013, 20013, 'RESERVATION', 1013, '2026-11-18 09:05:00', NULL, 25, NULL, 'ACTIVE', NULL, NULL, 0.00),
    (8003, 9414, 10014, 20014, 'RESERVATION', 1014, '2026-11-18 10:05:00', NULL, 30, NULL, 'ACTIVE', NULL, NULL, 0.00),
    (8004, 9415, 10015, 20015, 'RESERVATION', 1015, '2026-11-18 11:05:00', '2026-11-18 12:05:00', 18, 82, 'BILLED', 32.500, 65.00, 0.00),
    (8005, 9416, 10016, 20016, 'RESERVATION', 1016, '2026-11-18 12:05:00', '2026-11-18 13:05:00', 22, 78, 'BILLED', 28.000, 56.00, 0.00),
    (8006, 9406, 10006, 20006, 'QUEUE', 2013, '2026-11-20 08:18:30', '2026-11-20 09:18:30', 30, 85, 'BILLED', 25.000, 50.00, 0.00),
    (8007, 9417, 10017, 20017, 'QUEUE', 2014, '2026-11-20 08:19:30', '2026-11-20 09:19:30', 25, 80, 'BILLED', 22.000, 44.00, 0.00),
    (8008, 9418, 10018, 20018, 'QUEUE', 2015, '2026-11-20 08:20:30', '2026-11-20 09:20:30', 28, 88, 'BILLED', 30.000, 60.00, 0.00),
    (8009, 9419, 10019, 20019, 'QUEUE', 2016, '2026-11-20 08:21:30', '2026-11-20 09:21:30', 20, 75, 'BILLED', 18.000, 36.00, 0.00),
    (8010, 9420, 10020, 20020, 'QUEUE', 2017, '2026-11-20 08:22:30', NULL, 35, NULL, 'ACTIVE', NULL, NULL, 0.00);

-- ---------------------------------------------------------------------------
-- 资格消费：5 条预约、5 条排队转为 CONSUMED。
-- ---------------------------------------------------------------------------
SET @a_change_reason = 'SEED_CONSUME_RESERVATION';

UPDATE charging_reservation
   SET status = 'CONSUMED',
       consumed_at = '2026-11-18 08:05:00',
       consumed_order_id = 8001
 WHERE reservation_id = 1012;

UPDATE charging_reservation
   SET status = 'CONSUMED',
       consumed_at = '2026-11-18 09:05:00',
       consumed_order_id = 8002
 WHERE reservation_id = 1013;

UPDATE charging_reservation
   SET status = 'CONSUMED',
       consumed_at = '2026-11-18 10:05:00',
       consumed_order_id = 8003
 WHERE reservation_id = 1014;

UPDATE charging_reservation
   SET status = 'CONSUMED',
       consumed_at = '2026-11-18 11:05:00',
       consumed_order_id = 8004
 WHERE reservation_id = 1015;

UPDATE charging_reservation
   SET status = 'CONSUMED',
       consumed_at = '2026-11-18 12:05:00',
       consumed_order_id = 8005
 WHERE reservation_id = 1016;

SET @a_change_reason = 'SEED_CONSUME_QUEUE';

UPDATE queue_record
   SET status = 'CONSUMED',
       consumed_at = '2026-11-20 08:18:30',
       consumed_order_id = 8006
 WHERE queue_id = 2013;

UPDATE queue_record
   SET status = 'CONSUMED',
       consumed_at = '2026-11-20 08:19:30',
       consumed_order_id = 8007
 WHERE queue_id = 2014;

UPDATE queue_record
   SET status = 'CONSUMED',
       consumed_at = '2026-11-20 08:20:30',
       consumed_order_id = 8008
 WHERE queue_id = 2015;

UPDATE queue_record
   SET status = 'CONSUMED',
       consumed_at = '2026-11-20 08:21:30',
       consumed_order_id = 8009
 WHERE queue_id = 2016;

UPDATE queue_record
   SET status = 'CONSUMED',
       consumed_at = '2026-11-20 08:22:30',
       consumed_order_id = 8010
 WHERE queue_id = 2017;

-- ---------------------------------------------------------------------------
-- 释放 5 个车位：预约 1016 已结束充电并驶离；排队 2013-2016 已结束并驶离。
-- 其他 15 个车位保持占用，其中包含“充电结束但未驶离”的预约 1015 和排队 2017。
-- ---------------------------------------------------------------------------
UPDATE parking_occupancy
   SET released_at = occupied_at + INTERVAL 2 HOUR,
       release_reason = 'VEHICLE_LEFT'
 WHERE checkin_id IN (5010, 5016, 5017, 5018, 5019);

-- ---------------------------------------------------------------------------
-- 21 条公告：1 条 DRAFT（公共）、14 条 PUBLISHED、3 条 WITHDRAWN、3 条 EXPIRED。
-- 先全部按 DRAFT 插入，再按状态机更新，触发器会保留 CREATE/PUBLISH/WITHDRAW/EXPIRE 版本。
-- ---------------------------------------------------------------------------
INSERT INTO station_notice (
    notice_id, station_id, notice_type, severity, title, content,
    status, effective_from, effective_to, published_at,
    withdrawn_at, withdraw_reason, created_by, updated_by,
    related_outage_plan_id
) VALUES
    (3001, 9101, 'PUBLIC', 'INFO', '入口临时调整', '2026-11-20 起东门入口施工，请从南门进入。', 'DRAFT', '2026-11-18 00:00:00', '2026-12-31 23:59:59', NULL, NULL, NULL, 'seed', 'seed', NULL),
    (3002, 9102, 'PUBLIC', 'INFO', '停车场优惠', '本周停车费按 5 折收取。', 'DRAFT', '2026-11-18 00:00:00', '2026-12-31 23:59:59', NULL, NULL, NULL, 'seed', 'seed', NULL),
    (3003, 9103, 'PUBLIC', 'WARNING', '夜间施工提醒', '22:00-次日 06:00 进行设备巡检，可能产生噪声。', 'DRAFT', '2026-11-18 00:00:00', '2026-12-31 23:59:59', NULL, NULL, NULL, 'seed', 'seed', NULL),
    (3004, 9104, 'PUBLIC', 'INFO', '新增快充枪', '新增 2 把 120kW 快充枪，已投入使用。', 'DRAFT', '2026-11-18 00:00:00', '2026-12-31 23:59:59', NULL, NULL, NULL, 'seed', 'seed', NULL),
    (3005, 9101, 'PUBLIC', 'EMERGENCY', '暴雨安全提示', '暴雨期间请勿在露天区域长时间停留。', 'DRAFT', '2026-11-18 00:00:00', '2026-12-31 23:59:59', NULL, NULL, NULL, 'seed', 'seed', NULL),
    (3006, 9102, 'PUBLIC', 'INFO', '服务台位置变更', '服务台移至 A 区入口。', 'DRAFT', '2026-11-18 00:00:00', '2026-12-31 23:59:59', NULL, NULL, NULL, 'seed', 'seed', NULL),
    (3007, 9103, 'PUBLIC', 'WARNING', '高温充电提示', '高温时段请优先使用液冷枪线。', 'DRAFT', '2026-11-18 00:00:00', '2026-12-31 23:59:59', NULL, NULL, NULL, 'seed', 'seed', NULL),
    (3008, 9104, 'PUBLIC', 'INFO', '会员日活动', '每周三会员充电服务费 8 折。', 'DRAFT', '2026-11-18 00:00:00', '2026-12-31 23:59:59', NULL, NULL, NULL, 'seed', 'seed', NULL),
    (3009, 9101, 'PUBLIC', 'INFO', '卫生间开放', '场站卫生间已恢复开放。', 'DRAFT', '2026-11-18 00:00:00', '2026-12-31 23:59:59', NULL, NULL, NULL, 'seed', 'seed', NULL),
    (3010, 9102, 'PUBLIC', 'WARNING', '排队高峰提示', '晚高峰 18:00-20:00 排队较长，建议错峰。', 'DRAFT', '2026-11-18 00:00:00', '2026-12-31 23:59:59', NULL, NULL, NULL, 'seed', 'seed', NULL),
    (3011, 9101, 'OUTAGE_TARGETED', 'WARNING', '1号枪计划停运', '2026-12-01 08:00-12:00 计划检修，请改约其他枪。', 'DRAFT', '2026-11-18 00:00:00', '2026-12-31 23:59:59', NULL, NULL, NULL, 'seed', 'seed', 9501),
    (3012, 9102, 'OUTAGE_TARGETED', 'WARNING', '2号枪计划停运', '2026-12-02 08:00-12:00 计划检修，请改约其他枪。', 'DRAFT', '2026-11-18 00:00:00', '2026-12-31 23:59:59', NULL, NULL, NULL, 'seed', 'seed', 9502),
    (3013, 9103, 'OUTAGE_TARGETED', 'EMERGENCY', '3号枪紧急停运', '2026-12-03 08:00-12:00 紧急停运，请立即改约。', 'DRAFT', '2026-11-18 00:00:00', '2026-12-31 23:59:59', NULL, NULL, NULL, 'seed', 'seed', 9503),
    (3014, 9104, 'OUTAGE_TARGETED', 'WARNING', '4号枪计划停运', '2026-12-04 08:00-12:00 计划检修，请改约其他枪。', 'DRAFT', '2026-11-18 00:00:00', '2026-12-31 23:59:59', NULL, NULL, NULL, 'seed', 'seed', 9504),
    (3015, 9101, 'OUTAGE_TARGETED', 'WARNING', '5号枪计划停运', '2026-12-05 08:00-12:00 计划检修。', 'DRAFT', '2026-11-18 00:00:00', '2026-12-31 23:59:59', NULL, NULL, NULL, 'seed', 'seed', 9505),
    (3016, 9102, 'OUTAGE_TARGETED', 'WARNING', '6号枪计划停运', '2026-12-06 08:00-12:00 计划检修。', 'DRAFT', '2026-11-18 00:00:00', '2026-12-31 23:59:59', NULL, NULL, NULL, 'seed', 'seed', 9506),
    (3017, 9103, 'OUTAGE_TARGETED', 'WARNING', '7号枪计划停运', '2026-12-07 08:00-12:00 计划检修。', 'DRAFT', '2026-11-18 00:00:00', '2026-12-31 23:59:59', NULL, NULL, NULL, 'seed', 'seed', 9507),
    (3018, 9104, 'OUTAGE_TARGETED', 'INFO', '8号枪停运通知', '2026-12-08 08:00-12:00 停运。', 'DRAFT', '2026-11-18 00:00:00', '2026-11-19 23:59:59', NULL, NULL, NULL, 'seed', 'seed', 9508),
    (3019, 9101, 'OUTAGE_TARGETED', 'INFO', '9号枪停运通知', '2026-12-09 08:00-12:00 停运。', 'DRAFT', '2026-11-18 00:00:00', '2026-11-19 23:59:59', NULL, NULL, NULL, 'seed', 'seed', 9509),
    (3020, 9102, 'OUTAGE_TARGETED', 'INFO', '10号枪停运通知', '2026-12-10 08:00-12:00 停运。', 'DRAFT', '2026-11-18 00:00:00', '2026-11-19 23:59:59', NULL, NULL, NULL, 'seed', 'seed', 9510),
    (3021, 9103, 'PUBLIC', 'INFO', '草稿公告待发布', '本公告用于演示发布/撤回流程。', 'DRAFT', '2026-11-18 00:00:00', '2026-12-31 23:59:59', NULL, NULL, NULL, 'seed', 'seed', NULL);

-- 发布会话：3001-3014 保持 PUBLISHED；3015-3017 再撤回；3018-3020 再过期。
UPDATE station_notice
   SET status = 'PUBLISHED',
       published_at = TIMESTAMP('2026-11-18 09:00:00') + INTERVAL (notice_id - 3000) MINUTE
 WHERE notice_id BETWEEN 3001 AND 3020;

UPDATE station_notice
   SET status = 'WITHDRAWN',
       withdrawn_at = TIMESTAMP('2026-11-19 10:00:00') + INTERVAL (notice_id - 3000) MINUTE,
       withdraw_reason = '测试撤回'
 WHERE notice_id IN (3015, 3016, 3017);

UPDATE station_notice
   SET status = 'EXPIRED',
       updated_by = 'SYSTEM'
 WHERE notice_id IN (3018, 3019, 3020);

-- ---------------------------------------------------------------------------
-- 20 条公告接收对象：10 条公开公告的 MANUAL 接收人 + 10 条定向公告的预约接收人。
-- ---------------------------------------------------------------------------
INSERT INTO notice_recipient (
    recipient_id, notice_id, user_id, vehicle_id,
    reservation_id, queue_id, recipient_reason
) VALUES
    (7001, 3001, 10001, 20001, NULL, NULL, 'MANUAL'),
    (7002, 3002, 10002, 20002, NULL, NULL, 'MANUAL'),
    (7003, 3003, 10003, 20003, NULL, NULL, 'MANUAL'),
    (7004, 3004, 10004, 20004, NULL, NULL, 'MANUAL'),
    (7005, 3005, 10005, 20005, NULL, NULL, 'MANUAL'),
    (7006, 3006, 10006, 20006, NULL, NULL, 'MANUAL'),
    (7007, 3007, 10007, 20007, NULL, NULL, 'MANUAL'),
    (7008, 3008, 10008, 20008, NULL, NULL, 'MANUAL'),
    (7009, 3009, 10009, 20009, NULL, NULL, 'MANUAL'),
    (7010, 3010, 10010, 20010, NULL, NULL, 'MANUAL'),
    (7011, 3011, 10001, 20001, 1001, NULL, 'AFFECTED_RESERVATION'),
    (7012, 3012, 10002, 20002, 1002, NULL, 'AFFECTED_RESERVATION'),
    (7013, 3013, 10003, 20003, 1003, NULL, 'AFFECTED_RESERVATION'),
    (7014, 3014, 10004, 20004, 1004, NULL, 'AFFECTED_RESERVATION'),
    (7015, 3015, 10005, 20005, 1005, NULL, 'AFFECTED_RESERVATION'),
    (7016, 3016, 10006, 20006, 1006, NULL, 'AFFECTED_RESERVATION'),
    (7017, 3017, 10007, 20007, 1007, NULL, 'AFFECTED_RESERVATION'),
    (7018, 3018, 10008, 20008, 1008, NULL, 'AFFECTED_RESERVATION'),
    (7019, 3019, 10009, 20009, 1009, NULL, 'AFFECTED_RESERVATION'),
    (7020, 3020, 10010, 20010, 1010, NULL, 'AFFECTED_RESERVATION');

-- ---------------------------------------------------------------------------
-- 20 条通知发送记录：
--   * 前 14 条按 PENDING/SENT/READ/FAILED 轮换；
--   * 7015-7017 因公告撤回而 FAILED；
--   * 7018-7020 已读。
-- ---------------------------------------------------------------------------
INSERT INTO notification_record (
    recipient_id, channel, status, sent_at, read_at, failure_reason, retry_count
)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 20
)
SELECT
    7000 + n,
    CASE MOD(n, 4)
        WHEN 0 THEN 'EMAIL'
        WHEN 1 THEN 'IN_APP'
        WHEN 2 THEN 'SMS'
        ELSE 'PUSH'
    END,
    CASE
        WHEN n BETWEEN 15 AND 17 THEN 'FAILED'
        WHEN n BETWEEN 18 AND 20 THEN 'READ'
        WHEN MOD(n, 4) = 0 THEN 'PENDING'
        WHEN MOD(n, 4) = 1 THEN 'SENT'
        WHEN MOD(n, 4) = 2 THEN 'READ'
        ELSE 'FAILED'
    END,
    CASE
        WHEN n BETWEEN 18 AND 20 THEN TIMESTAMP('2026-11-19 11:00:00') + INTERVAL n MINUTE
        WHEN n BETWEEN 15 AND 17 THEN NULL
        WHEN MOD(n, 4) IN (1, 2) THEN TIMESTAMP('2026-11-19 09:00:00') + INTERVAL n MINUTE
        ELSE NULL
    END,
    CASE
        WHEN n BETWEEN 18 AND 20 THEN TIMESTAMP('2026-11-19 09:30:00') + INTERVAL n MINUTE
        WHEN n BETWEEN 15 AND 17 THEN NULL
        WHEN MOD(n, 4) = 2 THEN TIMESTAMP('2026-11-19 09:30:00') + INTERVAL n MINUTE
        ELSE NULL
    END,
    CASE
        WHEN n BETWEEN 15 AND 17 THEN 'NOTICE_WITHDRAWN'
        WHEN n BETWEEN 18 AND 20 THEN NULL
        WHEN MOD(n, 4) = 3 THEN 'TEST_CHANNEL_FAILURE'
        ELSE NULL
    END,
    CASE
        WHEN n BETWEEN 15 AND 17 THEN 1
        WHEN MOD(n, 4) = 3 THEN 1
        ELSE 0
    END
FROM seq;

SELECT 'A seed' AS section;
SELECT 'charging_reservation' AS table_name, COUNT(*) AS row_count FROM charging_reservation
UNION ALL SELECT 'reservation_status_log', COUNT(*) FROM reservation_status_log
UNION ALL SELECT 'queue_record', COUNT(*) FROM queue_record
UNION ALL SELECT 'queue_status_log', COUNT(*) FROM queue_status_log
UNION ALL SELECT 'arrival_checkin', COUNT(*) FROM arrival_checkin
UNION ALL SELECT 'parking_occupancy', COUNT(*) FROM parking_occupancy
UNION ALL SELECT 'station_notice', COUNT(*) FROM station_notice
UNION ALL SELECT 'notice_revision', COUNT(*) FROM notice_revision
UNION ALL SELECT 'notice_recipient', COUNT(*) FROM notice_recipient
UNION ALL SELECT 'notification_record', COUNT(*) FROM notification_record;

SELECT 'TRANSACTION IS STILL OPEN' AS next_action,
       'verify each row_count >= 20, then COMMIT; otherwise ROLLBACK' AS instruction;
