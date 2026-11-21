USE charging_platform;

CREATE OR REPLACE
SQL SECURITY INVOKER
VIEW v_c_alarm_board AS
SELECT
    a.alarm_id,
    a.pile_id,
    a.gun_id,
    s.station_id,
    s.name AS station_name,
    a.alarm_code,
    a.alarm_level,
    a.alarm_status,
    a.occur_time,
    a.recover_time,
    a.recover_verify_status,
    COUNT(DISTINCT wo.work_order_id) AS work_order_count,
    MAX(wo.dispatch_time) AS latest_dispatch_time,
    MAX(t.collect_time) AS latest_telemetry_time
FROM alarm AS a
JOIN charging_pile AS p ON p.pile_id = a.pile_id
JOIN station AS s ON s.station_id = p.station_id
LEFT JOIN maintenance_work_order AS wo ON wo.alarm_id = a.alarm_id
LEFT JOIN device_telemetry AS t
    ON t.pile_id = a.pile_id
   AND (a.gun_id IS NULL OR t.gun_id = a.gun_id)
GROUP BY
    a.alarm_id, a.pile_id, a.gun_id, s.station_id, s.name,
    a.alarm_code, a.alarm_level, a.alarm_status,
    a.occur_time, a.recover_time, a.recover_verify_status;

CREATE OR REPLACE
SQL SECURITY INVOKER
VIEW v_c_work_order_queue AS
SELECT
    wo.work_order_id,
    wo.work_order_no,
    wo.work_order_type,
    wo.work_order_status,
    wo.maintainer_id,
    wo.dispatch_time,
    wo.accept_time,
    wo.arrive_time,
    wo.repair_finish_time,
    a.alarm_id,
    a.alarm_code,
    a.alarm_level,
    a.pile_id,
    a.gun_id,
    s.station_id,
    s.name AS station_name,
    TIMESTAMPDIFF(MINUTE, wo.dispatch_time, COALESCE(wo.repair_finish_time, CURRENT_TIMESTAMP))
        AS elapsed_minutes
FROM maintenance_work_order AS wo
JOIN alarm AS a ON a.alarm_id = wo.alarm_id
JOIN charging_pile AS p ON p.pile_id = a.pile_id
JOIN station AS s ON s.station_id = p.station_id;

CREATE OR REPLACE
SQL SECURITY INVOKER
VIEW v_c_device_health_24h AS
SELECT
    p.pile_id,
    p.station_id,
    s.name AS station_name,
    p.status AS pile_status,
    t.last_collect_time,
    t.max_offline_duration_sec,
    t.average_power_kw,
    t.max_module_temp,
    COALESCE(t.abnormal_samples, 0) AS abnormal_samples,
    COALESCE(a.active_alarm_count, 0) AS active_alarm_count,
    COALESCE(a.open_work_order_count, 0) AS open_work_order_count
FROM charging_pile AS p
JOIN station AS s ON s.station_id = p.station_id
LEFT JOIN (
    SELECT
        pile_id,
        MAX(collect_time) AS last_collect_time,
        MAX(offline_duration_sec) AS max_offline_duration_sec,
        AVG(power) AS average_power_kw,
        MAX(module_temp) AS max_module_temp,
        SUM(quality_flag = 'ABNORMAL') AS abnormal_samples
    FROM device_telemetry
    WHERE collect_time >= CURRENT_TIMESTAMP - INTERVAL 1 DAY
    GROUP BY pile_id
) AS t ON t.pile_id = p.pile_id
LEFT JOIN (
    SELECT
        a.pile_id,
        SUM(a.alarm_status IN ('OPEN', 'ACKNOWLEDGED')) AS active_alarm_count,
        COUNT(DISTINCT CASE
            WHEN wo.work_order_status NOT IN ('CLOSED', 'CANCELLED') THEN wo.work_order_id
        END) AS open_work_order_count
    FROM alarm AS a
    LEFT JOIN maintenance_work_order AS wo ON wo.alarm_id = a.alarm_id
    GROUP BY a.pile_id
) AS a ON a.pile_id = p.pile_id;

CREATE OR REPLACE
SQL SECURITY INVOKER
VIEW v_c_inventory_available AS
SELECT
    i.inventory_id,
    w.warehouse_id,
    w.warehouse_code,
    w.warehouse_name,
    sp.spare_part_id,
    sp.part_code,
    sp.part_name,
    sp.model,
    sp.unit,
    i.quantity,
    i.locked_quantity,
    i.quantity - i.locked_quantity AS available_quantity,
    i.version_no,
    i.updated_at
FROM inventory AS i
JOIN warehouse AS w ON w.warehouse_id = i.warehouse_id
JOIN spare_part AS sp ON sp.spare_part_id = i.spare_part_id;

CREATE OR REPLACE
SQL SECURITY INVOKER
VIEW v_c_work_order_part_reconciliation AS
SELECT
    wo.work_order_id,
    wo.work_order_no,
    wo.work_order_status,
    a.alarm_id,
    a.alarm_code,
    a.pile_id,
    sp.spare_part_id,
    sp.part_code,
    sp.part_name,
    w.warehouse_id,
    w.warehouse_name,
    wop.planned_qty,
    wop.issued_qty,
    wop.installed_qty,
    wop.returned_qty,
    wop.issued_qty - wop.installed_qty - wop.returned_qty AS unresolved_quantity,
    wop.part_usage_status
FROM work_order_part AS wop
JOIN maintenance_work_order AS wo ON wo.work_order_id = wop.work_order_id
JOIN alarm AS a ON a.alarm_id = wo.alarm_id
JOIN spare_part AS sp ON sp.spare_part_id = wop.spare_part_id
JOIN warehouse AS w ON w.warehouse_id = wop.warehouse_id;

CREATE OR REPLACE
SQL SECURITY INVOKER
VIEW v_c_inventory_turnover_30d AS
SELECT
    w.warehouse_id,
    w.warehouse_name,
    sp.spare_part_id,
    sp.part_code,
    sp.part_name,
    i.quantity AS current_quantity,
    i.locked_quantity,
    SUM(CASE WHEN it.transaction_type = 'RECEIPT' THEN it.quantity_change ELSE 0 END)
        AS received_quantity_30d,
    SUM(CASE WHEN it.transaction_type = 'ISSUE' THEN -it.quantity_change ELSE 0 END)
        AS issued_quantity_30d,
    SUM(CASE WHEN it.transaction_type = 'RETURN' THEN it.quantity_change ELSE 0 END)
        AS returned_quantity_30d,
    COUNT(it.transaction_id) AS transaction_count_30d
FROM inventory AS i
JOIN warehouse AS w ON w.warehouse_id = i.warehouse_id
JOIN spare_part AS sp ON sp.spare_part_id = i.spare_part_id
LEFT JOIN inventory_transaction AS it
    ON it.warehouse_id = i.warehouse_id
   AND it.spare_part_id = i.spare_part_id
   AND it.occurred_at >= CURRENT_TIMESTAMP - INTERVAL 30 DAY
GROUP BY
    w.warehouse_id, w.warehouse_name, sp.spare_part_id,
    sp.part_code, sp.part_name, i.quantity, i.locked_quantity;
