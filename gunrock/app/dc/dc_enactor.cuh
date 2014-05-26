// ----------------------------------------------------------------
// Gunrock -- Fast and Efficient GPU Graph Library
// ----------------------------------------------------------------
// This source code is distributed under the terms of LICENSE.TXT
// in the root directory of this source distribution.
// ----------------------------------------------------------------

/**
 * @file
 * dc_enactor.cuh
 *
 * @brief DC Problem Enactor
 */

#pragma once

#include <gunrock/util/kernel_runtime_stats.cuh>
#include <gunrock/util/test_utils.cuh>
#include <gunrock/util/sort_utils.cuh>

#include <gunrock/oprtr/advance/kernel.cuh>
#include <gunrock/oprtr/advance/kernel_policy.cuh>
#include <gunrock/oprtr/filter/kernel.cuh>
#include <gunrock/oprtr/filter/kernel_policy.cuh>

#include <gunrock/app/enactor_base.cuh>
#include <gunrock/app/dc/dc_problem.cuh>
#include <gunrock/app/dc/dc_functor.cuh>

#include <cub/cub.cuh> // cub scan
#include <moderngpu.cuh>

using namespace mgpu;

namespace gunrock {
namespace app {
namespace dc {

/**
 * @brief DC problem enactor class.
 *
 * @tparam INSTRUMWENT Boolean type to show whether or not to collect per-CTA clock-count statistics
 */
template<bool INSTRUMENT>
class DCEnactor : public EnactorBase
{
  // Members
protected:
  
  /**
   * CTA duty kernel stats
   */
    
  unsigned long long total_runtimes;  // Total working time by each CTA
  unsigned long long total_lifetimes; // Total life time of each CTA
  unsigned long long total_queued;
  
  /**
   * A pinned, mapped word that the traversal kernels will signal when done
   */
  volatile int        *done;
  int                 *d_done;
  cudaEvent_t         throttle_event;
  
  /**
   * Current iteration, also used to get the final search depth of the DC search
   */
  long long           iteration;
  
  // Methods
protected:
  
  /**
   * @brief Prepare the enactor for DC kernel call. Must be called prior to each DC iteration.
   *
   * @param[in] problem DC Problem object which holds the graph data and DC problem data to compute.
   * @param[in] edge_map_grid_size CTA occupancy for edge mapping kernel call.
   * @param[in] filter_grid_size CTA occupancy for filter kernel call.
   *
   * \return cudaError_t object which indicates the success of all CUDA function calls.
   */
  template <typename ProblemData>
  cudaError_t Setup(ProblemData *problem)
  {
    typedef typename ProblemData::SizeT     SizeT;
    typedef typename ProblemData::VertexId  VertexId;
    
    cudaError_t retval = cudaSuccess;
    
    //initialize the host-mapped "done"
    if (!done) {
      int flags = cudaHostAllocMapped;
      
      // Allocate pinned memory for done
      if (retval = util::GRError(cudaHostAlloc((void**)&done, sizeof(int) * 1, flags),
				 "DCEnactor cudaHostAlloc done failed", __FILE__, __LINE__)) return retval;
      
      // Map done into GPU space
      if (retval = util::GRError(cudaHostGetDevicePointer((void**)&d_done, (void*) done, 0),
				 "DCEnactor cudaHostGetDevicePointer done failed", __FILE__, __LINE__)) return retval;
      
      // Create throttle event
      if (retval = util::GRError(cudaEventCreateWithFlags(&throttle_event, cudaEventDisableTiming),
				 "DCEnactor cudaEventCreateWithFlags throttle_event failed", __FILE__, __LINE__)) return retval;
    }
    
    //graph slice
    typename ProblemData::GraphSlice *graph_slice = problem->graph_slices[0];
    //typename ProblemData::DataSlice  *data_slice  = problem->data_slices[0];
  
    do {
      // Bind row-offsets and bitmask texture
      cudaChannelFormatDesc   row_offsets_desc = cudaCreateChannelDesc<SizeT>();
      if (retval = util::GRError(cudaBindTexture(0,
						 gunrock::oprtr::edge_map_forward::RowOffsetTex<SizeT>::ref,
						 graph_slice->d_row_offsets,
						 row_offsets_desc,
						 (graph_slice->nodes + 1) * sizeof(SizeT)),
				 "DCEnactor cudaBindTexture row_offset_tex_ref failed", __FILE__, __LINE__)) break;
      
      
      /*cudaChannelFormatDesc   column_indices_desc = cudaCreateChannelDesc<VertexId>();
	if (retval = util::GRError(cudaBindTexture(
	0,
	gunrock::oprtr::edge_map_forward::ColumnIndicesTex<SizeT>::ref,
	graph_slice->d_column_indices,
	column_indices_desc,
	graph_slice->edges * sizeof(VertexId)),
	"DCEnactor cudaBindTexture column_indices_tex_ref failed", __FILE__, __LINE__)) break;*/
    } while (0);
    
    return retval;
  }
  
public:
  
