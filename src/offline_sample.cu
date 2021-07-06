#include "app.cuh"

// static __global__ void sample_kernel(Sampler_new *sampler) {
//   Jobs_result<JobType::NS, uint> &result = sampler->result;
//   gpu_graph *graph = &sampler->ggraph;
//   curandState state;
//   curand_init(TID, 0, 0, &state);
//   __shared__ uint current_itr;
//   if (threadIdx.x == 0) current_itr = 0;
//   __syncthreads();

//   for (; current_itr < result.hop_num - 1;)  // for 2-hop, hop_num=3
//   {
//     sample_job job;
//     __threadfence_block();
//     job = result.requireOneJob(current_itr);
//     while (job.val && graph->CheckValid(job.node_id)) {
//       uint src_id = job.node_id;
//       Vector_virtual<uint> alias;
//       Vector_virtual<float> prob;
//       uint src_degree = graph->getDegree((uint)src_id);
//       alias.Construt(
//           graph->alias_array + graph->xadj[src_id] - graph->local_vtx_offset,
//           src_degree);
//       prob.Construt(
//           graph->prob_array + graph->xadj[src_id] - graph->local_vtx_offset,
//           src_degree);
//       alias.Init(src_degree);
//       prob.Init(src_degree);
//       {
//         uint target_size = result.hops[current_itr + 1];
//         if ((target_size > 0) && (target_size < src_degree)) {
//           //   int itr = 0;
//           for (size_t i = 0; i < target_size; i++) {
//             int col = (int)floor(curand_uniform(&state) * src_degree);
//             float p = curand_uniform(&state);
//             uint candidate;
//             if (p < prob[col])
//               candidate = col;
//             else
//               candidate = alias[col];
//             result.AddActive(current_itr, result.getNextAddr(current_itr),
//                              graph->getOutNode(src_id, candidate));
//           }
//         } else if (target_size >= src_degree) {
//           for (size_t i = 0; i < src_degree; i++) {
//             result.AddActive(current_itr, result.getNextAddr(current_itr),
//                              graph->getOutNode(src_id, i));
//           }
//         }
//       }

//       job = result.requireOneJob(current_itr);
//     }
//     __syncthreads();
//     if (threadIdx.x == 0) result.NextItr(current_itr);
//     __syncthreads();
//   }
// }

