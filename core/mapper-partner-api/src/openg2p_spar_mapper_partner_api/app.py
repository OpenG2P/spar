# ruff: noqa: E402
import asyncio
import logging

from .config import Settings

_config = Settings.get_config()

from openg2p_fastapi_common.app import Initializer as BaseInitializer
from openg2p_fastapi_common.utils.crypto import build_crypto_helper
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
        # Inbound partner-signature verification — fetches partner public keys from
        # the Partner Manager (PM) service (crypto_backend=partner-mgmt). SPAR only
        # verifies (never signs) and keeps no local key store; see
        # openg2p_fastapi_common.utils.crypto.PartnerMgmtKeyStore.
        build_crypto_helper()

        MapperController().post_init()

    def migrate_database(self, args):
        super().migrate_database(args)

        async def migrate():
            _logger.info("Migrating database")
            await IdFaMapping.create_migrate()
            await Strategy.create_migrate()
            # Partner public keys are served by the Partner Manager (PM) service —
            # no local partner_keys table or cert seeding here.

        asyncio.run(migrate())
