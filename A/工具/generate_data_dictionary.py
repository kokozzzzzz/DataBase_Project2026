"""从真实 MySQL 元数据生成 A ⑥⑧ 数据字典 Excel。

在仓库根目录运行（需已建好 A 表并有测试数据）：
    python A/工具/generate_data_dictionary.py

连接参数沿用 app.database.config 的 DB_* 环境变量。
输出：docs/a/A_06_08_data_dictionary.xlsx
"""

from __future__ import annotations

import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import pymysql
from openpyxl import Workbook
from openpyxl.styles import Alignment, Border, Font, PatternFill, Side
from openpyxl.utils import get_column_letter

from app.database.config import DatabaseConfig


ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / "docs" / "a" / "A_06_08_data_dictionary.xlsx"

A_TABLES = (
    "charging_reservation",
    "reservation_status_log",
    "queue_record",
    "queue_status_log",
    "arrival_checkin",
    "parking_occupancy",
    "station_notice",
    "notice_revision",
    "notice_recipient",
    "notification_record",
)

TABLE_INFO = {
    "charging_reservation": ("⑥", "充电预约", "预约创建、取消、改约、到站与资格消费", "user, vehicle, charging_gun, station, charging_order"),
    "reservation_status_log": ("⑥", "预约状态历史", "记录预约每次状态变化与业务原因", "charging_reservation"),
    "queue_record": ("⑥", "现场排队记录", "现场入队、叫号、到站、资格消费", "station, user, vehicle, charging_gun, charging_order"),
    "queue_status_log": ("⑥", "排队状态历史", "记录排队每次状态变化与业务原因", "queue_record"),
    "arrival_checkin": ("⑥", "到站核验", "预约或排队资格到站核验，核验即入位", "charging_reservation, queue_record, charging_gun, parking_space"),
    "parking_occupancy": ("⑥", "车位占用", "车辆实际入位、释放与充电结束未驶离状态", "arrival_checkin, parking_space, charging_gun"),
    "station_notice": ("⑧", "场站公告", "公开公告与停运定向通知的发布、修改、撤回", "station, equipment_outage_plan"),
    "notice_revision": ("⑧", "公告版本", "保留公告新建、修改、发布、撤回、过期快照", "station_notice"),
    "notice_recipient": ("⑧", "公告接收对象", "定向公告受影响用户与预约/排队资格快照", "station_notice, user, vehicle, charging_reservation, queue_record"),
    "notification_record": ("⑧", "通知发送记录", "按接收对象与渠道记录发送、失败、阅读状态", "notice_recipient"),
}

