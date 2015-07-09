// ----------------------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------------------

/**
 * @file cc_app.cu
 *
 * @brief connected component (CC) application
 */

#include <gunrock/gunrock.h>

// graph construction utilities
#include <gunrock/graphio/market.cuh>

// connected component includes
#include <gunrock/app/cc/cc_enactor.cuh>
#include <gunrock/app/cc/cc_problem.cuh>
#include <gunrock/app/cc/cc_functor.cuh>

using namespace gunrock;
using namespace gunrock::util;
using namespace gunrock::oprtr;
using namespace gunrock::app::cc;

struct Test_Parameter : gunrock::app::TestParameter_Base {
  public:
    Test_Parameter()  { }
    ~Test_Parameter() { }
};

template <
    typename VertexId,
    typename Value,
    typename SizeT,
    bool INSTRUMENT,
    bool DEBUG,
    bool SIZE_CHECK >
void runCC(GRGraph* output, Test_Parameter *parameter);

template <
    typename      VertexId,
    typename      Value,
    typename      SizeT,
    bool          INSTRUMENT,
    bool          DEBUG >
void sizeCheckCC(GRGraph* output, Test_Parameter *parameter) {
    if (parameter->size_check)
        runCC<VertexId, Value, SizeT, INSTRUMENT, DEBUG,
              true > (output, parameter);

    else
        runCC<VertexId, Value, SizeT, INSTRUMENT, DEBUG,
              false> (output, parameter);
}

template <
    typename    VertexId,
    typename    Value,
    typename    SizeT,
    bool        INSTRUMENT >
void debugCC(GRGraph* output, Test_Parameter *parameter) {
    if (parameter->debug)
        sizeCheckCC<VertexId, Value, SizeT, INSTRUMENT,
                    true > (output, parameter);
    else
        sizeCheckCC<VertexId, Value, SizeT, INSTRUMENT,
                    false> (output, parameter);
}

template <
    typename      VertexId,
    typename      Value,
    typename      SizeT >
void instrumentedCC(GRGraph* output, Test_Parameter *parameter) {
    if (parameter->instrumented)
        debugCC<VertexId, Value, SizeT,  true>(output, parameter);
    else
        debugCC<VertexId, Value, SizeT, false>(output, parameter);
}

/**
 * @brief Run tests for connected component algorithm
 *
 * @tparam VertexId
 * @tparam Value
 * @tparam SizeT
 * @tparam INSTRUMENT
 *
 * @param[in] graph Reference to the CSR graph we process on
 * @param[in] max_grid_size Maximum CTA occupancy for CC kernels
 * @param[in] iterations Number of iterations for running the test
 * @param[in] num_gpus Number of GPUs
 */
template <
    typename VertexId,
    typename Value,
    typename SizeT,
    bool INSTRUMENT,
    bool DEBUG,
    bool SIZE_CHECK >
