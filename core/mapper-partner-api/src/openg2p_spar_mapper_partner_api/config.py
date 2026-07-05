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

    keymanager_sign_app_id: str = "SPAR"
    # SPAR_MAPPER_PARTNER_API_JWT_AUTH_ENABLED — when false, signature validation is skipped.
    jwt_auth_enabled: bool = False

    # Verify inbound partner signatures against public keys fetched from the Partner
    # Manager (PM) service. `partner_mgmt_api_url` + partner_key_* cache settings are
    # inherited from the openg2p-fastapi-common base Settings.
    crypto_backend: str = "partner-mgmt"
