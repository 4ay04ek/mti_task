import os
from dataclasses import dataclass
from functools import lru_cache

import jwt
from fastapi import Depends, HTTPException
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

bearer = HTTPBearer(auto_error=False)


@dataclass
class Principal:
    subject: str
    roles: set[str]
    name: str


@lru_cache
def key_client():
    return jwt.PyJWKClient(os.environ['AUTH_JWKS_URL'], cache_keys=True, lifespan=300)


def get_principal(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)):
    if credentials is None:
        raise HTTPException(401, 'Требуется вход', headers={'WWW-Authenticate': 'Bearer'})
    try:
        key = key_client().get_signing_key_from_jwt(credentials.credentials)
        claims = jwt.decode(
            credentials.credentials, key.key, algorithms=['RS256'],
            issuer=os.environ['AUTH_ISSUER'], audience=os.environ['AUTH_AUDIENCE'],
            options={'require': ['exp', 'iat', 'sub', 'iss', 'aud']},
        )
    except (jwt.PyJWTError, jwt.PyJWKClientError):
        raise HTTPException(401, 'Недействительный токен', headers={'WWW-Authenticate': 'Bearer'}) from None
    return Principal(claims['sub'], set(claims.get('realm_access', {}).get('roles', [])),
                     claims.get('name') or claims.get('preferred_username', claims['sub']))


def require_admin(user: Principal = Depends(get_principal)):
    if 'admin' not in user.roles:
        raise HTTPException(403, 'Требуются права администратора')
    return user


def require_trainer(user: Principal = Depends(get_principal)):
    if 'training-export' not in user.roles:
        raise HTTPException(403, 'Требуется сервисная учётная запись')
    return user
