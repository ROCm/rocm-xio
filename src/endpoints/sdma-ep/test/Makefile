HIP_PATH?= $(wildcard /opt/rocm/)
ifeq (,$(HIP_PATH))
	HIP_PATH=../../..
endif

MPI_PATH=/home/nusislam/new-mpi-install/install/ompi/

HIPCC=$(HIP_PATH)/bin/hipcc

CXXFLAGS +=-g -I/home/nusislam/new-mpi-install/install/ompi/include -I/opt/rocm/include/ -I/home/nusislam/rocm-xio/src/endpoints/sdma-ep/ -I/home/nusislam/rocm-xio/install/include/rocm-xio -I/opt/rocm/include/hsa
CXX=$(HIPCC)
LDFLAGS += -L/home/nusislam/new-mpi-install/install/ompi/lib -L/opt/rocm/lib -L/home/nusislam/rocm-xio/install/lib
# librocm-xio.a pulls in hsaKmt* from anvil — link hsakmt; static libhsakmt.a also needs drm, numa, rt, dl.
LDLIBS += -lpthread -lm -lmpi -lrocm-xio -lhsa-runtime64 -lhsakmt -ldrm -ldrm_amdgpu -lnuma -lrt -ldl -lstdc++


TARGET = shader-sdma-coll

all: $(TARGET)

$(TARGET): $(TARGET).cpp
	$(CXX) $(CXXFLAGS) $(LDFLAGS) $(LDLIBS) -o $(TARGET) $(TARGET).cpp


clean:
	rm -f $(EXECUTABLE)
	rm -f $(OBJECTS)
	rm -f $(TARGET)
	rm -f $(TARGET).o
	rm -f $(HIP_PATH)/src/*.o
