
#include <ATen/ATen.h>
#include <ATen/cuda/detail/IndexUtils.cuh>
#include <ATen/cuda/Exceptions.h>

#include <torch/extension.h>
#include <THC/THCAtomics.cuh>

#include <cuda.h>
#include <cuda_runtime.h>
#include <cstdio>
#include <cmath>

using torch::Tensor;

static __device__ __const__ float _exp_qmap [] = {
                -0.8875,
                -0.6625,
                -0.4375,
                -0.2125,
                -0.0775,
                -0.0325,
                -0.0055,
                0.0000,
                0.0055,
                0.0325,
                0.0775,
                0.2125,
                0.4375,
                0.6625,
                0.8875,
                1.0000,
};

static __device__ __const__ float _exp_qmidpt [] = {

            -0.775,
            -0.55,
            -0.325,
            -0.145,
            -0.055,
            -0.019,
            -0.00275,
            0.00275,
            0.019,
            0.055,
            0.145,
            0.325,
            0.55,
            0.775,
            0.94375,
};

static __device__ __const__ float _sq_qmap [] = {
                0.0625,
                0.1250,
                0.1875,
                0.2500,
                0.3125,
                0.3750,
                0.4375,
                0.5000,
                0.5625,
                0.6250,
                0.6875,
                0.7500,
                0.8125,
                0.8750,
                0.9375,
                1.0000,
};

static __device__ __const__ float _sq_qmidpt [] = {
            0.09375,
            0.15625,
            0.21875,
            0.28125,
            0.34375,
            0.40625,
            0.46875,
            0.53125,
            0.59375,
            0.65625,
            0.71875,
            0.78125,
            0.84375,
            0.90625,
            0.96875,
};

template <typename T>
__global__ void kernel_cuda_single_tensor(
        T* __restrict__ p,
        const T * __restrict__ g,
        T* __restrict__ exp_avg,
        T* __restrict__ exp_avg_sq,
        const float beta1,
        const float beta2,
        const float lr,
        const float weight_decay,
        const float eps,
        const float step,
        const size_t total_size)
{
        const int global_id = blockIdx.x * blockDim.x + threadIdx.x;
        if (global_id >= total_size) return;

        float curr_grad = g[global_id];

        //decoupled weight decay
        p[global_id] = p[global_id] * (1 - lr * weight_decay);


        exp_avg[global_id] = beta1 * exp_avg[global_id] + (1 - beta1) * curr_grad;
        exp_avg_sq[global_id] = beta2 * exp_avg_sq[global_id] + (1 - beta2) * (curr_grad * curr_grad);

        const float correction1 = 1.0f - powf(beta1, step);
        const float correction2_sqrt = sqrtf(1.0f - powf(beta2, step));
        float step_size = lr / correction1;

        float denom = (sqrtf(exp_avg_sq[global_id]) / correction2_sqrt + eps); // * correction1;
        float update = (exp_avg[global_id]/denom); // + (weight_decay * p[global_id]);
        p[global_id] = p[global_id] - (step_size * update);
}

// interface and launcher for fused adamw cuda kernel
void cuda_fused_single_tensor(Tensor& p, Tensor& g, Tensor& exp_avg, Tensor& exp_avg_sq,
                      float beta1, float beta2, float lr, float weight_decay, float eps, float step) {
    // Get tensor size
    int total_size = p.numel();
    AT_ASSERTM(at::cuda::detail::canUse32BitIndexMath(p),
              "parameter tensor is too large to be indexed with int32");

    const int block_dim = 128;
    int grid_dim = ((total_size + block_dim - 1) / block_dim);
    const dim3 blocks(grid_dim);

    AT_DISPATCH_FLOATING_TYPES_AND_HALF(p.scalar_type(), "cuda_fused_single_tensor", ([&] {
        kernel_cuda_single_tensor<scalar_t><<<blocks, block_dim>>>(
            p.data_ptr<scalar_t>(),
            g.data_ptr<scalar_t>(),
            exp_avg.data_ptr<scalar_t>(),
            exp_avg_sq.data_ptr<scalar_t>(),
            beta1,
            beta2,
            lr,
            weight_decay,
            eps,
            step,
            total_size
        );
    }));

    AT_CUDA_CHECK(cudaGetLastError());
}

// binary search for quantization
__device__ __forceinline__ float q_mapping( const float* __restrict__ qmap,
                                            const float* __restrict__ qmidpt,
                                            float x)
{
    // 4 bit range
    int low = 0;
    int high = 15;

    if (x <= qmap[low]) return low;
    if (qmap[high] <=x) return high;

    while (low < high) {
        int mid = (low + high) >> 1;
        if (qmap[mid] <= x)
        {
            low = mid + 1;
        }
        else
        {
            high = mid;
        }
    }

    return (qmidpt[low-1] < x) ? low : low-1;

}

