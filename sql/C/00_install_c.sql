-- 已有B/D、C尚未建表时补装C。推荐python -m app.run_sql --file sql/C/00_install_c.sql，首错停止。
USE charging_platform;
DROP PROCEDURE IF EXISTS tmp_c_install_guard;
DELIMITER $$
CREATE PROCEDURE tmp_c_install_guard()
BEGIN
    IF EXISTS(SELECT 1 FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE()
        AND TABLE_NAME IN ('device_telemetry','alarm','maintenance_work_order','spare_part',
        'warehouse','inventory','inventory_transaction','work_order_part')) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='C表已存在，请核对进度或执行09过程升级';
    END IF;
    IF (SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE()
        AND TABLE_NAME IN ('charging_pile','charging_gun','equipment_status_log',
            'equipment_offline_task','equipment_outage_plan'))<>5 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT='B设备依赖不完整';
    END IF;
END$$
DELIMITER ;
CALL tmp_c_install_guard();
DROP PROCEDURE tmp_c_install_guard;
SOURCE sql/C/01_schema.sql;
SOURCE sql/C/02_triggers.sql;
SOURCE sql/C/03_procedures.sql;
SOURCE sql/C/04_views.sql;
