from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import httpx
from fastapi import HTTPException

from .config import get_settings
from .models import DeploymentDetail, DeploymentNode, TelemetryPoint


@dataclass
class QuestDbClient:
    base_url: str
    timeout_seconds: float

    async def execute(self, query: str) -> list[dict[str, Any]]:
        url = f"{self.base_url.rstrip('/')}/exec"

        try:
            async with httpx.AsyncClient(timeout=self.timeout_seconds) as client:
                response = await client.get(url, params={"query": query})
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
        timestamp=_normalize_timestamp(row.get("timestamp")),
        sensorType=_normalize_optional_string(row.get("sensor_type")),
    )


async def get_health() -> dict[str, str]:
    settings = get_settings()
    client = QuestDbClient(
        base_url=settings.questdb_base_url,
        timeout_seconds=settings.query_timeout_seconds,
    )
    await client.execute("SELECT 1;")
    return {
        "status": "ok",
        "questdb": "reachable",
        "version": settings.app_version,
    }


async def list_deployments() -> list[DeploymentNode]:
    settings = get_settings()
    client = QuestDbClient(
        base_url=settings.questdb_base_url,
        timeout_seconds=settings.query_timeout_seconds,
    )

    rows = await client.execute(
        """
        SELECT
          deployment_id,
          board_id,
          latitude,
          longitude,
          location_name,
          timestamp
        FROM deployments
        WHERE latitude IS NOT NULL
          AND longitude IS NOT NULL
        ORDER BY timestamp DESC;
        """
    )

    deployments_by_id: dict[str, DeploymentNode] = {}

    for row in rows:
        node = _build_node(row)
        if node is None:
            continue

        if node.deployment_id not in deployments_by_id:
            deployments_by_id[node.deployment_id] = node

    return list(deployments_by_id.values())


async def get_deployment_detail(deployment_id: str) -> DeploymentDetail:
    settings = get_settings()
    client = QuestDbClient(
        base_url=settings.questdb_base_url,
        timeout_seconds=settings.query_timeout_seconds,
    )

    safe_deployment_id = _escape_sql_literal(deployment_id)

    deployment_rows = await client.execute(
        f"""
        SELECT deployment_id, board_id, latitude, longitude, location_name, timestamp
        FROM deployments
        WHERE deployment_id = '{safe_deployment_id}'
        ORDER BY timestamp DESC
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
        SELECT sensor_type, timestamp
        FROM devices
        WHERE board_id = '{_escape_sql_literal(node.board_id)}'
        ORDER BY timestamp DESC
        LIMIT 1;
        """
    )

    telemetry_rows = await client.execute(
        f"""
        SELECT co2, temp, rh, errors, timestamp
        FROM telemetria_datos
        WHERE deployment_id = '{safe_deployment_id}'
        ORDER BY timestamp DESC
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
        timestamp=node.timestamp,
        sensorType=_normalize_optional_string(
            sensor_rows[0].get("sensor_type") if sensor_rows else None
        ),
        latestCo2=_normalize_float(latest.get("co2")),
        latestTemp=_normalize_float(latest.get("temp")),
        latestRh=_normalize_float(latest.get("rh")),
        latestErrors=_normalize_int(latest.get("errors")),
        variables=["CO2", "Temperatura", "Humedad relativa"],
    )


async def get_deployment_telemetry(
    deployment_id: str,
    hours: int,
) -> list[TelemetryPoint]:
    settings = get_settings()
    client = QuestDbClient(
        base_url=settings.questdb_base_url,
        timeout_seconds=settings.query_timeout_seconds,
    )
    safe_deployment_id = _escape_sql_literal(deployment_id)

    rows = await client.execute(
        f"""
        SELECT timestamp, co2, temp, rh
        FROM telemetria_datos
        WHERE deployment_id = '{safe_deployment_id}'
          AND timestamp > dateadd('h', -{hours}, now())
        ORDER BY timestamp ASC;
        """
    )

    return [
        TelemetryPoint(
            timestamp=_normalize_timestamp(row.get("timestamp")),
            co2=_normalize_float(row.get("co2")),
            temp=_normalize_float(row.get("temp")),
            rh=_normalize_float(row.get("rh")),
        )
        for row in rows
    ]
