#include <iostream>
#include <algorithm>
#include <string>
#include <stdio.h>
#include <vector>
#include <bitset>
#include <unordered_set>
#include <time.h>
#include <sys/time.h>
#include <unistd.h>
#include <algorithm>
#include <numeric>
#include <string.h>
#include <assert.h>
#include <tuple>
#include <queue>
#include <cub/block/block_load.cuh>
#include <cub/block/block_store.cuh>
#include <cub/block/block_radix_sort.cuh>
#include <cub/block/block_scan.cuh>
#include <cub/device/device_select.cuh>
#include <cub/cub.cuh>
#include <curand.h>
#include <curand_kernel.h>
#include <cuda.h>

#include "sample.hpp"

#ifndef __NEXTDOOR_CU__
#define __NEXTDOOR_CU__

typedef VertexID VertexID_t;

//TODO-List:
//[] Divide main() function in several small functions.
//[] Divide the code in several include files that can be included in the API.
//[] In GPU Kernels, do refactoring and move them to other places.
//[] Use vectors instead of dynamic arrays and new.
//[] Convert these vectors to a new array type that does not do initialization of data.
//[] Use MKL or cuSPARSE to do the matrix transpose or sorting
//[] A configuration that specifies all the parameters.
//[] Use Templates for cleaner code of Sampler

//Supported:
//citeseer.graph
// const int N = 3312;
// const int N_EDGES = 9074;
//micro.graph
//const int N = 100000;
//const int N_EDGES = 2160312;
//rmat.graph
// const int N = 1024;
// const int N_EDGES = 29381;
//ego-facebook
// const int N = 4039;
// const int N_EDGES = 88244;
//ego-twitter
//const int N = 81306;
//const int N_EDGES = 2420766;
//ego-gplus
//const int N = 107614;
//const int N_EDGES = 13652253;
//soc-pokec-relationships
//const int N = 1632803;
//const int N_EDGES = 30480021;
//soc-LiveJournal1
//const int N = 4847571;
//const int N_EDGES = 68556521;

//Not supportred:
//com-orkut.ungraph
// const int N = 3072441;
// const int N_EDGES = 117185083;

#include "csr.hpp"
#include "utils.hpp"
#include "sampler.cuh"
#include "rand_num_gen.cuh"
#include "libNextDoor.hpp"

using namespace utils;
using namespace GPUUtils;

#define CHECK_RESULT

//For mico, 512 works best
const size_t N_THREADS = 256;

//TODO try for larger random walks to improve results

#define WARP_HOP

const int ALL_NEIGHBORS = -1;

/**User Defined Functions**/

enum TransitKernelTypes {
  GridKernel = 1,
  ThreadBlockKernel = 2,
  SubWarpKernel = 3,
};

//GraphSage 2-hop sampling
const bool has_random = true;
__host__ __device__ int steps();

__host__ __device__ 
int stepSize(int k);

__device__ inline
VertexID next(int step, const VertexID transit, const VertexID sample, 
              const float maxWeight,
              const CSR::Edge* transitEdges, const float* transitEdgeWeights,
              const EdgePos_t numEdges, const EdgePos_t neighbrID, 
              curandState* state);
template<int CACHE_SIZE, bool CACHE_EDGES, bool CACHE_WEIGHTS, bool DECREASE_GM_LOADS>
__device__ inline
VertexID nextCached(int step, const VertexID transit, const VertexID sample, 
              const float maxWeight,
              const CSR::Edge* transitEdges, const float* transitEdgeWeights,
              const EdgePos_t numEdges, const EdgePos_t neighbrID, 
              curandState* state, VertexID_t* cachedEdges, float* cachedWeights,
              bool* globalLoadBV);
__host__ __device__ int steps();

__constant__ char csrPartitionBuff[sizeof(CSRPartition)];

// __host__ __device__ 
// int stepSize(int k) {
//   return ((k == 0) ? 5 : 2);
// }

// __device__ inline
// VertexID next(int step, const VertexID transit, const VertexID sample, 
//               const CSR::Edge* transitEdges, const EdgePos_t numEdges,
//               const EdgePos_t neighbrID, 
//               curandState* state)
// {
//   EdgePos_t id = RandNumGen::rand_int(state, numEdges);
//   // if (sample == 100 && transit == 100) {
//   //   printf("113: id %ld transitEdges[id] %d\n", (long)id, transitEdges[id]);
//   // }
//   return transitEdges[id];
// }

/**********************/

__host__ __device__
EdgePos_t newNeighborsSize(int hop, EdgePos_t num_edges)
{
  return (stepSize(hop) == ALL_NEIGHBORS) ? num_edges : (EdgePos_t)stepSize(hop);
}

__host__ __device__
EdgePos_t stepSizeAtStep(int step)
{
  if (step == -1)
    return 0;

  EdgePos_t n = 1;
  for (int i = 0; i <= step; i++) {
    n = n * stepSize(i);
  }

  return n;
}


__host__ __device__ int numberOfTransits(int step) {
  return stepSizeAtStep(step);
}

#include "check_results.cu"

__global__ void samplingKernel(const int step, GPUCSRPartition graph, const VertexID_t invalidVertex,
                               const VertexID_t* transitToSamplesKeys, const VertexID_t* transitToSamplesValues,
                               const size_t transitToSamplesSize, const size_t NumSamples,
                               VertexID_t* samplesToTransitKeys, VertexID_t* samplesToTransitValues,
                               VertexID_t* finalSamples, const size_t finalSampleSize, EdgePos_t* sampleInsertionPositions,
                               curandState* randStates)
{
  int threadId = threadIdx.x + blockDim.x * blockIdx.x;
  //__shared__ VertexID newNeigbhors[N_THREADS];

  if (threadId >= transitToSamplesSize)
    return;
  
  EdgePos_t transitIdx = threadId/stepSize(step);
  EdgePos_t transitNeighborIdx = threadId % stepSize(step);
  
  VertexID_t sample = transitToSamplesValues[transitIdx];
  assert(sample < NumSamples);
  VertexID_t transit = transitToSamplesKeys[transitIdx];
  VertexID_t neighbor = invalidVertex;
  graph.device_csr = (CSRPartition*)&csrPartitionBuff[0];

  if (transit != invalidVertex) {
    // if (graph.device_csr->has_vertex(transit) == false)
    //   printf("transit %d\n", transit);
    assert(graph.device_csr->has_vertex(transit));

    EdgePos_t numTransitEdges = graph.device_csr->get_n_edges_for_vertex(transit);
    
    if (numTransitEdges != 0) {
      const CSR::Edge* transitEdges = graph.device_csr->get_edges(transit);
      const float* transitEdgeWeights = graph.device_csr->get_weights(transit);
      const float maxWeight = graph.device_csr->get_max_weight(transit);

      curandState* randState = &randStates[threadId];
      neighbor = next(step, transit, sample, maxWeight, transitEdges, transitEdgeWeights, 
                      numTransitEdges, transitNeighborIdx, randState);
#if 0
      //search if neighbor has already been selected.
      //we can do that in register if required
      newNeigbhors[threadIdx.x] = neighbor;

      bool found = false;
      for (int i = 0; i < N_THREADS; i++) {
        if (newNeigbhors[i] == neighbor) {
          found = true;
          // break;
        }
      }

      __syncwarp();
      if (found) {
        neighbor = next(step, transit, sample, transitEdges, numTransitEdges, 
          transitNeighborIdx, randState);;
      }
#endif
    }
  }

  __syncwarp();

  EdgePos_t totalSizeOfSample = stepSizeAtStep(step - 1);

  if (step != steps() - 1) {
    //No need to store at last step
    samplesToTransitKeys[threadId] = sample;
    samplesToTransitValues[threadId] = neighbor;
  }
  
  EdgePos_t insertionPos = 0; 
  if (numberOfTransits(step) > 1) {    
    insertionPos = utils::atomicAdd(&sampleInsertionPositions[sample], 1);
  } else {
    insertionPos = step;
  }

  // if (insertionPos < finalSampleSize) {
  //   printf("insertionPos %d finalSampleSize %d\n", insertionPos, finalSampleSize);
  // }
  assert(finalSampleSize > 0);
  if (insertionPos >= finalSampleSize) {
    printf("insertionPos %d finalSampleSize %ld sample %d\n", insertionPos, finalSampleSize, sample);
  }
  assert(insertionPos < finalSampleSize);
  finalSamples[sample*finalSampleSize + insertionPos] = neighbor;
  // if (sample == 100) {
  //   printf("neighbor for 100 %d insertionPos %ld transit %d\n", neighbor, (long)insertionPos, transit);
  // }
  //TODO: We do not need atomic instead store indices of transit in another array,
  //wich can be accessed based on sample and transitIdx.
}

