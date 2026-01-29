#! /bin/bash

docker build -t axiio-build-image:v1  -f docker/Dockerfile .
 
# docker run --rm axiio-build-image:v1 find /usr -name "CLI.hpp"

docker run -it --rm   --device=/dev/kfd   --device=/dev/dri \
      	axiio-build-image:v1 \
	CXXFLAGS="-ferror-limit=10" \
	make all

