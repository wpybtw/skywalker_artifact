/*
 * @Description: just perform RW
 * @Date: 2020-11-30 14:30:06
 * @LastEditors: PengyuWang
 * @LastEditTime: 2021-01-10 15:09:28
 * @FilePath: /skywalker/src/unbiased_walk.cu
 */
#include "app.cuh"

#define PV 2.0f
#define QV 0.5f
#define MAX_SCALE MAX(PV, QV)

__global__ void Node2vecKernelStaticBuffer(Walker *walker) {
  Jobs_result<JobType::RW, uint> &result = walker->result;
  gpu_graph *graph = &walker->ggraph;
  curandState state;
  curand_init(TID, 0, 0, &state);
  __shared__ matrixBuffer<BLOCK_SIZE, 31, uint> buffer;
  buffer.Init();
  size_t idx_i = TID;
  uint lastV = idx_i;
  if (idx_i < result.size) {
    result.length[idx_i] = result.hop_num - 1;
    for (uint current_itr = 0; current_itr < result.hop_num - 1;
         current_itr++) {
      uint src_id = result.GetData(current_itr, idx_i);
      uint src_degree = graph->getDegree((uint)src_id);
      if (src_degree == 0) {
        result.length[idx_i] = current_itr;
        buffer.Finish();
        return;
      } else if (src_degree > 1) {
        uint outV;
        do {
          uint x = (int)floor(curand_uniform(&state) * src_degree);
          uint y = (int)floor(curand_uniform(&state) * MAX_SCALE);
          float h;
          outV = graph->getOutNode(src_id, x);
          if (graph->CheckConnect(lastV, outV)) {
            h = QV;
          } else if (lastV == outV) {
            h = PV;
          } else {
            h = 1.0;
          }
          if (y < h) break;
        } while (true);
        buffer.Set(outV);
      } else {
        buffer.Set(graph->getOutNode(src_id, 0));
      }
      lastV = src_id;
      buffer.CheckFlush(result.data + result.hop_num * idx_i, current_itr);
    }
    buffer.Flush(result.data + result.hop_num * idx_i, 0);
  }
}
__global__ void UnbiasedWalkKernelStaticBuffer(Walker *walker, float *tp) {
  Jobs_result<JobType::RW, uint> &result = walker->result;
  gpu_graph *graph = &walker->ggraph;
  curandState state;
  curand_init(TID, 0, 0, &state);
  __shared__ matrixBuffer<BLOCK_SIZE, 31, uint> buffer;
  buffer.Init();
  size_t idx_i = TID;
  if (idx_i < result.size) {
    result.length[idx_i] = result.hop_num - 1;
    uint src_id;
    bool alive = true;
    for (uint current_itr = 0; current_itr < result.hop_num - 1;
         current_itr++) {
      if (alive) {
        src_id =
            (current_itr == 0) ? result.GetData(current_itr, idx_i) : src_id;
        uint src_degree = graph->getDegree((uint)src_id);
        if (src_degree == 0 || curand_uniform(&state) < *tp) {
          result.length[idx_i] = current_itr;
          // buffer.Finish();
          alive = false;
        } else if (src_degree > 1) {
          uint candidate = (int)floor(curand_uniform(&state) * src_degree);
          uint next_src = graph->getOutNode(src_id, candidate);
          buffer.Set(next_src);
          src_id = next_src;
        } else {
          uint next_src = graph->getOutNode(src_id, 0);
          buffer.Set(next_src);
          src_id = next_src;
        }
      }
      buffer.CheckFlush(result.data + result.hop_num * idx_i, current_itr);
    }
    buffer.Flush(result.data + result.hop_num * idx_i, 0);
  }
}
__global__ void UnbiasedWalkKernelStatic(Walker *walker, float *tp) {
  Jobs_result<JobType::RW, uint> &result = walker->result;
  gpu_graph *graph = &walker->ggraph;
  curandState state;
  curand_init(TID, 0, 0, &state);

  size_t idx_i = TID;
  if (idx_i < result.size) {
    result.length[idx_i] = result.hop_num - 1;
    for (uint current_itr = 0; current_itr < result.hop_num - 1;
         current_itr++) {
      uint src_id = result.GetData(current_itr, idx_i);
      uint src_degree = graph->getDegree((uint)src_id);
      if (src_degree == 0 || curand_uniform(&state) < *tp) {
        result.length[idx_i] = current_itr;
        break;
      } else if (1 < src_degree) {
        uint candidate = (int)floor(curand_uniform(&state) * src_degree);
        *result.GetDataPtr(current_itr + 1, idx_i) =
            graph->getOutNode(src_id, candidate);
      } else {
        *result.GetDataPtr(current_itr + 1, idx_i) =
            graph->getOutNode(src_id, 0);
      }
    }
  }
}
__global__ void UnbiasedWalkKernel(Walker *walker, float *tp) {
  Jobs_result<JobType::RW, uint> &result = walker->result;
  gpu_graph *graph = &walker->ggraph;
  curandState state;
  curand_init(TID, 0, 0, &state);
  for (size_t idx_i = TID; idx_i < result.size;
       idx_i += gridDim.x * blockDim.x) {
    result.length[idx_i] = result.hop_num - 1;
    for (uint current_itr = 0; current_itr < result.hop_num - 1;
         current_itr++) {
      uint src_id = result.GetData(current_itr, idx_i);
      uint src_degree = graph->getDegree((uint)src_id);
      // if(idx_i==0) printf("src_id %d src_degree %d\n",src_id,src_degree );
      if (src_degree == 0 || curand_uniform(&state) < *tp) {
        result.length[idx_i] = current_itr;
        break;
      } else if (1 < src_degree) {
        uint candidate = (int)floor(curand_uniform(&state) * src_degree);
        *result.GetDataPtr(current_itr + 1, idx_i) =
            graph->getOutNode(src_id, candidate);
      } else {
        *result.GetDataPtr(current_itr + 1, idx_i) =
            graph->getOutNode(src_id, 0);
      }
    }
  }
}
__global__ void UnbiasedWalkKernelPerItr(Walker *walker, uint current_itr) {
  Jobs_result<JobType::RW, uint> &result = walker->result;
  gpu_graph *graph = &walker->ggraph;
  curandState state;
  curand_init(TID, 0, 0, &state);
  // for (uint current_itr = 0; current_itr < result.hop_num - 1;
  // current_itr++)
  // {
  if (TID < result.frontier.Size(current_itr)) {
    size_t idx_i = result.frontier.Get(current_itr, TID);
    uint src_id = result.GetData(current_itr, idx_i);
    uint src_degree = graph->getDegree((uint)src_id);
    result.length[idx_i] = current_itr;
    if (1 < src_degree) {
      int col = (int)floor(curand_uniform(&state) * src_degree);
      uint candidate = col;
      *result.GetDataPtr(current_itr + 1, idx_i) =
          graph->getOutNode(src_id, candidate);
      result.frontier.SetActive(current_itr + 1, idx_i);
    } else if (src_degree == 1) {
      *result.GetDataPtr(current_itr + 1, idx_i) = graph->getOutNode(src_id, 0);
      result.frontier.SetActive(current_itr + 1, idx_i);
    }
  }
}

