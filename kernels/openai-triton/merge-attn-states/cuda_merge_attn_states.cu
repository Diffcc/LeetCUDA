#include <ATen/cuda/CUDAContext.h>
#include <algorithm>
#include <c10/cuda/CUDAGuard.h>
#include <optional>
#include <torch/all.h>
#include <torch/extension.h>

inline __device__ float to_float(float u) { return u; }
inline __device__ float to_float(half u) { return __half2float(u); }
inline __device__ float to_float(__nv_bfloat16 u) {
  return __bfloat162float(u);
}
inline __device__ void from_float(float &d, float s) { d = s; }
inline __device__ void from_float(half &d, float s) { d = __float2half(s); }
inline __device__ void from_float(__nv_bfloat16 &d, float s) {
  d = __float2bfloat16(s);
}

// Implements section 2.2 of https://www.arxiv.org/pdf/2501.01005
// can be used to combine partial attention results (in the split-KV case)
/*************** 
 * @param 
 * output 合并后的注意力输出结果指针
 * output_lse 合并后的LogSumExp(LSE)值的指针，LSE在注意力机制中用于数值稳定
 * prefix_output 指向第一部分(前缀)
 * prefix_lse 指向第一部分的输出对应的LSE指针
 * suffix_output 指向第二部分(后缀)
 * suffix_lse 指向第二部分注意力输出的LSE指针
 * num_tokens 序列中token数量
 * num_heads 注意力头的数量
 * head_size 每个注意力头的大小(维度)
 * 对于每个token，注意力头head都会计算当前token和其他token的注意力权重
 * 进而生成一个输出向量，head_size就是输出向量的维度
 * 对于num_heads(多个头)，会一起决定整个注意力层的总维度（num_heads * head_size = 隐藏层维度）
 * 
 * 这里的切分是将KV序列分为前缀和后缀两个部分，每个部分单独计算注意力，然后将这些注意力结果合并
 * ****************/
template <typename scalar_t, const uint NUM_THREADS>
__global__ void
merge_attn_states_kernel(scalar_t *output, float *output_lse,
                         const scalar_t *prefix_output, const float *prefix_lse,
                         const scalar_t *suffix_output, const float *suffix_lse,
                         const uint num_tokens, const uint num_heads,
                         const uint head_size) {
  using pack_128b_t = uint4;
  const uint pack_size = 16 / sizeof(scalar_t); //128（16 * 8）位数据包 包含的元素数量，例如half = 2, 16 /2 = 8
  // 也就是每个head需要多少线程
  const uint threads_per_head = head_size / pack_size; //每个注意力头的数据被划分为多少个128位的数据包

  const uint global_idx = blockIdx.x * NUM_THREADS + threadIdx.x;
  // 总共需要的线程数
  const uint token_head_threads = num_tokens * num_heads * threads_per_head;

  if (global_idx >= token_head_threads)
    return;

  // global_idx -> token_idx + head_idx + pack_idx
  // 当前线程处理的是哪个token的哪个注意力头
  const uint token_head_idx = global_idx / threads_per_head;
  // 当前线程处理的是这个注意力头的第几个128位数据包
  const uint pack_idx = global_idx % threads_per_head;

  // 当前线程处理的是哪个token
  const uint token_idx = token_head_idx / num_heads;
  // 当前线程处理的注意力头索引
  const uint head_idx = token_head_idx % num_heads;

  const uint pack_offset = pack_idx * pack_size; // (0~15)*8, etc.
  const uint head_offset =
      token_idx * num_heads * head_size + head_idx * head_size;
  const scalar_t *prefix_head_ptr = prefix_output + head_offset;
  const scalar_t *suffix_head_ptr = suffix_output + head_offset;
  scalar_t *output_head_ptr = output + head_offset;

  float p_lse = prefix_lse[head_idx * num_tokens + token_idx];
  float s_lse = suffix_lse[head_idx * num_tokens + token_idx];
  p_lse = std::isinf(p_lse) ? -std::numeric_limits<float>::infinity() : p_lse;
  s_lse = std::isinf(s_lse) ? -std::numeric_limits<float>::infinity() : s_lse;

  const float max_lse = fmaxf(p_lse, s_lse);
  p_lse = p_lse - max_lse;
  s_lse = s_lse - max_lse;
  const float p_se = expf(p_lse);
  const float s_se = expf(s_lse);
  const float out_se = p_se + s_se;
  const float p_scale = p_se / out_se;
  const float s_scale = s_se / out_se;

  if (pack_offset < head_size) {
    // Pack 128b load
    pack_128b_t p_out_pack = reinterpret_cast<const pack_128b_t *>(
        prefix_head_ptr)[pack_offset / pack_size];
    pack_128b_t s_out_pack = reinterpret_cast<const pack_128b_t *>(
        suffix_head_ptr)[pack_offset / pack_size];
    pack_128b_t o_out_pack;

#pragma unroll
    for (uint i = 0; i < pack_size; ++i) {
      // Always use float for FMA to keep high precision.
      // half(uint16_t), bfloat16, float -> float.
      const float p_out_f =
          to_float(reinterpret_cast<const scalar_t *>(&p_out_pack)[i]);
      const float s_out_f =
          to_float(reinterpret_cast<const scalar_t *>(&s_out_pack)[i]);
      // fma: a * b + c = p_out_f * p_scale + (s_out_f * s_scale)

      // result = (a * b) + c FMA(Fused Multiply-Add)语义, 将单独的乘法 + 加法优化为一条指令，并且精度更高
      const float o_out_f = p_out_f * p_scale + (s_out_f * s_scale);
      // float -> half(uint16_t), bfloat16, float.
      from_float(reinterpret_cast<scalar_t *>(&o_out_pack)[i], o_out_f);
    }

    // Pack 128b storage
    reinterpret_cast<pack_128b_t *>(output_head_ptr)[pack_offset / pack_size] =
        o_out_pack;
  }
  // We only need to write to output_lse once per head.
  if (output_lse != nullptr && pack_idx == 0) {
    float out_lse = logf(out_se) + max_lse;
    output_lse[head_idx * num_tokens + token_idx] = out_lse;
  }
}

