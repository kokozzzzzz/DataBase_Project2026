# D 模块权限与备份恢复方案

## 1. 安全目标

- 账号、角色和密码不写入业务表，不在 Git 中提交真实密码。
- ④运营、⑤结算和只读报表职责分离。
- 业务角色不拥有 `DELETE`、`DROP`、`ALTER`、`CREATE`、`TRIGGER`、`FILE` 或转授权权限。
- 手机号、车牌、信用代码和税号只保存密文或摘要；只读角色不能访问这些列。
- 数据恢复先进入隔离库，验收通过后再由管理员决定是否切换，禁止直接覆盖 `charging_platform`。

## 2. 角色矩阵

| 角色 | 用途 | 允许 | 明确禁止 |
| --- | --- | --- | --- |
| `cp_d_reporting` | 课程演示、运营看板、审计查询 | 6个脱敏视图及其必要安全列 `SELECT` | 敏感列、所有写入、结构变更 |
| `cp_d_membership_operator` | ④可信 Python 服务 | D④表 `SELECT/INSERT/UPDATE`、订单优惠列更新、优惠试算过程 | D⑤写入、物理删除、账号管理 |
| `cp_d_settlement_operator` | ⑤可信 Python 服务 | D⑤表 `SELECT/INSERT/UPDATE`、B交易事实只读、结算生成过程 | D④写入、物理删除、账号管理 |

角色脚本不创建具体登录账号。部署时由管理员在本机单独创建账号，再分配角色并设置默认角色。真实账号名和密码不得写进仓库。

## 3. 安装和验收

角色创建会修改 MySQL 权限元数据，但不会修改业务表。确认使用管理员账号后，在仓库根目录执行：

```powershell
.\.venv\Scripts\python.exe -m app.run_sql `
  --file sql/D/06_security_roles.sql `
  --admin `
  --commit

.\.venv\Scripts\python.exe -m app.run_sql `
  --file sql/D/06_security_roles_verify.sql `
  --admin
```

预期 `R01～R07` 全部为 `PASS`。验收脚本末尾会显示三个角色的实际授权，重点确认没有 `DELETE`、DDL权限和 `WITH GRANT OPTION`。

如果课程演示不要求创建真实登录账号，可以只保留角色，不创建用户。需要账号时由管理员交互式执行，密码不要出现在命令历史或脚本中。

## 4. 备份策略

课程设计环境采用以下目标：

- 每次执行安装、升级或正式种子脚本前做一次全量备份。
- 开发期间每个工作日结束做一次全量备份；重要联调完成后追加一次里程碑备份。
- 增量恢复依赖 MySQL binary log：使用 `ROW` 格式持续记录变更，每4小时确认并归档新的 binlog 文件及起止位置。
- 日常目标 RPO 不超过4小时；若 binlog 连续可用，可恢复到指定事务前的时间点。恢复目标 RTO 为60分钟以内。
- 日备份保留7份，里程碑备份至少保留到课程验收结束。
- binlog 至少保留7天，且不能早于对应全量备份；删除或清理日志必须由管理员按保留策略执行，本项目脚本不自动清理。
- 备份文件含个人信息密文和业务数据，应放在受限目录；对外提交前使用加密压缩或只提交虚构测试数据。
- 数据库全量备份不包含 MySQL 账号和角色；角色通过 `06_security_roles.sql` 重建。

在声称支持增量恢复前，使用管理员账号执行只读预检：

```powershell
.\.venv\Scripts\python.exe -m app.run_sql `
  --file sql/D/06_backup_incremental_preflight.sql `
  --admin
```

`BI01～BI05` 应为 `PASS`。若显示 `NEED_CONFIG` 或 `REVIEW`，只记录差异并由管理员评估 MySQL 配置；不要在业务脚本中动态修改全局日志参数。

时间点恢复顺序为：恢复最近一次全量备份到全新的隔离库，核对备份记录中的 binlog 文件和位置，再用 `mysqlbinlog` 截取目标时间范围并回放，最后运行 `06_restore_verify.sql`。禁止直接在 `charging_platform` 上试演增量回放。

## 5. 创建全量备份

以下 PowerShell 命令不会覆盖已有文件：

```powershell
$dBackupDirectory = 'D:\Desktop'

if (-not (Test-Path -LiteralPath $dBackupDirectory -PathType Container)) {
    throw "备份目录不存在，请改为本机实际存在的受限目录。"
}

