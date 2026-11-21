from __future__ import annotations

from datetime import datetime
from decimal import Decimal

import pytest

from yX.c_app import service


def test_ingest_sample_rejects_negative_measurement(monkeypatch: pytest.MonkeyPatch) -> None:
    def unexpected_call(*args: object, **kwargs: object) -> None:
        raise AssertionError(f"database must not be called: {args!r}, {kwargs!r}")

    monkeypatch.setattr(service.repository, "ingest_telemetry", unexpected_call)
    with pytest.raises(ValueError, match="voltage"):
        service.ingest_sample(
            object(),  # type: ignore[arg-type]
            pile_id=1,
            gun_id=None,
            collect_time=datetime(2026, 11, 20),
            voltage=Decimal("-1"),
        )


def test_ingest_sample_rejects_temperature_outside_supported_range(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def unexpected_call(*args: object, **kwargs: object) -> None:
        raise AssertionError(f"database must not be called: {args!r}, {kwargs!r}")

    monkeypatch.setattr(service.repository, "ingest_telemetry", unexpected_call)
    with pytest.raises(ValueError, match="module_temp"):
        service.ingest_sample(
            object(),  # type: ignore[arg-type]
            pile_id=1,
            gun_id=None,
            collect_time=datetime(2026, 11, 20),
            module_temp=Decimal("201"),
        )


def test_ingest_sample_normalizes_empty_fault_code(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    captured: dict[str, object] = {}
    connection = object()

    def fake_ingest(
        received_connection: object, **kwargs: object
    ) -> dict[str, int | None]:
        assert received_connection is connection
        captured.update(kwargs)
        return {"telemetry_id": 7, "alarm_id": None}

    monkeypatch.setattr(service.repository, "ingest_telemetry", fake_ingest)
    result = service.ingest_sample(
        connection,  # type: ignore[arg-type]
        pile_id=1,
        gun_id=None,
        collect_time=datetime(2026, 11, 20),
        fault_code=" ",
    )

    assert result == {"telemetry_id": 7, "alarm_id": None}
    assert captured["fault_code"] is None