void runCC(GRGraph* output, Test_Parameter *parameter) {
    typedef CCProblem < VertexId,
            SizeT,
            Value,
            false > CcProblem; // use double buffer

    typedef CCEnactor < CcProblem,
            INSTRUMENT,
            DEBUG,
            SIZE_CHECK > CcEnactor;

    Csr<VertexId, Value, SizeT> *graph =
        (Csr<VertexId, Value, SizeT>*)parameter->graph;
    int           max_grid_size      = parameter -> max_grid_size;
    int           num_gpus           = parameter -> num_gpus;
    double        max_queue_sizing   = parameter -> max_queue_sizing;
    double        max_in_sizing      = parameter -> max_in_sizing;
    ContextPtr   *context            = (ContextPtr*)parameter -> context;
    std::string   partition_method   = parameter -> partition_method;
    int          *gpu_idx            = parameter -> gpu_idx;
    cudaStream_t *streams            = parameter -> streams;
    float         partition_factor   = parameter -> partition_factor;
    int           partition_seed     = parameter -> partition_seed;
    bool          g_stream_from_host = parameter -> g_stream_from_host;
    size_t       *org_size           = new size_t  [num_gpus];
    // Allocate host-side label array
    VertexId    *h_component_ids     = new VertexId[graph->nodes];

    for (int gpu = 0; gpu < num_gpus; gpu++) {
        size_t dummy;
        cudaSetDevice(gpu_idx[gpu]);
        cudaMemGetInfo(&(org_size[gpu]), &dummy);
    }

    CcEnactor* enactor = new CcEnactor(num_gpus, gpu_idx);  // CC enactor map
    CcProblem* problem = new CcProblem;  // Allocate problem on GPU

    util::GRError(
        problem->Init(
            g_stream_from_host,
            graph,
            NULL,
            num_gpus,
            gpu_idx,
            partition_method,
            streams,
            max_queue_sizing,
            max_in_sizing,
            partition_factor,
            partition_seed),
        "CC Problem Initialization Failed", __FILE__, __LINE__);
    util::GRError(
        enactor->Init(context, problem, max_grid_size),
        "BC Enactor Init failed", __FILE__, __LINE__);

    // Perform CC
    CpuTimer cpu_timer;

    util::GRError(
        problem->Reset(enactor->GetFrontierType(), max_queue_sizing),
        "CC Problem Data Reset Failed", __FILE__, __LINE__);
    util::GRError(
        enactor->Reset(), "CC Enactor Reset failed", __FILE__, __LINE__);

    printf("_________________________\n"); fflush(stdout);
    cpu_timer.Start();
    util::GRError(
        enactor->Enact(), "CC Problem Enact Failed", __FILE__, __LINE__);
    cpu_timer.Stop();
    printf("-------------------------\n"); fflush(stdout);
    float elapsed = cpu_timer.ElapsedMillis();

    // Copy out results
    util::GRError(
        problem->Extract(h_component_ids),
        "CC Problem Data Extraction Failed", __FILE__, __LINE__);

    output->node_value1 = (VertexId*)&h_component_ids[0];

    printf("GPU Connected Component finished in %lf msec.\n", elapsed);

    // Clean up
    if (org_size) { delete[] org_size; org_size = NULL; }
    if (problem ) { delete   problem ; problem  = NULL; }
    if (enactor ) { delete   enactor ; enactor  = NULL; }
}

/**
 * @brief dispatch function to handle data_types
 *
 * @param[out] graph_o GRGraph type output
 * @param[in]  graph_i GRGraph type input graph
 * @param[in]  config  cc specific configurations
 * @param[in]  data_t  data type configurations
 */
void dispatch_cc(
    GRGraph*       graph_o,
    const GRGraph* graph_i,
    const GRSetup  config,
    const GRTypes  data_t,
    ContextPtr*    context,
    cudaStream_t*  streams) {
    Test_Parameter *parameter = new Test_Parameter;
    parameter->context  = context;
    parameter->streams  = streams;
    parameter->num_gpus = config.num_devices;
    parameter->gpu_idx  = config.device_list;

    switch (data_t.VTXID_TYPE) {
    case VTXID_INT: {
        switch (data_t.SIZET_TYPE) {
        case SIZET_INT: {
            switch (data_t.VALUE_TYPE) {
            case VALUE_INT: {  // template type = <int, int, int>
                // build input CSR format graph
                Csr<int, int, int> csr(false);
                csr.nodes = graph_i->num_nodes;
                csr.edges = graph_i->num_edges;
                csr.row_offsets    = (int*)graph_i->row_offsets;
                csr.column_indices = (int*)graph_i->col_indices;
                parameter->graph = &csr;

                instrumentedCC<int, int, int>(graph_o, parameter);

                // reset for free memory
                csr.row_offsets    = NULL;
                csr.column_indices = NULL;
                break;
            }
            case VALUE_UINT: {  // template type = <int, uint, int>
                printf("Not Yet Support This DataType Combination.\n");
                break;
            }
            case VALUE_FLOAT: {  // template type = <int, float, int>
                printf("Not Yet Support This DataType Combination.\n");
                break;
            }
            }
            break;
        }
        }
        break;
    }
    }
}