$dFullBackupPath = Join-Path $dBackupDirectory `
  "charging_platform_$(Get-Date -Format 'yyyyMMdd_HHmmss').sql"

if (Test-Path -LiteralPath $dFullBackupPath) {
    throw "备份文件已存在，请更换文件名。"
}

mysqldump -u root -p `
  --host=127.0.0.1 `
  --port=3306 `
  --single-transaction `
  --routines `
  --triggers `
  --events `
  --hex-blob `
  --no-tablespaces `
  --set-gtid-purged=OFF `
  --default-character-set=utf8mb4 `
  --result-file="$dFullBackupPath" `
  charging_platform

if ($LASTEXITCODE -ne 0) {
    throw "mysqldump执行失败。"
}

Get-Item -LiteralPath $dFullBackupPath |
  Select-Object FullName, Length, LastWriteTime
Get-FileHash -LiteralPath $dFullBackupPath -Algorithm SHA256
```

成功标准：退出码为0、文件长度大于0，并保存文件大小、时间和 SHA-256 摘要作为验收证据。

## 6. 隔离恢复演练

恢复演练不能使用原库名。先确认候选测试库不存在；如果已经存在，请换一个新名字，不要执行 `DROP DATABASE`：

```powershell
mysql -u root -p --execute="
SELECT SCHEMA_NAME
FROM information_schema.SCHEMATA
WHERE SCHEMA_NAME = 'charging_platform_restore_test';"
```

结果为空后，创建隔离库：

```powershell
mysql -u root -p --execute="
CREATE DATABASE charging_platform_restore_test
  DEFAULT CHARACTER SET utf8mb4
  COLLATE utf8mb4_0900_ai_ci;"
```

保持当前 PowerShell 窗口中的 `$dFullBackupPath` 指向刚才生成的备份，然后恢复。`SOURCE` 使用正斜杠路径：

```powershell
$dBackupSourcePath = $dFullBackupPath.Replace('\', '/')

mysql -u root -p `
  --database=charging_platform_restore_test `
  --execute="SOURCE $dBackupSourcePath;"

if ($LASTEXITCODE -ne 0) {
    throw "隔离库恢复失败。"
}
```

## 7. 恢复结果验收

连接隔离库执行专用只读脚本：

```powershell
mysql -u root -p `
  --database=charging_platform_restore_test `
  --execute="SOURCE D:/Desktop/乱七八糟/SQL_experiment/课设/DataBase_Project2026/sql/D/06_restore_verify.sql;"
```

预期 `B01～B05` 全部为 `PASS`，覆盖：

- 当前数据库不是正式开发库；
- D的17张表、6个视图和2个过程齐全；
- 17张表均至少20行；
- 车队有效归属、会员等级和净开票金额不变量成立。

验收通过后，记录恢复开始时间、结束时间、文件摘要和检查结果。课程演练完成后是否删除隔离库应由组长确认，本方案不自动删除任何数据库。

## 8. 故障排查

- `Access denied`：确认执行角色脚本和恢复操作的是管理员账号，不要扩大应用账号权限。
- `PROCESS privilege` 或表空间错误：确认备份命令包含 `--no-tablespaces`。
- 过程或触发器缺失：确认备份命令包含 `--routines --triggers --events`。
- 中文乱码：备份和恢复均使用 `utf8mb4`，数据库排序规则应为 `utf8mb4_0900_ai_ci`。
- 恢复时对象已存在：说明测试库不是空库。更换新的隔离库名，不要清空或覆盖原库。
- `B01` 失败：当前连接仍指向 `charging_platform`，立即停止恢复验收并切换到隔离库。

## 9. 实际演练记录

2026-11-23 在 MySQL 8.0.46、Windows 11 环境完成一次全量备份和隔离恢复：

| 项目 | 实测结果 |
| --- | --- |
| 备份文件 | `charging_platform_20261123_193427.sql` |
| 文件大小 | 439,400 字节 |
| SHA-256 | `A1AC4DAE013DA7A3D35450B905EBEE34635EDB761C34EE87232FE96CD0B9D579` |
| 隔离恢复库 | `charging_platform_restore_20261123_193734` |
| 恢复耗时 | 约 7.90 秒 |
| 权限验收 | `R01～R07` 全部 `PASS` |
| 恢复验收 | `B01～B05` 全部 `PASS` |

隔离恢复库未覆盖正式开发库，演练完成后也未自动删除，符合本项目的数据库安全约定。

2026-11-27 使用 `06_backup_incremental_preflight.sql` 完成增量恢复条件检查：

| 检查项 | 实测值 | 结论 |
| --- | --- | --- |
| binary log | `ON` | `BI01 PASS` |
| binlog格式 | `ROW` | `BI02 PASS` |
| server_id | `1` | `BI03 PASS` |
| sync_binlog | `1` | `BI04 PASS` |
| binlog保留时间 | 2,592,000秒（30天） | `BI05 PASS` |
| GTID | `OFF` | `BI06 INFO`，本地按文件位置或时间点恢复 |

当前实例满足本课程设计的 binlog 增量恢复前置条件。GTID不是本地单实例时间点恢复的强制条件，因此不为课程演练修改服务器模式。
