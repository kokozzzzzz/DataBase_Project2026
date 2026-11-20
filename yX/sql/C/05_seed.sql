-- Test data for a clean C schema after B has at least one pile and one gun.
-- Data is deterministic and uses the real B device identifiers.
USE charging_platform;
SET SESSION time_zone = '+08:00';

SET @c_seed_pile_id := (
    SELECT pile_id FROM charging_pile ORDER BY pile_id LIMIT 1
);
SET @c_seed_time := CURRENT_TIMESTAMP(6);
SET @c_seed_gun_id := (
    SELECT gun_id
    FROM charging_gun
    WHERE pile_id = @c_seed_pile_id
    ORDER BY gun_id
    LIMIT 1
);

SELECT CASE
    WHEN @c_seed_pile_id IS NULL OR @c_seed_gun_id IS NULL
    THEN 'FAIL: seed B charging_pile/charging_gun before C'
    ELSE 'PASS: found B device fixtures'
END AS c_seed_preflight;

CREATE TEMPORARY TABLE c_seed_sequence (
    n INT UNSIGNED NOT NULL PRIMARY KEY
) ENGINE=MEMORY;
INSERT INTO c_seed_sequence (n) VALUES
(1),(2),(3),(4),(5),(6),(7),(8),(9),(10),
(11),(12),(13),(14),(15),(16),(17),(18),(19),(20);

START TRANSACTION;

SET @c_telemetry_base := (SELECT COALESCE(MAX(telemetry_id), 0) FROM device_telemetry);
INSERT INTO device_telemetry (
    pile_id, gun_id, collect_time, voltage, current, power, module_temp,
    offline_duration_sec, fault_code, quality_flag
)
SELECT
    @c_seed_pile_id, @c_seed_gun_id,
    @c_seed_time - INTERVAL (n + IF(n <= 10, 4, 0)) HOUR,
    400.00 + n, 10.00 + n, 5.00 + n, 25.00 + n / 10,
    0, CONCAT('SEED-', LPAD(n, 3, '0')),
    IF(MOD(n, 5) = 0, 'ABNORMAL', 'NORMAL')
FROM c_seed_sequence;

SET @c_alarm_base := (SELECT COALESCE(MAX(alarm_id), 0) FROM alarm);
INSERT INTO alarm (
    pile_id, gun_id, alarm_code, alarm_level, alarm_desc,
    occur_time, recover_time, alarm_status, recover_verify_status,
    source_telemetry_id
)
SELECT
    @c_seed_pile_id, @c_seed_gun_id,
    CONCAT('SEED-', LPAD(n, 3, '0')),
    CASE WHEN n > 15 THEN 'HIGH' ELSE 'MEDIUM' END,
    CONCAT('C模块样例告警 ', n),
    @c_seed_time - INTERVAL (n + IF(n <= 10, 4, 0)) HOUR,
    IF(n <= 10, @c_seed_time - INTERVAL (n - 1) HOUR, NULL),
    IF(n <= 10, 'RESOLVED', 'ACKNOWLEDGED'),
    IF(n <= 10, 'PASSED', 'PENDING'),
    @c_telemetry_base + n
FROM c_seed_sequence;

SET @c_work_order_base := (
    SELECT COALESCE(MAX(work_order_id), 0) FROM maintenance_work_order
);
INSERT INTO maintenance_work_order (
    work_order_no, alarm_id, work_order_type, maintainer_id,
    dispatch_time, accept_time, arrive_time, repair_finish_time, verify_time,
    work_order_status, repair_result, verify_result, verify_remark
)
SELECT
    CONCAT('C-SEED-WO-', LPAD(n, 4, '0')),
    @c_alarm_base + n,
    'REPAIR', 80000 + n,
    @c_seed_time - INTERVAL (n + IF(n <= 10, 3, -1)) HOUR,
    IF(n <= 10, @c_seed_time - INTERVAL (n + 2) HOUR, NULL),
    IF(n <= 10, @c_seed_time - INTERVAL (n + 1) HOUR, NULL),
    IF(n <= 10, @c_seed_time - INTERVAL n HOUR, NULL),
    IF(n <= 10, @c_seed_time - INTERVAL (n - 1) HOUR, NULL),
    IF(n <= 10, 'CLOSED', 'ASSIGNED'),
    IF(n <= 10, '更换故障模块并完成通电检查', NULL),
    IF(n <= 10, 'PASS', 'PENDING'),
    IF(n <= 10, '样例复核通过', NULL)
