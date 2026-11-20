"""B 分时计费边界回归。真实事务与并发见 verify_b_workflow.py。"""
from datetime import date, datetime, timedelta
from decimal import Decimal

import pytest

from app.services.charging_billing import ChargingError, _calculate
from app.services.charging_service import _number


def scenario():
    start=datetime(2026,11,10,7,30)
    rates=[dict(band_id=1,valid_from=date(2026,1,1),valid_until=date(2027,1,1),
                starts_minute=0,ends_minute=480,energy_price=Decimal('.40'),
                service_price=Decimal('.20'),service_basis='KWH',free_minutes=0,minimum_fee=Decimal(0)),
           dict(band_id=2,valid_from=date(2026,1,1),valid_until=date(2027,1,1),
                starts_minute=480,ends_minute=1440,energy_price=Decimal('.70'),
                service_price=Decimal('.20'),service_basis='KWH',free_minutes=0,minimum_fee=Decimal(0))]
    order={'order_id':1,'starts_at':start}
    readings=[{'read_at':start,'cumulative_kwh':Decimal(0)},
              {'read_at':start+timedelta(minutes=30),'cumulative_kwh':Decimal(6)},
              {'read_at':start+timedelta(hours=1),'cumulative_kwh':Decimal(16)}]
    return order,start+timedelta(hours=1),readings,rates


def test_valley_flat_hand_calculation():
    segments,kwh,gross=_calculate(*scenario())
    assert len(segments)==2
    assert kwh==Decimal(16)
    assert gross==Decimal('12.60')


def test_missing_boundary_reading_requires_review():
    order,end,readings,rates=scenario()
    with pytest.raises(ChargingError,match='边界'):
        _calculate(order,end,[readings[0],readings[-1]],rates)


def test_tariff_overlap_requires_review():
    order,end,readings,rates=scenario()
    with pytest.raises(ChargingError,match='重叠'):
        _calculate(order,end,readings,rates+[rates[0]])


def test_no_sampling_frequency_rounding_drift():
    order,end,readings,rates=scenario()
    detailed=[readings[0],{'read_at':order['starts_at']+timedelta(minutes=15),'cumulative_kwh':Decimal('2.333')},*readings[1:]]
    assert _calculate(order,end,detailed,rates)[2]==Decimal('12.60')


def test_minimum_fee_and_free_service():
    order,end,readings,rates=scenario()
    for rate in rates:
        rate['free_minutes']=30
        rate['minimum_fee']=Decimal(20)
    segments,_,gross=_calculate(order,end,readings,rates)
    assert segments[0][-1]==0
    assert gross==Decimal(20)


def test_cross_midnight_tariff_version_change():
    order,end,readings,rates=scenario()
    start=datetime(2026,11,10,23,30)
    order['starts_at']=start
    end=start+timedelta(hours=1)
    for index,reading in enumerate(readings):
        reading['read_at']=start+timedelta(minutes=30*index)
    rates[0].update(valid_from=date(2026,11,10),valid_until=date(2026,11,11),starts_minute=0,ends_minute=1440)
    rates[1].update(valid_from=date(2026,11,11),valid_until=date(2026,11,12),starts_minute=0,ends_minute=1440)
    assert _calculate(order,end,readings,rates)[2]==Decimal('12.60')


def test_service_fee_per_minute():
    order,end,readings,rates=scenario()
    for rate in rates:
        rate['service_basis']='MINUTE'
    assert _calculate(order,end,readings,rates)[2]==Decimal('21.40')


def test_missing_free_service_boundary():
    order,end,readings,rates=scenario()
    rates[0]['free_minutes']=15
    with pytest.raises(ChargingError,match='免费'):
        _calculate(order,end,readings,rates)


def test_minute_fee_can_be_reconstructed_from_stored_units():
    order,_,_,rates=scenario()
    end=order['starts_at']+timedelta(seconds=1)
    readings=[{'read_at':order['starts_at'],'cumulative_kwh':Decimal(0)},
              {'read_at':end,'cumulative_kwh':Decimal('0.001')}]
    rates[0].update(service_basis='MINUTE',service_price=Decimal('99999.9999'))
    segments,_,_=_calculate(order,end,readings,rates)
    assert segments[0][8]==Decimal('0.016667')
    assert segments[0][-1]==Decimal('1666.70')


@pytest.mark.parametrize('raw',['NaN','Infinity','-1','1.001',None])
def test_money_rejects_invalid_values(raw):
    with pytest.raises(ChargingError):
        _number(raw)