template <typename T>
__global__ void cuda_fused_4bit_kernel(
    T* __restrict__ p,
    const T* __restrict__ g,
    int8_t* __restrict__ exp,
    int8_t* __restrict__ sq,
    T* __restrict__ exp_qscale,
    T* __restrict__ sq_qscale,
    const float beta1,
    const float beta2,
    const float lr,
    const float weight_decay,
    const float eps,
    const float step,
    const size_t total_size,
    const float correction1,
    const float correction2_sqrt,
    const float step_size,
    const uint8_t bitmask

)
{
    // establish thread, block and global situational awareness
    const int thread_id = threadIdx.x;
    const int block_id = blockIdx.x;
    const int global_id = blockIdx.x * blockDim.x + thread_id;

    const int left_id = global_id << 1;
    const int right_id = left_id + 1;

    __shared__ float absmax_exp;
    __shared__ float absmax_sq;

    if (thread_id == 0) {
        absmax_exp = 0;
        absmax_sq = 0;
    }
    __syncthreads();

    if (left_id >= total_size) return;

    // left side processing
    const int8_t exp_left_index = (exp[global_id]) & bitmask;
    const int8_t sq_left_index = (sq[left_id]) & bitmask;

    //decoupled weight decay
    p[left_id] = p[left_id] * (1 - lr * weight_decay);

    // left exp and sq updates
    float curr_grad = g[left_id];
    float exp_avg_qscale = exp_qscale[block_id];

    T exp_left = _exp_qmap[exp_left_index] * exp_avg_qscale;
    exp_left = beta1 * exp_left + (1 - beta1) * curr_grad;

    T sq_left = _sq_qmap[sq_left_index] * sq_qscale[block_id];
    sq_left = beta2 * sq_left + (1 - beta2) * (curr_grad * curr_grad);

    float denom = (sqrtf(sq_left) / correction2_sqrt + eps);
    float update = (exp_left/denom);

    // param update
    p[left_id] = p[left_id] - (step_size * update);

    // right side processing
    T exp_right =0;
    T sq_right = 0;

    if (right_id < total_size) {
        const int8_t exp_right_index = (exp[global_id] >> 4) & bitmask;
        const int8_t sq_right_index = (sq[global_id]>>4) & bitmask;
        curr_grad = g[right_id];

        //decoupled weight decay, right side
        p[right_id] = p[right_id] * (1 - lr * weight_decay);

        exp_right = _exp_qmap[exp_right_index] * exp_avg_qscale;
        exp_right = beta1 * exp_right + (1-beta1) * curr_grad;

        sq_right = _sq_qmap[sq_right_index] * sq_qscale[block_id];
        sq_right = beta2 * sq_right + (1 - beta2) * (curr_grad * curr_grad);

        denom = (sqrtf(sq_right) / correction2_sqrt + eps);
        update = (exp_right/denom);

        // param update
        p[right_id] = p[right_id] - (step_size * update);

        }

    // prepare quantization info - update absmax scales
    float local_absmax_exp = fmax(fabsf((float)exp_left), fabsf((float)exp_right));
    float local_absmax_sq = fmaxf((float)sq_left, (float)sq_right);

    // determine global max for this block
    __int_as_float(atomicMax((int *)&absmax_exp, __float_as_int(local_absmax_exp)));
    __int_as_float(atomicMax((int *)&absmax_sq, __float_as_int(local_absmax_sq)));

    __syncthreads();

    int8_t local_packed_exp = 0;
    int8_t local_packed_sq = 0;

    // quantize and pack
    const int8_t q_exp_left = (int8_t)q_mapping(_exp_qmap, _exp_qmidpt, (float)exp_left / absmax_exp);
    const int8_t q_sq_left = (int8_t)q_mapping(_sq_qmap, _sq_qmidpt, (float)sq_left / absmax_sq);
    local_packed_exp |= (q_exp_left & bitmask);
    local_packed_sq |= (q_sq_left & bitmask);

    if (right_id < total_size) {
        const int8_t q_exp_right = (int8_t)q_mapping(_exp_qmap, _exp_qmidpt, (float)exp_right / absmax_exp);
        const int8_t q_sq_right = (int8_t)q_mapping(_sq_qmap, _sq_qmidpt, (float)sq_right / absmax_sq);
        local_packed_exp |= (q_exp_right & bitmask << 4);
        local_packed_sq |= (q_sq_right & bitmask << 4);

    }

    // store updated exp and sq
    exp[global_id] = local_packed_exp;
    sq[global_id] = local_packed_sq;

    if (thread_id == 0) {
        exp_qscale[block_id] = (T)absmax_exp;
        sq_qscale[block_id] = (T)absmax_sq;
    }
    __syncthreads();

}

// interface and launcher for 4bit quantized cuda kernel
void cuda_fused_4bit(Tensor& p, Tensor& g,
                        Tensor& exp, Tensor& sq,
                        Tensor& exp_scale, Tensor& sq_scale,
                        float beta1, float beta2,
                        float lr, float weight_decay,
                        float eps, float step
                        ){

    int total_size = p.numel();
    const int block_size = 128;
    int grid = ((total_size + block_size -1) / block_size);
    const dim3 blocks(grid);
    //universal computations
    const float correction1 = 1.0f - powf(beta1, step);
    const float correction2_sqrt = sqrtf(1.0f - powf(beta2, step));
    const float step_size = lr / correction1;

    // leverage constant memory
    const uint8_t g_bitmask = 15;


    AT_DISPATCH_FLOATING_TYPES_AND_HALF(p.scalar_type(), "cuda_fused_4bit", ([&] {
        cuda_fused_4bit_kernel<scalar_t><<<blocks, block_size/2>>>(
            p.data_ptr<scalar_t>(),
            g.data_ptr<scalar_t>(),
            exp.data_ptr<int8_t>(),
            sq.data_ptr<int8_t>(),
            exp_scale.data_ptr<scalar_t>(),
            sq_scale.data_ptr<scalar_t>(),
            beta1,
            beta2,
            lr,
            weight_decay,
            eps,
            step,
            total_size,
            correction1,
            correction2_sqrt,
            step_size,
            g_bitmask

        );
    }));

    AT_CUDA_CHECK(cudaGetLastError());
}
