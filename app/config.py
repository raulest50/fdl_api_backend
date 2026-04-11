from functools import lru_cache
from typing import List

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_name: str = "Frontera Data Labs API"
    app_version: str = "0.1.0"
    api_host: str = "0.0.0.0"
    api_port: int = 8000
    questdb_base_url: str = "http://127.0.0.1:9000"
    api_cors_origins_raw: str = Field(
        default="http://localhost:5174",
        alias="API_CORS_ORIGINS",
    )
    query_timeout_seconds: float = 15.0

    model_config = SettingsConfigDict(
      env_file=".env",
      env_file_encoding="utf-8",
      extra="ignore",
      populate_by_name=True,
    )

    @property
    def api_cors_origins(self) -> List[str]:
        return [
            origin.strip()
            for origin in self.api_cors_origins_raw.split(",")
            if origin.strip()
        ]


@lru_cache
def get_settings() -> Settings:
    return Settings()
