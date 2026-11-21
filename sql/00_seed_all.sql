-- 全组本地联调种子：D ④ 核心 20 行 + A 夹具 + A 10 表各 ≥20 行
--
-- 前提：已执行 sql/00_install_all.sql（或等价的 D/B/A 结构安装）。
-- 不要重复执行：脚本会检测 D/A 的固定种子编号，已存在时中止。
--
-- 运行方式（必须在仓库根目录，SOURCE 路径按客户端当前目录解析）：
--   mysql -h127.0.0.1 -P3306 -uroot -p --default-character-set=utf8mb4 < sql/00_seed_all.sql
-- 或在 mysql 客户端中：
--   SOURCE sql/00_seed_all.sql;
--
-- 说明：A 的 00_local_shared_fixtures.sql 仅用于本地联调；B 正式种子可用时，
--       以 B 的固定测试集替代 A 的场站/枪/车位夹具，不影响 A 的表结构与业务规则。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

DROP PROCEDURE IF EXISTS tmp_seed_all_guard;
DELIMITER $$
CREATE PROCEDURE tmp_seed_all_guard()
BEGIN
    IF (
        SELECT COUNT(*)
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_TYPE = 'BASE TABLE'
          AND TABLE_NAME IN ('user', 'vehicle', 'station', 'charging_reservation')
    ) < 4 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = '缺少 D/B/A 结构：请先执行 sql/00_install_all.sql，或按模块安装齐 user/vehicle/station/charging_reservation。';
    END IF;

    IF EXISTS (SELECT 1 FROM `user` WHERE user_id BETWEEN 10001 AND 10020)
       OR EXISTS (SELECT 1 FROM station WHERE station_id BETWEEN 9101 AND 9104)
       OR EXISTS (SELECT 1 FROM charging_reservation WHERE reservation_id BETWEEN 1001 AND 1020)
    THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = '检测到 D/A 固定种子编号：00_seed_all 不可重复执行。请核对现有数据。';
    END IF;
END$$
DELIMITER ;
CALL tmp_seed_all_guard();
DROP PROCEDURE tmp_seed_all_guard;

-- ---------------------------------------------------------------------------
-- 1) D ④ 核心种子：user 10001–10020、vehicle 20001–20020 等 9 表各 20 行
--    脚本故意不 COMMIT；下方 COMMIT 前会打印行数统计。
-- ---------------------------------------------------------------------------
SOURCE sql/D/04_membership_seed_core.sql;
COMMIT;

-- ---------------------------------------------------------------------------
-- 2) A 本地共享夹具：4 场站、20 枪、20 车位、20 停运计划（脚本自行 COMMIT）
-- ---------------------------------------------------------------------------
SOURCE sql/A/00_local_shared_fixtures.sql;

-- ---------------------------------------------------------------------------
-- 3) A 10 表测试数据：脚本故意不 COMMIT；下方 COMMIT 前会打印行数统计。
-- ---------------------------------------------------------------------------
SOURCE sql/A/05_seed.sql;
COMMIT;

SELECT 'seed_all' AS stage, 'D/A test data committed' AS result;
