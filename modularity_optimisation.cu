#include "modularity_optimisation.cuh"
#include <climits>
#include <cstdio>
#include <thrust/partition.h>
#include <cmath>

/**
 * Computes hashing (using double hashing) for open-addressing purposes of arrays in prepareHashArrays function.
 * @param val   value we want to insert
 * @param index current position
 * @param prime size of hash array
 * @return hash
 */
__device__ int getHash(int val, int index, int prime) {
	int h1 = val % prime;
	int h2 = 1 + (val % (prime - 1));
	return (h1 + index * h2) % prime;
}

__device__ float atomicMaxFloat(float *addr, float value) {
	float old;
	old = (value >= 0) ? __int_as_float(atomicMax((int *)addr, __float_as_int(value))) :
		  __uint_as_float(atomicMin((unsigned int *)addr, __float_as_uint(value)));

	return old;
}

/**
 * Computes sum of weights of edges adjacent to vertices (results are stored in vertexEdgesSum).
 * @param deviceStructures structures stored in device memory
 */
__global__ void computeEdgesSum(device_structures deviceStructures) {
	int verticesPerBlock = blockDim.y;
	int concurrentNeighbours = blockDim.x;
	float edgesSum = 0;
	int vertex = blockIdx.x * verticesPerBlock + threadIdx.y;
	if (vertex < *deviceStructures.V) {
		int startOffset = deviceStructures.edgesIndex[vertex], endOffset = deviceStructures.edgesIndex[vertex + 1];
		for (int index = startOffset + threadIdx.x; index < endOffset; index += concurrentNeighbours)
			edgesSum += deviceStructures.weights[index];

		for (unsigned int offset = concurrentNeighbours / 2; offset > 0; offset /= 2) {
			edgesSum += __shfl_down_sync(FULL_MASK, edgesSum, offset);
		}
		if (threadIdx.x == 0) {
			deviceStructures.vertexEdgesSum[vertex] = edgesSum;
		}
	}
}

/**
 * Computes sum of weights of edges adjacent to vertices (results are stored in vertexEdgesSum).
 * @param V               number of vertices
 * @param communityWeight community -> weight (sum of edges adjacent to vertices of community)
 * @param vertexCommunity vertex -> community assignment
 * @param vertexEdgesSum  vertex -> sum of edges adjacent to vertex
 */
__global__ void computeCommunityWeight(device_structures deviceStructures) {
	int vertex = blockIdx.x * THREADS_PER_BLOCK + threadIdx.x;
	if (vertex < *deviceStructures.V) {
		int community = deviceStructures.vertexCommunity[vertex];
		atomicAdd(&deviceStructures.communityWeight[community], deviceStructures.vertexEdgesSum[vertex]);
	}
}

/**
 * Fills content of hashCommunity and hash_weights arrays that are later used in computeGain function.
 * @param community        neighbour's community
 * @param prime            prime number used for hashing
 * @param weight		   neighbour's weight
 * @param hashWeight	   table of sum of weights between vertices and communities
 * @param hashCommunity	   table informing which community's info is stored in given index
 * @param hashTablesOffset offset of the vertex in hash arrays (single hash array may contain multiple vertices)
 */
__device__ int prepareHashArrays(int community, int prime, float weight, float *hashWeight, int *hashCommunity,
								  int hashTablesOffset) {
	int it = 0, curPos;
	do {
		curPos = hashTablesOffset + getHash(community, it++, prime);
		if (hashCommunity[curPos] == community)
			atomicAdd(&hashWeight[curPos], weight);
			// TODO - uses inelegant solution with -1
		else if (hashCommunity[curPos] == -1) {
			if (atomicCAS(&hashCommunity[curPos], -1, community) == -1)
				atomicAdd(&hashWeight[curPos], weight);
			else if (hashCommunity[curPos] == community)
				atomicAdd(&hashWeight[curPos], weight);
		}
	} while (hashCommunity[curPos] != community);
	return curPos;
}

