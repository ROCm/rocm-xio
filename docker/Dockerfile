# Use the official ROCm 6.2 development image as a base (Update to current version as needed)
FROM rocm/dev-ubuntu-24.04:latest

# Install additional development tools
RUN apt-get update && apt-get install -y \
	rocm-hip-sdk rocminfo libcli11-dev cmake \
  	libdrm-dev libhsa-runtime-dev \
	&& rm -rf /var/lib/apt/lists/*

# COPY /home/AMD/dondai/rocm-xio.git /rocm-xio.git

# Set working directory
WORKDIR /home/AMD/dondai/rocm-xio.git

# Set environment variables
ENV PATH="${PATH}:/opt/rocm/bin"
ENV LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:/opt/rocm/lib"

CMD ["which cmake"]
CMD ["/bin/bash"]

