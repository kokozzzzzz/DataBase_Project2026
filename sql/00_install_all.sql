-- 全组首次安装：charging_platform 结构（仅用于空库）
-- 适用：刚创建的空库，或只有空数据库、尚无任何业务表的实例。
-- 不适用：已有 D/B/A 对象的库。已有库请只补装缺失模块；
--         仅 A 未安装时执行 sql/A/00_install_a.sql。
--
-- 推荐从仓库根目录运行（先配置.env，mysql.exe需为8.0客户端）：
--   python -m app.run_sql --file sql/00_install_all.sql
-- mysql不在PATH时增加 --mysql "完整路径"；展开SOURCE后批处理，首错停止。
--
-- 本脚本只安装结构，不插入业务测试数据。
-- 需要 D/A 本地种子时，再执行 sql/00_seed_all.sql。
-- 综合验收执行 sql/00_verify_all.sql。

CREATE DATABASE IF NOT EXISTS charging_platform
  DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

-- 空库守卫：检测到任一模块的表就中止，避免重复 CREATE 或半途失败。
DROP PROCEDURE IF EXISTS tmp_install_all_guard;
DELIMITER $$
CREATE PROCEDURE tmp_install_all_guard()
BEGIN
    IF EXISTS (
        SELECT 1
        FROM information_schema.TABLES
        WHERE TABLE_SCHEMA = DATABASE()
          AND TABLE_TYPE='BASE TABLE'
    ) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = '00_install_all 只用于空库：检测到已有表。已有库请只补装缺失模块；A 未安装时执行 sql/A/00_install_a.sql。';
    END IF;
END$$
DELIMITER ;
CALL tmp_install_all_guard();
DROP PROCEDURE tmp_install_all_guard;

-- ---------------------------------------------------------------------------
-- 1) D ④ 核心表
-- ---------------------------------------------------------------------------
SOURCE sql/D/04_membership_core.sql;

-- ---------------------------------------------------------------------------
-- 2) B ① ② 正式结构、设施触发器、查询视图、交易保护触发器
-- ---------------------------------------------------------------------------
SOURCE sql/B/01_schema.sql;
SOURCE sql/B/02_structure_triggers.sql;
SOURCE sql/B/03_views.sql;
SOURCE sql/B/05_transaction_guards.sql;

-- ---------------------------------------------------------------------------
-- 3) D ④ 跨模块表（依赖 B 的 station、charging_order）
-- ---------------------------------------------------------------------------
SOURCE sql/D/04_membership_integration.sql;

-- ---------------------------------------------------------------------------
-- 4) A ⑥ ⑧ 结构、触发器、存储过程、视图
--    依赖 D 的 user/vehicle 与 B 的 station/charging_gun/parking_space/
--    equipment_outage_plan/charging_order
-- ---------------------------------------------------------------------------
SOURCE sql/A/01_schema.sql;
SOURCE sql/A/02_triggers.sql;
SOURCE sql/A/03_procedures.sql;
SOURCE sql/A/04_views.sql;

-- ---------------------------------------------------------------------------
-- 5) D ④ 视图/过程、D ⑤ 结算五表
-- ---------------------------------------------------------------------------
SOURCE sql/D/04_membership_views.sql;
SOURCE sql/D/04_membership_procedure.sql;
SOURCE sql/D/05_settlement_schema.sql;
SOURCE sql/D/05_settlement_views.sql;

-- C ③⑦结构，依赖B设备主数据；过程参与调用方事务。
SOURCE sql/C/01_schema.sql;
SOURCE sql/C/02_triggers.sql;
SOURCE sql/C/03_procedures.sql;
SOURCE sql/C/04_views.sql;

SELECT 'install_all' AS stage,
       'structure installation completed' AS result;
SELECT 'next' AS stage,
       'optional seed: SOURCE sql/00_seed_all.sql; verify: SOURCE sql/00_verify_all.sql; D settlement data: python -m app.seed_b_integration --commit' AS instruction;
