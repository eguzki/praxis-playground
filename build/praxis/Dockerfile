# Multi-stage configurable Praxis AI build
#
# Build args:
#   PRAXIS_FEATURES          - Cargo features to enable (comma-separated)
#   PRAXIS_AI_SOURCE         - Source spec: git:REF | crate:VERSION | path:PATH
#   PRAXIS_CORE_SOURCE       - Core source spec
#   PRAXIS_POLICY_SOURCE     - Policy source spec
#   APPLY_RATELIMIT_PATCHES  - Apply experimental-ratelimit vendoring/patches (true|false)

ARG PRAXIS_FEATURES=full,token-rate-limit-filter
ARG PRAXIS_AI_SOURCE=git:main
ARG PRAXIS_CORE_SOURCE=crate:0.7.5
ARG PRAXIS_POLICY_SOURCE=crate:0.4.1
ARG APPLY_RATELIMIT_PATCHES=false

# ============================================================================
# Stage 1: Source Fetcher
# ============================================================================

FROM rust:1.81 AS source-fetcher

ARG PRAXIS_AI_SOURCE
ARG PRAXIS_CORE_SOURCE
ARG PRAXIS_POLICY_SOURCE

WORKDIR /src

# Install git for cloning
RUN apt-get update && apt-get install -y git && rm -rf /var/lib/apt/lists/*

# Fetch praxis-proxy/ai
RUN echo "Fetching PRAXIS_AI_SOURCE=${PRAXIS_AI_SOURCE}" && \
    case "${PRAXIS_AI_SOURCE}" in \
      git:*) \
        REF="${PRAXIS_AI_SOURCE#git:}"; \
        git clone --depth 1 --branch "${REF}" https://github.com/praxis-proxy/ai.git praxis-ai || \
        git clone https://github.com/praxis-proxy/ai.git praxis-ai; \
        cd praxis-ai && git checkout "${REF}"; \
        ;; \
      crate:*) \
        echo "ERROR: crate: source not yet implemented for PRAXIS_AI_SOURCE" >&2; \
        exit 1; \
        ;; \
      path:*) \
        echo "ERROR: path: source requires bind-mount, not applicable in Dockerfile" >&2; \
        exit 1; \
        ;; \
      *) \
        echo "ERROR: Invalid PRAXIS_AI_SOURCE format: ${PRAXIS_AI_SOURCE}" >&2; \
        exit 1; \
        ;; \
    esac

# TODO: Fetch praxis-core and praxis-policy for experimental-ratelimit vendoring
# For now, most configs use published crates via workspace dependencies

# ============================================================================
# Stage 2: Ratelimit Patches (if enabled)
# ============================================================================

FROM source-fetcher AS ratelimit-patches-prep

ARG APPLY_RATELIMIT_PATCHES

# Install Python3 for patches (git already installed from source-fetcher)
RUN apt-get update && apt-get install -y python3 && rm -rf /var/lib/apt/lists/*

# Copy patches script
COPY apply-experimental-ratelimit-patches.sh /tmp/

# Apply patches if requested
RUN if [ "${APPLY_RATELIMIT_PATCHES}" = "true" ]; then \
      echo "Applying experimental-ratelimit patches..."; \
      chmod +x /tmp/apply-experimental-ratelimit-patches.sh; \
      export PRAXIS_AI_SOURCE_DIR=/src/praxis-ai; \
      export PRAXIS_POLICY_REPO=https://github.com/praxis-proxy/policy; \
      export PRAXIS_POLICY_REF=main; \
      export PRAXIS_CORE_REPO=https://github.com/praxis-proxy/praxis; \
      export PRAXIS_CORE_REF=v0.7.5; \
      /tmp/apply-experimental-ratelimit-patches.sh; \
    else \
      echo "Skipping experimental-ratelimit patches"; \
    fi

# ============================================================================
# Stage 3: Builder
# ============================================================================

FROM rust:1.81 AS builder

ARG PRAXIS_FEATURES

# Install build dependencies
RUN apt-get update && \
    apt-get install -y \
      pkg-config \
      libssl-dev \
      cmake \
      protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*

# Copy source from previous stages
COPY --from=ratelimit-patches-prep /src/praxis-ai /src/praxis-ai

WORKDIR /src/praxis-ai

# Build with specified features
RUN echo "Building with features: ${PRAXIS_FEATURES}" && \
    cargo build --release --features="${PRAXIS_FEATURES}" --bin praxis-ai

# ============================================================================
# Stage 4: Runtime
# ============================================================================

FROM debian:bookworm-slim

# Install runtime dependencies
RUN apt-get update && \
    apt-get install -y \
      ca-certificates \
      curl \
    && rm -rf /var/lib/apt/lists/*

# Copy binary
COPY --from=builder /src/praxis-ai/target/release/praxis-ai /usr/local/bin/praxis-ai

# Create config directory
RUN mkdir -p /etc/praxis

# Expose ports
EXPOSE 8080 9901

ENTRYPOINT ["praxis-ai"]
CMD ["-c", "/etc/praxis/praxis-ai.yaml"]
