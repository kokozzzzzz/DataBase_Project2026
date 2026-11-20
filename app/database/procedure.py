"""调用 MySQL 存储过程并读取 OUT 参数的公共帮助函数。"""

from __future__ import annotations

from typing import Any, Sequence

import pymysql
from pymysql.connections import Connection


PROCEDURE_MESSAGES = {
    "RESERVATION_ID_INVALID": "预约编号无效。",
    "RESERVATION_TIME_INVALID": "预约开始时间必须早于结束时间。",
    "RESERVATION_DURATION_INVALID": "预约时长必须在 5 分钟到 24 小时之间。",
    "RESERVATION_IN_PAST": "不能预约过去的时间。",
    "RESERVATION_GRACE_INVALID": "迟到保留时长必须在 1 到 120 分钟之间。",
    "RESERVATION_SOURCE_INVALID": "预约来源不合法。",
    "RESERVATION_USER_NOT_ACTIVE": "用户不存在或不是 ACTIVE 状态。",
    "RESERVATION_VEHICLE_NOT_OWNED_OR_INACTIVE": "车辆不属于该用户或不可用。",
    "RESERVATION_GUN_NOT_FOUND": "充电枪不存在。",
    "RESERVATION_GUN_NOT_AVAILABLE": "充电枪当前不可预约。",
    "RESERVATION_STATION_CLOSED": "场站当前未营业。",
    "RESERVATION_OUTSIDE_BUSINESS_HOURS": "预约开始时间不在场站营业时间内。",
    "RESERVATION_GUN_OUTAGE": "预约时段与停运计划冲突。",
    "RESERVATION_GUN_OVERLAP": "该充电枪在所选时段已有有效预约。",
    "RESERVATION_USER_OVERLAP": "该用户在所选时段已有有效预约。",
    "RESERVATION_NOT_FOUND": "预约不存在。",
    "RESERVATION_CANCEL_REASON_REQUIRED": "取消预约必须填写原因。",
    "RESERVATION_CANNOT_CANCEL": "当前状态的预约不能取消。",
    "RESERVATION_CANCEL_RACE": "预约已被并发修改，请重试。",
    "RESERVATION_CANNOT_RESCHEDULE": "只有 BOOKED 状态的预约可以改约。",
    "RESERVATION_RESCHEDULE_TOO_LATE": "已到预约开始时间，不能改约。",
    "RESERVATION_RESCHEDULE_RACE": "预约已被并发修改，请重试。",
    "RESERVATION_NOT_BOOKED": "预约不是 BOOKED 状态，不能到站核验。",
    "RESERVATION_TOO_EARLY": "尚未到可核验时间（最多提前 30 分钟）。",
    "RESERVATION_EXPIRED": "预约已超过迟到保留期，不能核验。",
    "CHECKIN_USER_NOT_ACTIVE": "用户不存在或不是 ACTIVE 状态。",
    "CHECKIN_VEHICLE_NOT_ACTIVE": "车辆不属于该用户或不可用。",
    "CHECKIN_GUN_STATION_MISMATCH": "充电枪与场站不匹配。",
    "CHECKIN_GUN_NOT_READY": "充电枪当前不是 READY 状态。",
    "CHECKIN_STATION_CLOSED": "场站当前未营业。",
    "CHECKIN_OUTSIDE_BUSINESS_HOURS": "当前时间不在场站营业时间内。",
    "CHECKIN_GUN_OUTAGE": "充电枪当前处于停运计划内。",
    "CHECKIN_GUN_HAS_ACTIVE_ORDER": "充电枪已有进行中的订单。",
    "CHECKIN_SPACE_OCCUPIED": "目标车位已被占用。",
    "CHECKIN_VEHICLE_OCCUPIED": "该车辆已有未释放的车位占用。",
    "CHECKIN_METHOD_INVALID": "到站核验方式不合法。",
    "CHECKIN_RESERVATION_RACE": "预约已被并发修改，请重试。",
    "CHECKIN_RESERVATION_NOT_FOUND": "预约不存在。",
    "CHECKIN_RESERVATION_NOT_READY": "预约未处于 CHECKED_IN 状态。",
    "CHECKIN_RESERVATION_MISMATCH": "预约的用户、车辆、枪或场站不一致。",
    "CHECKIN_QUEUE_NOT_FOUND": "排队记录不存在。",
    "CHECKIN_QUEUE_NOT_READY": "排队记录未处于 CHECKED_IN 状态。",
    "CHECKIN_QUEUE_MISMATCH": "排队的用户、车辆、枪或场站不一致。",
    "CHECKIN_SPACE_GUN_MISMATCH": "车位不是该充电枪绑定的车位。",
    "CHECKIN_ONE_QUALIFICATION_REQUIRED": "到站核验必须且只能关联预约或排队之一。",
    "CHECKIN_QUEUE_RACE": "排队记录已被并发修改，请重试。",
    "QUEUE_ID_INVALID": "排队编号无效。",
    "QUEUE_ID_INVALID_FOR_STATION": "排队编号无效。",
    "QUEUE_STATION_ID_INVALID": "场站编号无效。",
    "QUEUE_PRIORITY_INVALID": "排队优先级不合法。",
    "QUEUE_HOLD_INVALID": "叫号保留时长必须在 1 到 60 分钟之间。",
    "QUEUE_STATION_NOT_FOUND": "场站不存在。",
    "QUEUE_STATION_CLOSED": "场站当前未营业。",
    "QUEUE_OUTSIDE_BUSINESS_HOURS": "当前时间不在场站营业时间内。",
    "QUEUE_USER_NOT_ACTIVE": "用户不存在或不是 ACTIVE 状态。",
    "QUEUE_VEHICLE_NOT_OWNED_OR_INACTIVE": "车辆不属于该用户或不可用。",
    "QUEUE_GUN_STATION_MISMATCH": "充电枪与场站不匹配。",
    "QUEUE_GUN_DISABLED": "充电枪已停用。",
    "QUEUE_USER_ALREADY_ACTIVE": "该用户已有有效排队记录。",
    "QUEUE_CALL_RACE": "排队记录已被并发修改，请重试。",
    "QUEUE_NOT_FOUND": "排队记录不存在。",
    "QUEUE_NOT_CALLED": "排队记录尚未被叫号。",
    "QUEUE_CALL_EXPIRED": "叫号已超时，资格不能使用。",
    "OCCUPANCY_ID_INVALID": "车位占用编号无效。",
    "OCCUPANCY_RELEASE_REASON_INVALID": "车位释放原因不合法。",
    "OCCUPANCY_NOT_FOUND": "车位占用记录不存在。",
    "OCCUPANCY_ALREADY_RELEASED": "车位占用已经释放。",
    "OCCUPANCY_VEHICLE_STILL_CHARGING": "车辆仍在充电，不能按正常驶离释放车位。",
    "OCCUPANCY_RELEASE_RACE": "车位占用已被并发修改，请重试。",
    "ADMISSION_CHANNEL_INVALID": "资格类型必须是 RESERVATION 或 QUEUE。",
    "ADMISSION_ID_INVALID": "资格编号或订单编号无效。",
    "ADMISSION_ORDER_NOT_FOUND": "充电订单不存在。",
    "ADMISSION_ORDER_MISMATCH": "订单的资格类型或资格编号不匹配。",
    "ADMISSION_RESERVATION_NOT_FOUND": "预约不存在。",
    "ADMISSION_RESERVATION_NOT_CHECKED_IN": "预约未到站核验或已被消费。",
    "ADMISSION_RESERVATION_ALREADY_CONSUMED": "预约资格已被消费。",
    "ADMISSION_RESERVATION_ORDER_MISMATCH": "订单用户、车辆或枪与预约不一致。",
    "ADMISSION_RESERVATION_RACE": "预约资格已被并发消费。",
    "ADMISSION_QUEUE_NOT_FOUND": "排队记录不存在。",
    "ADMISSION_QUEUE_NOT_CHECKED_IN": "排队未到站核验或已被消费。",
    "ADMISSION_QUEUE_ALREADY_CONSUMED": "排队资格已被消费。",
    "ADMISSION_QUEUE_ORDER_MISMATCH": "订单用户、车辆或枪与排队不一致。",
    "ADMISSION_QUEUE_RACE": "排队资格已被并发消费。",
    "NOTICE_ID_INVALID": "公告编号无效。",
    "NOTICE_NOT_FOUND": "公告不存在。",
    "NOTICE_NOT_DRAFT": "只有 DRAFT 状态的公告可以发布。",
    "NOTICE_PUBLISH_RACE": "公告已被并发修改，请重试。",
    "NOTICE_OUTAGE_PLAN_NOT_FOUND": "公告关联的停运计划不存在。",
    "NOTICE_WITHDRAW_REASON_REQUIRED": "撤回公告必须填写原因。",
    "NOTICE_NOT_PUBLISHED": "只有 PUBLISHED 状态的公告可以撤回。",
    "NOTICE_WITHDRAW_RACE": "公告已被并发修改，请重试。",
    "NOTIFICATION_ID_INVALID": "通知编号无效。",
    "NOTIFICATION_STATUS_INVALID": "通知状态不合法。",
    "NOTIFICATION_NOT_FOUND": "通知不存在。",
    "NOTIFICATION_UPDATE_RACE": "通知已被并发修改，请重试。",
}


