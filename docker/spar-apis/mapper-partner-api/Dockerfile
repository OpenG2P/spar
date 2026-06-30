FROM python:3.11-slim

# External OpenG2P library ref (not part of this repo). Override via build-arg /
# workflow input. The SPAR code itself is installed from local source (core/).
ARG FASTAPI_COMMON_REF=develop

ARG container_user=openg2p
ARG container_user_group=openg2p
ARG container_user_uid=1001
ARG container_user_gid=1001

# Create non-root user
RUN groupadd -g ${container_user_gid} ${container_user_group} && \
    useradd -mN -u ${container_user_uid} -G ${container_user_group} -s /bin/bash ${container_user}

WORKDIR /app

# Install dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    libpq-dev \
    git \
    gunicorn \
  && apt-get clean \
  && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives

# Local SPAR source (build context = repo root).
ADD --chown=${container_user}:${container_user_group} core/models /app/models
ADD --chown=${container_user}:${container_user_group} core/mapper-core /app/mapper-core
ADD --chown=${container_user}:${container_user_group} core/mapper-partner-api /app/mapper-partner-api

# Install Python dependencies
RUN python -m pip install --upgrade pip setuptools wheel && \
    python -m pip install --no-cache-dir \
      git+https://github.com/openg2p/openg2p-fastapi-common@${FASTAPI_COMMON_REF}#subdirectory=openg2p-fastapi-auth-models \
      git+https://github.com/openg2p/openg2p-fastapi-common@${FASTAPI_COMMON_REF}#subdirectory=openg2p-fastapi-auth \
      git+https://github.com/openg2p/openg2p-fastapi-common@${FASTAPI_COMMON_REF}#subdirectory=openg2p-fastapi-partner-auth \
      git+https://github.com/openg2p/openg2p-fastapi-common@${FASTAPI_COMMON_REF}#subdirectory=openg2p-fastapi-common && \
    python -m pip install --no-cache-dir -e /app/models && \
    python -m pip install --no-cache-dir -e /app/mapper-core && \
    python -m pip install --no-cache-dir -e /app/mapper-partner-api

# Switch to non-root user
USER ${container_user}

# Environment variables
ENV PYTHONUNBUFFERED=1
ENV PYTHONDONTWRITEBYTECODE=1
ENV SPAR_MAPPER_PARTNER_API_HOST=0.0.0.0
ENV SPAR_MAPPER_PARTNER_API_PORT=8000
ENV SPAR_MAPPER_PARTNER_API_NO_OF_WORKERS=4

# Set working directory to the mapper partner API
WORKDIR /app/mapper-partner-api

# Run application
CMD ["sh", "-c", "python main.py migrate && gunicorn main:app --workers ${SPAR_MAPPER_PARTNER_API_NO_OF_WORKERS} --worker-class uvicorn.workers.UvicornWorker --bind ${SPAR_MAPPER_PARTNER_API_HOST}:${SPAR_MAPPER_PARTNER_API_PORT} --log-level info --access-logfile - --error-logfile -"]