static __global__ void sample_kernel_first(Sampler_new *sampler, uint itr) {
  Jobs_result<JobType::NS, uint> &result = sampler->result;
  gpu_graph *graph = &sampler->ggraph;
  curandState state;
  curand_init(TID, 0, 0, &state);
  __shared__ matrixBuffer<BLOCK_SIZE, 10, uint> buffer_1hop;
  Vector_virtual<uint> alias;
  Vector_virtual<float> prob;

  buffer_1hop.Init();
  size_t idx_i = TID;
  if (idx_i < result.size) {
    uint current_itr = 0;
    coalesced_group active = coalesced_threads();
    {
      uint src_id = result.GetData(idx_i, current_itr, 0);
      uint src_degree = graph->getDegree((uint)src_id);
      uint sample_size = MIN(result.hops[current_itr + 1], src_degree);

      alias.Construt(
          graph->alias_array + graph->xadj[src_id] - graph->local_vtx_offset,
          src_degree);
      prob.Construt(
          graph->prob_array + graph->xadj[src_id] - graph->local_vtx_offset,
          src_degree);
      alias.Init(src_degree);
      prob.Init(src_degree);

      for (size_t i = 0; i < sample_size; i++) {
        int col = (int)floor(curand_uniform(&state) * src_degree);
        float p = curand_uniform(&state);
        uint candidate;
        if (p < prob[col])
          candidate = col;
        else
          candidate = alias[col];

        // *result.GetDataPtr(idx_i, current_itr + 1, i) =
        //       graph->getOutNode(src_id, candidate);
        buffer_1hop.Set(
            graph->getOutNode(src_id, candidate));  // can move back latter
      }
      active.sync();
      buffer_1hop.Flush(result.data + result.length_per_sample * idx_i, 0);
      result.SetSampleLength(idx_i, current_itr, 0, sample_size);
    }
  }
}
template <uint subwarp_size>
static __global__ void sample_kernel_second_buffer(Sampler_new *sampler,
                                                   uint current_itr) {
#define buffer_len 15  // occupancy allows 15, 15 75% occupancy but best?
  Jobs_result<JobType::NS, uint> &result = sampler->result;
  gpu_graph *graph = &sampler->ggraph;
  curandState state;
  curand_init(TID, 0, 0, &state);

  size_t subwarp_id = TID / subwarp_size;
  uint subwarp_idx = TID % subwarp_size;
  uint local_subwarp_id = LTID / subwarp_size;
  bool alive = (subwarp_idx < result.hops[current_itr]) ? 1 : 0;
  size_t idx_i = subwarp_id;  //

  Vector_virtual<uint> alias;
  Vector_virtual<float> prob;

  thread_block tb = this_thread_block();
  auto warp = tiled_partition<32>(tb);
  auto subwarp = tiled_partition<subwarp_size>(warp);

  __shared__ uint buffer[BLOCK_SIZE][buffer_len];
  // buffer.Init();
  __shared__ uint idxMap[BLOCK_SIZE];
  __shared__ uint iMap[BLOCK_SIZE];
  __shared__ uint len[BLOCK_SIZE];
  // __shared__ uint MainLen[BLOCK_SIZE / subwarp_size];
  idxMap[LTID] = 0;
  iMap[LTID] = 0;
  len[LTID] = 0;
  // if (!subwarp.thread_rank()) MainLen[LTID] = 0;

  if (idx_i < result.size)  // for 2-hop, hop_num=3
  {
    idxMap[LTID] = idx_i;
    iMap[LTID] = subwarp_idx;
    coalesced_group active = coalesced_threads();
    {
      uint src_id, sample_size, src_degree = 0;
      if (alive) {
        src_id = result.GetData(idx_i, current_itr, subwarp_idx);
        src_degree = graph->getDegree((uint)src_id);
        alive = (src_degree == 0) ? false : true;
      }
      // sample_size = MIN(result.hops[current_itr + 1], src_degree);
      sample_size = result.hops[current_itr + 1];
      alias.Construt(
          graph->alias_array + graph->xadj[src_id] - graph->local_vtx_offset,
          src_degree);
      prob.Construt(
          graph->prob_array + graph->xadj[src_id] - graph->local_vtx_offset,
          src_degree);
      alias.Init(src_degree);
      prob.Init(src_degree);

      for (size_t i = 0; i < sample_size; i++) {
        if (alive) {
          // uint candidate = (int)floor(curand_uniform(&state) * src_degree);
          // *result.GetDataPtr(idx_i, current_itr + 1, i) =
          //     graph->getOutNode(src_id, candidate);
          int col = (int)floor(curand_uniform(&state) * src_degree);
          float p = curand_uniform(&state);
          uint candidate;
          if (p < prob[col])
            candidate = col;
          else
            candidate = alias[col];
          buffer[LTID][len[LTID]] = graph->getOutNode(src_id, candidate);
          len[LTID] += 1;
        }
        subwarp.sync();
        uint mainLen = cg::reduce(subwarp, len[LTID], cg::greater<uint>());
        if (mainLen == buffer_len) {
          for (size_t j = 0; j < subwarp_size; j++) {
            subwarp.sync();
            for (size_t k = subwarp.thread_rank();
                 k < len[local_subwarp_id * subwarp_size + j];
                 k += subwarp.size()) {
              *result.GetDataPtr(idxMap[local_subwarp_id * subwarp_size + j],
                                 current_itr + 1, k) =
                  buffer[local_subwarp_id * subwarp_size + j][k];
            }
            if (subwarp.thread_rank() == 0)
              len[local_subwarp_id * subwarp_size + j] = 0;
          }
        }
      }

      if (alive)
        result.SetSampleLength(idx_i, current_itr, subwarp_idx, sample_size);
      subwarp.sync();
      for (size_t j = 0; j < subwarp_size; j++) {
        subwarp.sync();
        for (size_t k = subwarp.thread_rank();
             k < len[local_subwarp_id * subwarp_size + j];
             k += subwarp.size()) {
          *result.GetDataPtr(idxMap[local_subwarp_id * subwarp_size + j],
                             current_itr + 1, k) =
              buffer[local_subwarp_id * subwarp_size + j][k];
        }
      }
    }
  }
}
template <uint subwarp_size>
static __global__ void sample_kernel_second(Sampler_new *sampler,
                                            uint current_itr) {
  Jobs_result<JobType::NS, uint> &result = sampler->result;
  gpu_graph *graph = &sampler->ggraph;
  curandState state;
  curand_init(TID, 0, 0, &state);
  size_t subwarp_id = TID / subwarp_size;
  uint subwarp_idx = TID % subwarp_size;
  uint local_subwarp_id = LTID % subwarp_size;
  bool alive = (subwarp_idx < result.hops[current_itr]) ? 1 : 0;
  size_t idx_i = subwarp_id;  //
  Vector_virtual<uint> alias;
  Vector_virtual<float> prob;

  if (idx_i < result.size)  // for 2-hop, hop_num=3
  {
    coalesced_group active = coalesced_threads();
    {
      uint src_id, src_degree, sample_size;
      if (alive) {
        src_id = result.GetData(idx_i, current_itr, subwarp_idx);
        src_degree = graph->getDegree((uint)src_id);
        sample_size = MIN(result.hops[current_itr + 1], src_degree);
        alias.Construt(
            graph->alias_array + graph->xadj[src_id] - graph->local_vtx_offset,
            src_degree);
        prob.Construt(
            graph->prob_array + graph->xadj[src_id] - graph->local_vtx_offset,
            src_degree);
        alias.Init(src_degree);
        prob.Init(src_degree);
        for (size_t i = 0; i < sample_size; i++) {
          int col = (int)floor(curand_uniform(&state) * src_degree);
          float p = curand_uniform(&state);
          uint candidate;
          if (p < prob[col])
            candidate = col;
          else
            candidate = alias[col];
          *result.GetDataPtr(idx_i, current_itr + 1, i) =
              graph->getOutNode(src_id, candidate);
        }
      }
      if (alive)
        result.SetSampleLength(idx_i, current_itr, subwarp_idx, sample_size);
    }
  }
}

