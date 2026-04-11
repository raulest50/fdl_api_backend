from fastapi import APIRouter

from ..models import HealthResponse
from ..questdb import get_health

router = APIRouter(tags=["health"])


@router.get("/health", response_model=HealthResponse)
async def healthcheck():
    return await get_health()