__global__ void Reset(Walker *walker, uint current_itr) {
  if (TID == 0) walker->result.frontier.Reset(current_itr);
}
__global__ void GetSize(Walker *walker, uint current_itr, uint *size) {
  if (TID == 0) *size = walker->result.frontier.Size(current_itr);
}
static __global__ void print_result(Walker *walker) {
  walker->result.PrintResult();
}

float UnbiasedWalk(Walker &walker) {
  LOG("%s\n", __FUNCTION__);
  int device;
  cudaDeviceProp prop;
  cudaGetDevice(&device);
  cudaGetDeviceProperties(&prop, device);
  int n_sm = prop.multiProcessorCount;

  Walker *sampler_ptr;
  cudaMalloc(&sampler_ptr, sizeof(Walker));
  CUDA_RT_CALL(
      cudaMemcpy(sampler_ptr, &walker, sizeof(Walker), cudaMemcpyHostToDevice));

  float *tp_d, tp;
  tp = FLAGS_tp;
  cudaMalloc(&tp_d, sizeof(float));
  CUDA_RT_CALL(cudaMemcpy(tp_d, &tp, sizeof(float), cudaMemcpyHostToDevice));

  double start_time, total_time;
  // init_kernel_ptr<<<1, 32, 0, 0>>>(sampler_ptr);

  // cudaEvent_t start, stop;
  // cudaEventCreate(&start);
  // cudaEventCreate(&stop);

  // allocate global buffer
  int block_num = n_sm * FLAGS_m;
  CUDA_RT_CALL(cudaDeviceSynchronize());
  CUDA_RT_CALL(cudaPeekAtLastError());

  uint size_h, *size_d;
  cudaMalloc(&size_d, sizeof(uint));

  // cudaEventRecord(start);
  start_time = wtime();

  if (FLAGS_node2vec) {
    Node2vecKernelStaticBuffer<<<walker.num_seed / BLOCK_SIZE + 1, BLOCK_SIZE,
                                 0, 0>>>(sampler_ptr);
  } else if (!FLAGS_peritr) {
    if (FLAGS_static) {
      if (FLAGS_buffer)
        UnbiasedWalkKernelStaticBuffer<<<walker.num_seed / BLOCK_SIZE + 1,
                                         BLOCK_SIZE, 0, 0>>>(sampler_ptr, tp_d);
      else
        UnbiasedWalkKernelStatic<<<walker.num_seed / BLOCK_SIZE + 1, BLOCK_SIZE,
                                   0, 0>>>(sampler_ptr, tp_d);
    } else
      UnbiasedWalkKernel<<<block_num, BLOCK_SIZE, 0, 0>>>(sampler_ptr, tp_d);
  } else {
    for (uint current_itr = 0; current_itr < walker.result.hop_num - 1;
         current_itr++) {
      GetSize<<<1, 32, 0, 0>>>(sampler_ptr, current_itr, size_d);
      CUDA_RT_CALL(
          cudaMemcpy(&size_h, size_d, sizeof(uint), cudaMemcpyDeviceToHost));
      if (size_h > 0) {
        UnbiasedWalkKernelPerItr<<<size_h / BLOCK_SIZE + 1, BLOCK_SIZE, 0, 0>>>(
            sampler_ptr, current_itr);
        Reset<<<1, 32, 0, 0>>>(sampler_ptr, current_itr);
      } else {
        break;
      }
    }
  }

  CUDA_RT_CALL(cudaDeviceSynchronize());
  // cudaEventRecord(stop);
  // cudaEventSynchronize(stop);

  // CUDA_RT_CALL(cudaPeekAtLastError());
  total_time = wtime() - start_time;
  // float milliseconds = 0;
  // cudaEventElapsedTime(&milliseconds, start, stop);
  // printf("cuda event time %f \n",milliseconds);
  LOG("Device %d sampling time:\t%.6f ratio:\t %.2f MSEPS sampled %u\n",
      omp_get_thread_num(), total_time,
      static_cast<float>(walker.result.GetSampledNumber() / total_time /
                         1000000),
      walker.result.GetSampledNumber());
  walker.sampled_edges = walker.result.GetSampledNumber();
  if (FLAGS_printresult) print_result<<<1, 32, 0, 0>>>(sampler_ptr);
  CUDA_RT_CALL(cudaDeviceSynchronize());
  return total_time;
}