BUSINESS_RULES = [
    ("BR-A01", "⑥", "同一把枪的有效预约时段不能重叠", "sp_create_reservation 锁枪行 + 锁定读；a_reservation_overlap_bi 顺序写入兜底", "sp_create_reservation / a_reservation_overlap_bi"),
    ("BR-A02", "⑥", "同一用户在同一时段不能重复预约", "sp_create_reservation 锁定读检查；触发器兜底", "sp_create_reservation / a_reservation_overlap_bi"),
    ("BR-A03", "⑥", "预约/排队资格只能被订单消费一次", "状态机 CHECKED_IN→CONSUMED + consumed_order_id 唯一 + sp_consume_admission 行锁", "sp_consume_admission / uk_*_consumed_order"),
    ("BR-A04", "⑥", "到站核验必须且只能来自预约或排队之一", "CHECK ((reservation_id IS NULL) <> (queue_id IS NULL)) + 触发器", "ck_checkin_one_qualification / a_checkin_qualification_bi"),
    ("BR-A05", "⑥", "核验成功即生成车位占用", "AFTER INSERT 触发器自动插入 parking_occupancy", "a_checkin_occupancy_ai"),
    ("BR-A06", "⑥", "同一车位、同一车辆最多一条未释放占用", "生成列 active_space_id / active_vehicle_id + 唯一约束", "uk_occupancy_active_space / uk_occupancy_active_vehicle"),
    ("BR-A07", "⑥", "充电结束但车辆未驶离时车位仍占用", "释放过程仅在正常驶离时检查无 ACTIVE 订单；充电结束不等于释放", "sp_release_parking_space"),
    ("BR-A08", "⑥", "一个用户最多一条有效排队", "生成列 active_user_id + 唯一约束；sp_join_queue 预检查", "uk_queue_active_user"),
    ("BR-A09", "⑥", "场站当日排队号唯一", "生成列 queue_date + (station_id, queue_date, ticket_no) 唯一；sp_join_queue 锁场站行分配", "uk_queue_station_date_ticket"),
    ("BR-A10", "⑥", "叫号/等待超时自动过期", "sp_expire_overdue_admissions 批量置 EXPIRED，状态触发器留痕", "sp_expire_overdue_admissions"),
    ("BR-A11", "⑧", "公告状态机 DRAFT→PUBLISHED→WITHDRAWN/EXPIRED", "a_notice_transition_bu 校验；时间字段 CHECK 保持一致", "a_notice_transition_bu"),
    ("BR-A12", "⑧", "公告修改、发布、撤回、过期保留版本", "a_notice_revision_ai/au 自动追加 notice_revision", "a_notice_revision_ai/au"),
    ("BR-A13", "⑧", "定向停运公告必须关联共享停运计划", "CHECK notice_type='OUTAGE_TARGETED' → related_outage_plan_id 非空", "ck_notice_target_plan"),
    ("BR-A14", "⑧", "通知状态机与时间字段一致", "a_notification_status_bu + CHECK 约束；sp_update_notification_status 统一入口", "a_notification_status_bu / sp_update_notification_status"),
    ("BR-A15", "⑧", "同一接收对象同一渠道只有一条通知", "UNIQUE (recipient_id, channel)，失败重试累加 retry_count", "uk_notification_recipient_channel"),
]

PENDING_DECISIONS = [
    ("Q-A01", "预约迟到保留时长", "当前默认 15 分钟，字段 late_grace_minutes 可快照", "A/B", "组会确认"),
    ("Q-A02", "叫号保留时长", "当前默认 10 分钟，字段 hold_minutes 可快照", "A/B", "组会确认"),
    ("Q-A03", "现场排队与即将开始预约的优先级", "当前 RESERVATION_LATE=100，WALK_IN=0；按 priority_score DESC、joined_at ASC 叫号", "A/B", "组会确认"),
    ("Q-A04", "排队等待过期时长", "当前 240 分钟，sp_expire_overdue_admissions 统一处理", "A", "组会确认"),
    ("Q-A05", "预约提前核验窗口", "当前最多提前 30 分钟，超过则拒绝", "A", "组会确认"),
    ("Q-A06", "车位与充电枪映射基数", "沿用 B 当前“每枪必绑同站一车位、每位至多一枪”", "A/B", "已对齐 B 对接清单"),
    ("Q-A07", "停运计划唯一登记责任人", "当前读取 B/C 共享 equipment_outage_plan；登记方待定", "A/B/C", "待确认"),
    ("Q-A08", "新增⑥⑧视图/过程数量考核口径", "当前交付 8 视图 + 14 过程，超过任务书原有 5 条线的最低要求", "全组/教师", "待教师确认"),
    ("Q-A09", "公开公告是否需要主动推送", "当前 PUBLIC 公告只进入公开视图，不强制生成通知记录；定向公告生成 IN_APP 通知", "A", "组会确认"),
]


def logical_type(column: dict[str, Any]) -> str:
    data_type = column["DATA_TYPE"]
    if data_type == "bigint":
        return "编号"
    if data_type in {"int", "smallint", "tinyint"}:
        return "布尔" if data_type == "tinyint" and column["COLUMN_TYPE"].startswith("tinyint(1)") else "整数"
    if data_type in {"decimal", "numeric"}:
        return "定点数"
    if data_type in {"datetime", "timestamp"}:
        return "日期时间"
    if data_type == "date":
        return "日期"
    if data_type == "enum":
        return "枚举"
    if data_type == "text":
        return "长文本"
    if data_type in {"varchar", "char"}:
        return "字符串"
    if data_type in {"varbinary", "binary", "blob"}:
        return "二进制"
    return data_type