__global__ void subWarpKernel(const int step, GPUCSRPartition graph, const VertexID_t invalidVertex,
                               const VertexID_t* transitToSamplesKeys, const VertexID_t* transitToSamplesValues,
                               const size_t transitToSamplesSize, const size_t NumSamples,
                               VertexID_t* samplesToTransitKeys, VertexID_t* samplesToTransitValues,
                               VertexID_t* finalSamples, const size_t finalSampleSize, EdgePos_t* sampleInsertionPositions,
                               curandState* randStates, const int* kernelTypeForTransit)
{
  
  int threadId = threadIdx.x + blockDim.x * blockIdx.x;
  //__shared__ VertexID newNeigbhors[N_THREADS];

  if (threadId >= transitToSamplesSize)
    return;
  
  EdgePos_t transitIdx = threadId/stepSize(step);
  EdgePos_t transitNeighborIdx = threadId % stepSize(step);
  VertexID_t transit = transitToSamplesKeys[transitIdx];
  if (kernelTypeForTransit[transit] == TransitKernelTypes::GridKernel) {
    return;
  }

  graph.device_csr = (CSRPartition*)&csrPartitionBuff[0];
  VertexID_t sample = transitToSamplesValues[transitIdx];
  assert(sample < NumSamples);
  VertexID_t neighbor = invalidVertex;

  curandState randState = randStates[threadId];

  if (transit != invalidVertex) {
    // if (graph.device_csr->has_vertex(transit) == false)
    //   printf("transit %d\n", transit);
    assert(graph.device_csr->has_vertex(transit));

    EdgePos_t numTransitEdges = graph.device_csr->get_n_edges_for_vertex(transit);
    
    if (numTransitEdges != 0) {
      const CSR::Edge* transitEdges = graph.device_csr->get_edges(transit);
      const float* transitEdgeWeights = graph.device_csr->get_weights(transit);
      const float maxWeight = graph.device_csr->get_max_weight(transit);

      neighbor = next(step, transit, sample, maxWeight, transitEdges, transitEdgeWeights, 
                      numTransitEdges, transitNeighborIdx, &randState);
#if 0
      //search if neighbor has already been selected.
      //we can do that in register if required
      newNeigbhors[threadIdx.x] = neighbor;

      bool found = false;
      for (int i = 0; i < N_THREADS; i++) {
        if (newNeigbhors[i] == neighbor) {
          found = true;
          // break;
        }
      }

      __syncwarp();
      if (found) {
        neighbor = next(step, transit, sample, transitEdges, numTransitEdges, 
          transitNeighborIdx, randState);;
      }
#endif
    }
  }

  __syncwarp();

  EdgePos_t totalSizeOfSample = stepSizeAtStep(step - 1);

  if (step != steps() - 1) {
    //No need to store at last step
    samplesToTransitKeys[threadId] = sample;
    samplesToTransitValues[threadId] = neighbor;
  }
  
  EdgePos_t insertionPos = 0; 
  if (numberOfTransits(step) > 1) {    
    insertionPos = utils::atomicAdd(&sampleInsertionPositions[sample], 1);
  } else {
    insertionPos = step;
  }

  // if (insertionPos < finalSampleSize) {
  //   printf("insertionPos %d finalSampleSize %d\n", insertionPos, finalSampleSize);
  // }
  assert(finalSampleSize > 0);
  if (insertionPos >= finalSampleSize) {
    printf("insertionPos %d finalSampleSize %ld sample %d\n", insertionPos, finalSampleSize, sample);
  }
  assert(insertionPos < finalSampleSize);
  finalSamples[sample*finalSampleSize + insertionPos] = neighbor;
  // if (sample == 100) {
  //   printf("neighbor for 100 %d insertionPos %ld transit %d\n", neighbor, (long)insertionPos, transit);
  // }
  //TODO: We do not need atomic instead store indices of transit in another array,
  //wich can be accessed based on sample and transitIdx.
}

template<int CACHE_SIZE, bool COALESCE_GL_LOADS, typename T>
__device__ inline VertexID_t cacheAndGet(EdgePos_t id, const T* transitEdges, T* cachedEdges, bool* globalLoadBV)
{
  VertexID_t e;

  if (id >= CACHE_SIZE)
    return transitEdges[id];
  
  if (COALESCE_GL_LOADS) {
    e = cachedEdges[id];
    if (e == -1)
      globalLoadBV[id] = true;

    __syncthreads();

    for (int i = threadIdx.x; i < CACHE_SIZE; i += blockDim.x) {
      if (globalLoadBV[i]) {
        cachedEdges[i] = transitEdges[i];
      }
    }
    
    __syncthreads();

    globalLoadBV[id] = false;
    e = cachedEdges[id];
  } else {
    e = cachedEdges[id];
    if (e == -1) {
      e = transitEdges[id];
      cachedEdges[id] = e;
    }
  }

  return e;
}

#define MAX(x,y) (((x)<(y))?(y):(x))

