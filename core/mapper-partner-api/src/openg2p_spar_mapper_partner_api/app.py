# ruff: noqa: E402
import asyncio
import logging

from .config import Settings

_config = Settings.get_config()

from openg2p_fastapi_common.app import Initializer as BaseInitializer
from openg2p_fastapi_partner_auth.jwt_validation_helper import JWTValidationHelper
from openg2p_spar_mapper_core.helpers import ResponseHelper, StrategyHelper
from openg2p_spar_mapper_core.services import (
    IdFaMappingValidations,
    MapperService,
    RequestValidation,
)
from openg2p_spar_models.crypto import PyJWTCryptoHelper
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
        PyJWTCryptoHelper(
            partner_keys_dir=_config.partner_keys_dir,
            allowed_algorithms=[
                alg.strip()
                for alg in _config.signature_allowed_algorithms.split(",")
                if alg.strip()
            ],
        )

        MapperController().post_init()

    def migrate_database(self, args):
        super().migrate_database(args)

        async def migrate():
            _logger.info("Migrating database")
            await IdFaMapping.create_migrate()
            await Strategy.create_migrate()

        asyncio.run(migrate())
