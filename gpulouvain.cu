#include "utils.cuh"
#include "modularity_optimisation.cuh"
#include "community_aggregation.cuh"


int main(int argc, char *argv[]) {
	char *fileName;
	float minGain;
	bool isVerbose;
	parseCommandLineArgs(argc, argv, &minGain, &isVerbose, &fileName);
	printf("Using graph %s ...\n", fileName);

    auto hostStructures = readInputData(fileName);
		printf("Read input data\n");
    device_structures deviceStructures;
    aggregation_phase_structures aggregationPhaseStructures;

	printf("Copying structures to device memory ...\n");
    cudaEvent_t start, stop;
	HANDLE_ERROR(cudaEventCreate(&start));
	HANDLE_ERROR(cudaEventCreate(&stop));
	HANDLE_ERROR(cudaEventRecord(start, 0));
	copyStructures(hostStructures, deviceStructures, aggregationPhaseStructures);
	initM(hostStructures);
	HANDLE_ERROR(cudaEventRecord(stop, 0));
	HANDLE_ERROR(cudaEventSynchronize(stop));
	float memoryTime;
	HANDLE_ERROR(cudaEventElapsedTime(&memoryTime, start, stop));
	printf("Memory time measured\n");

	HANDLE_ERROR(cudaEventCreate(&start));
	HANDLE_ERROR(cudaEventCreate(&stop));
	HANDLE_ERROR(cudaEventRecord(start, 0));
	for (;;) {
		if (!optimiseModularity(minGain, deviceStructures, hostStructures))
			break;
		aggregateCommunities(deviceStructures, hostStructures, aggregationPhaseStructures);
	}
	int V;
	HANDLE_ERROR(cudaMemcpy(&V, deviceStructures.V, sizeof(int), cudaMemcpyDeviceToHost));
	printf("modularity: %f\n", calculateModularity(V, hostStructures.M, deviceStructures));
	HANDLE_ERROR(cudaEventRecord(stop, 0));
	HANDLE_ERROR(cudaEventSynchronize(stop));
	float algorithmTime;
	HANDLE_ERROR(cudaEventElapsedTime(&algorithmTime, start, stop));
	printf("algorithm_time: %f all_time: %f\n", algorithmTime, algorithmTime + memoryTime);
	if (isVerbose)
		printOriginalToCommunity(deviceStructures, hostStructures);
	deleteStructures(hostStructures, deviceStructures, aggregationPhaseStructures);
	printf("\n");
}
