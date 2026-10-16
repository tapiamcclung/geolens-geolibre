"""Validation of Clerk session JWTs for the GeoLibre API."""

import threading
from urllib.parse import urlsplit

from joserfc import jwt
from joserfc.errors import InvalidKeyIdError, JoseError
from joserfc.jws import JWSRegistry
from joserfc.registry import HeaderParameter
from sqlalchemy.orm import Session

from geolibre_server_api import oidc
from geolibre_server_api.auth_models import Account

CLOCK_LEEWAY_SECONDS = 60
JWKS_REFRESH_SECONDS = 60
MAX_TOKEN_LENGTH = 16384

_cache_lock = threading.Lock()
_key_cache: dict[str, tuple[object, int]] = {}

CLERK_JWT_REGISTRY = JWSRegistry(
    {
        "oiat": HeaderParameter("Clerk original issued-at", "int"),
        "cat": HeaderParameter("Clerk client ID", "str"),
    }
)

def _valid_issuer(issuer: str) -> bool:
    try:
        parsed = urlsplit(issuer)
        return (
            parsed.scheme == "https"
            and bool(parsed.hostname)
            and parsed.username is None
            and parsed.password is None
            and parsed.path in ("", "/")
            and not parsed.query
            and not parsed.fragment
        )
    except ValueError:
        return False


def _get_key_set(http, issuer: str, now_ts: int, *, force: bool = False):
    with _cache_lock:
        cached = _key_cache.get(issuer)

        if (
            cached is not None
            and not force
            and now_ts - cached[1] < JWKS_REFRESH_SECONDS
        ):
            return cached

        document = oidc.fetch_json(
            http,
            "GET",
            issuer.rstrip("/") + "/.well-known/jwks.json",
        )
        key_set = oidc._import_key_set(document)
        result = (key_set, now_ts)
        _key_cache[issuer] = result
        return result

def resolve_clerk_session_token(
    session: Session,
    http,
    token_str: str,
    *,
    issuer: str,
    allowed_origins: set[str],
    now_ts: int,
) -> tuple[Account, int]:
    """Verify a Clerk session JWT and resolve its stable GeoLibre identity."""

    if not _valid_issuer(issuer) or not allowed_origins:
        raise oidc.OidcError("Clerk configuration")

    if (
        not isinstance(token_str, str)
        or len(token_str) > MAX_TOKEN_LENGTH
        or token_str.count(".") != 2
    ):
        raise oidc.OidcError("token format")

    try:
        key_set, _ = _get_key_set(http, issuer, now_ts)
        try:
            verified = jwt.decode(
                token_str, key_set, algorithms=["RS256"], registry=CLERK_JWT_REGISTRY,
            )
        except InvalidKeyIdError:
            key_set, _ = _get_key_set(
                http, issuer, now_ts, force=True
            )
            verified = jwt.decode(
                token_str, key_set, algorithms=["RS256"], registry=CLERK_JWT_REGISTRY,
            )
    except (JoseError, ValueError, KeyError, TypeError):
        raise oidc.OidcError("Clerk signature") from None

    claims = verified.claims
    if not isinstance(claims, dict):
        raise oidc.OidcError("Clerk claims")

    if claims.get("iss") != issuer:
        raise oidc.OidcError("Clerk issuer")

    def is_int(value):
        return isinstance(value, int) and not isinstance(value, bool)

    expires = claims.get("exp")
    issued = claims.get("iat")
    not_before = claims.get("nbf")

    if not is_int(expires) or expires <= now_ts - CLOCK_LEEWAY_SECONDS:
        raise oidc.OidcError("Clerk expiry")
    if not is_int(issued) or issued > now_ts + CLOCK_LEEWAY_SECONDS:
        raise oidc.OidcError("Clerk issued-at")
    if expires <= issued:
        raise oidc.OidcError("Clerk time range")
    if not_before is not None and (
        not is_int(not_before)
        or not_before > now_ts + CLOCK_LEEWAY_SECONDS
    ):
        raise oidc.OidcError("Clerk not-before")

    azp = claims.get("azp")
    if not isinstance(azp, str) or azp not in allowed_origins:
        raise oidc.OidcError("Clerk authorized party")

    subject = claims.get("sub")
    if not isinstance(subject, str) or not subject or len(subject) > 255:
        raise oidc.OidcError("Clerk subject")

    account = oidc._resolve_identity(
        session,
        provider_key="clerk",
        provider_id=None,
        subject=subject,
        username_source=subject,
        new_email=lambda: None,
        managed_by=None,
        now_ts=now_ts,
    )
    session.commit()

    return account, issued