CHECK_CONSTRAINT_MESSAGES = {
    "ck_reservation_time": "预约时长或时间区间不合法。",
    "ck_reservation_grace": "迟到保留时长不合法。",
    "ck_reservation_cancelled": "取消预约必须同时填写取消时间和原因。",
    "ck_reservation_not_cancelled": "非取消预约不能带取消时间和原因。",
    "ck_reservation_consumed": "已消费预约必须同时填写消费时间和订单。",
    "ck_reservation_not_consumed": "未消费预约不能带消费信息。",
    "ck_queue_ticket": "排队号必须大于 0。",
    "ck_queue_hold": "叫号保留时长不合法。",
    "ck_queue_priority": "排队优先级分值不合法。",
    "ck_queue_waiting_not_called": "WAITING 状态不能有叫号时间。",
    "ck_queue_called_time": "CALLED/CHECKED_IN/CONSUMED 必须填写叫号和截止时间。",
    "ck_queue_call_pair": "叫号时间和截止时间必须同时存在。",
    "ck_queue_call_order": "叫号截止时间必须晚于叫号时间。",
    "ck_queue_cancelled": "取消排队必须同时填写取消时间和原因。",
    "ck_queue_not_cancelled": "非取消排队不能带取消时间和原因。",
    "ck_queue_consumed": "已消费排队必须同时填写消费时间和订单。",
    "ck_queue_not_consumed": "未消费排队不能带消费信息。",
    "ck_checkin_one_qualification": "到站核验必须且只能关联预约或排队之一。",
    "ck_checkin_plate": "车牌核验标志只能是 0 或 1。",
    "ck_occupancy_release_time": "车辆释放时间不能早于入位时间。",
    "ck_occupancy_release_pair": "释放时间和释放原因必须同时存在。",
    "ck_notice_effective": "公告失效时间必须晚于生效时间。",
    "ck_notice_draft_published": "DRAFT 公告不能有发布时间。",
    "ck_notice_published_time": "非 DRAFT 公告必须有发布时间。",
    "ck_notice_withdrawn": "撤回公告必须同时填写撤回时间和原因。",
    "ck_notice_not_withdrawn": "非撤回公告不能带撤回信息。",
    "ck_notice_target_plan": "定向停运公告必须关联停运计划。",
    "ck_notice_public_plan": "公开公告不能关联停运计划。",
    "ck_notice_recipient_reservation": "预约接收人必须关联预约编号。",
    "ck_notice_recipient_not_reservation": "非预约接收人不能关联预约编号。",
    "ck_notice_recipient_queue": "排队接收人必须关联排队编号。",
    "ck_notice_recipient_not_queue": "非排队接收人不能关联排队编号。",
    "ck_notice_recipient_vehicle": "受影响接收人必须关联车辆。",
    "ck_notification_sent_pair": "PENDING/FAILED 通知不能有发送时间，SENT/READ 必须有发送时间。",
    "ck_notification_read_time": "READ 通知必须有阅读时间。",
    "ck_notification_not_read": "非 READ 通知不能有阅读时间。",
    "ck_notification_read_after_sent": "阅读时间不能早于发送时间。",
    "ck_notification_failed": "FAILED 通知必须填写失败原因。",
    "ck_notification_not_failed": "非 FAILED 通知不能有失败原因。",
    "ck_notification_retry": "通知重试次数不能超过 10。",
}