  /**
   * @brief DCEnactor constructor
   */
  DCEnactor(bool DEBUG = false) :
    EnactorBase(EDGE_FRONTIERS, DEBUG),
    iteration(0),
    total_queued(0),
    done(NULL),
    d_done(NULL)
  {}
  
  /**
   * @brief DCEnactor destructor
   */
  virtual ~DCEnactor()
  {
    if (done) 
    {
      util::GRError(cudaFreeHost((void*)done),
		    "DCEnactor cudaFreeHost done failed", __FILE__, __LINE__);
      
      util::GRError(cudaEventDestroy(throttle_event),
		    "DCEnactor cudaEventDestroy throttle_event failed", __FILE__, __LINE__);
    }
  }
  
  /**
   * \addtogroup PublicInterface
   * @{
   */
  
  /**
   * @brief Obtain statistics about the last DC search enacted.
   *
   * @param[out] total_queued Total queued elements in DC kernel running.
   * @param[out] search_depth Search depth of DC algorithm.
   * @param[out] avg_duty Average kernel running duty (kernel run time/kernel lifetime).
   */
template <typename VertexId>
void GetStatistics(long long   &total_queued,
		   VertexId    &search_depth,
		   double      &avg_duty)
  {
    cudaThreadSynchronize();
    
    total_queued = this->total_queued;
    search_depth = this->iteration;
    
    avg_duty = (total_lifetimes > 0) ?
      double(total_runtimes) / total_lifetimes : 0.0;
  }
  
  /** @} */
  