/*
 * @brief gunrock_cc function
 *
 * @param[out] graph_o output subgraph of cc problem
 * @param[in]  graph_i input graph need to process on
 * @param[in]  config  primitive specific configurations
 * @param[in]  data_t  gunrock data_t struct
 */
void gunrock_cc(
    GRGraph       *graph_o,
    const GRGraph *graph_i,
    const GRSetup  config,
    const GRTypes  data_t) {
    // GPU-related configurations
    int           num_gpus =    0;
    int           *gpu_idx = NULL;
    ContextPtr    *context = NULL;
    cudaStream_t  *streams = NULL;

    num_gpus = config.num_devices;
    gpu_idx  = new int [num_gpus];
    for (int i = 0; i < num_gpus; ++i) {
        gpu_idx[i] = config.device_list[i];
    }

    // Create streams and MordernGPU context for each GPU
    streams = new cudaStream_t[num_gpus * num_gpus * 2];
    context = new ContextPtr[num_gpus * num_gpus];
    printf(" using %d GPUs:", num_gpus);
    for (int gpu = 0; gpu < num_gpus; ++gpu) {
        printf(" %d ", gpu_idx[gpu]);
        util::SetDevice(gpu_idx[gpu]);
        for (int i = 0; i < num_gpus * 2; ++i) {
            int _i = gpu * num_gpus * 2 + i;
            util::GRError(cudaStreamCreate(&streams[_i]),
                          "cudaStreamCreate fialed.", __FILE__, __LINE__);
            if (i < num_gpus) {
                context[gpu * num_gpus + i] =
                    mgpu::CreateCudaDeviceAttachStream(gpu_idx[gpu],
                                                       streams[_i]);
            }
        }
    }
    printf("\n");

    dispatch_cc(graph_o, graph_i, config, data_t, context, streams);
}

/*
 * @brief Simple interface take in CSR arrays as input
 * @param[out] components  Return component ID for each node
 * @param[out] num_comps   Return number of components calculated
 * @param[in]  num_nodes   Number of nodes of the input graph
 * @param[in]  num_edges   Number of edges of the input graph
 * @param[in]  row_offsets CSR-formatted graph input row offsets
 * @param[in]  col_indices CSR-formatted graph input column indices
 */
int cc(
    int*       component,
    const int  num_nodes,
    const int  num_edges,
    const int* row_offsets,
    const int* col_indices) {
    printf("-------------------- setting --------------------\n");

    struct GRTypes data_t;          // primitive-specific data types
    data_t.VTXID_TYPE = VTXID_INT;  // integer vertex identifier
    data_t.SIZET_TYPE = SIZET_INT;  // integer graph size type
    data_t.VALUE_TYPE = VALUE_INT;  // integer attributes type

    struct GRSetup config;          // primitive-specific configures
    int list[] = {0};               // device to run algorithm
    config.num_devices = sizeof(list) / sizeof(list[0]);  // number of devices
    config.device_list = list;      // device list to run algorithm

    unsigned int num_components = 0;
    struct GRGraph *graph_o = (struct GRGraph*)malloc(sizeof(struct GRGraph));
    struct GRGraph *graph_i = (struct GRGraph*)malloc(sizeof(struct GRGraph));

    graph_i->num_nodes   = num_nodes;
    graph_i->num_edges   = num_edges;
    graph_i->row_offsets = (void*)&row_offsets[0];
    graph_i->col_indices = (void*)&col_indices[0];

    printf(" loaded %d nodes and %d edges\n", num_nodes, num_edges);

    printf("-------------------- running --------------------\n");
    gunrock_cc(graph_o, graph_i, config, data_t);
    memcpy(component, (int*)graph_o->node_value1, num_nodes * sizeof(int));

    if (graph_i) free(graph_i);
    if (graph_o) free(graph_o);

    printf("------------------- completed -------------------\n");
    return num_components;
}

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End:
