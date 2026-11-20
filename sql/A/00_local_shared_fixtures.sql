-- A 模块本地联调测试夹具（不是正式业务数据）
-- 用途：在本地空库中为 A 的 20 条测试数据提供 B 模块的场站/桩/枪/车位/停运计划引用。
-- 正式联调时由 B 的正式种子数据替代本文件；本文件不应纳入小组正式演示数据。
-- 前置：D 核心表已建好，B 结构表已建好，D 核心种子已提交（user 10001-10020）。
-- 本脚本只 INSERT，不 DROP/TRUNCATE/DELETE。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

START TRANSACTION;

INSERT INTO `operator` (operator_id, name) VALUES
    (9001, '测试运营商甲'),
    (9002, '测试运营商乙'),
    (9003, '测试运营商丙'),
    (9004, '测试运营商丁');

INSERT INTO station (
    station_id, operator_id, name, address, longitude, latitude,
    parking_fee_hour, opens_minute, closes_minute, status
) VALUES
    (9101, 9001, '测试场站一', '北京市海淀区测试路1号', 116.300000, 39.900000, 5.00, 0, 1440, 'OPEN'),
    (9102, 9002, '测试场站二', '北京市朝阳区测试路2号', 116.400000, 39.910000, 6.00, 0, 1440, 'OPEN'),
    (9103, 9003, '测试场站三', '北京市丰台区测试路3号', 116.500000, 39.920000, 4.00, 0, 1440, 'OPEN'),
    (9104, 9004, '测试场站四', '北京市石景山区测试路4号', 116.600000, 39.930000, 5.00, 0, 1440, 'OPEN');

INSERT INTO charging_pile (
    pile_id, station_id, serial_no, model, protocol, rated_kw,
    accepted_at, acceptance_status, commissioned_on, warranty_until, status
) VALUES
    (9201, 9101, 'TEST-PILE-0001', 'TestPile-180', 'OCPP 1.6J', 180.00, '2025-12-20 10:00:00', 'PASSED', '2026-01-01', '2029-12-31', 'READY'),
    (9202, 9101, 'TEST-PILE-0002', 'TestPile-180', 'OCPP 1.6J', 180.00, '2025-12-20 10:00:00', 'PASSED', '2026-01-01', '2029-12-31', 'READY'),
    (9203, 9102, 'TEST-PILE-0003', 'TestPile-180', 'OCPP 1.6J', 180.00, '2025-12-20 10:00:00', 'PASSED', '2026-01-01', '2029-12-31', 'READY'),
    (9204, 9102, 'TEST-PILE-0004', 'TestPile-180', 'OCPP 1.6J', 180.00, '2025-12-20 10:00:00', 'PASSED', '2026-01-01', '2029-12-31', 'READY'),
    (9205, 9103, 'TEST-PILE-0005', 'TestPile-180', 'OCPP 1.6J', 180.00, '2025-12-20 10:00:00', 'PASSED', '2026-01-01', '2029-12-31', 'READY'),
    (9206, 9103, 'TEST-PILE-0006', 'TestPile-180', 'OCPP 1.6J', 180.00, '2025-12-20 10:00:00', 'PASSED', '2026-01-01', '2029-12-31', 'READY'),
    (9207, 9104, 'TEST-PILE-0007', 'TestPile-180', 'OCPP 1.6J', 180.00, '2025-12-20 10:00:00', 'PASSED', '2026-01-01', '2029-12-31', 'READY'),
    (9208, 9104, 'TEST-PILE-0008', 'TestPile-180', 'OCPP 1.6J', 180.00, '2025-12-20 10:00:00', 'PASSED', '2026-01-01', '2029-12-31', 'READY');

INSERT INTO parking_space (parking_space_id, station_id, code)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 20
)
SELECT
    9300 + n,
    9100 + CEIL(n / 5),
    CONCAT('TEST-SPACE-', LPAD(n, 2, '0'))
FROM seq;

INSERT INTO charging_gun (
    gun_id, pile_id, station_id, parking_space_id, gun_no,
    gun_type, interface_type, max_kw, status
)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 20
)
SELECT
    9400 + n,
    9200 + (CEIL(n / 5) - 1) * 2 + IF(MOD(n - 1, 5) < 3, 1, 2),
    9100 + CEIL(n / 5),
    9300 + n,
    IF(MOD(n - 1, 5) < 3, MOD(n - 1, 5) + 1, MOD(n - 1, 5) - 2),
    IF(MOD(n, 2) = 1, 'DC', 'AC'),
    'GB/T 20234',
    120.00,
    'READY'
FROM seq;

INSERT INTO equipment_outage_plan (
    outage_plan_id, station_id, gun_id, starts_at, ends_at, reason, status
)
WITH RECURSIVE seq(n) AS (
    SELECT 1
    UNION ALL
    SELECT n + 1 FROM seq WHERE n < 20
)
SELECT
    9500 + n,
    9100 + MOD(n - 1, 4) + 1,
    IF(MOD(n, 3) = 0, NULL,
       9400 + (MOD(n - 1, 4)) * 5 + 1 + MOD(n - 1, 5)),
    TIMESTAMP('2026-12-01 08:00:00') + INTERVAL (n - 1) DAY,
    TIMESTAMP('2026-12-01 12:00:00') + INTERVAL (n - 1) DAY,
    CONCAT('测试计划检修-', LPAD(n, 2, '0')),
    CASE
        WHEN n <= 14 THEN 'SCHEDULED'
        WHEN n <= 17 THEN 'COMPLETED'
        ELSE 'CANCELLED'
    END
FROM seq;

COMMIT;

SELECT 'shared fixtures' AS section,
       (SELECT COUNT(*) FROM station) AS stations,
       (SELECT COUNT(*) FROM charging_gun) AS guns,
       (SELECT COUNT(*) FROM parking_space) AS spaces,
       (SELECT COUNT(*) FROM equipment_outage_plan) AS outage_plans;