template<int THREADS, int CACHE_SIZE, bool CACHE_EDGES, bool CACHE_WEIGHTS, bool COALESCE_GL_LOADS, int TRANSITS_PER_THREAD, bool COALESCE_CURAND_LOAD>
__global__ void gridKernel(const int step, GPUCSRPartition graph, const VertexID_t invalidVertex,
                           const VertexID_t* transitToSamplesKeys, const VertexID_t* transitToSamplesValues,
                           const size_t transitToSamplesSize, const size_t NumSamples,
                           VertexID_t* samplesToTransitKeys, VertexID_t* samplesToTransitValues,
                           VertexID_t* finalSamples, const size_t finalSampleSize, EdgePos_t* sampleInsertionPositions,
                           curandState* randStates, const int* kernelTypeForTransit, const VertexID_t* gridKernelTBPositions, 
                           const EdgePos_t gridKernelTBPositionsNum)
{
  #define EDGE_CACHE_SIZE (CACHE_EDGES ? CACHE_SIZE*sizeof(CSR::Edge) : 0)
  #define WEIGHT_CACHE_SIZE (CACHE_WEIGHTS ? CACHE_SIZE*sizeof(float) : 0)
  #define CURAND_SHMEM_SIZE (sizeof(curandState)*THREADS)
  // #define COALESCE_GL_LOADS_SHMEM_SIZE ()

  __shared__ unsigned char shMemAlloc[MAX(EDGE_CACHE_SIZE+WEIGHT_CACHE_SIZE, CURAND_SHMEM_SIZE)];
  
  //__shared__ bool globalLoadBV[COALESCE_GL_LOADS ? CACHE_SIZE : 1];
  bool* globalLoadBV;
  __shared__ VertexID_t numEdgesInShMem;
  __shared__ bool invalidateCache;
  __shared__ VertexID_t transitForTB;
  __shared__ CSR::Edge* glTransitEdges;
  __shared__ float* glTransitEdgeWeights;
  __shared__ float maxWeight;
  __shared__ EdgePos_t mapStartPos;

  CSR::Edge* edgesInShMem = CACHE_EDGES ? (CSR::Edge*)&shMemAlloc[0] : nullptr;
  float* edgeWeightsInShMem = CACHE_WEIGHTS ? (float*)&shMemAlloc[EDGE_CACHE_SIZE] : nullptr;
  
  int threadId = threadIdx.x + blockDim.x * blockIdx.x;
  
  curandState* curandSrcPtr;

  if (COALESCE_CURAND_LOAD) {
    const int intsInRandState = sizeof(curandState)/sizeof(int);
    int* shStateBuff = (int*)&shMemAlloc[0];

    int* randStatesAsInts = (int*)randStates;
  
    for (int i = threadIdx.x; i < intsInRandState*blockDim.x; i += blockDim.x) {
      shStateBuff[i] = randStatesAsInts[i + blockDim.x*blockIdx.x];
    }

    __syncthreads();
    curandSrcPtr = (curandState*)(&shStateBuff[threadIdx.x*intsInRandState]);
  } else {
    curandSrcPtr = &randStates[threadId];
  }

  curandState localRandState = *curandSrcPtr;

  //__shared__ VertexID newNeigbhors[N_THREADS];
  //if (threadIdx.x == 0) printf("blockIdx.x %d\n", blockIdx.x);
  //shRandStates[threadIdx.x] = randStates[threadId];  
  //__syncthreads();
  
  CSRPartition* csr = (CSRPartition*)&csrPartitionBuff[0];

  for (int transitI = 0; transitI < TRANSITS_PER_THREAD; transitI++) {
    EdgePos_t transitIdx = 0;
    EdgePos_t transitNeighborIdx = 0;//threadId % stepSize(step); //TODO: Correct this for k-hop
    if (TRANSITS_PER_THREAD * blockIdx.x + transitI >= gridKernelTBPositionsNum) {
      continue;
    }
    if (threadIdx.x == 0) {
      mapStartPos = gridKernelTBPositions[TRANSITS_PER_THREAD * blockIdx.x + transitI];
    }
    __syncthreads();
    transitIdx = mapStartPos + threadIdx.x; //threadId/stepSize(step);
    VertexID_t transit = transitToSamplesKeys[transitIdx];

    if (threadIdx.x == 0) {
      invalidateCache = transitForTB != transit || transitI == 0;
      transitForTB = transit;
    }
    if (threadIdx.x == 0 && invalidateCache) {
      //assert(graph.device_csr->has_vertex(transit));
      //TODO: fuse below functions into one to decrease reads
      numEdgesInShMem = csr->get_n_edges_for_vertex(transit);
      glTransitEdges = (CSR::Edge*)csr->get_edges(transit);
      glTransitEdgeWeights = (float*)csr->get_weights(transit);
      maxWeight = csr->get_max_weight(transit);
    }

    __syncthreads();

    if (CACHE_EDGES && invalidateCache) {
      for (int i = threadIdx.x; i < min(CACHE_SIZE, numEdgesInShMem); i += blockDim.x) {
        edgesInShMem[i] = -1;//glTransitEdges[i];
      }
    }
  
    if (CACHE_WEIGHTS && invalidateCache) {
      for (int i = threadIdx.x; i < min(CACHE_SIZE, numEdgesInShMem); i += blockDim.x) {
        edgeWeightsInShMem[i] = -1;//glTransitEdgeWeights[i];
      }
    }

    __syncthreads();

    if (transit == transitForTB) {
      // if (threadIdx.x == 0 && kernelTypeForTransit[transit] != TransitKernelTypes::GridKernel) {
      //   printf("transit %d transitIdx %d gridDim.x %d\n", transit, transitIdx, gridDim.x);
      // }
      // assert (kernelTypeForTransit[transit] == TransitKernelTypes::GridKernel);

      VertexID_t sample = transitToSamplesValues[transitIdx];

      assert(sample < NumSamples);
      VertexID_t neighbor = invalidVertex;
      // if (graph.device_csr->has_vertex(transit) == false)
      //   printf("transit %d\n", transit);
      neighbor = nextCached<CACHE_SIZE, CACHE_EDGES, CACHE_WEIGHTS, 0>(step, transit, sample, maxWeight, 
                                                              glTransitEdges, glTransitEdgeWeights, 
                                                              numEdgesInShMem, transitNeighborIdx, &localRandState,
                                                              edgesInShMem, edgeWeightsInShMem,
                                                              &globalLoadBV[0]);
      __syncwarp();

      //EdgePos_t totalSizeOfSample = stepSizeAtStep(step - 1);

      if (step != steps() - 1) {
        //No need to store at last step
        samplesToTransitKeys[transitIdx] = sample; //TODO: Update this for khop to transitIdx + transitNeighborIdx
        samplesToTransitValues[transitIdx] = neighbor;
      }
      
      EdgePos_t insertionPos = 0; 
      if (false && numberOfTransits(step) > 1) {
        //insertionPos = utils::atomicAdd(&sampleInsertionPositions[sample], 1);
      } else {
        insertionPos = step;
      }

      // if (insertionPos < finalSampleSize) {
      //   printf("insertionPos %d finalSampleSize %d\n", insertionPos, finalSampleSize);
      // }
      assert(finalSampleSize > 0);
      if (insertionPos >= finalSampleSize) {
        printf("insertionPos %d finalSampleSize %ld sample %d\n", insertionPos, finalSampleSize, sample);
      }
      assert(insertionPos < finalSampleSize);

      if (step %2 == 0) {
        //((uint64_t*)finalSamples)[(sample*finalSampleSize)/2 + threadIdx.x] = (uint64_t)(((uint64_t)transit) | (((uint64_t)neighbor) << 32));
      }

      finalSamples[sample*finalSampleSize + insertionPos] = neighbor;
      // if (sample == 100) {
      //   printf("neighbor for 100 %d insertionPos %ld transit %d\n", neighbor, (long)insertionPos, transit);
      // }
      //TODO: We do not need atomic instead store indices of transit in another array,
      //wich can be accessed based on sample and transitIdx.
    }
  }
}

__global__ void sampleParallelKernel(const int step, GPUCSRPartition graph, const VertexID_t invalidVertex,
                               const size_t NumSamples,
                               VertexID_t* finalSamples, const size_t finalSampleSize, EdgePos_t* sampleInsertionPositions,
                               curandState* randStates)
{
  //TODO: Following code assumes Random Walk

  int threadId = threadIdx.x + blockDim.x * blockIdx.x;
  //__shared__ VertexID newNeigbhors[N_THREADS];

  if (threadId >= NumSamples)
    return;
  
  VertexID_t sample = threadId;
  VertexID_t transit = (step == 0) ? sample : finalSamples[sample*finalSampleSize + step - 1];
  VertexID_t neighbor = invalidVertex;
  
  if (transit == invalidVertex) {
    return;
  }
  assert(graph.device_csr->has_vertex(transit));

  EdgePos_t numTransitEdges = graph.device_csr->get_n_edges_for_vertex(transit);
  
  if (numTransitEdges != 0) {
    const CSR::Edge* transitEdges = graph.device_csr->get_edges(transit);
    const float* transitEdgeWeights = graph.device_csr->get_weights(transit);
    const float maxWeight = graph.device_csr->get_max_weight(transit);

    curandState* randState = &randStates[threadId];
    neighbor = next(step, transit, sample, maxWeight, transitEdges, transitEdgeWeights, 
                    numTransitEdges, 0, randState);
#if 0
    //search if neighbor has already been selected.
    //we can do that in register if required
    newNeigbhors[threadIdx.x] = neighbor;

    bool found = false;
    for (int i = 0; i < N_THREADS; i++) {
      if (newNeigbhors[i] == neighbor) {
        found = true;
        // break;
      }
    }

    __syncwarp();
    if (found) {
      neighbor = next(step, transit, sample, transitEdges, numTransitEdges, 
        transitNeighborIdx, randState);;
    }
#endif
  }

  EdgePos_t totalSizeOfSample = stepSizeAtStep(step - 1);  
  
  EdgePos_t insertionPos = 0; 

  if (numberOfTransits(step) > 1) {    
    insertionPos = utils::atomicAdd(&sampleInsertionPositions[sample], 1);
  } else {
    insertionPos = step;
  }

  // if (insertionPos < finalSampleSize) {
  //   printf("insertionPos %d finalSampleSize %d\n", insertionPos, finalSampleSize);
  // }
  assert(finalSampleSize > 0);
  if (insertionPos >= finalSampleSize) {
    printf("insertionPos %d finalSampleSize %ld sample %d\n", insertionPos, finalSampleSize, sample);
  }
  assert(insertionPos < finalSampleSize);
  finalSamples[sample*finalSampleSize + insertionPos] = neighbor;
  // if (sample == 100) {
  //   printf("neighbor for 100 %d insertionPos %ld transit %d\n", neighbor, (long)insertionPos, transit);
  // }
  //TODO: We do not need atomic instead store indices of transit in another array,
  //wich can be accessed based on sample and transitIdx.
}

