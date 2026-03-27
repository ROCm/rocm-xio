#include <hip/hip_runtime.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <iostream>
#include <string>
#include <fstream>
#include "mpi.h"

#include <hip/hip_ext.h>
#include <hip/hip_runtime.h>

#include <unistd.h>
#include <stdio.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <sys/un.h>
#include <netdb.h>
#include <time.h>
#include <iomanip>
#include <chrono>
#include <map>

#include "anvil.hpp"
#include "anvil_device.hpp"
#include "sdma-ep.h"
#include "xio.h"


#define SUCCESS 0
#define FAILURE 1

#define N 128 * 1024 * 1024

#define FLOAT_PRECISION 2
#define FIELD_WIDTH 14
using namespace std;

// Helper macro for catching HIP errors
#define HIP_CALL(cmd)                                                                   \
    do {                                                                                \
        hipError_t error = (cmd);                                                       \
        if (error != hipSuccess)                                                        \
        {                                                                               \
            std::cerr << "Encountered HIP error (" << hipGetErrorString(error)          \
                      << ") at line " << __LINE__ << " in file " << __FILE__ << "\n";   \
            exit(-1);                                                                   \
        }                                                                               \
    } while (0)


// Initialize the anvil library singleton
static bool anvil_initialized = false;

void ensureAnvilInit() {
  if (!anvil_initialized) {
    anvil::AnvilLib::getInstance().init();
    anvil_initialized = true;
  }
}

/*__global__ void sdma_ag_kernel(anvil::SdmaQueueDeviceHandle* sendHandle, anvil::SdmaQueueDeviceHandle* recvHandle,
                                void* srcBuf, void *ptrs, size_t transferSize, int nranks, int myrank, uint64_t* sig_ptrs) {


}*/

