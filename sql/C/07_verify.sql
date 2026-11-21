-- Read-only structural and data-integrity checks for C.
USE charging_platform;

SELECT
    expected.object_type,
    expected.expected_count,
    actual.actual_count,
    IF(actual.actual_count = expected.expected_count, 'PASS', 'FAIL') AS result
FROM (
    SELECT 'C_TABLES' AS object_type, 8 AS expected_count
    UNION ALL SELECT 'C_VIEWS', 6
    UNION ALL SELECT 'C_PROCEDURES', 12
    UNION ALL SELECT 'C_TRIGGERS', 8
) AS expected
JOIN (
    SELECT 'C_TABLES' AS object_type, COUNT(*) AS actual_count
    FROM information_schema.tables
    WHERE table_schema = DATABASE()
      AND table_type = 'BASE TABLE'
      AND table_name IN (
          'device_telemetry', 'alarm', 'maintenance_work_order', 'spare_part',
          'warehouse', 'inventory', 'inventory_transaction', 'work_order_part'
      )
    UNION ALL
    SELECT 'C_VIEWS', COUNT(*)
    FROM information_schema.views
    WHERE table_schema = DATABASE()
      AND LEFT(table_name, 4) = 'v_c_'
    UNION ALL
    SELECT 'C_PROCEDURES', COUNT(*)
    FROM information_schema.routines
    WHERE routine_schema = DATABASE()
      AND routine_type = 'PROCEDURE'
      AND LEFT(routine_name, 5) = 'sp_c_'
    UNION ALL
    SELECT 'C_TRIGGERS', COUNT(*)
    FROM information_schema.triggers
    WHERE trigger_schema = DATABASE()
      AND LEFT(trigger_name, 2) = 'c_'
) AS actual USING (object_type);

SELECT table_name, table_rows AS estimated_rows
FROM information_schema.tables
WHERE table_schema = DATABASE()
  AND table_name IN (
      'device_telemetry', 'alarm', 'maintenance_work_order', 'spare_part',
      'warehouse', 'inventory', 'inventory_transaction', 'work_order_part'
  )
ORDER BY table_name;

SELECT 'inventory_available_not_negative' AS check_name,
       COUNT(*) AS failure_count,
       IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM inventory
WHERE locked_quantity > quantity;

SELECT 'work_order_parts_reconciled_when_closed' AS check_name,
       COUNT(*) AS failure_count,
       IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM work_order_part AS wop
JOIN maintenance_work_order AS wo ON wo.work_order_id = wop.work_order_id
WHERE wo.work_order_status = 'CLOSED'
  AND wop.issued_qty <> wop.installed_qty + wop.returned_qty;

SELECT 'inventory_quantity_matches_ledger' AS check_name,
       COUNT(*) AS failure_count,
       IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM inventory AS i
LEFT JOIN (
    SELECT warehouse_id, spare_part_id, SUM(quantity_change) AS net_change
    FROM inventory_transaction
    GROUP BY warehouse_id, spare_part_id
) AS ledger
  ON ledger.warehouse_id = i.warehouse_id
 AND ledger.spare_part_id = i.spare_part_id
WHERE i.quantity <> COALESCE(ledger.net_change, 0);

SELECT 'telemetry_and_alarm_reference_existing_devices' AS check_name,
       COUNT(*) AS failure_count,
       IF(COUNT(*) = 0, 'PASS', 'FAIL') AS result
FROM (
    SELECT t.telemetry_id
    FROM device_telemetry AS t
    LEFT JOIN charging_pile AS p ON p.pile_id = t.pile_id
    LEFT JOIN charging_gun AS g ON g.gun_id = t.gun_id
    WHERE p.pile_id IS NULL OR (t.gun_id IS NOT NULL AND g.pile_id <> t.pile_id)
    UNION ALL
    SELECT a.alarm_id
    FROM alarm AS a
    LEFT JOIN charging_pile AS p ON p.pile_id = a.pile_id
    LEFT JOIN charging_gun AS g ON g.gun_id = a.gun_id
    WHERE p.pile_id IS NULL OR (a.gun_id IS NOT NULL AND g.pile_id <> a.pile_id)
) AS broken_device_reference;

SELECT
    transaction_id,
    transaction_no,
    warehouse_id,
    spare_part_id,
    transaction_type,
    quantity_change,
    before_quantity,
    after_quantity,
    occurred_at
FROM inventory_transaction
ORDER BY transaction_id DESC
LIMIT 20;
