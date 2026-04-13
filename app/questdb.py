from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any, Generic, TypeVar
import time

import httpx
from fastapi import HTTPException

from .config import get_settings
from .models import DeploymentDetail, DeploymentNode, TelemetryPoint

T = TypeVar("T")


@dataclass
class CacheEntry(Generic[T]):
    value: T
    expires_at: float


@dataclass
class TtlCache(Generic[T]):
    ttl_seconds: float
    entries: dict[str, CacheEntry[T]] = field(default_factory=dict)
    lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    async def get_or_set(
        self,
        key: str,
        loader: Callable[[], Awaitable[T]],
    ) -> T:
        now = time.monotonic()
        entry = self.entries.get(key)
        if entry and entry.expires_at > now:
            return entry.value

        async with self.lock:
            now = time.monotonic()
            entry = self.entries.get(key)
            if entry and entry.expires_at > now:
                return entry.value

            value = await loader()
            self.entries[key] = CacheEntry(
                value=value,
                expires_at=now + self.ttl_seconds,
            )
            return value

    def clear(self) -> None:
        self.entries.clear()


class QuestDbClient:
    def __init__(self, base_url: str, timeout_seconds: float) -> None:
        self.base_url = base_url.rstrip("/")
        self.client = httpx.AsyncClient(
            base_url=self.base_url,
            timeout=timeout_seconds,
            limits=httpx.Limits(
                max_connections=20,
                max_keepalive_connections=5,
            ),
        )

    async def close(self) -> None:
        await self.client.aclose()

    async def execute(self, query: str) -> list[dict[str, Any]]:
        try:
            response = await self.client.get("/exec", params={"query": query})
        except httpx.HTTPError as exc:
            raise HTTPException(
                status_code=502,
                detail=f"No fue posible conectar con QuestDB: {exc}",
            ) from exc

        if response.status_code != 200:
            raise HTTPException(
                status_code=502,
                detail=(
                    f"QuestDB respondio con estado {response.status_code}: "
                    f"{response.text.strip()}"
                ),
            )

        payload = response.json()
        columns = [column["name"] for column in payload.get("columns", [])]
        dataset = payload.get("dataset", [])

        return [
            dict(zip(columns, row, strict=False))
            for row in dataset
        ]


_questdb_client: QuestDbClient | None = None
_questdb_client_lock = asyncio.Lock()
_deployments_cache = TtlCache[list[DeploymentNode]](ttl_seconds=30.0)
_deployment_detail_cache = TtlCache[DeploymentDetail](ttl_seconds=15.0)


async def get_questdb_client() -> QuestDbClient:
    global _questdb_client

    if _questdb_client is not None:
        return _questdb_client

    async with _questdb_client_lock:
        if _questdb_client is None:
            settings = get_settings()
            _questdb_client = QuestDbClient(
                base_url=settings.questdb_base_url,
                timeout_seconds=settings.query_timeout_seconds,
            )

    return _questdb_client


async def close_questdb_client() -> None:
    global _questdb_client

    if _questdb_client is None:
        return

    await _questdb_client.close()
    _questdb_client = None
    _deployments_cache.clear()
    _deployment_detail_cache.clear()


def _normalize_string(value: Any, fallback: str = "") -> str:
    return value if isinstance(value, str) else fallback


def _normalize_optional_string(value: Any) -> str | None:
    if isinstance(value, str) and value.strip():
        return value
    return None


def _normalize_float(value: Any) -> float | None:
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str) and value.strip():
        try:
            return float(value)
        except ValueError:
            return None
    return None


def _normalize_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str) and value.strip():
        try:
            return int(float(value))
        except ValueError:
            return None
    return None


def _normalize_timestamp(value: Any) -> str:
    return str(value) if value is not None else ""


def _escape_sql_literal(value: str) -> str:
    return value.replace("'", "''")


def _build_node(row: dict[str, Any]) -> DeploymentNode | None:
    latitude = _normalize_float(row.get("latitude"))
    longitude = _normalize_float(row.get("longitude"))
    deployment_id = _normalize_string(row.get("deployment_id"))
    board_id = _normalize_string(row.get("board_id"))

    if latitude is None or longitude is None or not deployment_id or not board_id:
        return None

    return DeploymentNode(
        deploymentId=deployment_id,
        boardId=board_id,
        latitude=latitude,
        longitude=longitude,
        locationName=_normalize_string(
            row.get("location_name"),
            "Ubicacion sin nombre",
        ),
        timestamp="",
        sensorType=_normalize_optional_string(row.get("sensor_type")),
    )


def _extract_first_timestamp(
    row: dict[str, Any],
    keys: tuple[str, ...],
) -> str:
    for key in keys:
        if key in row:
            return _normalize_timestamp(row.get(key))
    return ""


def _parse_timestamp(value: Any) -> datetime | None:
    timestamp = _normalize_timestamp(value).strip()
    if not timestamp:
        return None

    normalized = timestamp.replace(" ", "T")
    if normalized.endswith("Z"):
        normalized = normalized[:-1] + "+00:00"

    if "." in normalized:
        prefix, suffix = normalized.split(".", 1)
        tz_index = max(suffix.rfind("+"), suffix.rfind("-"))

        if tz_index >= 0:
            fraction = suffix[:tz_index]
            timezone_suffix = suffix[tz_index:]
        else:
            fraction = suffix
            timezone_suffix = ""

        digits = "".join(character for character in fraction if character.isdigit())
        normalized = f"{prefix}.{(digits + '000000')[:6]}{timezone_suffix}"

    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return None

    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)

    return parsed.astimezone(timezone.utc)