/**
 * Computes gain that would be obtained if we would move vertex to community.
 * @param vertex      	   vertex number
 * @param prime            prime number used for hashing (and size of vertex's area in hash arrays)
 * @param community 	   neighbour's community
 * @param currentCommunity current community of vertex
 * @param communityWeight  community -> weight (sum of edges adjacent to vertices of community)
 * @param vertexEdgesSum   vertex -> sum of edges adjacent to vertex
 * @param hashCommunity    table informing which community's info is stored in given index
 * @param hashWeight       table of sum of weights between vertices and communities
 * @param hashTablesOffset offset of the vertex in hash arrays (single hash array may contain multiple vertices
 * @return gain that would be obtained by moving vertex to community
 */
__device__ float computeGain(int vertex, int community, int currentCommunity, float *communityWeight,
							 float *vertexEdgesSum, float vertexToCommunity) {
	float communitySum = communityWeight[community];
	float currentCommunitySum = communityWeight[currentCommunity] - vertexEdgesSum[vertex];
	float gain = vertexToCommunity / M + vertexEdgesSum[vertex] * (currentCommunitySum - communitySum) / (2 * M * M);
	return gain;
}

/**
 * Finds new vertex -> community assignment (stored in newVertexCommunity) that maximise gains for each vertex.
 * @param V                number of vertices
 * @param vertices		   vertices
 * @param prime            prime number used for hashing
 * @param deviceStructures structures kept in device memory
 */
__device__ void computeMove(int V, int *vertices, int prime, device_structures deviceStructures, int *hashCommunity,
		float *hashWeight, float *vertexToCurrentCommunity, float *bestGains, int *bestCommunities) {
	int verticesPerBlock = blockDim.y;
	int vertexIndex = blockIdx.x * verticesPerBlock + threadIdx.y;
	if (vertexIndex < V) {
		int *vertexCommunity = deviceStructures.vertexCommunity, *edgesIndex = deviceStructures.edgesIndex,
		*edges = deviceStructures.edges, *communitySize = deviceStructures.communitySize,
		*newVertexCommunity = deviceStructures.newVertexCommunity;
		float *weights = deviceStructures.weights, *communityWeight = deviceStructures.communityWeight,
		*vertexEdgesSum = deviceStructures.vertexEdgesSum;

		int concurrentNeighbours = blockDim.x;
		int hashTablesOffset = threadIdx.y * prime;

		// TODO - concurrently
		vertexToCurrentCommunity[threadIdx.y] = 0;
		for (int i = 0; i < prime; i++) {
			hashWeight[hashTablesOffset + i] = 0;
			hashCommunity[hashTablesOffset + i] = -1;
		}

		if (concurrentNeighbours > WARP_SIZE)
			__syncthreads();

		int vertex = vertices[vertexIndex];
		int currentCommunity = vertexCommunity[vertex];
		int bestCommunity = currentCommunity;
		float bestGain = 0;
		// putting data in hash table
		int neighbourIndex = threadIdx.x + edgesIndex[vertex];
		int upperBound = edgesIndex[vertex + 1];
		int curPos;

		while (neighbourIndex < upperBound) {
			int neighbour = edges[neighbourIndex];
			int community = vertexCommunity[neighbour];
			float weight = weights[neighbourIndex];
			// this lets us achieve ei -> C(i)\{i} instead of ei -> C(i)
			if (neighbour != vertex) {
				curPos = prepareHashArrays(community, prime, weight, hashWeight, hashCommunity, hashTablesOffset);
				if (community == currentCommunity)
					 atomicAdd(&vertexToCurrentCommunity[threadIdx.y], weight);
			}
			if ((community < currentCommunity || communitySize[community] > 1 || communitySize[currentCommunity] > 1) &&
				community != currentCommunity) {
				float gain = computeGain(vertex, community, currentCommunity, communityWeight, vertexEdgesSum, hashWeight[curPos]);
				if (gain > bestGain || (gain == bestGain && community < bestCommunity)) {
					bestGain = gain;
					bestCommunity = community;
				}
			}
			neighbourIndex += concurrentNeighbours;
		}

		if (concurrentNeighbours <= WARP_SIZE) {
			for (unsigned int offset = concurrentNeighbours / 2; offset > 0; offset /= 2) {
				float otherGain = __shfl_down_sync(FULL_MASK, bestGain, offset);
				int otherCommunity = __shfl_down_sync(FULL_MASK, bestCommunity, offset);
				if (otherGain > bestGain || (otherGain == bestGain && otherCommunity < bestCommunity)) {
					bestGain = otherGain;
					bestCommunity = otherCommunity;
				}
			}
		} else {
			for (unsigned int offset = concurrentNeighbours / 2; offset > 0; offset /= 2) {
				__syncthreads();
				bestGains[threadIdx.x] = bestGain;
				bestCommunities[threadIdx.x] = bestCommunity;
				__syncthreads();
				if (threadIdx.x + offset < THREADS_PER_BLOCK) {
					float otherGain = bestGains[threadIdx.x + offset];
					int otherCommunity = bestCommunities[threadIdx.x + offset];
					if (otherGain > bestGain || (otherGain == bestGain && otherCommunity < bestCommunity)) {
						bestGain = otherGain;
						bestCommunity = otherCommunity;
					}
				}
			}
		}
		if (threadIdx.x == 0 && bestGain - vertexToCurrentCommunity[threadIdx.y] / M > 0) {
			newVertexCommunity[vertex] = bestCommunity;
		} else {
			newVertexCommunity[vertex] = currentCommunity;
		}
	}
}