int main(int argc, char* argv[])
{

    int myrank, nranks;
    int srcGpu, dstGpu;
    hipError_t err;

    // Store SDMA queue handles in a map indexed by rank
    std::map<int, anvil::SdmaQueueDeviceHandle*> sdmaSendHandles;
    std::map<int, anvil::SdmaQueueDeviceHandle*> sdmaRecvHandles;

    // Allocate individual signal memory on each GPU
    uint64_t* signals[8];
    //uint64_t* remoteSignal[8];

    // Declare timers
    std::chrono::high_resolution_clock::time_point t1, t2;

    MPI_Init(&argc, &argv);
    MPI_Comm_size(MPI_COMM_WORLD, &nranks);
    MPI_Comm_rank(MPI_COMM_WORLD, &myrank);
    void *ptrs[nranks];
    void *sig_ptrs[nranks];

    hipDeviceProp_t devProp;

    HIP_CALL(hipSetDevice(myrank));
    hipGetDeviceProperties(&devProp, myrank);

    // Initialize anvil library for hardware SDMA access
    try {
      ensureAnvilInit();
    } catch (const std::exception& e) {
      std::cerr << "Failed to initialize anvil library: " << e.what()
              << std::endl;
      return hipErrorInitializationError;
    }

    for (int i = 0; i < nranks; i++) {
	if (i != myrank) {
		srcGpu = myrank;
		dstGpu = i;
	}
	int canAccess = 0;
        err = hipDeviceCanAccessPeer(&canAccess, srcGpu, dstGpu);
        if (err != hipSuccess) {
      	    std::cerr << "hipDeviceCanAccessPeer failed: " << hipGetErrorString(err)
                << std::endl;
      	    return err;
        }
        if (canAccess == 0) {
      	   std::cerr << "P2P not available: GPU " << srcGpu << " cannot access GPU "
                << dstGpu << " (hipDeviceCanAccessPeer returned 0)"
                << std::endl;
      	   return hipErrorInvalidDevice;
        }

	anvil::EnablePeerAccess(srcGpu, dstGpu);

	//Check reverse access
	int canAccessReverse = 0;
        err = hipDeviceCanAccessPeer(&canAccessReverse, dstGpu, srcGpu);
        if (err != hipSuccess) {
           std::cerr << "hipDeviceCanAccessPeer (reverse) failed: "
                  << hipGetErrorString(err) << std::endl;
           return err;
        }
        if (canAccessReverse == 0) {
           std::cerr << "P2P not available: GPU " << dstGpu
                  << " cannot access GPU " << srcGpu
                  << " (hipDeviceCanAccessPeer returned 0)" << std::endl;
           return hipErrorInvalidDevice;
        }
        anvil::EnablePeerAccess(dstGpu, srcGpu);

	// Create bidirectional SDMA connections and queues
  	try {
    	    bool success = anvil::AnvilLib::getInstance().connect(srcGpu, dstGpu, 1);
            if (!success) {
      		std::cerr << "Failed to connect SDMA (src=" << srcGpu
                	<< ", dst=" << dstGpu << ")" << std::endl;
      		return hipErrorInvalidDevice;
    	    }

    	    success = anvil::AnvilLib::getInstance().connect(dstGpu, srcGpu, 1);
    	    if (!success) {
      		std::cerr << "Failed to connect SDMA (src=" << dstGpu
                	<< ", dst=" << srcGpu << ")" << std::endl;
      		return hipErrorInvalidDevice;
    	    }
  	} catch (const std::exception& e) {
    		std::cerr << "SDMA connect error: " << e.what() << std::endl;
    		return hipErrorInvalidDevice;
  	}

	try {
    	    anvil::SdmaQueue* queue0 =
      		anvil::AnvilLib::getInstance().getSdmaQueue(srcGpu, dstGpu, 0);
    	    if (queue0 == nullptr) {
      		std::cerr << "Failed to get SDMA queue (rank 0: " << srcGpu << " -> "
                	<< dstGpu << ")" << std::endl;
      		return hipErrorInvalidValue;
    	    }
    	    sdmaSendHandles[dstGpu] = queue0->deviceHandle();

    	    anvil::SdmaQueue* queue1 =
      		anvil::AnvilLib::getInstance().getSdmaQueue(dstGpu, srcGpu, 0);
    	    if (queue1 == nullptr) {
      		std::cerr << "Failed to get SDMA queue (rank 1: " << dstGpu << " -> "
                	<< srcGpu << ")" << std::endl;
      		return hipErrorInvalidValue;
    	    }
    	    sdmaRecvHandles[dstGpu] = queue1->deviceHandle();
  	} catch (const std::exception& e) {
    	    std::cerr << "SDMA queue error: " << e.what() << std::endl;
    	    return hipErrorInvalidValue;
  	}
    }
 
    hipIpcMemHandle_t sigHandle;
    hipIpcMemHandle_t *sig_handles = NULL;
    sig_handles = (hipIpcMemHandle_t *) malloc(nranks * sizeof(hipIpcMemHandle_t));

   /* Allocate signals */
    err = hipExtMallocWithFlags((void**)&signals, 8 * sizeof(uint64_t),
                              hipDeviceMallocUncached);

    /*err = hipExtMallocWithFlags((void**)&remoteSignal, sizeof(uint64_t),
                              hipDeviceMallocUncached);*/

     /* Get IPC handle of outbuf */
    HIP_CALL(hipIpcGetMemHandle(&sigHandle, (void*)signals));

    /* Exchange IPC handles for the out bufs */
    MPI_Allgather(&sigHandle, sizeof(hipIpcMemHandle_t), MPI_BYTE, sig_handles, sizeof(hipIpcMemHandle_t),
                    MPI_BYTE, MPI_COMM_WORLD);

    for (int i = 0; i < nranks; i++) {
        if (i != myrank) {
           HIP_CALL(hipIpcOpenMemHandle(&sig_ptrs[i], sig_handles[i], hipIpcMemLazyEnablePeerAccess));
        }
    }

    MPI_Barrier(MPI_COMM_WORLD);
    /* Initial input,output for the host and create memory objects for the kernel*/
    int* input;
    int* expected;
    input = (int*) malloc(N*sizeof(int));
    expected = (int*) malloc(N*nranks*sizeof(int));

    for (int i = 0; i < N; i++) {
	input[i] = myrank + 1;
    }

    for (int i = 0; i < nranks; i++) {
        for (int j = 0; j < N; j++) {
            expected[i*N + j] = i+1;  
        }
    }
    void *output = (void*) malloc(N*nranks*sizeof(int));

    int* inputBuffer;
    int* outputBuffer;

    hipIpcMemHandle_t outHandle, inHandle;
    hipIpcMemHandle_t rcvOutHandle;
    hipIpcMemHandle_t *ipc_handles = NULL;
    ipc_handles = (hipIpcMemHandle_t *) malloc(nranks * sizeof(hipIpcMemHandle_t));

    HIP_CALL(hipMalloc((void**)&inputBuffer, N * sizeof(int)));
    HIP_CALL(hipMalloc((void**)&outputBuffer, N * nranks * sizeof(int)));

    /* Copy input from host to device */
    HIP_CALL(hipMemcpy(inputBuffer, input, N * sizeof(int), hipMemcpyHostToDevice));

    /* Get IPC handle of outbuf */
    HIP_CALL(hipIpcGetMemHandle(&outHandle, (void*)outputBuffer));

    /* Exchange IPC handles for the out bufs */
    MPI_Allgather(&outHandle, sizeof(hipIpcMemHandle_t), MPI_BYTE, ipc_handles, sizeof(hipIpcMemHandle_t), 
		    MPI_BYTE, MPI_COMM_WORLD);

    for (int i = 0; i < nranks; i++) {
        if (i != myrank) {
           HIP_CALL(hipIpcOpenMemHandle(&ptrs[i], ipc_handles[i], hipIpcMemLazyEnablePeerAccess));		
        }
    }

    MPI_Barrier(MPI_COMM_WORLD);

    // Launch kernel for allgather
    const unsigned numBlocks = 1;
    const unsigned threadsPerBlock = 1;

    /*hipLaunchKernelGGL(sdma_ag_kernel, dim3(numBlocks), dim3(threadsPerBlock),
                       0, 0, sdmaSendHandles, sdmaRecvHandles, inputBuffer, ptrs, 
		       N * sizeof(int), nranks, myrank, sig_ptrs);*/

    //hipStreamSynchrnonize();
    hipDeviceSynchronize();

    
    void* dest = (void*) outputBuffer;
    hipMemcpy(output, dest, N * nranks * sizeof(int), hipMemcpyDeviceToHost);
    if (memcmp(output, expected, N * nranks * sizeof(int)) != 0) {
       printf("Validation error\n");
    }

    /* Cleanup */
    hipFree(inputBuffer);
    hipFree(outputBuffer);
    free(output);

    MPI_Finalize();

    return SUCCESS;
}

