# ruff: noqa: E402
import asyncio
import logging

from .config import Settings

_config = Settings.get_config()

from openg2p_fastapi_common.app import Initializer as BaseInitializer
from openg2p_fastapi_common.models import PartnerKey
from openg2p_fastapi_common.utils.crypto import build_crypto_helper, seed_partner_certs
from openg2p_fastapi_partner_auth.jwt_validation_helper import JWTValidationHelper
from openg2p_spar_mapper_core.helpers import ResponseHelper, StrategyHelper
from openg2p_spar_mapper_core.services import (
    IdFaMappingValidations,
    MapperService,
    RequestValidation,
)
from openg2p_spar_models.models import IdFaMapping, Strategy

from .controllers import MapperController

_logger = logging.getLogger(_config.logging_default_logger_name)


class Initializer(BaseInitializer):
    def initialize(self, **kwargs):
        super().initialize()

        IdFaMappingValidations()
        RequestValidation()
        StrategyHelper()
        MapperService()
        ResponseHelper()
        JWTValidationHelper()
        # Inbound partner-signature verification. Backend (keymanager | local) is
        # chosen by crypto_backend config; see openg2p_fastapi_common.utils.crypto.
        # SPAR only verifies (it does not sign), so no signing key is configured.
        build_crypto_helper()

        MapperController().post_init()

    def migrate_database(self, args):
        super().migrate_database(args)

        async def migrate():
            _logger.info("Migrating database")
            await IdFaMapping.create_migrate()
            await Strategy.create_migrate()
            # Local crypto backend: create the partner_keys table and seed-onboard
            # configured partner certs (idempotent). No-op for the keymanager backend.
            if _config.crypto_backend == "local":
                await PartnerKey.create_migrate()
                await seed_partner_certs(_config.crypto_partner_certs)

        asyncio.run(migrate())
