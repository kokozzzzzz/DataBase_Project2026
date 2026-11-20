-- C-module business queries; each query joins at least three relations.
USE charging_platform;
SET SESSION time_zone = '+08:00';

-- Q01: station alarm pressure, latest sample and maintenance closure rate.
SELECT
    s.station_id,
    s.name AS station_name,
    a.alarm_level,
    COUNT(DISTINCT a.alarm_id) AS alarm_count,
    COUNT(DISTINCT CASE WHEN wo.work_order_status = 'CLOSED' THEN wo.work_order_id END)
        AS closed_work_order_count,
    MAX(t.collect_time) AS latest_sample_at
FROM alarm AS a
JOIN charging_pile AS p ON p.pile_id = a.pile_id
JOIN station AS s ON s.station_id = p.station_id
LEFT JOIN maintenance_work_order AS wo ON wo.alarm_id = a.alarm_id
LEFT JOIN device_telemetry AS t ON t.telemetry_id = a.source_telemetry_id
WHERE a.occur_time >= CURRENT_TIMESTAMP - INTERVAL 30 DAY
GROUP BY s.station_id, s.name, a.alarm_level
ORDER BY alarm_count DESC, s.station_id;

-- Q02: maintenance response, repair and verification durations by work order.
SELECT
    wo.work_order_id,
    wo.work_order_no,
    a.alarm_code,
    a.alarm_level,
    p.pile_id,
    s.name AS station_name,
    TIMESTAMPDIFF(MINUTE, wo.dispatch_time, wo.accept_time) AS dispatch_to_accept_min,
    TIMESTAMPDIFF(MINUTE, wo.accept_time, wo.arrive_time) AS accept_to_arrive_min,
    TIMESTAMPDIFF(MINUTE, wo.arrive_time, wo.repair_finish_time) AS repair_min,
    wo.work_order_status,
    wo.verify_result
FROM maintenance_work_order AS wo
JOIN alarm AS a ON a.alarm_id = wo.alarm_id
JOIN charging_pile AS p ON p.pile_id = a.pile_id
JOIN station AS s ON s.station_id = p.station_id
WHERE wo.dispatch_time >= CURRENT_TIMESTAMP - INTERVAL 90 DAY
ORDER BY wo.dispatch_time DESC, wo.work_order_id DESC;

-- Q03: correlate abnormal telemetry, active alarms and open work orders per device.
SELECT
    p.pile_id,
    s.name AS station_name,
    COUNT(DISTINCT CASE WHEN t.quality_flag = 'ABNORMAL' THEN t.telemetry_id END)
        AS abnormal_samples_24h,
    COUNT(DISTINCT CASE WHEN a.alarm_status IN ('OPEN', 'ACKNOWLEDGED') THEN a.alarm_id END)
        AS active_alarms,
    COUNT(DISTINCT CASE
        WHEN wo.work_order_status NOT IN ('CLOSED', 'CANCELLED') THEN wo.work_order_id
    END) AS active_work_orders,
    MAX(t.module_temp) AS max_module_temp
FROM charging_pile AS p
JOIN station AS s ON s.station_id = p.station_id
LEFT JOIN device_telemetry AS t
    ON t.pile_id = p.pile_id
   AND t.collect_time >= CURRENT_TIMESTAMP - INTERVAL 1 DAY
LEFT JOIN alarm AS a ON a.pile_id = p.pile_id
LEFT JOIN maintenance_work_order AS wo ON wo.alarm_id = a.alarm_id
GROUP BY p.pile_id, s.name
ORDER BY active_alarms DESC, abnormal_samples_24h DESC;

-- Q04: unresolved parts and stock sufficiency for active repair work.
SELECT
    wo.work_order_id,
    wo.work_order_no,
    a.alarm_code,
    s.name AS station_name,
    sp.part_code,
    sp.part_name,
    w.warehouse_name,
    wop.planned_qty,
    wop.issued_qty,
    wop.installed_qty,
    wop.returned_qty,
    wop.issued_qty - wop.installed_qty - wop.returned_qty AS unresolved_qty,
    i.quantity - i.locked_quantity AS available_qty
