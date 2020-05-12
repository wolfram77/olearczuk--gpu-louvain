#ifndef __UTILS__CUH__
#define __UTILS__CUH__

#include <cstdio>
#include <climits>

const int THREADS_PER_BLOCK = 128;
const int WARP_SIZE = 32;
const int FULL_MASK = 0xffffffff;

struct host_structures {
	// sum of weights of graph
    float M = 0;
    // original number of vertices
    int originalV;
    // current number of vertices
    int V, E;
    // vertex -> community
    int *vertexCommunity;
    // sum of edges adjacent to community
    float *communityWeight;
    // array of neighbours
    int *edges;
    // array of weights of edges
    float *weights;
    // starting index of edges for given vertex (compressed neighbours list)
    int *edgesIndex;
    // represents final assignment of vertex to community
    int *originalToCommunity;
};

struct device_structures {
	float *M;
	// current number of vertices and edges
	int *V, *E;
	// original number of vertices
	int *originalV;
	// vertex -> community
	int *vertexCommunity;
	// sum of edges adjacent to community
	float *communityWeight;
	// array of neighbours
	int *edges;
	// array of weights of edges
	float *weights;
	// starting index of edges for given vertex (compressed neighbours list)
	int *edgesIndex;
	// represents final assignment of vertex to community
	int *originalToCommunity;
	// sums of edges adjacent to vertices
	float *vertexEdgesSum;
	// auxiliary array used for remembering new community
	int *newVertexCommunity;
	// community -> number of vertices in community
	int *communitySize;
	// array used for splitting vertices into buckest
	int *partition;
};

/**
 * Reads input data and initialises values of global variables.
 */
host_structures readInputData(char *fileName);

/**
 * Deletes both host, and device structures.
 * @param hostStructures   structures stored in host memory
 * @param deviceStructures structures stored in device memory
 */
void  deleteStructures(host_structures& hostStructures, device_structures& deviceStructures);

/**
 * Copies structures from hostStructures to deviceStructures.
 * @param hostStructures   structures stored in host memory
 * @param deviceStructures structures stored in device memory
 */
void copyStructures(host_structures& hostStructures, device_structures& deviceStructures);

int blocksNumber(int V, int threadsPerVertex);

static void HandleError(cudaError_t err, const char *file, int line) {
    if (err != cudaSuccess) {
        printf( "%s in %s at line %d\n", cudaGetErrorString(err),
                file, line );
        exit( EXIT_FAILURE );
    }
}

#define HANDLE_ERROR( err) (HandleError( err, __FILE__, __LINE__ ))

#endif /* __UTILS__CUH__ */