USE charging_platform;
SET SESSION time_zone = '+08:00';
CREATE SQL SECURITY INVOKER VIEW v_b_gun_availability AS
SELECT g.gun_id,g.gun_no,g.gun_type,g.parking_space_id,g.station_id,p.pile_id,
 CASE WHEN s.status='CLOSED' OR p.commissioned_on IS NULL OR
     (HOUR(NOW())*60+MINUTE(NOW())) NOT BETWEEN s.opens_minute AND s.closes_minute-1
     THEN 'CLOSED'
  WHEN p.status<>'READY' THEN p.status WHEN g.status<>'READY' THEN g.status
  WHEN EXISTS(SELECT 1 FROM equipment_outage_plan x WHERE x.station_id=s.station_id
        AND (x.gun_id IS NULL OR x.gun_id=g.gun_id) AND x.status='SCHEDULED'
        AND x.starts_at<=NOW() AND x.ends_at>NOW()) THEN 'OUTAGE'
  WHEN o.order_id IS NOT NULL THEN 'OCCUPIED' ELSE 'READY' END AS device_availability
FROM charging_gun g JOIN charging_pile p ON p.pile_id=g.pile_id
 JOIN station s ON s.station_id=p.station_id LEFT JOIN charging_order o ON o.active_gun_id=g.gun_id;
CREATE SQL SECURITY INVOKER VIEW v_b_pile_warranty AS
SELECT p.pile_id,p.station_id,s.name AS station_name,p.serial_no,p.warranty_until,
 DATEDIFF(p.warranty_until,CURRENT_DATE) AS days_to_expiry
FROM charging_pile p JOIN station s ON s.station_id=p.station_id
WHERE p.warranty_until<=CURRENT_DATE+INTERVAL 30 DAY;
CREATE SQL SECURITY INVOKER VIEW v_b_equipment_history AS
SELECT l.log_id,COALESCE(p.station_id,g.station_id) AS station_id,
 l.pile_id,l.gun_id,l.old_status,l.new_status,l.changed_at
FROM equipment_status_log l LEFT JOIN charging_pile p ON p.pile_id=l.pile_id
 LEFT JOIN charging_gun g ON g.gun_id=l.gun_id;
CREATE SQL SECURITY INVOKER VIEW v_b_active_order AS
SELECT o.order_id,o.user_id,o.vehicle_id,o.gun_id,o.starts_at,g.station_id
FROM charging_order o JOIN charging_gun g ON g.gun_id=o.gun_id WHERE o.state='ACTIVE';
CREATE SQL SECURITY INVOKER VIEW v_b_fee_segment AS
SELECT f.fee_id,f.order_id,g.station_id,b.label,f.starts_at,f.ends_at,f.kwh,
 f.energy_price,f.service_price,f.energy_amount,f.service_amount
FROM order_fee_detail f JOIN tariff_band b ON b.band_id=f.band_id
 JOIN charging_order o ON o.order_id=f.order_id JOIN charging_gun g ON g.gun_id=o.gun_id;
CREATE SQL SECURITY INVOKER VIEW v_b_order_funds AS
SELECT o.order_id,o.user_id,g.station_id,s.operator_id,o.state,o.starts_at,o.ends_at,o.confirmed_at,o.total_kwh,
 o.gross_amount,o.discount_amount,o.gross_amount-o.discount_amount AS payable,
 COALESCE(p.paid,0) AS paid,COALESCE(r.refunded,0) AS refunded,
 COALESCE(p.paid,0)-COALESCE(r.refunded,0) AS net_received,
 o.review_reason
FROM charging_order o JOIN charging_gun g ON g.gun_id=o.gun_id JOIN station s ON s.station_id=g.station_id
LEFT JOIN (SELECT order_id,SUM(amount) AS paid FROM payment_record WHERE status='SUCCESS' GROUP BY order_id) p
 ON p.order_id=o.order_id
LEFT JOIN (SELECT p.order_id,SUM(r.amount) AS refunded FROM payment_record p JOIN refund_record r
 ON r.payment_id=p.payment_id GROUP BY p.order_id) r ON r.order_id=o.order_id;