FROM work_order_part AS wop
JOIN maintenance_work_order AS wo ON wo.work_order_id = wop.work_order_id
JOIN alarm AS a ON a.alarm_id = wo.alarm_id
JOIN charging_pile AS p ON p.pile_id = a.pile_id
JOIN station AS s ON s.station_id = p.station_id
JOIN spare_part AS sp ON sp.spare_part_id = wop.spare_part_id
JOIN warehouse AS w ON w.warehouse_id = wop.warehouse_id
JOIN inventory AS i
    ON i.warehouse_id = wop.warehouse_id
   AND i.spare_part_id = wop.spare_part_id
WHERE wo.work_order_status NOT IN ('CLOSED', 'CANCELLED')
ORDER BY wo.dispatch_time, wo.work_order_id, sp.part_code;

-- Q05: inventory movement audit; positive values increase stock, negative values consume it.
SELECT
    w.warehouse_code,
    w.warehouse_name,
    sp.part_code,
    sp.part_name,
    i.quantity AS current_quantity,
    SUM(CASE WHEN it.transaction_type = 'RECEIPT' THEN it.quantity_change ELSE 0 END)
        AS received_30d,
    SUM(CASE WHEN it.transaction_type = 'ISSUE' THEN -it.quantity_change ELSE 0 END)
        AS issued_30d,
    SUM(CASE WHEN it.transaction_type = 'RETURN' THEN it.quantity_change ELSE 0 END)
        AS returned_30d,
    COUNT(DISTINCT wo.work_order_id) AS work_orders_using_part,
    SUM(CASE WHEN a.alarm_level IN ('HIGH', 'CRITICAL') THEN 1 ELSE 0 END)
        AS high_severity_movement_count
FROM inventory AS i
JOIN warehouse AS w ON w.warehouse_id = i.warehouse_id
JOIN spare_part AS sp ON sp.spare_part_id = i.spare_part_id
LEFT JOIN inventory_transaction AS it
    ON it.warehouse_id = i.warehouse_id
   AND it.spare_part_id = i.spare_part_id
   AND it.occurred_at >= CURRENT_TIMESTAMP - INTERVAL 30 DAY
LEFT JOIN maintenance_work_order AS wo ON wo.work_order_id = it.work_order_id
LEFT JOIN alarm AS a ON a.alarm_id = wo.alarm_id
GROUP BY
    w.warehouse_code, w.warehouse_name, sp.part_code, sp.part_name, i.quantity
ORDER BY issued_30d DESC, w.warehouse_code, sp.part_code;

-- Q06: maintenance consumption by station, alarm severity and spare part.
SELECT
    s.station_id,
    s.name AS station_name,
    a.alarm_level,
    sp.part_code,
    sp.part_name,
    SUM(wop.issued_qty) AS issued_quantity,
    SUM(wop.installed_qty) AS installed_quantity,
    SUM(wop.returned_qty) AS returned_quantity,
    SUM(wop.issued_qty - wop.installed_qty - wop.returned_qty) AS unresolved_quantity,
    COUNT(DISTINCT wo.work_order_id) AS work_order_count
FROM work_order_part AS wop
JOIN maintenance_work_order AS wo ON wo.work_order_id = wop.work_order_id
JOIN alarm AS a ON a.alarm_id = wo.alarm_id
JOIN charging_pile AS p ON p.pile_id = a.pile_id
JOIN station AS s ON s.station_id = p.station_id
JOIN spare_part AS sp ON sp.spare_part_id = wop.spare_part_id
GROUP BY s.station_id, s.name, a.alarm_level, sp.part_code, sp.part_name
ORDER BY issued_quantity DESC, s.station_id, sp.part_code;

-- Run these plans against representative data and retain output with the test record:
-- EXPLAIN ANALYZE SELECT * FROM v_c_alarm_board WHERE alarm_status IN ('OPEN','ACKNOWLEDGED');
-- EXPLAIN ANALYZE SELECT * FROM v_c_inventory_available WHERE available_quantity < 5;
-- EXPLAIN ANALYZE SELECT * FROM v_c_inventory_turnover_30d;
