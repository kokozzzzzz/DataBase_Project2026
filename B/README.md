# B 场站设施与充电交易

> **2026-11-21更新**：最新全组进度、规则、升级步骤及分工见[集成修正与交接](../docs/集成修正_2026-11-21/README.md)。下文保留本模块历史记录，以最新交接说明为准。

B 负责①场站与充电设施、②充电订单与计费。2026-11-20 更新，接入基线为 dev 的 237b401。本次完成正式开单、分时核价、支付补缴和部分退款服务，接 A 的资格与占位及 D 的优惠券事务，提供固定测试数据供 D 继续结算。

## 当前进度与材料

| 内容 | 本次结果及文件 |
| --- | --- |
| 数据结构 | 沿用已交付的16张表、124个字段、7个设施触发器和6个视图；[第二天物理字典与设计](第二天材料/)保留 |
| 正式交易 | [charging_service.py](../app/services/charging_service.py) 实现 open_order、add_readings、finish_order、confirm_bill、record_payment、record_refund；使用公共连接，由调用方控制事务 |
| 分时计算 | [charging_billing.py](../app/services/charging_billing.py) 提供可信读数校验、分段与 Decimal 金额计算 |
| 查询入口 | [charging_repository.py](../app/database/charging_repository.py) 提供订单资金、用户订单分页和场站设备；[run_charging_demo.py](../app/run_charging_demo.py) 提供只读命令入口 |
| 增量保护 | [05_transaction_guards.sql](../sql/B/05_transaction_guards.sql) 新增3个触发器，保护费用快照、已出账事实及成功支付后的金额 |
| 固定测试集 | [seed_b_integration.py](../app/seed_b_integration.py) 生成真实A/B/D表中的虚构样例；B每表至少20行，含40笔足额支付订单、80条费用分段、100条支付、20条次月退款 |
| 真实验收 | [verify_b_workflow.py](../tests/verify_b_workflow.py) 的16项功能、回滚、幂等、旧快照及并发检查通过；[test_charging_billing.py](../tests/test_charging_billing.py) 补充14项计费回归，全仓87项单元测试通过 |
| 交接与证据 | [接口与交接决定](第三天材料/接口与交接决定.md)、[固定数据说明](第三天材料/固定测试数据说明.md)、[验证记录](第三天材料/验证记录.md)、[实测输出](第三天材料/实测/) |
| 第一阶段资料 | [第一日字典](B_第一天统一数据字典.xlsx)、[业务图](业务图/)；跨模块调用以本次实现及说明为最新依据 |

本次验证使用独立 MySQL **8.4.13** 临时实例，复用仓库A/D正式结构与服务，结束后已关闭。小组目标 **8.0.46** 需对本次新增服务与触发器复验。D已记录旧B结构在8.0.46的验证，第二天材料继续作为历史证据。枪表保留station_id用于同站复合外键，是已说明的范式例外。

## 现有项目更新与空库顺序

使用仓库公共 app/database/connection.py、config.py 和 .env 的 DB_HOST、DB_PORT、DB_USER、DB_PASSWORD、DB_NAME。会话统一+08:00，数据库名 charging_platform。现有密码自己在本机填写；服务采用公共 DB_* 配置。

> 空库可直接执行仓库根目录的 `sql/00_install_all.sql`：它已按 D 核心 → B 结构/触发器/视图/保护触发器 → D 跨模块 → A 结构 → D 结算表的顺序安装。下面的 SOURCE 顺序用于理解依赖，或在已有库中单独补装 B。

**已安装B第二阶段、D与A正式对象时**，在仓库根目录打开的 MySQL 客户端首次执行本次增量。

```sql
USE charging_platform;
SOURCE sql/B/05_transaction_guards.sql;
```

该文件创建3个触发器，成功后无需重复。先用 SHOW TRIGGERS 核对；中途失败时按已创建对象定位失败位置。DDL会隐式提交。

**从空集成实例开始时**，在仓库根目录的 MySQL 客户端按下列顺序执行。已有对象按安装进度跳过；已有独立版同名表与数据需先评估迁移。

```sql
CREATE DATABASE charging_platform
  DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
USE charging_platform;
SET SESSION time_zone = '+08:00';
SOURCE sql/D/04_membership_core.sql;
SOURCE sql/B/01_schema.sql;
SOURCE sql/B/02_structure_triggers.sql;
SOURCE sql/B/03_views.sql;
SOURCE sql/D/04_membership_integration.sql;
SOURCE sql/A/01_schema.sql;
SOURCE sql/A/02_triggers.sql;
SOURCE sql/A/03_procedures.sql;
SOURCE sql/A/04_views.sql;
SOURCE sql/B/05_transaction_guards.sql;
-- 用于后面的D结算数据预检。
SOURCE sql/D/05_settlement_schema.sql;
```

A的shared_fixtures与A种子不是运行本次B测试集的前置条件。B测试集自行添加虚构用户车辆及集成记录，D原有核心种子可按D说明另外准备。已安装A夹具的本机可保留其9000段数据，本集采用7200000段。

## 运行、验证和重复执行

在仓库根目录的 PowerShell 终端，使用已安装 requirements.txt 的Python环境并配置好.env后执行。