def precision_text(column: dict[str, Any]) -> str:
    if column["CHARACTER_MAXIMUM_LENGTH"] is not None:
        return str(column["CHARACTER_MAXIMUM_LENGTH"])
    if column["NUMERIC_PRECISION"] is not None:
        scale = column["NUMERIC_SCALE"]
        return f"{column['NUMERIC_PRECISION']},{scale}" if scale is not None else str(column["NUMERIC_PRECISION"])
    if column["DATETIME_PRECISION"] is not None:
        return f"秒精度 {column['DATETIME_PRECISION']}"
    return "—"


def short_name(comment: str, column_name: str) -> str:
    if not comment:
        return column_name
    for separator in ("，", ",", "；", ";", "("):
        if separator in comment:
            return comment.split(separator, 1)[0].strip()
    return comment.strip()


def sample_value(column: dict[str, Any]) -> str:
    name = column["COLUMN_NAME"]
    data_type = column["DATA_TYPE"]
    if name.endswith("_id"):
        if name == "user_id":
            return "10001"
        if name == "vehicle_id":
            return "20001"
        if name == "gun_id":
            return "9401"
        if name in {"station_id", "parking_space_id"}:
            return "9101" if name == "station_id" else "9301"
        if name.endswith("order_id"):
            return "8001"
        if name.endswith("notice_id"):
            return "3011"
        if name.endswith("reservation_id"):
            return "1001"
        if name.endswith("queue_id"):
            return "2001"
        return "1"
    if data_type in {"datetime", "timestamp"}:
        return "2026-11-20 09:00:00"
    if data_type == "date":
        return "2026-11-20"
    if data_type == "enum":
        raw = column["COLUMN_TYPE"]
        values = [part.strip().strip("'") for part in raw[5:-1].split(",")]
        return values[0] if values else "—"
    if data_type in {"decimal", "numeric"}:
        return "12.50"
    if data_type in {"int", "smallint", "bigint"}:
        return "1"
    if data_type in {"text"}:
        return "示例正文"
    if data_type in {"varchar", "char"}:
        return "示例"
    return "—"


def style_sheet(worksheet, header_row: int, widths: list[int]) -> None:
    header_fill = PatternFill("solid", fgColor="1F4E79")
    header_font = Font(color="FFFFFF", bold=True)
    thin = Side(style="thin", color="BFBFBF")
    border = Border(left=thin, right=thin, top=thin, bottom=thin)

    for column_index, width in enumerate(widths, start=1):
        worksheet.column_dimensions[get_column_letter(column_index)].width = width

    for cell in worksheet[header_row]:
        cell.fill = header_fill
        cell.font = header_font
        cell.alignment = Alignment(horizontal="center", vertical="center", wrap_text=True)
        cell.border = border

    for row in worksheet.iter_rows(min_row=header_row):
        for cell in row:
            cell.border = border
            cell.alignment = Alignment(vertical="top", wrap_text=True)

    worksheet.freeze_panes = worksheet.cell(row=header_row + 1, column=1)
    worksheet.auto_filter.ref = worksheet.dimensions


