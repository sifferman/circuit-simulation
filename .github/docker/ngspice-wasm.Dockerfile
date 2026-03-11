FROM python:3.13-slim

ENV EMSDK_DIR=/opt/emsdk
ENV PYODIDE_RECIPES_DIR=/opt/pyodide-recipes
ENV PYODIDE_INSTALL_DIR=/opt/pyodide-install

SHELL ["/bin/bash", "-lc"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       build-essential git curl ca-certificates python3-venv python3-pip \
       autoconf automake libtool pkg-config cmake bison flex \
       libncurses5-dev libreadline-dev libx11-dev libxaw7-dev \
       wget unzip xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Install pyodide-build from pyodide-recipes.
RUN git clone https://github.com/pyodide/pyodide-recipes.git "${PYODIDE_RECIPES_DIR}" \
    && cd "${PYODIDE_RECIPES_DIR}" \
    && git submodule update --init --recursive \
    && python3 -m pip install --no-cache-dir ./pyodide-build

# Install emsdk version pinned by pyodide.
RUN git clone https://github.com/emscripten-core/emsdk.git "${EMSDK_DIR}" \
    && cd "${EMSDK_DIR}" \
    && EMS_VERSION="$(pyodide config get emscripten_version)" \
    && ./emsdk install "${EMS_VERSION}" \
    && ./emsdk activate "${EMS_VERSION}"

# Build libngspice WASM package.
RUN cd "${PYODIDE_RECIPES_DIR}" \
    && source "${EMSDK_DIR}/emsdk_env.sh" \
    && mkdir -p "${PYODIDE_INSTALL_DIR}" \
    && pyodide build-recipes libngspice --install --install-dir="${PYODIDE_INSTALL_DIR}"