```powershell
# 默认预览并回滚。
python -m app.seed_b_integration

# 确认本机测试库后提交，保存本机实际编号。
python -m app.seed_b_integration --commit --output ../B_本机实测/固定测试集.json

# 正常用例回滚；并发用例短暂提交后按精确标记清理。
python tests/verify_b_workflow.py --output ../B_本机实测/B业务流程验证.json

# 只读查看该测试集的用户、站点。
python -m app.run_charging_demo --user 7200001
python -m app.run_charging_demo --station 7200001
python -m pytest -q
```

预期真实流程16项PASS、全仓87项单元测试通过。单元测试不连接数据库；真实验收需已提交固定测试集。实测时为隔离额外pytest插件，使用PYTEST_DISABLE_PLUGIN_AUTOLOAD=1和`-p no:cacheprovider`，同样通过。

生成程序使用GET_LOCK串行加载，默认回滚，--commit才提交。重复执行会核对固定主数据规模、40笔订单金额和券状态后复用，部分占用或数据变动时拒绝覆盖并回滚。预览及失败可产生正常自增空号。历史预约以专用夹具INSERT导入，再调用A核验、B交易服务；正式预约仍走A的create_reservation，保留其过去时间限制。

在MySQL客户端继续执行D的只读检查。

```sql
SOURCE sql/D/05_settlement_seed_preflight.sql;
```

本次DP03为40笔可结算订单（建议≥20），DP06为20笔成功支付对应退款（建议≥1），均PASS。订单自增编号以本机输出或admission_id关联查询为准。

## 服务调用及事务约定

```python
from app.database.connection import database_connection, transaction
from app.services.charging_service import open_order

with database_connection() as connection:
    with transaction(connection):
        order_id = open_order(
            connection,
            user_id=actual_user_id,
            vehicle_id=actual_vehicle_id,
            gun_id=actual_gun_id,
            channel="RESERVATION",
            admission_id=actual_reservation_id,
        )
```

actual_*由A核验结果或真实业务请求提供。其他服务也接收公共connection并使用同一事务约定，参数见函数定义与真实验收用例。异常应传播到transaction外以完整回滚。死锁或锁超时整笔回滚后，按同一资格/支付/退款流水键重试。接前端时由统一身份权限层验证操作者与订单归属。

## 本次落实的业务口径

1. 正式开单要求A的CHECKED_IN预约/排队资格及本车有效占位。现场车主走A的WALK_IN流程，当前B入口拒绝无资格DIRECT。默认启动余额预检5元为B配置，非老师规定。
2. 使用北京时间、秒精度DATETIME、左闭右开区间。可信读数包含开单、结束、电价及必要免费边界；缺失或断连进入REVIEW。复核须提供依据。服务计量单位先四舍五入至6位与快照一致，连续分段两类费用分别四舍五入到分。免费只免服务费，起步金额在优惠前补差。
3. 已出账后调用D锁券，再由B确认账单。部分支付保留锁券，足额成功与核销原子完成；首笔失败且无成功支付时释放券、清零优惠并使确认失效，之后重新确认。零应付可核销券，无需生成零元支付。
4. 收退款服务记录已确认的外部渠道结果，B不直接扣D钱包。退款锁定订单与原成功支付，累计不超过原支付并按流水幂等。退款后USED券暂保持原状，返券需B/D另定。
5. 充电结束保留A占位，车辆驶离调用A释放。读取C的设备状态与共享停运计划拦截开单。维修恢复和停运登记按对接清单推进。

## 队友交接与文件影响

**A** 已实测预约与现场排队两条资格路径，复用核验、消费和释放服务。提前核验、迟到保留与B开单区间各有用途，若要预约结束后仍在宽限期内开单，双方同步修改区间及边界测试。B不另建占位表。

**D** 可使用40笔已出账、足额支付订单和20笔次月退款继续结算。总原价504元、优惠40元、成功实收464元、退款60元、迄今净收404元。零应付无成功支付流水的结算口径需另定。本次对coupon_service.py做三处接入修正：释放与核销的支付判定使用FOR UPDATE当前读；释放券同时清除confirmed_at。函数签名保留，请D审查。

**C** B已验证故障与排定停运拦截新开单。请C落实离线、故障、维修复核及恢复接口，并与A/B确认唯一停运登记人及心跳阈值，继续共用equipment_outage_plan。B没有新增自动恢复入口。

本次新增B代码、SQL增量、测试和第三天材料，同时更新本README、第二日对接清单导航及根README。数据库列仍为16表124字段，原图与字典保留。A实现和D表结构保持原版，D券服务必要改动如上。

## 后续推进

新增服务与触发器在8.0.46复验；C真实故障恢复与停运通知、D结算事务、钱包收退款和退款返券政策继续交接。设施维护入口、费率发布管理、前端、权限、复杂查询优化、备份恢复与最终报告按总计划继续验收。本次交易测试不替代这些验收记录。

GitHub提交建议为 `feat: 接入B交易服务与ABD流程并提供结算测试数据`。检查个人分支改动后提交、推送并向dev发PR，请A核对资格与占位、D审查券服务修正和结算输入。