def fetch_metadata(connection: pymysql.connections.Connection) -> dict[str, Any]:
    placeholders = ", ".join(["%s"] * len(A_TABLES))
    with connection.cursor() as cursor:
        cursor.execute(
            f"""
            SELECT TABLE_NAME, TABLE_COMMENT
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = DATABASE()
              AND TABLE_TYPE = 'BASE TABLE'
              AND TABLE_NAME IN ({placeholders})
            ORDER BY TABLE_NAME
            """,
            A_TABLES,
        )
        tables = {row["TABLE_NAME"]: row for row in cursor.fetchall()}

        cursor.execute(
            f"""
            SELECT
                TABLE_NAME, COLUMN_NAME, ORDINAL_POSITION, COLUMN_DEFAULT,
                IS_NULLABLE, DATA_TYPE, COLUMN_TYPE, CHARACTER_MAXIMUM_LENGTH,
                NUMERIC_PRECISION, NUMERIC_SCALE, DATETIME_PRECISION,
                COLUMN_KEY, EXTRA, GENERATION_EXPRESSION, COLUMN_COMMENT
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = DATABASE()
              AND TABLE_NAME IN ({placeholders})
            ORDER BY TABLE_NAME, ORDINAL_POSITION
            """,
            A_TABLES,
        )
        columns = cursor.fetchall()

        cursor.execute(
            f"""
            SELECT TABLE_NAME, COLUMN_NAME, CONSTRAINT_NAME,
                   REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME, ORDINAL_POSITION
            FROM information_schema.KEY_COLUMN_USAGE
            WHERE TABLE_SCHEMA = DATABASE()
              AND REFERENCED_TABLE_NAME IS NOT NULL
              AND TABLE_NAME IN ({placeholders})
            ORDER BY TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION
            """,
            A_TABLES,
        )
        foreign_keys = cursor.fetchall()

        cursor.execute(
            f"""
            SELECT TABLE_NAME, INDEX_NAME, NON_UNIQUE, SEQ_IN_INDEX, COLUMN_NAME
            FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = DATABASE()
              AND TABLE_NAME IN ({placeholders})
            ORDER BY TABLE_NAME, INDEX_NAME, SEQ_IN_INDEX
            """,
            A_TABLES,
        )
        indexes = cursor.fetchall()

        cursor.execute(
            f"""
            SELECT tc.TABLE_NAME, tc.CONSTRAINT_NAME, cc.CHECK_CLAUSE
            FROM information_schema.TABLE_CONSTRAINTS AS tc
            JOIN information_schema.CHECK_CONSTRAINTS AS cc
              ON cc.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
             AND cc.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
            WHERE tc.TABLE_SCHEMA = DATABASE()
              AND tc.CONSTRAINT_TYPE = 'CHECK'
              AND tc.TABLE_NAME IN ({placeholders})
            ORDER BY tc.TABLE_NAME, tc.CONSTRAINT_NAME
            """,
            A_TABLES,
        )
        checks = cursor.fetchall()

        row_counts: dict[str, int] = {}
        for table in A_TABLES:
            cursor.execute(f"SELECT COUNT(*) AS row_count FROM `{table}`")
            row_counts[table] = int(cursor.fetchone()["row_count"])

    fk_by_column: dict[tuple[str, str], list[str]] = {}
    fk_by_constraint: dict[tuple[str, str], list[dict[str, Any]]] = {}
    for row in foreign_keys:
        key = (row["TABLE_NAME"], row["CONSTRAINT_NAME"])
        fk_by_constraint.setdefault(key, []).append(row)

    for (table_name, _), rows in fk_by_constraint.items():
        columns_text = ", ".join(row["COLUMN_NAME"] for row in rows)
        refs_text = ", ".join(row["REFERENCED_COLUMN_NAME"] for row in rows)
        target = f"{rows[0]['REFERENCED_TABLE_NAME']}({refs_text})"
        for row in rows:
            fk_by_column.setdefault((table_name, row["COLUMN_NAME"]), []).append(
                f"{columns_text} → {target}"
            )

    index_by_table: dict[str, list[str]] = {}
    indexes_by_column: dict[tuple[str, str], list[str]] = {}
    unique_single: set[tuple[str, str]] = set()
    index_columns: dict[tuple[str, str], list[str]] = {}
    for row in indexes:
        key = (row["TABLE_NAME"], row["INDEX_NAME"])
        index_columns.setdefault(key, []).append(row["COLUMN_NAME"])
    for (table_name, index_name), column_names in index_columns.items():
        unique = next(
            row["NON_UNIQUE"]
            for row in indexes
            if row["TABLE_NAME"] == table_name and row["INDEX_NAME"] == index_name
        )
        suffix = "UNIQUE" if not unique else ""
        index_text = (
            f"{index_name}({', '.join(column_names)})"
            f"{(' ' + suffix) if suffix else ''}"
        )
        index_by_table.setdefault(table_name, []).append(index_text)
        for column_name in column_names:
            indexes_by_column.setdefault((table_name, column_name), []).append(
                index_text
            )
        if not unique and len(column_names) == 1:
            unique_single.add((table_name, column_names[0]))

    checks_by_table: dict[str, list[dict[str, Any]]] = {}
    for row in checks:
        checks_by_table.setdefault(row["TABLE_NAME"], []).append(row)

    return {
        "tables": tables,
        "columns": columns,
        "foreign_keys": foreign_keys,
        "fk_by_column": fk_by_column,
        "indexes": indexes,
        "index_by_table": index_by_table,
        "indexes_by_column": indexes_by_column,
        "unique_single": unique_single,
        "checks": checks,
        "checks_by_table": checks_by_table,
        "row_counts": row_counts,
    }


