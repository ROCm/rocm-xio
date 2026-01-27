#! /bin/bash

docker build -t axiio-build-image:v1  -f docker/Dockerfile .

docker run -it --rm   --device=/dev/kfd   --device=/dev/dri \
      	axiio-build-image:v1 \
	find / -name "CLI.hpp" 2> /dev/null; \
	export CPATH="/usr/include" ; \
	echo ${CPATH} ; \
	pwd; ls ; \
	make all

#	pwd; ls; which make; cd ../; make all
#	echo $CPATH ; \