FROM c_seed_sequence;

SET @c_part_base := (SELECT COALESCE(MAX(spare_part_id), 0) FROM spare_part);
INSERT INTO spare_part (part_code, part_name, model, spec, unit, part_status)
SELECT
    CONCAT('C-SEED-PART-', LPAD(n, 4, '0')),
    CONCAT('C模块测试备件', LPAD(n, 2, '0')),
    CONCAT('MODEL-', LPAD(n, 3, '0')),
    CONCAT('SPEC-', LPAD(n, 3, '0')),
    '件', 'ACTIVE'
FROM c_seed_sequence;

SET @c_warehouse_base := (SELECT COALESCE(MAX(warehouse_id), 0) FROM warehouse);
INSERT INTO warehouse (warehouse_code, warehouse_name, location, warehouse_status)
SELECT
    CONCAT('C-SEED-WH-', LPAD(n, 4, '0')),
    CONCAT('C模块测试仓库', LPAD(n, 2, '0')),
    CONCAT('测试区域-', LPAD(n, 2, '0')),
    'ACTIVE'
FROM c_seed_sequence;

INSERT INTO inventory (warehouse_id, spare_part_id, quantity, locked_quantity)
SELECT @c_warehouse_base + n, @c_part_base + n, 0, 0
FROM c_seed_sequence;

SET @c_transaction_base := (
    SELECT COALESCE(MAX(transaction_id), 0) FROM inventory_transaction
);
UPDATE inventory AS i
JOIN c_seed_sequence AS seq ON i.warehouse_id = @c_warehouse_base + seq.n
                          AND i.spare_part_id = @c_part_base + seq.n
SET i.quantity = 20, i.version_no = i.version_no + 1;
INSERT INTO inventory_transaction (
    transaction_no, warehouse_id, spare_part_id, transaction_type,
    quantity_change, before_quantity, after_quantity, operator_id
)
SELECT
    CONCAT('C-SEED-TXN-', LPAD(n, 4, '0')),
    @c_warehouse_base + n, @c_part_base + n, 'RECEIPT',
    20, 0, 20, 81000 + n
FROM c_seed_sequence;

INSERT INTO work_order_part (
    work_order_id, spare_part_id, warehouse_id,
    planned_qty, issued_qty, installed_qty, returned_qty,
    part_usage_status, remark
)
SELECT
    @c_work_order_base + n, @c_part_base + n, @c_warehouse_base + n,
    2, 0, 0, 0, 'PLANNED', 'C模块测试计划，未领用'
FROM c_seed_sequence;

SELECT 'device_telemetry' AS table_name, COUNT(*) AS row_count FROM device_telemetry
UNION ALL SELECT 'alarm', COUNT(*) FROM alarm
UNION ALL SELECT 'maintenance_work_order', COUNT(*) FROM maintenance_work_order
UNION ALL SELECT 'spare_part', COUNT(*) FROM spare_part
UNION ALL SELECT 'warehouse', COUNT(*) FROM warehouse
UNION ALL SELECT 'inventory', COUNT(*) FROM inventory
UNION ALL SELECT 'inventory_transaction', COUNT(*) FROM inventory_transaction
UNION ALL SELECT 'work_order_part', COUNT(*) FROM work_order_part;

-- Review all eight counts before committing this seed transaction.
-- Run COMMIT manually when each table has at least 20 rows; otherwise ROLLBACK.
DROP TEMPORARY TABLE c_seed_sequence;
