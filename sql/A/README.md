# sql/A：A ⑥⑧ 数据库脚本

## 执行顺序

> 空库优先使用仓库根目录的 `sql/00_install_all.sql`；已有 D/B、仅缺 A 时使用 `sql/A/00_install_a.sql`。
> `sql/A/07_verify.sql` 是只读验收，不会创建任何对象；A03～A06 为 0 时应先运行 `sql/A/00_preflight.sql` 定位依赖。

前置：D 的 `user`、`vehicle` 已创建；B 的 `station`、`charging_gun`、`parking_space`、`equipment_outage_plan`、`charging_order` 已创建。

```sql
USE charging_platform;
SET SESSION time_zone = '+08:00';

SOURCE sql/A/00_preflight.sql;    -- 只读：检查 D/B 依赖与 A 当前对象数
SOURCE sql/A/01_schema.sql;       -- 10 张表、主外键、唯一、CHECK、生成列、索引
SOURCE sql/A/02_triggers.sql;     -- 13 个触发器
SOURCE sql/A/03_procedures.sql;   -- 14 个存储过程
SOURCE sql/A/04_views.sql;        -- 8 个视图

SOURCE sql/A/00_local_shared_fixtures.sql; -- 仅本地联调：场站/枪/车位/停运计划夹具
SOURCE sql/A/05_seed.sql;                  -- 每张 A 表 ≥20 行；检查末尾统计后手动 COMMIT
```

仅补装 A 结构时，用 `SOURCE sql/A/00_install_a.sql;` 代替手工执行 01～04；它会先检查前置表和 A 表是否已存在，避免重复建表。

正式联调时，用 B 的正式种子替代 `00_local_shared_fixtures.sql`；A 的 `05_seed.sql` 依赖以下公共编号：

- `user_id` 10001–10020、`vehicle_id` 20001–20020（D 核心种子）
- `station_id` 9101–9104、`gun_id` 9401–9420、`parking_space_id` 9301–9320、`equipment_outage_plan` 9501–9520（本地夹具；B 正式种子需提供等价记录或调整 A 种子）

## 文件说明

| 文件 | 内容 |
| --- | --- |
| `00_preflight.sql` | 只读安装前置检查：D/B 依赖表、编号类型、A 当前对象数与诊断提示 |
| `00_install_a.sql` | 仅补装 A 结构（01～04）；带前置与重复建表守卫，适合已有 D/B 的库 |
| `00_local_shared_fixtures.sql` | 本地共享夹具：4 场站、8 桩、20 枪、20 车位、20 停运计划；不纳入正式数据 |
| `01_schema.sql` | 10 张 A 表 DDL |
| `02_triggers.sql` | 区间冲突兜底、预约/排队状态机与历史、核验占位、公告版本、通知状态机 |
| `03_procedures.sql` | 预约/改约/取消、到站核验、排队叫号、车位释放、资格消费、过期批处理、公告发布/撤回 |
| `04_views.sql` | 预约/排队/占用看板、履约统计、公开公告、送达统计、受影响用户、版本历史 |
| `05_seed.sql` | 10 张 A 表测试数据，触发器会追加状态历史和公告版本 |
| `06_business_queries.sql` | Q01～Q07，均连接 3 个及以上关系 |
| `07_verify.sql` | 只读结构/数据验收 |
| `08_constraint_tests.sql` | 16 项约束/状态机/过程测试，结束统一 ROLLBACK |

## 验收

```powershell
# SQL
mysql -u root -p charging_platform < sql/A/07_verify.sql
mysql -u root -p charging_platform < sql/A/08_constraint_tests.sql
mysql -u root -p charging_platform < sql/A/06_business_queries.sql

# Python（仓库根目录）
python -m pytest -q
python tests/verify_a_module.py
```

预期：`07_verify.sql` 全部 PASS；`08_constraint_tests.sql` 16 PASS；`pytest` 61 passed；`verify_a_module.py` 17 PASS。

## 注意事项

- `01_schema.sql` 中的 `charging_reservation.consumed_order_id`、`queue_record.consumed_order_id` 外键引用 B 的 `charging_order`，必须后于 B 建表执行。
- `02_triggers.sql` 中预约冲突触发器使用普通一致性读，不能对同一张表做锁定读；并发创建入口必须使用 `sp_create_reservation`。
- `05_seed.sql` 不自动提交，检查末尾每表行数 ≥20 后再 `COMMIT`。
- `00_local_shared_fixtures.sql` 仅供本地测试，正式提交材料时应说明其与 B 正式种子的替换关系。
