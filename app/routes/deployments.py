from typing import List

from fastapi import APIRouter, Path, Query

from ..models import DeploymentDetail, DeploymentNode, TelemetryPoint
from ..questdb import (
    get_deployment_detail,
    get_deployment_telemetry,
    list_deployments,
)

router = APIRouter(prefix="/api/deployments", tags=["deployments"])


@router.get("", response_model=List[DeploymentNode])
async def fetch_deployments():
    return await list_deployments()


@router.get("/{deployment_id}", response_model=DeploymentDetail)
async def fetch_deployment_detail(
    deployment_id: str = Path(..., min_length=3),
):
    return await get_deployment_detail(deployment_id)


@router.get("/{deployment_id}/telemetry", response_model=List[TelemetryPoint])
async def fetch_deployment_telemetry(
    deployment_id: str = Path(..., min_length=3),
    hours: int = Query(default=24, ge=1, le=168),
):
    return await get_deployment_telemetry(deployment_id, hours)