__global__ void computeMoveShared(int V, int *vertices, int prime, device_structures deviceStructures) {
	int verticesPerBlock = blockDim.y;
	int vertexIndex = blockIdx.x * verticesPerBlock + threadIdx.y;
	if (vertexIndex < V) {
		extern __shared__ int s[];
		int *hashCommunity = s;
		auto *hashWeight = (float *) &hashCommunity[verticesPerBlock * prime];
		auto *vertexToCurrentCommunity = (float *) &hashWeight[verticesPerBlock * prime];
		float *bestGains = nullptr;
		int *bestCommunities = nullptr;
		if (blockDim.x > WARP_SIZE) {
			bestGains = &vertexToCurrentCommunity[verticesPerBlock];
			bestCommunities = (int *) &bestGains[THREADS_PER_BLOCK];
		}
		computeMove(V, vertices, prime, deviceStructures, hashCommunity, hashWeight, vertexToCurrentCommunity,
				bestGains, bestCommunities);
	}
}

__global__ void computeMoveGlobal(int V, int *vertices, int prime, device_structures deviceStructures, int *hashCommunity, float *hashWeight) {
	int verticesPerBlock = blockDim.y;
	int vertexIndex = blockIdx.x * verticesPerBlock + threadIdx.y;
	if (vertexIndex < V) {
		extern __shared__ int s[];
		auto *vertexToCurrentCommunity = (float *) s;
		float *bestGains = &vertexToCurrentCommunity[verticesPerBlock];
		int *bestCommunities = (int *) &bestGains[THREADS_PER_BLOCK];
		computeMove(V, vertices, prime, deviceStructures, hashCommunity, hashWeight, vertexToCurrentCommunity,
					bestGains, bestCommunities);
	}
}

/**
 * Updates vertexCommunity content based on newVertexCommunity content..
 * Additionally, updates communitySize.
 * @param V                number of vertices
 * @param vertices         vertices
 * @param deviceStructures structures kept in device memory
 */
__global__ void updateVertexCommunity(int V, int *vertices, device_structures deviceStructures) {
	int index = blockIdx.x * THREADS_PER_BLOCK + threadIdx.x;
	if (index < V) {
		int vertex = vertices[index];
		int oldCommunity = deviceStructures.vertexCommunity[vertex];
		int newCommunity = deviceStructures.newVertexCommunity[vertex];
		if (oldCommunity != newCommunity) {
			deviceStructures.vertexCommunity[vertex] = newCommunity;
			atomicSub(&deviceStructures.communitySize[oldCommunity], 1);
			atomicAdd(&deviceStructures.communitySize[newCommunity], 1);
		}
	}
}

__global__ void updateOriginalToCommunity(device_structures deviceStructures) {
	int vertex = blockIdx.x * THREADS_PER_BLOCK + threadIdx.x;
	if (vertex < *deviceStructures.originalV) {
		int community = deviceStructures.originalToCommunity[vertex];
		deviceStructures.originalToCommunity[vertex] = deviceStructures.vertexCommunity[community];
	}
}

