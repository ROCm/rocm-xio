# Use the official ROCm 6.2 development image as a base (Update to current version as needed)
FROM rocm/dev-ubuntu-24.04:latest

# Install additional development tools
RUN apt-get update && apt-get install -y \
    build-essential \
    git \
    cmake \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
# WORKDIR ../

# 4. Set environment variables
ENV PATH="${PATH}:/opt/rocm/bin"
ENV LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:/opt/rocm/lib"

# RUN apt-get install -y libcli11-dev
# Fix for libcli11-dev error
RUN apt-get update && \
    apt-get install -y software-properties-common && \
    add-apt-repository universe 

RUN apt-get update && \
    apt-get install -y libcli11-dev && \
    rm -rf /var/lib/apt/lists/*

