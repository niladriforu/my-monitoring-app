"""JWT authentication + role based access control."""
import time
from dataclasses import dataclass

import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from .config import settings

bearer = HTTPBearer(auto_error=False)
ROLE_RANK = {"viewer": 1, "analyst": 2, "admin": 3}
_jwk_client = jwt.PyJWKClient(settings.cognito_jwks_url) if settings.cognito_jwks_url else None


@dataclass
class Principal:
    sub: str
    roles: list[str]


def dev_token() -> str:
    now = int(time.time())
    return jwt.encode(
        {"sub": "dev-user", "cognito:groups": ["analyst"], "iat": now, "exp": now + 3600},
        settings.dev_secret,
        algorithm="HS256",
    )


def _decode(token: str) -> dict:
    if _jwk_client:  # production: Cognito RS256
        key = _jwk_client.get_signing_key_from_jwt(token).key
        return jwt.decode(
            token, key, algorithms=["RS256"],
            issuer=settings.cognito_issuer,
            options={"verify_aud": False},
        )
    if settings.env == "prod":
        raise HTTPException(status.HTTP_500_INTERNAL_SERVER_ERROR, "auth not configured")
    return jwt.decode(token, settings.dev_secret, algorithms=["HS256"])


def current_user(creds: HTTPAuthorizationCredentials | None = Depends(bearer)) -> Principal:
    if creds is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "missing token")
    try:
        claims = _decode(creds.credentials)
    except jwt.PyJWTError:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid token")
    return Principal(sub=claims["sub"], roles=claims.get("cognito:groups", ["viewer"]))


def require_role(minimum: str):
    def dep(user: Principal = Depends(current_user)) -> Principal:
        best = max((ROLE_RANK.get(r, 0) for r in user.roles), default=0)
        if best < ROLE_RANK[minimum]:
            raise HTTPException(status.HTTP_403_FORBIDDEN, "insufficient role")
        return user
    return dep