template<int TB_THREADS>
__global__ void partitionTransitsInKernels(EdgePos_t* uniqueTransits, EdgePos_t* uniqueTransitCounts, EdgePos_t* transitPositions,
                                           EdgePos_t uniqueTransitCountsNum, VertexID_t invalidVertex,
                                           EdgePos_t* gridKernelTransits, EdgePos_t* gridKernelTransitsNum,
                                           int* kernelTypeForTransit) 
{
  //__shared__ EdgePos_t insertionPosOfThread[TB_THREADS];
  const int SHMEM_SIZE = 4096;
  __shared__ EdgePos_t shGridTransits[SHMEM_SIZE];
  __shared__ EdgePos_t gridTotalTBs;
  __shared__ EdgePos_t gridInsertionPos;
  __shared__ EdgePos_t gridKernelTransitsIter;

  int threadId = blockIdx.x * blockDim.x + threadIdx.x;

  if (threadIdx.x == 0) {
    gridTotalTBs = 0;
    gridKernelTransitsIter = 0;
  }

  __syncthreads();
  
  VertexID_t transit = uniqueTransits[threadId];
  EdgePos_t trCount = (threadId >= uniqueTransitCountsNum || transit == invalidVertex) ? -1: uniqueTransitCounts[threadId];
  EdgePos_t trPos = (threadId >= uniqueTransitCountsNum || transit == invalidVertex) ? -1: transitPositions[threadId];

  int kernelType = -1;

  if (trCount >= LoadBalancing::LoadBalancingThreshold::GridLevel) {    
    kernelType = TransitKernelTypes::GridKernel;
  } else {
    kernelType = TransitKernelTypes::SubWarpKernel;
  }

  //Get all grid kernel transits
  EdgePos_t numThreadBlocks = (trCount + LoadBalancing::LoadBalancingThreshold::GridLevel-1)/LoadBalancing::LoadBalancingThreshold::GridLevel;
  EdgePos_t insertionPos = -1;
  if (trCount >= LoadBalancing::LoadBalancingThreshold::GridLevel)
    insertionPos = ::atomicAdd(&gridTotalTBs, numThreadBlocks);
  
  __syncthreads();

  if (threadIdx.x == 0) {
    gridInsertionPos = ::atomicAdd(gridKernelTransitsNum, gridTotalTBs);
  }

  bool done = false;
  int threadBlocksDone = 0;

  for (int shMemIter = 0; shMemIter < gridTotalTBs; shMemIter += SHMEM_SIZE) {
    if (!done && insertionPos - shMemIter + numThreadBlocks < SHMEM_SIZE && kernelType == TransitKernelTypes::GridKernel) {
      for (int tb = threadBlocksDone; tb < numThreadBlocks; tb++) {
        shGridTransits[insertionPos - shMemIter + tb] = trPos + LoadBalancing::LoadBalancingThreshold::GridLevel * tb;
        threadBlocksDone++;
      }
      done = true;
    }

    __syncthreads();

    for (EdgePos_t m = threadIdx.x; m < min(min(SHMEM_SIZE - shMemIter, SHMEM_SIZE), gridTotalTBs); m += blockDim.x) {
      gridKernelTransits[gridInsertionPos + m + shMemIter] = shGridTransits[m];
    }

    __syncthreads();
  }

  if (threadId < uniqueTransitCountsNum && transit != invalidVertex) {
    kernelTypeForTransit[transit] = kernelType;
  }

  __syncthreads();

  


  // if (shGridTrCount[threadIdx.x] >= 0 and shGridTrPos[threadIdx.x] >= 0) {
  //   EdgePos_t numThreadBlocks = (shGridTrCount[threadIdx.x] + LoadBalancing::LoadBalancingThreshold::GridLevel-1)/LoadBalancing::LoadBalancingThreshold::GridLevel;
  //   for (EdgePos_t i = 0; i < numThreadBlocks; i += 1) {
  //     gridKernelTransits[gridInsertionPos + i + insertionPosOfThread[threadIdx.x]] = shGridTrPos[threadIdx.x] + LoadBalancing::LoadBalancingThreshold::GridLevel * i;
  //   }
  // }
}

__global__ void init_curand_states(curandState* states, size_t num_states)
{
  int thread_id = blockIdx.x*blockDim.x + threadIdx.x;
  if (thread_id < num_states)
    curand_init(thread_id, 0, 0, &states[thread_id]);
}

CSR* loadGraph(Graph& graph, char* graph_file, char* graph_type, char* graph_format)
{
  CSR* csr;

   //Load Graph
   if (strcmp(graph_type, "adj-list") == 0) {
    if (strcmp(graph_format, "text") == 0) {
      graph.load_from_adjacency_list(graph_file);
      //Convert graph to CSR format
      csr = new CSR(graph.get_vertices().size(), graph.get_n_edges());
      csr_from_graph (csr, graph);
      return csr;
    }
    else {
      printf ("graph_format '%s' not supported for graph_type '%s'\n", 
              graph_format, graph_type);
      return nullptr;
    }
  } else if (strcmp(graph_type, "edge-list") == 0) {
    if (strcmp(graph_format, "binary") == 0) {
      graph.load_from_edge_list_binary(graph_file, true);
      csr = new CSR(graph.get_vertices().size(), graph.get_n_edges());
      csr_from_graph (csr, graph);
      return csr;
    } else if (strcmp(graph_format, "text") == 0) {
      FILE* fp = fopen (graph_file, "r");
      if (fp == nullptr) {
        std::cout << "File '" << graph_file << "' not found" << std::endl;
        return nullptr;
      }
      graph.load_from_edge_list_txt(fp, true);
      fclose (fp);
      csr = new CSR(graph.get_vertices().size(), graph.get_n_edges());
      csr_from_graph (csr, graph);
      return csr;
    } else {
      printf ("graph_format '%s' not supported for graph_type '%s'\n", 
              graph_format, graph_type);
      return nullptr;
    }
  } else {
    printf("Incorrect graph file type '%s'\n", graph_type);
    return nullptr;
  }

  return nullptr;
}