def _format_bucket_timestamp(value: datetime) -> str:
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _average_or_none(total: float, count: int) -> float | None:
    if count == 0:
        return None
    return total / count


def _bucket_telemetry_rows(rows: list[dict[str, Any]]) -> list[TelemetryPoint]:
    buckets: dict[datetime, dict[str, float | int]] = {}

    for row in rows:
        timestamp = _parse_timestamp(row.get("ts"))
        if timestamp is None:
            continue

        bucket_start = timestamp.replace(
            minute=(timestamp.minute // 5) * 5,
            second=0,
            microsecond=0,
        )

        bucket = buckets.setdefault(
            bucket_start,
            {
                "co2_total": 0.0,
                "co2_count": 0,
                "temp_total": 0.0,
                "temp_count": 0,
                "rh_total": 0.0,
                "rh_count": 0,
            },
        )

        co2 = _normalize_float(row.get("co2"))
        if co2 is not None:
            bucket["co2_total"] += co2
            bucket["co2_count"] += 1

        temp = _normalize_float(row.get("temp"))
        if temp is not None:
            bucket["temp_total"] += temp
            bucket["temp_count"] += 1

        rh = _normalize_float(row.get("rh"))
        if rh is not None:
            bucket["rh_total"] += rh
            bucket["rh_count"] += 1

    return [
        TelemetryPoint(
            timestamp=_format_bucket_timestamp(bucket_start),
            co2=_average_or_none(bucket["co2_total"], int(bucket["co2_count"])),
            temp=_average_or_none(bucket["temp_total"], int(bucket["temp_count"])),
            rh=_average_or_none(bucket["rh_total"], int(bucket["rh_count"])),
        )
        for bucket_start, bucket in sorted(buckets.items())
    ]


async def get_health() -> dict[str, str]:
    client = await get_questdb_client()
    await client.execute("SELECT 1;")
    settings = get_settings()
    return {
        "status": "ok",
        "questdb": "reachable",
        "version": settings.app_version,
    }


async def list_deployments() -> list[DeploymentNode]:
    async def load_deployments() -> list[DeploymentNode]:
        client = await get_questdb_client()
        rows = await client.execute(
            """
            SELECT
              deployment_id,
              board_id,
              latitude,
              longitude,
              location_name,
              deployed_at
            FROM (
              SELECT *
              FROM deployments
              WHERE latitude IS NOT NULL
                AND longitude IS NOT NULL
              LATEST ON deployed_at PARTITION BY deployment_id
            )
            ORDER BY deployed_at DESC;
            """
        )

        nodes: list[DeploymentNode] = []

        for row in rows:
            node = _build_node(row)
            if node is None:
                continue

            node.timestamp = _extract_first_timestamp(row, ("deployed_at",))
            nodes.append(node)

        return nodes

    return await _deployments_cache.get_or_set("all", load_deployments)


async def get_deployment_detail(deployment_id: str) -> DeploymentDetail:
    async def load_deployment_detail() -> DeploymentDetail:
        client = await get_questdb_client()
        safe_deployment_id = _escape_sql_literal(deployment_id)

        deployment_rows = await client.execute(
            f"""
            SELECT deployment_id, board_id, latitude, longitude, location_name, deployed_at
            FROM deployments
            WHERE deployment_id = '{safe_deployment_id}'
            ORDER BY deployed_at DESC
            LIMIT 1;
            """
        )

        if not deployment_rows:
            raise HTTPException(status_code=404, detail="Deployment no encontrado.")

        node = _build_node(deployment_rows[0])
        if node is None:
            raise HTTPException(status_code=422, detail="Deployment invalido.")

        sensor_rows = await client.execute(
            f"""
            SELECT sensor_type, registered_at
            FROM devices
            WHERE board_id = '{_escape_sql_literal(node.board_id)}'
            ORDER BY registered_at DESC
            LIMIT 1;
            """
        )

        telemetry_rows = await client.execute(
            f"""
            SELECT co2, temp, rh, errors, ts
            FROM telemetria_datos
            WHERE deployment_id = '{safe_deployment_id}'
            ORDER BY ts DESC
            LIMIT 1;
            """
        )

        latest = telemetry_rows[0] if telemetry_rows else {}

        return DeploymentDetail(
            deploymentId=node.deployment_id,
            boardId=node.board_id,
            latitude=node.latitude,
            longitude=node.longitude,
            locationName=node.location_name,
            timestamp=_extract_first_timestamp(deployment_rows[0], ("deployed_at",)),
            sensorType=_normalize_optional_string(
                sensor_rows[0].get("sensor_type") if sensor_rows else None
            ),
            latestCo2=_normalize_float(latest.get("co2")),
            latestTemp=_normalize_float(latest.get("temp")),
            latestRh=_normalize_float(latest.get("rh")),
            latestErrors=_normalize_int(latest.get("errors")),
            variables=["CO2", "Temperatura", "Humedad relativa"],
        )

    return await _deployment_detail_cache.get_or_set(
        f"deployment:{deployment_id}",
        load_deployment_detail,
    )


async def get_deployment_telemetry(
    deployment_id: str,
    hours: int,
) -> list[TelemetryPoint]:
    client = await get_questdb_client()
    safe_deployment_id = _escape_sql_literal(deployment_id)

    rows = await client.execute(
        f"""
        SELECT ts, co2, temp, rh
        FROM telemetria_datos
        WHERE deployment_id = '{safe_deployment_id}'
          AND ts > dateadd('h', -{hours}, now())
        ORDER BY ts ASC;
        """
    )

    return _bucket_telemetry_rows(rows)
