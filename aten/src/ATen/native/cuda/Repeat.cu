#include <ATen/ATen.h>
#include <ATen/cuda/CUDAContext.h>
#include <ATen/native/Repeat.h>

template <typename index_t>
__global__ static void compute_cuda_kernel(
    index_t* repeat_ptr,
    int64_t* cumsum_ptr,
    index_t* result_ptr,
    int64_t size,
    int64_t result_size) {
  CUDA_KERNEL_ASSERT(result_size == cumsum_ptr[size - 1]);
  int64_t idx = blockIdx.x * blockDim.x + threadIdx.x;
  int64_t stride = (blockDim.x * gridDim.x) / C10_WARP_SIZE;
  int warp_id = idx / C10_WARP_SIZE;
  int tid_in_warp = idx % C10_WARP_SIZE;
  for (int64_t i = warp_id; i < size; i += stride) {
    int64_t end = cumsum_ptr[i];
    index_t repeat = repeat_ptr[i];
    CUDA_KERNEL_ASSERT(repeat >= 0);
    int64_t start = end - repeat;
    for (int64_t j = start + tid_in_warp; j < end; j += C10_WARP_SIZE) {
      result_ptr[j] = i;
    }
  }
}

template <typename index_t>
static void compute_cuda(
    index_t* repeat_ptr,
    int64_t* cumsum_ptr,
    index_t* result_ptr,
    int64_t size,
    int64_t result_size) {
  int64_t block = 512;
  int64_t warps_per_block = block / at::cuda::warp_size();
  int64_t grid =
      std::min<int64_t>((size + warps_per_block - 1) / warps_per_block, 2048L);

  compute_cuda_kernel<<<grid, block, 0, at::cuda::getCurrentCUDAStream()>>>(
      repeat_ptr, cumsum_ptr, result_ptr, size, result_size);
  C10_CUDA_KERNEL_LAUNCH_CHECK();
}

namespace at {
namespace native {

Tensor repeat_interleave_cuda(
    const Tensor& repeat,
    c10::optional<int64_t> output_size) {
  Tensor output;
  AT_DISPATCH_INDEX_TYPES(
      repeat.scalar_type(), "repeat_interleave_cuda", [&]() {
        output = repeat_interleave_common<index_t, compute_cuda<index_t>>(
            repeat, output_size);
      });
  return output;
}

} // namespace native
} // namespace at
