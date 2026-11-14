# Horizon collector image.
#
# Bases are pinned to local registry mirrors (no Docker Hub pulls at build time):
#   python  -> 100.64.2.4:30095/base/python:3.11-slim-bookworm
#   ruby    -> 100.64.2.4:30095/base/ruby:pin-ff060227   (Dockerfile.site)
# `uv` is installed from the configured package index at build time instead of
# COPYing a floating uv image, so the runtime layer contains no uv cache or
# install step.
ARG PYTHON_IMAGE=100.64.2.4:30095/base/python:3.11-slim-bookworm@sha256:1f1ec589b344271dbfe75a010b6e6d10d7ef240e157421ac1a18ae72397ee443
ARG PYPI_INDEX_URL=https://mirrors.aliyun.com/pypi/simple
ARG UV_VERSION=0.12.17

# ---------------------------------------------------------------- base
FROM ${PYTHON_IMAGE} AS base

ARG PYPI_INDEX_URL
ARG UV_VERSION
ARG EXTRAS=""

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_INDEX_URL=${PYPI_INDEX_URL} \
    UV_DEFAULT_INDEX=${PYPI_INDEX_URL} \
    UV_INDEX_URL=${PYPI_INDEX_URL} \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never

WORKDIR /app

RUN set -eu; \
    for attempt in 1 2 3; do \
      pip install --no-cache-dir "uv==${UV_VERSION}" && break; \
      [ "$attempt" -lt 3 ] || exit 1; \
      echo "uv install attempt ${attempt}/3 failed; retrying" >&2; \
    done

COPY pyproject.toml uv.lock README.md ./
COPY src ./src
COPY data ./data
COPY profiles ./profiles
COPY .env.example .env.example

RUN set -eu; \
    set --; \
    if [ -n "$EXTRAS" ]; then \
        case "$EXTRAS" in ,*|*,|*,,*) echo "Invalid EXTRAS list: $EXTRAS" >&2; exit 2 ;; esac; \
        old_ifs=$IFS; IFS=,; \
        for extra in $EXTRAS; do \
            case "$extra" in [._-]*|*[._-]|*[!A-Za-z0-9._-]*) echo "Invalid extra: $extra" >&2; exit 2 ;; esac; \
            set -- "$@" --extra "$extra"; \
        done; \
        IFS=$old_ifs; \
    fi; \
    for attempt in 1 2 3; do \
      uv sync --frozen --no-dev "$@" && break; \
      [ "$attempt" -lt 3 ] || exit 1; \
      echo "uv sync attempt ${attempt}/3 failed; retrying" >&2; \
    done

# ---------------------------------------------------------------- test
# Carries the locked dev extra and the test suite so the factory can run the
# targeted regression set against the exact runtime dependencies.
FROM base AS test

RUN set -eu; \
    for attempt in 1 2 3; do \
      uv sync --frozen --extra dev && break; \
      [ "$attempt" -lt 3 ] || exit 1; \
      echo "uv sync (dev) attempt ${attempt}/3 failed; retrying" >&2; \
    done

COPY tests ./tests
COPY pyproject.toml ./

CMD ["python", "-m", "pytest", "-q", \
     "tests/test_openai_unauthenticated.py", \
     "tests/test_main.py", \
     "tests/test_fetch_reporting.py"]

# ---------------------------------------------------------------- runtime
FROM base AS runtime

ENV PATH="/app/.venv/bin:${PATH}" \
    HORIZON_DATA_DIR=/app/data

# Runtime data is mounted here; keep the image and process unprivileged.
RUN groupadd --gid 10001 horizon \
    && useradd --create-home --uid 10001 --gid 10001 horizon \
    && mkdir -p /app/data \
    && chown -R horizon:horizon /app

VOLUME ["/app/data"]

USER horizon

ENTRYPOINT ["/app/.venv/bin/horizon"]
CMD []