class DatabaseProcedureError(RuntimeError):
    """存储过程或数据库约束返回的可读业务错误。"""

    def __init__(self, code: int, message: str, detail: str | None = None) -> None:
        self.code = code
        self.message = message
        self.detail = detail
        super().__init__(message)


def _extract_check_name(detail: str) -> str | None:
    marker = "Check constraint '"
    start = detail.find(marker)
    if start < 0:
        return None
    start += len(marker)
    end = detail.find("'", start)
    if end < 0:
        return None
    return detail[start:end]


def translate_database_error(error: pymysql.MySQLError) -> DatabaseProcedureError:
    """把 MySQL 错误码和过程 SIGNAL 文本翻译成中文业务错误。"""

    raw_args = getattr(error, "args", ())
    code = int(raw_args[0]) if raw_args else 0
    detail = str(raw_args[1]) if len(raw_args) > 1 else str(error)

    if code == 1644:
        key = detail.strip()
        message = PROCEDURE_MESSAGES.get(
            key, f"业务规则校验失败：{key}"
        )
        return DatabaseProcedureError(code, message, detail)

    if code == 3819:
        check_name = _extract_check_name(detail)
        message = CHECK_CONSTRAINT_MESSAGES.get(
            check_name or "", "数据不满足 CHECK 约束。"
        )
        return DatabaseProcedureError(code, message, detail)

    if code == 1062:
        return DatabaseProcedureError(code, "违反唯一约束，记录已存在。", detail)

    if code == 1452:
        return DatabaseProcedureError(code, "引用的外部记录不存在。", detail)

    return DatabaseProcedureError(code, f"数据库操作失败：{detail}", detail)


def call_procedure(
    connection: Connection,
    call_sql: str,
    parameters: Sequence[Any],
    out_names: Sequence[str],
) -> dict[str, Any]:
    """执行存储过程并读取 OUT 参数。

    调用方负责开启和提交/回滚事务；本函数不提交。
    过程只允许使用 OUT 参数返回标量，不使用结果集，避免多结果集同步问题。
    """

    if not out_names:
        raise ValueError("out_names 不能为空。")

    try:
        with connection.cursor() as cursor:
            cursor.execute(call_sql, tuple(parameters))
            while cursor.nextset():
                pass

            select_sql = "SELECT " + ", ".join(
                f"@{name} AS {name}" for name in out_names
            )
            cursor.execute(select_sql)
            row = cursor.fetchone()
    except pymysql.MySQLError as exc:
        raise translate_database_error(exc) from exc

    if row is None:
        raise RuntimeError("存储过程 OUT 参数没有返回结果。")
    return row
