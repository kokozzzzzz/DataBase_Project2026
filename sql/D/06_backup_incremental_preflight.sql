-- D 模块增量备份与时间点恢复前置检查
-- 适用环境：MySQL 8.0.46。
-- 安全：只读取全局变量，不修改服务器配置、日志或业务数据。

USE charging_platform;
SET NAMES utf8mb4;
SET SESSION time_zone = '+08:00';

SELECT
    VERSION() AS mysql_version,
    DATABASE() AS current_database,
    @@session.time_zone AS session_time_zone;

-- BI01：只有开启 binary log，才具备基于 binlog 的增量恢复条件。
SELECT
    'BI01 binary_log_enabled' AS check_item,
    @@global.log_bin AS actual_value,
    1 AS expected_value,
    IF(@@global.log_bin = 1, 'PASS', 'NEED_CONFIG') AS result;

-- BI02：ROW 能更完整地记录实际行变化，适合恢复和审计。
SELECT
    'BI02 binlog_format' AS check_item,
    @@global.binlog_format AS actual_value,
    'ROW' AS expected_value,
    IF(@@global.binlog_format = 'ROW', 'PASS', 'REVIEW') AS result;

-- BI03：server_id 必须为正值，便于日志和复制场景识别实例。
SELECT
    'BI03 server_id' AS check_item,
    @@global.server_id AS actual_value,
    '> 0' AS expected_value,
    IF(@@global.server_id > 0, 'PASS', 'NEED_CONFIG') AS result;

-- BI04：sync_binlog=1 是更耐故障的基线；其他值不阻止课程演练，但需说明风险。
SELECT
    'BI04 sync_binlog' AS check_item,
    @@global.sync_binlog AS actual_value,
    1 AS recommended_value,
    IF(@@global.sync_binlog = 1, 'PASS', 'REVIEW') AS result;

-- BI05：本项目要求至少保留7天日志，以覆盖日备份间的时间点恢复。
SELECT
    'BI05 binlog_retention_seconds' AS check_item,
    @@global.binlog_expire_logs_seconds AS actual_value,
    604800 AS minimum_value,
    CASE
        WHEN @@global.binlog_expire_logs_seconds = 0 THEN 'REVIEW'
        WHEN @@global.binlog_expire_logs_seconds >= 604800 THEN 'PASS'
        ELSE 'NEED_CONFIG'
    END AS result;

-- BI06：GTID不是本地单实例恢复的强制条件，只记录当前状态。
SELECT
    'BI06 gtid_mode' AS check_item,
    @@global.gtid_mode AS actual_value,
    'informational' AS expected_value,
    'INFO' AS result;

SELECT
    'PREFLIGHT COMPLETE: BI01～BI05 should be PASS or explicitly documented before incremental recovery.'
        AS final_instruction;
