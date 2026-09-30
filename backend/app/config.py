import os
from dataclasses import dataclass, field


def _split(v: str) -> list[str]:
    return [x.strip() for x in v.split(",") if x.strip()]


@dataclass(frozen=True)
class Settings:
    env: str = os.getenv("ENV", "dev")
    allowed_origins: list[str] = field(
        default_factory=lambda: _split(os.getenv("ALLOWED_ORIGINS", "http://localhost:5173"))
    )
    # AWS Cognito (prod). If COGNITO_JWKS_URL is set, RS256 tokens are verified against it.
    cognito_jwks_url: str = os.getenv("COGNITO_JWKS_URL", "")
    cognito_issuer: str = os.getenv("COGNITO_ISSUER", "")
    cognito_client_id: str = os.getenv("COGNITO_CLIENT_ID", "")
    # Dev-only symmetric secret
    dev_secret: str = os.getenv("DEV_JWT_SECRET", "dev-only-secret-change-me-0123456789abcdef")


settings = Settings()
