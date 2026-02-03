#! /bin/bash

set -ex

docker build -t xio-build-image:v1  -f docker/Dockerfile .
 
# docker run --rm xio-build-image:v1 find /usr -name "CLI.hpp"
# docker run --rm xio-build-image:v1 cat /usr/include/CLI/CLI.hpp 
# docker run --rm xio-build-image:v1 pwd; ls; cd src/include; pwd ; cd ../.. 
docker run --rm xio-build-image:v1 \
    sh -c "mkdir -p /home/AMD/dondai/rocm-xio.git/src && \
           ln -s /usr/include/CLI /home/AMD/dondai/rocm-xio.git/src/include"
docker run --rm xio-build-image:v1 which cmake

docker run -it --rm   --device=/dev/kfd   --device=/dev/dri \
	-v $(pwd):/home/AMD/dondai/rocm-xio.git \
	-w /home/AMD/dondai/rocm-xio.git \
       	xio-build-image:v1 \
	sh -c "mkdir -p build && cd build && cmake .. && cmake --build . --target all"

set +x
echo "Build Complete!"

