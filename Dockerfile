# syntax=docker/dockerfile:1

# -----------------------
# Builder stage
# -----------------------
FROM python:3.11-slim-buster AS deps

# Core OS dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential \
        git \
        ffmpeg \
        libgl1 \
        libglib2.0-0 \
        libgomp1 && \
    rm -rf /var/lib/apt/lists/*

# Workdir for installing Python deps
WORKDIR /deps

# Copy requirements file
COPY backend/requirements.txt .

# Build wheels from source for scikit-learn
RUN --mount=type=cache,id=pip-cache-${TARGETOS}-${TARGETARCH},target=/root/.cache/pip \
    --mount=type=bind,source=backend/requirements.txt,target=requirements.txt \
    PIP_NO_BINARY=scikit-learn \
    pip install --no-cache-dir -r requirements.txt

# -----------------------
# Runtime stage (slimmer image)
# -----------------------
FROM python:3.11-slim-buster AS runtime

# Copy built site-packages
COPY --from=deps /usr/local /usr/local

# Install runtime OS dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        libgl1 \
        libglib2.0-0 \
        libgomp1 \
        curl && \
    rm -rf /var/lib/apt/lists/*

# Preload libgomp
ENV LD_PRELOAD=/usr/lib/aarch64-linux-gnu/libgomp.so.1 \
    OMP_NUM_THREADS=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app
# Copy backend code
COPY backend/ .

# Prefect home
ENV PREFECT_HOME=/root/.prefect

# Default entry
CMD ["bash"]