GPUCSRPartition transferCSRToGPU(CSR* csr)
{
  //Assume that whole graph can be stored in GPU Memory.
  //Hence, only one Graph Partition is created.
  CSRPartition full_partition = CSRPartition (0, csr->get_n_vertices() - 1, 0, csr->get_n_edges() - 1, 
                                              csr->get_vertices(), csr->get_edges(), csr->get_weights());
  
  //Copy full graph to GPU
  GPUCSRPartition gpuCSRPartition;
  CSRPartition deviceCSRPartition = copyPartitionToGPU(full_partition, gpuCSRPartition);
  gpuCSRPartition.device_csr = (CSRPartition*)csrPartitionBuff;
  CHK_CU(cudaMemcpyToSymbol(csrPartitionBuff, &deviceCSRPartition, sizeof(CSRPartition)));
  return gpuCSRPartition;
}

bool allocNextDoorDataOnGPU(CSR* csr, NextDoorData& data)
{
  //Initially each sample contains only one vertex
  //Allocate one sample for each vertex
  int maxV = 0;
  for (auto vertex : csr->iterate_vertices()) {
    data.samples.push_back(vertex);
    maxV = (maxV < vertex) ? vertex : maxV;
  }

  //Size of each sample output
  size_t maxNeighborsToSample = 1;
  for (int step = 0; step < steps(); step++) {
    maxNeighborsToSample *= stepSize(step);
  }

  size_t finalSampleSize = 0;
  size_t neighborsToSampleAtStep = 1;
  for (int step = 0; step < steps(); step++) {
    neighborsToSampleAtStep *= stepSize(step);
    finalSampleSize += neighborsToSampleAtStep;
  }

  data.INVALID_VERTEX = csr->get_n_vertices();
  int maxBits = 0;
  while ((data.INVALID_VERTEX >> maxBits) != 0) {
    maxBits++;
  }
  
  data.maxBits = maxBits + 1;

  //Allocate storage for final samples on GPU
  data.hFinalSamples = std::vector<VertexID_t>(finalSampleSize*data.samples.size());

  CHK_CU(cudaMalloc(&data.dFinalSamples, sizeof(VertexID_t)*data.hFinalSamples.size()));
  gpu_memset(data.dFinalSamples, data.INVALID_VERTEX, data.hFinalSamples.size());
  //Samples to Transit Map
  //TODO: hFinalSamples.size() is wrong.
  CHK_CU(cudaMalloc(&data.dSamplesToTransitMapKeys, sizeof(VertexID_t)*data.samples.size()*maxNeighborsToSample));
  CHK_CU(cudaMalloc(&data.dSamplesToTransitMapValues, sizeof(VertexID_t)*data.samples.size()*maxNeighborsToSample));

  //Transit to Samples Map
  //TODO: hFinalSamples.size() is wrong. It should be maximum number of transits.
  CHK_CU(cudaMalloc(&data.dTransitToSampleMapKeys, sizeof(VertexID_t)*data.samples.size()*maxNeighborsToSample));
  CHK_CU(cudaMalloc(&data.dTransitToSampleMapValues, sizeof(VertexID_t)*data.samples.size()*maxNeighborsToSample));

  //Same as initial values of samples for first iteration
  CHK_CU(cudaMemcpy(data.dTransitToSampleMapKeys, &data.samples[0], sizeof(VertexID_t)*data.samples.size(), 
                    cudaMemcpyHostToDevice));
  CHK_CU(cudaMemcpy(data.dTransitToSampleMapValues, &data.samples[0], sizeof(VertexID_t)*data.samples.size(), 
                    cudaMemcpyHostToDevice));

  //Insertion positions per transit vertex for each sample
  
  CHK_CU(cudaMalloc(&data.dSampleInsertionPositions, sizeof(EdgePos_t)*data.samples.size()));

  CHK_CU(cudaMalloc(&data.dCurandStates, maxNeighborsToSample*data.samples.size()*sizeof(curandState)));
  init_curand_states<<<thread_block_size(data.samples.size()*maxNeighborsToSample, 256UL), 256UL>>> (data.dCurandStates, data.samples.size()*maxNeighborsToSample);
  CHK_CU(cudaDeviceSynchronize());

  return true;
}

void freeDeviceData(NextDoorData& data) 
{
  CHK_CU(cudaFree(data.dSamplesToTransitMapKeys));
  CHK_CU(cudaFree(data.dSamplesToTransitMapValues));
  CHK_CU(cudaFree(data.dTransitToSampleMapKeys));
  CHK_CU(cudaFree(data.dTransitToSampleMapValues));
  CHK_CU(cudaFree(data.dSampleInsertionPositions));
  CHK_CU(cudaFree(data.dCurandStates));
  CHK_CU(cudaFree(data.dFinalSamples));
  CHK_CU(cudaFree(data.gpuCSRPartition.device_vertex_array));
  CHK_CU(cudaFree(data.gpuCSRPartition.device_edge_array));
  CHK_CU(cudaFree(data.gpuCSRPartition.device_weights_array));
}

void printKernelTypes(CSR* csr, VertexID_t* dUniqueTransits, VertexID_t* dUniqueTransitsCounts, EdgePos_t* dUniqueTransitsNumRuns)
{
  EdgePos_t* hUniqueTransitsNumRuns = GPUUtils::copyDeviceMemToHostMem(dUniqueTransitsNumRuns, 1);
  VertexID_t* hUniqueTransits = GPUUtils::copyDeviceMemToHostMem(dUniqueTransits, *hUniqueTransitsNumRuns);
  VertexID_t* hUniqueTransitsCounts = GPUUtils::copyDeviceMemToHostMem(dUniqueTransitsCounts, *hUniqueTransitsNumRuns);

  size_t identityKernelTransits = 0, identityKernelSamples = 0, maxEdgesOfIdentityTransits = 0;
  size_t subWarpLevelTransits = 0, subWarpLevelSamples = 0, maxEdgesOfSubWarpTransits = 0, subWarpTransitsWithEdgesLessThan384 = 0, subWarpTransitsWithEdgesMoreThan384 = 0;
  size_t threadBlockLevelTransits = 0, threadBlockLevelSamples = 0, tbVerticesWithEdgesLessThan3K = 0, tbVerticesWithEdgesMoreThan3K = 0;
  size_t gridLevelTransits = 0, gridLevelSamples = 0, gridVerticesWithEdgesLessThan10K = 0, gridVerticesWithEdgesMoreThan10K = 0;
  EdgePos_t maxEdgesOfGridTransits = 0;

  for (size_t tr = 0; tr < *hUniqueTransitsNumRuns; tr++) {
    // if (tr == 0) {printf("%s:%d hUniqueTransitsCounts[0] is %d\n", __FILE__, __LINE__, hUniqueTransitsCounts[tr]);}
    if (hUniqueTransitsCounts[tr] < 8) {
      identityKernelTransits++;
      identityKernelSamples += hUniqueTransitsCounts[tr];
      maxEdgesOfIdentityTransits = max(maxEdgesOfIdentityTransits, (size_t)csr->n_edges_for_vertex(tr));
    } else if (hUniqueTransitsCounts[tr] <= LoadBalancing::LoadBalancingThreshold::BlockLevel && 
               hUniqueTransitsCounts[tr] >= 8) {
      subWarpLevelTransits++;
      subWarpLevelSamples += hUniqueTransitsCounts[tr];
      maxEdgesOfSubWarpTransits = max(maxEdgesOfSubWarpTransits, (size_t)csr->n_edges_for_vertex(tr));
      if (csr->n_edges_for_vertex(tr) <= 384) {
        subWarpTransitsWithEdgesLessThan384 += 1;
      } else {
        subWarpTransitsWithEdgesMoreThan384 += 1;
      }
    } else if (hUniqueTransitsCounts[tr] > LoadBalancing::LoadBalancingThreshold::BlockLevel && 
               hUniqueTransitsCounts[tr] <= LoadBalancing::LoadBalancingThreshold::GridLevel) {
      threadBlockLevelTransits++;
      threadBlockLevelSamples += hUniqueTransitsCounts[tr];
      if (csr->n_edges_for_vertex(tr) <= 3*1024) {
        tbVerticesWithEdgesLessThan3K += 1;
      } else {
        tbVerticesWithEdgesMoreThan3K += 1;
      }
    } else {
      gridLevelTransits++;
      gridLevelSamples += hUniqueTransitsCounts[tr];
      if (csr->n_edges_for_vertex(tr) <= 3*1024) {
        gridVerticesWithEdgesLessThan10K += 1;
      } else {
        gridVerticesWithEdgesMoreThan10K += 1;
      }
      maxEdgesOfGridTransits = max(maxEdgesOfGridTransits, csr->n_edges_for_vertex(tr));
    }
  }

  printf("IdentityKernelTransits: %ld, IdentityKernelSamples: %ld, MaxEdgesOfIdentityTransits: %ld\n SubWarpLevelTransits: %ld, SubWarpLevelSamples: %ld, MaxEdgesOfSubWarpTranits: %ld, VerticesWithEdges > 384: %ld, VerticesWithEdges <= 384: %ld\n ThreadBlockLevelTransits: %ld, ThreadBlockLevelSamples: %ld, VerticesWithEdges > 3K: %ld, VerticesWithEdges < 3K: %ld\nGridLevelTransits: %ld, GridLevelSamples: %ld, VerticesWithEdges > 10K: %ld, VerticesWithEdges < 10K: %ld, MaxEdgesOfTransit: %d\n", 
         identityKernelTransits, identityKernelSamples, maxEdgesOfIdentityTransits, 
         subWarpLevelTransits, subWarpLevelSamples, maxEdgesOfSubWarpTransits, 
            subWarpTransitsWithEdgesMoreThan384, subWarpTransitsWithEdgesLessThan384,
         threadBlockLevelTransits, threadBlockLevelSamples, tbVerticesWithEdgesMoreThan3K, tbVerticesWithEdgesLessThan3K,
         gridLevelTransits, gridLevelSamples, gridVerticesWithEdgesMoreThan10K, gridVerticesWithEdgesLessThan10K, maxEdgesOfGridTransits);

  delete hUniqueTransits;
  delete hUniqueTransitsCounts;
  delete hUniqueTransitsNumRuns;
}