void printVertexAssignments(host_structures& structures) {
	for (int c = 0; c < structures.V; c++) {
		printf("%d", c + 1);
		for (int v = 0; v < structures.V; v++)
			if (c == structures.vertexCommunity[v])
				printf(" %d", v + 1);
		printf("\n");
	}
}

struct isInBucket
{
	isInBucket(int llowerBound, int uupperBound, int *eedgesIndex) {
		lowerBound = llowerBound;
		upperBound = uupperBound;
		edgesIndex = eedgesIndex;
	}

	int lowerBound, upperBound;
	int *edgesIndex;
	__host__ __device__
	bool operator()(const int &v) const
	{
		int edgesNumber = edgesIndex[v + 1] - edgesIndex[v];
		return edgesNumber > lowerBound && edgesNumber <= upperBound;
	}
};

bool isPrime(int n) {
	for (int i = 2; i < sqrt(n) + 1; i++)
		if (n % i == 0)
			return false;
	return true;
}

int getPrime(int n) {
	do {
		n++;
	} while(!isPrime(n));
	return n;
}

bool optimiseModularity(float minGain, device_structures& deviceStructures, host_structures& hostStructures) {
	int V = hostStructures.V;
	computeEdgesSum<<<blocksNumber(V, WARP_SIZE), dim3{WARP_SIZE, THREADS_PER_BLOCK / WARP_SIZE}>>>(deviceStructures);

	HANDLE_ERROR(cudaMemcpy(hostStructures.edgesIndex, deviceStructures.edgesIndex,(V + 1) * (sizeof(int)), cudaMemcpyDeviceToHost));

	int *partition = deviceStructures.partition;
	thrust::sequence(thrust::device, partition, partition + V, 0);

	int lastBucketPrime = getPrime(V * 1.5);
	int *hashCommunity;
	float *hashWeight;
	HANDLE_ERROR(cudaMalloc((void**)&hashCommunity, lastBucketPrime * sizeof(int)));
	HANDLE_ERROR(cudaMalloc((void**)&hashWeight, lastBucketPrime * sizeof(float)));

	float totalGain = minGain;
	bool wasAnythingChanged = false;
	while (totalGain >= minGain) {
		float modularityBefore = calculateModularity(V, hostStructures.M, deviceStructures);
		for(int bucketNum= 0; bucketNum < bucketsSize - 2; bucketNum++) {
//		for(int bucketNum= 0; bucketNum < 1; bucketNum++) {
			dim3 blockDimension = dims[bucketNum];
			int vertexDegree = buckets[bucketNum + 1];
			int prime = primes[bucketNum];
			auto predicate = isInBucket(buckets[bucketNum], buckets[bucketNum + 1], hostStructures.edgesIndex);
			int *deviceVerticesEnd = thrust::partition(thrust::device, partition, partition + V, predicate);
			int verticesInBucket = thrust::distance(partition, deviceVerticesEnd);
			if (verticesInBucket > 0) {
				int sharedMemSize = blockDimension.y * prime * (sizeof(float) + sizeof(int)) + blockDimension.y * sizeof(float);
				if (blockDimension.x > WARP_SIZE)
					sharedMemSize += THREADS_PER_BLOCK * (sizeof(int) + sizeof(float));
				computeMoveShared<<<blocksNumber(verticesInBucket, vertexDegree), blockDimension, sharedMemSize>>>(verticesInBucket, partition, prime,
						deviceStructures);
			}
			// updating vertex -> community assignment
			updateVertexCommunity<<<blocksNumber(V, 1), THREADS_PER_BLOCK>>>(verticesInBucket, partition, deviceStructures);
			// updating community weight
			thrust::fill(thrust::device, deviceStructures.communityWeight, deviceStructures.communityWeight + hostStructures.V, (float) 0);
			computeCommunityWeight<<<blocksNumber(V, 1), THREADS_PER_BLOCK>>>(deviceStructures);
		}

		// last bucket case
		int bucketNum = bucketsSize - 2;
		dim3 blockDimension = dims[bucketNum];
		int vertexDegree = V;
		auto predicate = isInBucket(buckets[bucketNum], buckets[bucketNum + 1], hostStructures.edgesIndex);
		int *deviceVerticesEnd = thrust::partition(thrust::device, partition, partition + V, predicate);
		int verticesInBucket = thrust::distance(partition, deviceVerticesEnd);
		if (verticesInBucket > 0) {
			int sharedMemSize = THREADS_PER_BLOCK * (sizeof(int) + sizeof(float)) + blockDimension.y * sizeof(float);
			computeMoveGlobal<<<blocksNumber(verticesInBucket, vertexDegree), blockDimension, sharedMemSize>>>(
					verticesInBucket, partition, lastBucketPrime,deviceStructures, hashCommunity, hashWeight);
		}

		float modularityAfter = calculateModularity(V, hostStructures.M, deviceStructures);
		totalGain = modularityAfter - modularityBefore;
//		printf("before: %f, after: %f\n", modularityBefore, modularityAfter);
		printf("%f\n", modularityBefore);
		wasAnythingChanged = wasAnythingChanged | (totalGain > 0);
	}
	HANDLE_ERROR(cudaMemcpy(hostStructures.vertexCommunity, deviceStructures.vertexCommunity,
							hostStructures.V * sizeof(float), cudaMemcpyDeviceToHost));
	V = hostStructures.V;
//	printVertexAssignments(hostStructures);
	updateOriginalToCommunity<<<blocksNumber(hostStructures.originalV, 1), THREADS_PER_BLOCK>>>(deviceStructures);
	HANDLE_ERROR(cudaFree(partition));
	return wasAnythingChanged;
}

