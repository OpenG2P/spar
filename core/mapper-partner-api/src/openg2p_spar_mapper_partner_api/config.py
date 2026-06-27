from openg2p_fastapi_partner_auth.config import Settings as BaseSettings
from pydantic_settings import SettingsConfigDict

from . import __version__


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="spar_mapper_partner_api_", env_file=".env", extra="allow"
    )

    openapi_title: str = "OpenG2P SPAR Mapper Partner API"
    openapi_description: str = """
        FastAPI Service for OpenG2P SPAR Mapper Partner API
        ***********************************
        Further details goes here
        ***********************************
        """
    openapi_version: str = __version__

    # SPAR Database
    db_username: str = "postgres"
    db_password: str = "password"
    db_hostname: str = "localhost"
    db_port: int = 5432
    db_dbname: str = "spardb"

    # Inbound partner JWS signature verification (local, Keymanager-free).
    # SPAR_MAPPER_PARTNER_API_JWT_AUTH_ENABLED — when false, signature validation
    # is skipped entirely. When true, each request must carry a detached JWS in the
    # "Signature" header, verified against the partner's public key loaded from
    # partner_keys_dir (one JWKS file per partner, named PARTNER_<MNEMONIC>.json).
    # The G2P Bridge calls SPAR as sender_app_mnemonic=g2p_bridge -> PARTNER_G2P_BRIDGE.
    jwt_auth_enabled: bool = False
    partner_keys_dir: str = "/etc/spar/partner-keys"
    # Comma-separated allowed JWS algorithms. RS256 only (asymmetric); "none" and
    # HMAC (HS*) are always rejected regardless of this list.
    signature_allowed_algorithms: str = "RS256"
