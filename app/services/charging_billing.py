"""按可信边界读数计算分时费用，金额采用 Decimal 四舍五入到分。"""
from datetime import datetime, time, timedelta
from decimal import Decimal, ROUND_HALF_UP


class ChargingError(ValueError):
    """充电业务校验失败。"""


def rounded(value):
    return value.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)


def _rate_at(at, rates):
    start_of_day = datetime.combine(at.date(), time())
    minute = (at - start_of_day).total_seconds() // 60
    matches = [r for r in rates if r["valid_from"] <= at.date() < r["valid_until"]
               and r["starts_minute"] <= minute < r["ends_minute"]]
    if len(matches) != 1:
        raise ChargingError("费率时段有断档或重叠")
    return matches[0], start_of_day


def _calculate(order, ends, readings, rates):
    start = order["starts_at"]
    if len(readings) < 2 or readings[0]["read_at"] != start or readings[-1]["read_at"] != ends:
        raise ChargingError("缺少开单或结束的可信读数")
    first_rate, _ = _rate_at(start, rates)
    free_until = start + timedelta(minutes=first_rate["free_minutes"])
    groups = []
    for a,b in zip(readings, readings[1:]):
        left,right = a["read_at"],b["read_at"]
        kwh = b["cumulative_kwh"] - a["cumulative_kwh"]
        rate, day = _rate_at(left, rates)
        if kwh < 0 or left >= right:
            raise ChargingError("累计读数倒退或时间无效")
        if right > day + timedelta(minutes=rate["ends_minute"]):
            raise ChargingError("缺少分时边界的累计读数")
        if rate["service_basis"] == "KWH":
            if left < free_until < right:
                raise ChargingError("缺少免费服务时段边界读数")
            units = kwh if left >= free_until else Decimal(0)
        else:
            units = Decimal(max(0,int((right-max(left,free_until)).total_seconds()))) / Decimal(60)
        # Round each continuous tariff segment once, regardless of sampling frequency.
        band = rate["band_id"]
        if groups and groups[-1]["band"] == band and groups[-1]["end"] == left:
            segment = groups[-1]
            segment["end"], segment["kwh"], segment["units"] = right, segment["kwh"]+kwh, segment["units"]+units
        else:
            groups.append(dict(band=band,start=left,end=right,kwh=kwh,units=units,rate=rate))
    result = []
    for s in groups:
        r = s["rate"]
        stored_units = s["units"].quantize(Decimal("0.000001"), rounding=ROUND_HALF_UP)
        result.append((order["order_id"],s["band"],s["start"],s["end"],s["kwh"],r["energy_price"],
                       r["service_price"],r["service_basis"],stored_units,
                       rounded(s["kwh"]*r["energy_price"]),rounded(stored_units*r["service_price"])))
    gross = max(first_rate["minimum_fee"], sum((x[-2]+x[-1] for x in result),Decimal(0)))
    return result, sum((x[4] for x in result),Decimal(0)), gross