// The following macro is used to dispatch the conversion function based on
// the output data type. The FN is a macro that calls a function with
// template<typename scalar_t>.
#define DISPATCH_BY_SCALAR_DTYPE(scalar_dtype, fn)                             \
  {                                                                            \
    if (scalar_dtype == at::ScalarType::Float) {                               \
      fn(float);                                                               \
    } else if (scalar_dtype == at::ScalarType::Half) {                         \
      fn(half);                                                                \
    } else if (scalar_dtype == at::ScalarType::BFloat16) {                     \
      fn(__nv_bfloat16);                                                       \
    } else {                                                                   \
      TORCH_CHECK(false, "Unsupported data type of O: ", scalar_dtype);        \
    }                                                                          \
  }

#define LAUNCH_MERGE_ATTN_STATES(scalar_t, NUM_THREADS)                        \
  {                                                                            \
    merge_attn_states_kernel<scalar_t, NUM_THREADS><<<grid, block>>>(          \
        reinterpret_cast<scalar_t *>(output.data_ptr()), output_lse_ptr,       \
        reinterpret_cast<scalar_t *>(prefix_output.data_ptr()),                \
        reinterpret_cast<float *>(prefix_lse.data_ptr()),                      \
        reinterpret_cast<scalar_t *>(suffix_output.data_ptr()),                \
        reinterpret_cast<float *>(suffix_lse.data_ptr()), num_tokens,          \
        num_heads, head_size);                                                 \
  }

template <typename scalar_t>
void merge_attn_states_launcher(
    torch::Tensor &output, // [NUM_TOKENS, NUM_HEADS, HEAD_SIZE]
    std::optional<torch::Tensor> output_lse, // [NUM_HEADS, NUM_TOKENS]
    const torch::Tensor &prefix_output, // [NUM_TOKENS, NUM_HEADS, HEAD_SIZE]
    const torch::Tensor &prefix_lse,    // [NUM_HEADS, NUM_TOKENS]
    const torch::Tensor &suffix_output, // [NUM_TOKENS, NUM_HEADS, HEAD_SIZE]
    const torch::Tensor &suffix_lse     // [NUM_HEADS, NUM_TOKENS]
) {
  constexpr uint NUM_THREADS = 128;
  const uint num_tokens = output.size(0);
  const uint num_heads = output.size(1);
  const uint head_size = output.size(2);
  const uint pack_size = 16 / sizeof(scalar_t);
  TORCH_CHECK(head_size % pack_size == 0,
              "headsize must be multiple of pack_size:", pack_size);
  float *output_lse_ptr = nullptr;
  if (output_lse.has_value()) {
    output_lse_ptr = output_lse.value().data_ptr<float>();
  }
  // process one pack elements per thread. float -> 4, half/bf16 -> 8
  const uint threads_per_head = head_size / pack_size;
  const uint total_threads = num_tokens * num_heads * threads_per_head;

  dim3 block(NUM_THREADS);
  dim3 grid((total_threads + NUM_THREADS - 1) / NUM_THREADS);

  LAUNCH_MERGE_ATTN_STATES(scalar_t, NUM_THREADS);
}

#define CALL_MERGE_ATTN_STATES_LAUNCHER(scalar_t)                              \
  {                                                                            \
    merge_attn_states_launcher<scalar_t>(output, output_lse, prefix_output,    \
                                         prefix_lse, suffix_output,            \
                                         suffix_lse);                          \
  }

void merge_attn_states_cuda(torch::Tensor &output,
                            std::optional<torch::Tensor> output_lse,
                            const torch::Tensor &prefix_output,
                            const torch::Tensor &prefix_lse,
                            const torch::Tensor &suffix_output,
                            const torch::Tensor &suffix_lse) {
  DISPATCH_BY_SCALAR_DTYPE(output.dtype(), CALL_MERGE_ATTN_STATES_LAUNCHER);
}

PYBIND11_MODULE(TORCH_EXTENSION_NAME, m) {
  m.def("merge_attn_states_cuda", &merge_attn_states_cuda, py::arg("output"),
        py::arg("output_lse").none(true), py::arg("prefix_output"),
        py::arg("prefix_lse"), py::arg("suffix_output"), py::arg("suffix_lse"),
        "Merge attention states (CUDA)");
}
