// Hearing Sense Simulator CPU adapter: exact affine 4-bit/group-64 weights.
// Prefill uses one native unpack per matrix; decode reads packed weights directly.
#pragma once
#include "mlx/backend/cpu/gemm.h"
#include "mlx/threadpool.h"
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

namespace mlx::core {
namespace {

ThreadPool& hs_q4_pool() {
  static ThreadPool pool(4);
  return pool;
}

template <class F>
void hs_q4_rows(size_t count, F body) {
  std::vector<std::future<void>> jobs;
  jobs.reserve(4);
  try {
    for (size_t part = 0; part < 4; ++part) {
      jobs.push_back(hs_q4_pool().enqueue([=]() {
        body(count * part / 4, count * (part + 1) / 4);
      }));
    }
  } catch (...) {
    for (auto& job : jobs) { job.wait(); }
    throw;
  }
  for (auto& job : jobs) { job.wait(); }
  for (auto& job : jobs) { job.get(); }
}

template <class T>
void hs_affine_q4(array& out, const array& x, const array& w,
                  const array& scales, const array& biases) {
  const size_t K = x.shape(-1), N = w.shape(0), M = x.size() / K;
  const size_t groups = K / 64, packs = K / 8;
  const auto* packed = w.data<uint32_t>();
  const auto* scale_data = scales.data<T>();
  const auto* bias_data = biases.data<T>();
  const auto* input = x.data<T>();
  auto* output = out.data<T>();
  std::vector<float> activations(M * K);
  for (size_t i = 0; i < M * K; ++i) { activations[i] = float(input[i]); }

  if (M == 1) {
    hs_q4_rows(N, [&](size_t first, size_t last) {
      for (size_t row = first; row < last; ++row) {
#if defined(__aarch64__)
        float32x4_t sum = vdupq_n_f32(0);
        const int32_t shift_data[4] = {0, -4, -8, -12};
        const int32x4_t shifts = vld1q_s32(shift_data);
        for (size_t group = 0; group < groups; ++group) {
          const float32x4_t scale = vdupq_n_f32(float(scale_data[row * groups + group]));
          const float32x4_t bias = vdupq_n_f32(float(bias_data[row * groups + group]));
          for (size_t pack = 0; pack < 8; ++pack) {
            size_t offset = group * 64 + pack * 8;
            uint32_t bits = packed[row * packs + group * 8 + pack];
            auto lo = vandq_u32(vshlq_u32(vdupq_n_u32(bits), shifts), vdupq_n_u32(15));
            auto hi = vandq_u32(vshlq_u32(vdupq_n_u32(bits >> 16), shifts), vdupq_n_u32(15));
            auto low_weights = vaddq_f32(vmulq_f32(vcvtq_f32_u32(lo), scale), bias);
            auto high_weights = vaddq_f32(vmulq_f32(vcvtq_f32_u32(hi), scale), bias);
            sum = vmlaq_f32(sum, vld1q_f32(activations.data() + offset), low_weights);
            sum = vmlaq_f32(sum, vld1q_f32(activations.data() + offset + 4), high_weights);
          }
        }
        output[row] = T(vaddvq_f32(sum));
#else
        float sum = 0;
        for (size_t group = 0; group < groups; ++group) {
          float scale = float(scale_data[row * groups + group]);
          float bias = float(bias_data[row * groups + group]);
          for (size_t pack = 0; pack < 8; ++pack) {
            uint32_t bits = packed[row * packs + group * 8 + pack];
            for (size_t lane = 0; lane < 8; ++lane) {
              size_t column = group * 64 + pack * 8 + lane;
              sum += activations[column] * (float((bits >> (4 * lane)) & 15) * scale + bias);
            }
          }
        }
        output[row] = T(sum);
#endif
      }
    });
    return;
  }

  std::vector<float> weights(N * K);
  hs_q4_rows(N, [&](size_t first, size_t last) {
    for (size_t row = first; row < last; ++row) {
      for (size_t group = 0; group < groups; ++group) {
        float scale = float(scale_data[row * groups + group]);
        float bias = float(bias_data[row * groups + group]);
        for (size_t pack = 0; pack < 8; ++pack) {
          uint32_t bits = packed[row * packs + group * 8 + pack];
          for (size_t lane = 0; lane < 8; ++lane) {
            weights[row * K + group * 64 + pack * 8 + lane] =
                float((bits >> (4 * lane)) & 15) * scale + bias;
          }
        }
      }
    }
  });
  std::vector<float> results(M * N);
  matmul<float>(activations.data(), weights.data(), results.data(), false, true,
                K, K, N, 1, 0, 1, Shape{int(M), int(K)}, Strides{int64_t(K), 1},
                Shape{int(K), int(N)}, Strides{1, int64_t(K)});
  for (size_t i = 0; i < M * N; ++i) { output[i] = T(results[i]); }
}

bool hs_try_affine_q4(array& out, const array& x, const array& w,
                       const array& scales, const array& biases) {
  if (w.ndim() != 2) { return false; }
  switch (out.dtype()) {
    case float32: hs_affine_q4<float>(out, x, w, scales, biases); return true;
    case bfloat16: hs_affine_q4<bfloat16_t>(out, x, w, scales, biases); return true;
    case float16: hs_affine_q4<float16_t>(out, x, w, scales, biases); return true;
    default: return false;
  }
}

} // namespace
} // namespace mlx::core