__global__ void calculateToOwnCommunity(device_structures deviceStructures, float *sum) {
	int community = blockIdx.x * THREADS_PER_BLOCK + threadIdx.x;
	if (community < *deviceStructures.V) {
		float toOwnCommunity = 0;
		for (int vertex = 0; vertex < *deviceStructures.V; vertex++) {
			if (deviceStructures.vertexCommunity[vertex] == community) {
				for (int i = deviceStructures.edgesIndex[vertex]; i < deviceStructures.edgesIndex[vertex+1]; i++) {
					int neighbour = deviceStructures.edges[i];
					int neighbourCommunity = deviceStructures.vertexCommunity[neighbour];
					if (neighbourCommunity == community)
						toOwnCommunity += deviceStructures.weights[i];
				}
			}
		}
		atomicAdd(sum, toOwnCommunity);
	}
}

__global__ void calculateCommunityWeightSum(device_structures deviceStructures, float *sum) {
	int community = blockIdx.x * THREADS_PER_BLOCK + threadIdx.x;
	if (community < *deviceStructures.V) {
		float communityWeight = deviceStructures.communityWeight[community];
		atomicAdd(sum, communityWeight * communityWeight);
	}
}

float calculateModularity(int V, float M, device_structures deviceStructures) {
	float *toOwnCommunityDevice, *communityWeightSumDevice;
	HANDLE_ERROR(cudaMalloc((void**)&toOwnCommunityDevice, sizeof(float)));
	HANDLE_ERROR(cudaMalloc((void**)&communityWeightSumDevice, sizeof(float)));
	thrust::fill(thrust::device, toOwnCommunityDevice, toOwnCommunityDevice + 1, (float) 0);
	thrust::fill(thrust::device, communityWeightSumDevice, communityWeightSumDevice + 1, (float) 0);

	float toOwnCommunity = 0, communityWeightSum = 0;
	int blocksNumber = (V + THREADS_PER_BLOCK - 1) / THREADS_PER_BLOCK;
	calculateToOwnCommunity<<<blocksNumber, THREADS_PER_BLOCK>>>(deviceStructures, toOwnCommunityDevice);
	calculateCommunityWeightSum<<<blocksNumber, THREADS_PER_BLOCK>>>(deviceStructures, communityWeightSumDevice);

	HANDLE_ERROR(cudaMemcpy(&toOwnCommunity, toOwnCommunityDevice, sizeof(float), cudaMemcpyDeviceToHost));
	HANDLE_ERROR(cudaMemcpy(&communityWeightSum, communityWeightSumDevice, sizeof(float), cudaMemcpyDeviceToHost));
	return toOwnCommunity / (2 * M) - communityWeightSum  / (4 * M * M);
}

void initM(host_structures& hostStructures) {
	HANDLE_ERROR(cudaMemcpyToSymbol(M, &hostStructures.M, sizeof(float)));
}