static __global__ void print_result(Sampler_new *sampler) {
  sampler->result.PrintResult();
}

float OfflineSample(Sampler_new &sampler) {
  LOG("%s\n", __FUNCTION__);
  int device;
  cudaDeviceProp prop;
  cudaGetDevice(&device);
  cudaGetDeviceProperties(&prop, device);
  int n_sm = prop.multiProcessorCount;

  Sampler_new *sampler_ptr;
  cudaMalloc(&sampler_ptr, sizeof(Sampler_new));
  CUDA_RT_CALL(cudaMemcpy(sampler_ptr, &sampler, sizeof(Sampler_new),
                          cudaMemcpyHostToDevice));
  double start_time, total_time;
  //   init_kernel_ptr<<<1, 32, 0, 0>>>(sampler_ptr, true);

  // allocate global buffer
  int block_num = n_sm * FLAGS_m;

  CUDA_RT_CALL(cudaDeviceSynchronize());
  CUDA_RT_CALL(cudaPeekAtLastError());
  start_time = wtime();
  sample_kernel_first<<<sampler.result.size / BLOCK_SIZE + 1, BLOCK_SIZE, 0,
                        0>>>(sampler_ptr, 0);
  sample_kernel_second<16>
      <<<sampler.result.size * 16 / BLOCK_SIZE + 1, BLOCK_SIZE, 0, 0>>>(
          sampler_ptr, 1);
  CUDA_RT_CALL(cudaDeviceSynchronize());
  // CUDA_RT_CALL(cudaPeekAtLastError());
  total_time = wtime() - start_time;
  LOG("Device %d sampling time:\t%.2f ms ratio:\t %.1f MSEPS\n",
      omp_get_thread_num(), total_time * 1000,
      static_cast<float>(sampler.result.GetSampledNumber() / total_time /
                         1000000));
  sampler.sampled_edges = sampler.result.GetSampledNumber();
  LOG("sampled_edges %d\n", sampler.sampled_edges);
  if (FLAGS_printresult) print_result<<<1, 32, 0, 0>>>(sampler_ptr);
  CUDA_RT_CALL(cudaDeviceSynchronize());
  return total_time;
}
