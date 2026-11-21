-- A ⑥⑧ 结构补装：仅当 A 的 10 张表全部不存在时使用。
--
-- 典型场景：D/B 已安装，但 sql/A/07_verify.sql 显示 A 表、视图、过程、触发器均为 0。
-- 注意：07_verify.sql 是只读验收脚本，本身不会创建任何对象。
--
-- 前置（必须已存在）：
--   D ④：user、vehicle
--   B ① ②：station、charging_pile、charging_gun、parking_space、
--           equipment_outage_plan、charging_order
-- 若前置不满足，脚本会中止并提示；可先执行 sql/A/00_preflight.sql 定位缺项。
--
-- 运行方式（必须在仓库根目录，SOURCE 路径按客户端当前目录解析）：
--   mysql -h127.0.0.1 -P3306 -uroot -p --default-character-set=utf8mb4 < sql/A/00_install_a.sql
-- 或在 mysql 客户端中：
--   SOURCE sql/A/00_install_a.sql;
--
-- 本脚本只安装结构，不插入 A 的测试数据。
-- 需要 A 本地种子时，再执行 sql/00_seed_all.sql 或按 sql/A/README.md 的顺序执行。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

DROP PROCEDURE IF EXISTS tmp_install_a_guard;
DELIMITER $$
CREATE PROCEDURE tmp_install_a_guard()
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_NAME IN (
              'charging_reservation', 'reservation_status_log',
              'queue_record', 'queue_status_log',
              'arrival_checkin', 'parking_occupancy',
              'station_notice', 'notice_revision',
              'notice_recipient', 'notification_record'
          )
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'A 表已存在：00_install_a 只用于 A 表全为 0 的库。请先核对，不要重复建表。';
    END IF;

    IF (
        SELECT COUNT(*)
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_TYPE = 'BASE TABLE'
          AND TABLE_NAME IN (
              'user', 'vehicle',
              'station', 'charging_pile', 'charging_gun', 'parking_space',
              'equipment_outage_plan', 'charging_order'
          )
    ) < 8 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = '缺少 D/B 前置表：请先安装 D 核心与 B 正式结构，或运行 sql/A/00_preflight.sql 查看缺项。';
    END IF;
END$$
DELIMITER ;
CALL tmp_install_a_guard();
DROP PROCEDURE tmp_install_a_guard;

SOURCE sql/A/01_schema.sql;
SOURCE sql/A/02_triggers.sql;
SOURCE sql/A/03_procedures.sql;
SOURCE sql/A/04_views.sql;

SELECT 'install_a' AS stage,
       'A structure installation completed: 10 tables / 13 triggers / 14 procedures / 8 views expected' AS result;
SELECT 'next' AS stage,
       'run SOURCE sql/A/07_verify.sql; to load A seed data run SOURCE sql/00_seed_all.sql' AS instruction;