  /**
   * @brief Enacts a degree centrality on the specified graph.
   *
   * @tparam EdgeMapPolicy Kernel policy for forward edge mapping.
   * @tparam FilterKernelPolicy Kernel policy for filtering.
   * @tparam DCProblem DC Problem type.
   *
   * @param[in] problem DCProblem object.
   * @param[in] max_grid_size Max grid size for DC kernel calls.
   *
   * \return cudaError_t object which indicates the success of all CUDA function calls.
   */
  template<
    typename AdvanceKernelPolicy,
    typename FilterKernelPolicy,
    typename DCProblem>
  cudaError_t EnactDC(CudaContext &context,
		      DCProblem   *problem,
		      int         top_nodes,
		      int         max_grid_size = 0)
  {
    typedef typename DCProblem::SizeT      SizeT;
    typedef typename DCProblem::Value      Value;
    typedef typename DCProblem::VertexId   VertexId;

    typedef DCFunctor<VertexId, SizeT, Value, DCProblem> DcFunctor;

    cudaError_t retval = cudaSuccess;
    
    unsigned int *d_scanned_edges = NULL;
    do {
      
      // initialization
      if (retval = Setup(problem)) break;
      if (retval = EnactorBase::Setup(problem, 
				      max_grid_size,
				      AdvanceKernelPolicy::CTA_OCCUPANCY, 
				      FilterKernelPolicy::CTA_OCCUPANCY)) break;
      
      // single gpu graph slice
      typename DCProblem::GraphSlice *graph_slice = problem->graph_slices[0];
      typename DCProblem::DataSlice  *data_slice  = problem->d_data_slices[0];
      
      // sort node_ids by degree centralities
      util::CUBRadixSort<Value, VertexId>(false, graph_slice->nodes, 
					  problem->data_slices[0]->d_degrees, 
					  problem->data_slices[0]->d_node_id);
      
      // scan to get row_offsets for top k subgraph
      void   *d_temp_storage = NULL;
      size_t temp_storage_bytes = 0;
      cub::DeviceScan::ExclusiveSum(d_temp_storage, 
				    temp_storage_bytes,
				    problem->data_slices[0]->d_degrees,
				    problem->data_slices[0]->d_sub_row_offsets,
				    top_nodes);
      
      cudaMalloc(&d_temp_storage, temp_storage_bytes);
      
      cub::DeviceScan::ExclusiveSum(d_temp_storage, 
				    temp_storage_bytes, 
				    problem->data_slices[0]->d_degrees,
				    problem->data_slices[0]->d_sub_row_offsets,
				    top_nodes);
      
      // advanced edge mapping to find neighbors for top k nodes
      frontier_attribute.queue_length = top_nodes;
      frontier_attribute.queue_index  = 0;
      frontier_attribute.selector     = 0;
      frontier_attribute.queue_reset  = true;

      if (AdvanceKernelPolicy::ADVANCE_MODE == gunrock::oprtr::advance::LB) 
      {
	if (retval = util::GRError(cudaMalloc((void**)&d_scanned_edges,
					      graph_slice->edges * sizeof(unsigned int)),
				   "DCProblem cudaMalloc d_scanned_edges failed", __FILE__, __LINE__)) 
	  return retval;
      }
      
      // put top nodes into frontier queue used for mapping
      util::MemsetCopyVectorKernel<<<128, 128>>>(graph_slice->frontier_queues.d_keys[frontier_attribute.selector],
						 problem->data_slices[0]->d_node_id,
						 top_nodes);
      
      // edge mapping
      gunrock::oprtr::advance::LaunchKernel<AdvanceKernelPolicy, DCProblem, DcFunctor>(
	d_done,
	enactor_stats,
	frontier_attribute,
	data_slice,
	(VertexId*)NULL,
	(bool*)NULL,
	(bool*)NULL,
	d_scanned_edges,
	graph_slice->frontier_queues.d_keys[frontier_attribute.selector],
	graph_slice->frontier_queues.d_keys[frontier_attribute.selector^1],
	(VertexId*)NULL,
	(VertexId*)NULL,
	graph_slice->d_row_offsets,
	graph_slice->d_column_indices,
	(SizeT*)NULL,
	(VertexId*)NULL,
	graph_slice->frontier_elements[frontier_attribute.selector],
	graph_slice->frontier_elements[frontier_attribute.selector^1],
	this->work_progress,
	context,
	gunrock::oprtr::advance::V2V);

      if (DEBUG && (retval = util::GRError(cudaThreadSynchronize(), 
					   "advance::Kernel failed", __FILE__, __LINE__))) break;
      cudaEventQuery(throttle_event);
      
      // get the length of sub graph column indices
      if (retval = work_progress.GetQueueLength(frontier_attribute.queue_index+1, 
						frontier_attribute.queue_length)) break;
      SizeT top_edges = frontier_attribute.queue_length;

      // copy sub graph column indices results back to d_sub_col_indices 
      util::MemsetCopyVectorKernel<<<128, 128>>>(problem->data_slices[0]->d_sub_col_indices,
						 graph_slice->frontier_queues.d_keys[frontier_attribute.selector^1],
						 top_edges);
      
      // print out results
      //util::DisplayDeviceResults(problem->data_slices[0]->d_sub_row_offsets, top_nodes);
      //util::DisplayDeviceResults(problem->data_slices[0]->d_sub_col_indices, top_edges);
      
      // check if any of the frontiers overflowed due to redundant expansion
      bool overflowed = false;
      if (retval = work_progress.CheckOverflow<SizeT>(overflowed)) break;
      if (overflowed) 
      {
	retval = util::GRError(cudaErrorInvalidConfiguration, 
			       "Frontier queue overflow. Please increase queus size factor.",
			       __FILE__, __LINE__); break;
      }
      
    } while(0);
    
    if (d_scanned_edges) cudaFree(d_scanned_edges);
    if (DEBUG) printf("====> GPU Degree Centrality Complete.\n");
    
    return retval;
  }
  