bool doTransitParallelSampling(CSR* csr, GPUCSRPartition gpuCSRPartition, NextDoorData& nextDoorData, bool enableLoadBalancing)
{
  //Size of each sample output
  size_t maxNeighborsToSample = 1;
  for (int step = 0; step < steps(); step++) {
    maxNeighborsToSample *= stepSize(step);
  }

  size_t finalSampleSize = 0;
  size_t neighborsToSampleAtStep = 1;
  for (int step = 0; step < steps(); step++) {
    neighborsToSampleAtStep *= stepSize(step);
    finalSampleSize += neighborsToSampleAtStep;
  }
  
  neighborsToSampleAtStep = 1;
  CHK_CU(cudaMemcpy(nextDoorData.dTransitToSampleMapKeys, &nextDoorData.samples[0], sizeof(VertexID_t)*nextDoorData.samples.size(), 
                  cudaMemcpyHostToDevice));
  CHK_CU(cudaMemcpy(nextDoorData.dTransitToSampleMapValues, &nextDoorData.samples[0], sizeof(VertexID_t)*nextDoorData.samples.size(), 
                  cudaMemcpyHostToDevice));
  VertexID_t* d_temp_storage = nullptr;
  size_t temp_storage_bytes = 0;
  VertexID_t* dUniqueTransits = nullptr;
  VertexID_t* dUniqueTransitsCounts = nullptr;
  EdgePos_t* dUniqueTransitsNumRuns = nullptr;
  EdgePos_t* dTransitPositions = nullptr;
  EdgePos_t* uniqueTransitNumRuns = nullptr;
  // VertexID_t* gridKernelTransits = nullptr;
  EdgePos_t* gridKernelTransitsNum = nullptr;
  EdgePos_t* dGridKernelTransitsNum = nullptr;
  VertexID_t* dGridKernelTransits = nullptr;
  int* dKernelTypeForTransit = nullptr;

  CHK_CU(cudaMallocHost(&uniqueTransitNumRuns, sizeof(EdgePos_t)));
  CHK_CU(cudaMallocHost(&gridKernelTransitsNum, sizeof(EdgePos_t)));

  CHK_CU(cudaMalloc(&dKernelTypeForTransit, sizeof(VertexID_t)*csr->get_n_vertices()));
  CHK_CU(cudaMalloc(&dTransitPositions, 
                    sizeof(VertexID_t)*nextDoorData.samples.size()));
  CHK_CU(cudaMalloc(&dGridKernelTransits, 
                    sizeof(VertexID_t)*nextDoorData.samples.size()*maxNeighborsToSample));
  CHK_CU(cudaMalloc(&dGridKernelTransitsNum, sizeof(EdgePos_t)));
  CHK_CU(cudaMemset(dGridKernelTransitsNum, 0, sizeof(EdgePos_t)));
  
  int* atomicPtrTest = nullptr;
  CHK_CU(cudaMalloc(&atomicPtrTest, sizeof(int)));
  //Check if the space runs out.
  //TODO: Use DoubleBuffer version that requires O(P) space.
  //TODO: hFinalSamples.size() is wrong.
  cub::DeviceRadixSort::SortPairs(d_temp_storage, temp_storage_bytes, 
            nextDoorData.dSamplesToTransitMapValues, nextDoorData.dTransitToSampleMapKeys, 
            nextDoorData.dSamplesToTransitMapKeys, nextDoorData.dTransitToSampleMapValues, 
            nextDoorData.samples.size()*maxNeighborsToSample);

  CHK_CU(cudaMalloc(&dUniqueTransits, (csr->get_n_vertices() + 1)*sizeof(VertexID_t)));
  CHK_CU(cudaMalloc(&dUniqueTransitsCounts, (csr->get_n_vertices() + 1)*sizeof(VertexID_t)));
  CHK_CU(cudaMalloc(&dUniqueTransitsNumRuns, sizeof(size_t)));
  
  if (temp_storage_bytes < nextDoorData.samples.size()*maxNeighborsToSample) {
    temp_storage_bytes = nextDoorData.samples.size()*maxNeighborsToSample;
  }

  // VertexID_t* gt1, *gt2;
  // CHK_CU(cudaMalloc(&gt1, nextDoorData.samples.size()*maxNeighborsToSample*sizeof(VertexID_t)));
  // CHK_CU(cudaMalloc(&gt2, nextDoorData.samples.size()*maxNeighborsToSample*sizeof(VertexID_t)));

  size_t free = 0, total = 0;
  CHK_CU(cudaMemGetInfo(&free, &total));
  // printf("free memory %ld temp_storage_bytes %ld nextDoorData.samples.size() %ld maxNeighborsToSample %ld\n", free, temp_storage_bytes, nextDoorData.samples.size(), maxNeighborsToSample);
  CHK_CU(cudaMalloc(&d_temp_storage, temp_storage_bytes));

  std::vector<VertexID_t*> hAllSamplesToTransitMapKeys;
  std::vector<VertexID_t*> hAllTransitToSampleMapValues;

  double loadBalancingTime = 0;
  double inversionTime = 0;
  double gridKernelTime = 0;
  double subWarpKernelTime = 0;
  double end_to_end_t1 = convertTimeValToDouble(getTimeOfDay ());
  for (int step = 0; step < steps(); step++) {
    neighborsToSampleAtStep *= stepSize(step);
    const size_t totalThreads = nextDoorData.samples.size()*neighborsToSampleAtStep;
    
    if (step == 0 || !enableLoadBalancing) {
      //When not doing load balancing call baseline transit parallel
      samplingKernel<<<thread_block_size(totalThreads, N_THREADS), N_THREADS>>>(step, gpuCSRPartition, nextDoorData.INVALID_VERTEX,
                      (const VertexID_t*)nextDoorData.dTransitToSampleMapKeys, (const VertexID_t*)nextDoorData.dTransitToSampleMapValues,
                      totalThreads, nextDoorData.samples.size(),
                      nextDoorData.dSamplesToTransitMapKeys, nextDoorData.dSamplesToTransitMapValues,
                      nextDoorData.dFinalSamples, finalSampleSize, nextDoorData.dSampleInsertionPositions,
                      nextDoorData.dCurandStates);
      CHK_CU(cudaGetLastError());
      CHK_CU(cudaDeviceSynchronize());
    } else {
      double loadBalancingT1 = convertTimeValToDouble(getTimeOfDay ());
      void* dRunLengthEncodeTmpStorage = nullptr;
      size_t dRunLengthEncodeTmpStorageSize = 0;

      cub::DeviceRunLengthEncode::Encode(dRunLengthEncodeTmpStorage, dRunLengthEncodeTmpStorageSize, 
                                        nextDoorData.dTransitToSampleMapKeys,
                                        dUniqueTransits, dUniqueTransitsCounts, dUniqueTransitsNumRuns, totalThreads);

      assert(dRunLengthEncodeTmpStorageSize < temp_storage_bytes);
      dRunLengthEncodeTmpStorage = d_temp_storage;
      cub::DeviceRunLengthEncode::Encode(dRunLengthEncodeTmpStorage, dRunLengthEncodeTmpStorageSize, 
                                        nextDoorData.dTransitToSampleMapKeys,
                                        dUniqueTransits, dUniqueTransitsCounts, dUniqueTransitsNumRuns, totalThreads);

      CHK_CU(cudaGetLastError());
      CHK_CU(cudaDeviceSynchronize());
      
      CHK_CU(cudaMemcpy(uniqueTransitNumRuns, dUniqueTransitsNumRuns, sizeof(*uniqueTransitNumRuns), cudaMemcpyDeviceToHost));

      void* dExclusiveSumTmpStorage = nullptr;
      size_t dExclusiveSumTmpStorageSize = 0;
      
      cub::DeviceScan::ExclusiveSum(dExclusiveSumTmpStorage, dExclusiveSumTmpStorageSize, dUniqueTransitsCounts, dTransitPositions, *uniqueTransitNumRuns);

      assert(dExclusiveSumTmpStorageSize < temp_storage_bytes);
      dExclusiveSumTmpStorage = d_temp_storage;

      cub::DeviceScan::ExclusiveSum(dExclusiveSumTmpStorage, dExclusiveSumTmpStorageSize, dUniqueTransitsCounts, dTransitPositions, *uniqueTransitNumRuns);

      CHK_CU(cudaGetLastError());
      CHK_CU(cudaDeviceSynchronize());
      //printKernelTypes(csr, dUniqueTransits, dUniqueTransitsCounts, dUniqueTransitsNumRuns);

      CHK_CU(cudaMemset(dGridKernelTransitsNum, 0, sizeof(EdgePos_t)));
      partitionTransitsInKernels<1024><<<thread_block_size((*uniqueTransitNumRuns), 1024), 1024>>>(dUniqueTransits, dUniqueTransitsCounts, 
          dTransitPositions, *uniqueTransitNumRuns, nextDoorData.INVALID_VERTEX, dGridKernelTransits, dGridKernelTransitsNum, dKernelTypeForTransit);
      CHK_CU(cudaGetLastError());
      CHK_CU(cudaDeviceSynchronize());
      CHK_CU(cudaMemcpy(gridKernelTransitsNum, dGridKernelTransitsNum, sizeof(EdgePos_t), cudaMemcpyDeviceToHost));
      
      // GPUUtils::printDeviceArray(dGridKernelTransits, *gridKernelTransitsNum, ',');
      // getchar();
      double loadBalancingT2 = convertTimeValToDouble(getTimeOfDay ());
      loadBalancingTime += (loadBalancingT2 - loadBalancingT1);
      
      double subWarpKernelTimeT1 = convertTimeValToDouble(getTimeOfDay ());
      subWarpKernel<<<thread_block_size(totalThreads, N_THREADS), N_THREADS>>>(step, gpuCSRPartition, nextDoorData.INVALID_VERTEX,
        (const VertexID_t*)nextDoorData.dTransitToSampleMapKeys, (const VertexID_t*)nextDoorData.dTransitToSampleMapValues,
        totalThreads, nextDoorData.samples.size(),
        nextDoorData.dSamplesToTransitMapKeys, nextDoorData.dSamplesToTransitMapValues,
        nextDoorData.dFinalSamples, finalSampleSize, nextDoorData.dSampleInsertionPositions,
        nextDoorData.dCurandStates, dKernelTypeForTransit);
      CHK_CU(cudaGetLastError());
      CHK_CU(cudaDeviceSynchronize());
      double subWarpKernelTimeT2 = convertTimeValToDouble(getTimeOfDay ());
      subWarpKernelTime += (subWarpKernelTimeT2 - subWarpKernelTimeT1);

      const int perThreadSamples = 4;
      double gridKernelTimeT1 = convertTimeValToDouble(getTimeOfDay ());
      int threadBlocks = DIVUP(*gridKernelTransitsNum, perThreadSamples);
      gridKernel<256,3*1024-3,false,true,false,perThreadSamples,true><<<threadBlocks, 256>>>(step, gpuCSRPartition, nextDoorData.INVALID_VERTEX,
        (const VertexID_t*)nextDoorData.dTransitToSampleMapKeys, (const VertexID_t*)nextDoorData.dTransitToSampleMapValues,
        totalThreads, nextDoorData.samples.size(),
        nextDoorData.dSamplesToTransitMapKeys, nextDoorData.dSamplesToTransitMapValues,
        nextDoorData.dFinalSamples, finalSampleSize, nextDoorData.dSampleInsertionPositions,
        nextDoorData.dCurandStates, dKernelTypeForTransit, dGridKernelTransits, *gridKernelTransitsNum);
      CHK_CU(cudaGetLastError());
      CHK_CU(cudaDeviceSynchronize());
      double gridKernelTimeT2 = convertTimeValToDouble(getTimeOfDay ());
      gridKernelTime += (gridKernelTimeT2 - gridKernelTimeT1);

      // atomicPointerInc<<<thread_block_size(totalThreads, N_THREADS), N_THREADS>>>(atomicPtrTest);
      // CHK_CU(cudaGetLastError());
      // CHK_CU(cudaDeviceSynchronize());
    }

    if (step != steps() - 1) {
      double inversionT1 = convertTimeValToDouble(getTimeOfDay ());
      //Invert sample->transit map by sorting samples based on the transit vertices
      cub::DeviceRadixSort::SortPairs(d_temp_storage, temp_storage_bytes, 
                                      nextDoorData.dSamplesToTransitMapValues, nextDoorData.dTransitToSampleMapKeys, 
                                      nextDoorData.dSamplesToTransitMapKeys, nextDoorData.dTransitToSampleMapValues, 
                                      totalThreads, 0, nextDoorData.maxBits);
      CHK_CU(cudaGetLastError());
      CHK_CU(cudaDeviceSynchronize());
      double inversionT2 = convertTimeValToDouble(getTimeOfDay ());
      inversionTime += (inversionT2 - inversionT1);

      #if 0
      VertexID_t* hTransitToSampleMapKeys = new VertexID_t[totalThreads];
      VertexID_t* hTransitToSampleMapValues = new VertexID_t[totalThreads];
      VertexID_t* hSampleToTransitMapKeys = new VertexID_t[totalThreads];
      VertexID_t* hSampleToTransitMapValues = new VertexID_t[totalThreads];
      CHK_CU(cudaMemcpy(hSampleToTransitMapKeys, nextDoorData.dSamplesToTransitMapKeys, 
        totalThreads*sizeof(VertexID_t), cudaMemcpyDeviceToHost));
      CHK_CU(cudaMemcpy(hSampleToTransitMapValues, nextDoorData.dSamplesToTransitMapValues,
        totalThreads*sizeof(VertexID_t), cudaMemcpyDeviceToHost));
      CHK_CU(cudaMemcpy(hTransitToSampleMapKeys, nextDoorData.dTransitToSampleMapKeys, 
                        totalThreads*sizeof(VertexID_t), cudaMemcpyDeviceToHost));
      CHK_CU(cudaMemcpy(hTransitToSampleMapValues, nextDoorData.dTransitToSampleMapValues,
                        totalThreads*sizeof(VertexID_t), cudaMemcpyDeviceToHost));
                  
      hAllTransitToSampleMapValues.push_back(hTransitToSampleMapValues);
      hAllSamplesToTransitMapKeys.push_back(hSampleToTransitMapKeys);
      #endif
    }
  }

  double end_to_end_t2 = convertTimeValToDouble(getTimeOfDay ());

  CHK_CU(cudaMemset(nextDoorData.dSampleInsertionPositions, 0, sizeof(EdgePos_t)*nextDoorData.samples.size()));

  std::cout << "Transit Parallel: End to end time " << (end_to_end_t2 - end_to_end_t1) << " secs" << std::endl;
  std::cout << "InversionTime: " << inversionTime <<", " << "LoadBalancingTime: " << loadBalancingTime << ", " << "GridKernelTime: " << gridKernelTime << ", SubWarpKernelTime: " << subWarpKernelTime << std::endl;
  CHK_CU(cudaFree(d_temp_storage));
  CHK_CU(cudaFree(dUniqueTransits));
  CHK_CU(cudaFree(dUniqueTransitsCounts));
  CHK_CU(cudaFree(dUniqueTransitsNumRuns));

  #if 0
  for (int s = 1; s < steps() - 2; s++) {
    std::unordered_set<VertexID_t> s1, s2, intersection;
    for (int i = 100000; i < 200000; i++) {
      VertexID_t v1 = hAllSamplesToTransitMapKeys[s+1][i];
      VertexID_t v2 = hAllTransitToSampleMapValues[s+2][i];
      //printf("v1 %d v2 %d\n", v1, v2);
      s1.insert(v1);
      s2.insert(v2);
    }
    
    for (auto e : s1) {
      if (s2.count(e) == 1) intersection.insert(e);
    }

    std::cout << "s: " << s << " intersection: " << intersection.size() << std::endl;
  }
  #endif
  return true;
}

bool doSampleParallelSampling(GPUCSRPartition gpuCSRPartition, NextDoorData& nextDoorData)
{
  //Size of each sample output
  size_t maxNeighborsToSample = 1;
  for (int step = 0; step < steps(); step++) {
    maxNeighborsToSample *= stepSize(step);
  }

  size_t finalSampleSize = 0;
  size_t neighborsToSampleAtStep = 1;
  for (int step = 0; step < steps(); step++) {
    neighborsToSampleAtStep *= stepSize(step);
    finalSampleSize += neighborsToSampleAtStep;
  }
  
  neighborsToSampleAtStep = 1;
  
  double end_to_end_t1 = convertTimeValToDouble(getTimeOfDay ());
  for (int step = 0; step < steps(); step++) {
    neighborsToSampleAtStep *= stepSize(step);
    const size_t totalThreads = nextDoorData.samples.size()*neighborsToSampleAtStep;
    
    //Sample neighbors of transit vertices
    sampleParallelKernel<<<thread_block_size(totalThreads, N_THREADS), N_THREADS>>>(step, gpuCSRPartition, nextDoorData.INVALID_VERTEX,
                    nextDoorData.samples.size(), nextDoorData.dFinalSamples, finalSampleSize, nextDoorData.dSampleInsertionPositions,
                    nextDoorData.dCurandStates);

                    
    CHK_CU(cudaGetLastError());
    CHK_CU(cudaDeviceSynchronize());
  }

  double end_to_end_t2 = convertTimeValToDouble(getTimeOfDay ());
  

  CHK_CU(cudaMemset(nextDoorData.dSampleInsertionPositions, 0, sizeof(EdgePos_t)*nextDoorData.samples.size()));

  std::cout << "SampleParallel: End to end time " << (end_to_end_t2 - end_to_end_t1) << " secs" << std::endl;
  return true;
}


std::vector<VertexID_t>& getFinalSamples(NextDoorData& nextDoorData)
{
  CHK_CU(cudaMemcpy(&nextDoorData.hFinalSamples[0], nextDoorData.dFinalSamples, 
                    nextDoorData.hFinalSamples.size()*sizeof(nextDoorData.hFinalSamples[0]), cudaMemcpyDeviceToHost));
  return nextDoorData.hFinalSamples;
}

int nextdoor(const char* graph_file, const char* graph_type, const char* graph_format, 
             const int nruns, const bool chk_results, const bool print_samples,
             const char* kernelType, const bool enableLoadBalancing)
{
  std::vector<Vertex> vertices;

  //Load Graph
  Graph graph;
  CSR* csr;
  if ((csr = loadGraph(graph, (char*)graph_file, (char*)graph_type, (char*)graph_format)) == nullptr) {
    return 1;
  }

  std::cout << "Graph has " <<graph.get_n_edges () << " edges and " << 
      graph.get_vertices ().size () << " vertices " << std::endl; 

  //graph.print(std::cout);
  GPUCSRPartition gpuCSRPartition = transferCSRToGPU(csr);
  
  NextDoorData nextDoorData;
  nextDoorData.gpuCSRPartition = gpuCSRPartition;
  allocNextDoorDataOnGPU(csr, nextDoorData);
  
  for (int i = 0; i < nruns; i++) {
    if (strcmp(kernelType, "TransitParallel") == 0)
      doTransitParallelSampling(csr, gpuCSRPartition, nextDoorData, enableLoadBalancing);
    else if (strcmp(kernelType, "SampleParallel") == 0)
      doSampleParallelSampling(gpuCSRPartition, nextDoorData);
    else
      abort();
  }
    

  std::vector<VertexID_t>& hFinalSamples = getFinalSamples(nextDoorData);

  size_t maxNeighborsToSample = 1;
  for (int step = 0; step < steps(); step++) {
    maxNeighborsToSample *= stepSize(step);
  }

  size_t finalSampleSize = 0;
  size_t neighborsToSampleAtStep = 1;
  for (int step = 0; step < steps(); step++) {
    neighborsToSampleAtStep *= stepSize(step);
    finalSampleSize += neighborsToSampleAtStep;
  }
  
  size_t totalSampledVertices = 0;
  for (auto s : hFinalSamples) {
    totalSampledVertices += (int)(s != nextDoorData.INVALID_VERTEX);
  }

  if (print_samples) {
    for (size_t s = 0; s < hFinalSamples.size(); s += finalSampleSize) {
      std::cout << "Contents of sample " << s/finalSampleSize << " [";
      for(size_t v = s; v < s + finalSampleSize; v++)
        std::cout << hFinalSamples[v] << ", ";
      std::cout << "]" << std::endl;
    }
  }

  std::cout << "totalSampledVertices " << totalSampledVertices << std::endl;
  freeDeviceData(nextDoorData);
  if (chk_results)
    return check_result(csr, nextDoorData.INVALID_VERTEX, nextDoorData.samples, finalSampleSize, hFinalSamples);

  return true;
}

#endif