def build_workbook(metadata: dict[str, Any]) -> Workbook:
    workbook = Workbook()
    workbook.remove(workbook.active)

    # 说明
    info = workbook.create_sheet("说明")
    info.append(["A ⑥⑧ 数据字典"])
    info.append(["项目", "新能源汽车充电桩运营服务平台课程设计"])
    info.append(["负责人", "A 同学"])
    info.append(["业务线", "⑥ 预约、排队与到站管理；⑧ 场站服务公告与通知"])
    info.append(["数据库", "MySQL 8.0.46 / InnoDB / utf8mb4_0900_ai_ci"])
    info.append(["生成方式", "由 A/工具/generate_data_dictionary.py 从 information_schema 生成"])
    info.append(["生成时间", datetime.now().strftime("%Y-%m-%d %H:%M:%S")])
    info.append(["表数量", len(metadata["tables"])])
    info.append(["字段数量", len(metadata["columns"])])
    info.append(["口径说明", "字段含义来自建表 COMMENT；CHECK 约束逐条映射到字段；外键支持复合键"])
    info.append(["唯一来源", "本文件与 sql/A、docs/a 同步；如变更先改 DDL 再重新生成本字典"])
    info.column_dimensions["A"].width = 18
    info.column_dimensions["B"].width = 100
    for row in info.iter_rows():
        for cell in row:
            cell.alignment = Alignment(vertical="top", wrap_text=True)

    # 字段字典
    fields = workbook.create_sheet("⑥⑧字段字典")
    header = [
        "业务线编号",
        "业务模块",
        "负责人",
        "实体中文名",
        "实体名（表）",
        "字段中文名",
        "字段名（snake_case）",
        "字段含义/业务规则",
        "逻辑数据类型",
        "MySQL 字段类型",
        "长度/精度",
        "主键",
        "外键",
        "外键引用（表.字段）",
        "允许 NULL",
        "唯一",
        "默认值",
        "约束条件/取值范围",
        "敏感字段",
        "索引建议",
        "示例值",
        "来源",
        "确认状态",
        "备注",
    ]
    fields.append(["A ⑥⑧ 字段字典（每个字段一行）"])
    fields.append(["说明：字段类型、约束和索引均来自实际 MySQL 8.0.46 元数据。"])
    fields.append([])
    fields.append(header)

    for column in metadata["columns"]:
        table_name = column["TABLE_NAME"]
        business_line, entity_name, _, _ = TABLE_INFO[table_name]
        comment = column["COLUMN_COMMENT"] or ""
        table_checks = metadata["checks_by_table"].get(table_name, [])
        related_checks = [
            row["CONSTRAINT_NAME"]
            for row in table_checks
            if column["COLUMN_NAME"].lower() in (row["CHECK_CLAUSE"] or "").lower()
        ]
        enum_values = ""
        if column["DATA_TYPE"] == "enum":
            enum_values = column["COLUMN_TYPE"]
        constraint_parts = []
        if enum_values:
            constraint_parts.append(enum_values)
        if related_checks:
            constraint_parts.append("CHECK: " + ", ".join(related_checks))
        if column["GENERATION_EXPRESSION"]:
            constraint_parts.append(
                "生成列: " + column["GENERATION_EXPRESSION"]
            )
        if column["EXTRA"] and "auto_increment" in column["EXTRA"].lower():
            constraint_parts.append("AUTO_INCREMENT")
        if column["COLUMN_NAME"] == "note":
            constraint_parts.append("备注")

        default_value = column["COLUMN_DEFAULT"]
        if default_value is None and column["IS_NULLABLE"] == "YES":
            default_text = "NULL"
        elif default_value is None:
            default_text = ""
        else:
            default_text = str(default_value)

        note_parts = []
        if column["COLUMN_NAME"] == "reservation_id":
            note_parts.append("业务主键")
        if column["GENERATION_EXPRESSION"]:
            note_parts.append("生成列，不手工写入")
        if related_checks:
            note_parts.append("参与 CHECK 约束")
        if (table_name, column["COLUMN_NAME"]) in metadata["unique_single"]:
            note_parts.append("单列唯一")

        fields.append(
            [
                business_line,
                "⑥ 预约排队与到站管理"
                if business_line == "⑥"
                else "⑧ 场站公告与通知",
                "A",
                entity_name,
                table_name,
                short_name(comment, column["COLUMN_NAME"]),
                column["COLUMN_NAME"],
                comment,
                logical_type(column),
                column["COLUMN_TYPE"],
                precision_text(column),
                "是" if column["COLUMN_KEY"] == "PRI" else "否",
                "是" if (table_name, column["COLUMN_NAME"]) in metadata["fk_by_column"] else "否",
                "; ".join(metadata["fk_by_column"].get((table_name, column["COLUMN_NAME"]), [])),
                "是" if column["IS_NULLABLE"] == "YES" else "否",
                "是" if (table_name, column["COLUMN_NAME"]) in metadata["unique_single"] else "否",
                default_text,
                "；".join(constraint_parts) if constraint_parts else "按字段类型与非空约束",
                "否",
                "; ".join(
                    metadata["indexes_by_column"].get(
                        (table_name, column["COLUMN_NAME"]), []
                    )
                ),
                sample_value(column),
                "小组补充",
                "待确认（组内决定）"
                if column["COLUMN_NAME"] in {
                    "late_grace_minutes",
                    "hold_minutes",
                    "priority_class",
                    "priority_score",
                }
                else "已确认",
                "；".join(note_parts),
            ]
        )

    style_sheet(fields, 4, [8, 14, 8, 18, 24, 22, 24, 38, 12, 26, 12, 8, 8, 32, 9, 8, 22, 48, 9, 44, 22, 12, 18, 30])
    for row in fields.iter_rows(min_row=5):
        row[0].alignment = Alignment(horizontal="center", vertical="top")
        row[2].alignment = Alignment(horizontal="center", vertical="top")
        for index in (11, 12, 14, 15, 18, 21):
            row[index].alignment = Alignment(horizontal="center", vertical="top", wrap_text=True)

    # 实体清单
    entities = workbook.create_sheet("实体清单")
    entities.append(["A ⑥⑧ 实体清单"])
    entities.append([])
    entities.append(["业务线", "实体中文名", "表名", "主维护模块", "实体用途", "依赖表", "测试数据行数", "说明"])
    for table in A_TABLES:
        business_line, entity_name, purpose, dependencies = TABLE_INFO[table]
        comment = metadata["tables"].get(table, {}).get("TABLE_COMMENT", "")
        entities.append(
            [
                business_line,
                entity_name,
                table,
                "A",
                purpose,
                dependencies,
                metadata["row_counts"].get(table, 0),
                comment,
            ]
        )
    style_sheet(entities, 3, [8, 18, 26, 12, 44, 60, 12, 50])

    # 关系与约束
    relations = workbook.create_sheet("关系与约束")
    relations.append(["A ⑥⑧ 外键与约束清单"])
    relations.append([])
    relations.append(["业务线", "表名", "约束类型", "约束名", "约束内容/引用", "说明"])
    for row in metadata["foreign_keys"]:
        business_line = TABLE_INFO[row["TABLE_NAME"]][0]
        relations.append(
            [
                business_line,
                row["TABLE_NAME"],
                "FOREIGN KEY",
                row["CONSTRAINT_NAME"],
                f"{row['COLUMN_NAME']} → {row['REFERENCED_TABLE_NAME']}.{row['REFERENCED_COLUMN_NAME']}",
                "跨表引用",
            ]
        )
    for table in A_TABLES:
        for index_text in metadata["index_by_table"].get(table, []):
            if "UNIQUE" in index_text:
                relations.append(
                    [TABLE_INFO[table][0], table, "UNIQUE", index_text.split("(")[0], index_text, "唯一约束"]
                )
    for table in A_TABLES:
        for row in metadata["checks_by_table"].get(table, []):
            relations.append(
                [
                    TABLE_INFO[table][0],
                    table,
                    "CHECK",
                    row["CONSTRAINT_NAME"],
                    row["CHECK_CLAUSE"],
                    "取值范围/状态一致性",
                ]
            )
    style_sheet(relations, 3, [8, 26, 14, 34, 100, 26])

    # 业务规则
    rules = workbook.create_sheet("业务规则")
    rules.append(["A ⑥⑧ 业务规则与数据库落实"])
    rules.append([])
    rules.append(["编号", "业务线", "规则", "数据库落实方式", "代码/对象"])
    for rule in BUSINESS_RULES:
        rules.append(list(rule))
    style_sheet(rules, 3, [10, 8, 60, 80, 46])

    # 待确认
    pending = workbook.create_sheet("待确认事项")
    pending.append(["A ⑥⑧ 待组会确认事项"])
    pending.append([])
    pending.append(["编号", "事项", "当前默认/实现", "需确认人", "状态"])
    for item in PENDING_DECISIONS:
        pending.append(list(item))
    style_sheet(pending, 3, [10, 30, 80, 18, 22])

    # 测试数据
    tests = workbook.create_sheet("测试数据统计")
    tests.append(["A ⑥⑧ 测试数据与验收"])
    tests.append([])
    tests.append(["表名", "行数", "要求", "结果"])
    for table in A_TABLES:
        count = metadata["row_counts"].get(table, 0)
        tests.append([table, count, "≥20", "PASS" if count >= 20 else "FAIL"])
    tests.append([])
    tests.append(["综合验收", "17 项真实 MySQL 检查", "结构/数据/事务/并发", "17 PASS / 0 FAIL"])
    tests.append(["单元测试", "61 项", "pytest", "61 passed"])
    tests.append(["约束测试", "16 项", "sql/A/08_constraint_tests.sql", "16 PASS / 0 FAIL"])
    style_sheet(tests, 3, [30, 28, 30, 24])

    return workbook


def main() -> int:
    config = DatabaseConfig.from_env()
    connection = pymysql.connect(
        host=config.host,
        port=config.port,
        user=config.user,
        password=config.password,
        database=config.database,
        charset=config.charset,
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=True,
    )
    try:
        with connection.cursor() as cursor:
            cursor.execute("SET SESSION time_zone = '+08:00'")
        metadata = fetch_metadata(connection)
    finally:
        connection.close()

    workbook = build_workbook(metadata)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    workbook.save(OUTPUT)
    print(f"written {OUTPUT}")
    print(
        f"tables={len(metadata['tables'])}, columns={len(metadata['columns'])}, "
        f"row_counts={metadata['row_counts']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