  /**
   * \addtogroup PublicInterface
   * @{
   */
  
  /**
   * @brief DC Enact kernel entry.
   *
   * @tparam DCProblem DC Problem type. @see DCProblem
   *
   * @param[in] problem Pointer to DCProblem object.
   * @param[in] src Source node for DC.
   * @param[in] max_grid_size Max grid size for DC kernel calls.
   *
   * \return cudaError_t object which indicates the success of all CUDA function calls.
   */
  template <typename DCProblem>
  cudaError_t Enact(CudaContext &context,
		    DCProblem   *problem,
		    int         top_nodes,
		    int	        max_grid_size = 0)
  {
    if (this->cuda_props.device_sm_version >= 300) 
    {
      typedef gunrock::oprtr::filter::KernelPolicy<
	DCProblem,                          // Problem data type
	300,                                // CUDA_ARCH
	INSTRUMENT,                         // INSTRUMENT
	0,                                  // SATURATION QUIT
	true,                               // DEQUEUE_PROBLEM_SIZE
	8,                                  // MIN_CTA_OCCUPANCY
	8,                                  // LOG_THREADS
	1,                                  // LOG_LOAD_VEC_SIZE
	0,                                  // LOG_LOADS_PER_TILE
	5,                                  // LOG_RAKING_THREADS
	5,                                  // END_BITMASK_CULL
	8>                                  // LOG_SCHEDULE_GRANULARITY
	FilterKernelPolicy;
      
      typedef gunrock::oprtr::advance::KernelPolicy<
	DCProblem,                          // Problem data type
	300,                                // CUDA_ARCH
	INSTRUMENT,                         // INSTRUMENT
	8,                                  // MIN_CTA_OCCUPANCY
	10,                                 // LOG_THREADS
	8,                                  // LOG_BLOCKS
	32 * 128,                           // LIGHT_EDGE_THRESHOLD (used for partitioned advance mode)
	1,                                  // LOG_LOAD_VEC_SIZE
	0,                                  // LOG_LOADS_PER_TILE
	5,                                  // LOG_RAKING_THREADS
	32,                                 // WARP_GATHER_THRESHOLD
	128 * 4,                            // CTA_GATHER_THRESHOLD
	7,                                  // LOG_SCHEDULE_GRANULARITY
	gunrock::oprtr::advance::LB>        
	AdvanceKernelPolicy;
      
      return  EnactDC<AdvanceKernelPolicy, FilterKernelPolicy, DCProblem>(context,
									  problem,
									  top_nodes,
									  max_grid_size);
    }
    
    //to reduce compile time, get rid of other architecture for now
    //TODO: add all the kernelpolicy settings for all archs
    
    printf("Not yet tuned for this architecture\n");
    return cudaErrorInvalidDeviceFunction;
  
  }
  
  /** @} */
  
};
  
} // namespace dc
} // namespace app
} // namespace gunrock

// Leave this at the end of the file
// Local Variables:
// mode:c++
// c-file-style: "NVIDIA"
// End:
