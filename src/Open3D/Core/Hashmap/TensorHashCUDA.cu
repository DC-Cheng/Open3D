// ----------------------------------------------------------------------------
// -                        Open3D: www.open3d.org                            -
// ----------------------------------------------------------------------------
// The MIT License (MIT)
//
// Copyright (c) 2018 www.open3d.org
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.
// ----------------------------------------------------------------------------

#include "Open3D/Core/Hashmap/Hashmap.h"
#include "Open3D/Core/Hashmap/TensorHash.h"
#include "Open3D/Core/Tensor.h"

namespace open3d {

CUDATensorHash::CUDATensorHash(Tensor coords, Tensor indices) {
    // Device check
    if (coords.GetDevice().GetType() != Device::DeviceType::CUDA ||
        indices.GetDevice().GetType() != Device::DeviceType::CUDA) {
        utility::LogError("CUDATensorHash::Input tensors must be on CUDA.");
    }

    // Contiguous check to fit internal hashmap
    if (!coords.IsContiguous() || !indices.IsContiguous()) {
        utility::LogError("CUDATensorHash::Input tensors must be contiguous.");
    }

    // Type check
    if (indices.GetDtype() != Dtype::Int64 &&
        indices.GetDtype() != Dtype::Int32) {
        utility::LogError(
                "CUDATensorHash::Input indices tensor must be Integers.");
    }

    // Shape check
    auto coords_shape = coords.GetShape();
    auto indices_shape = indices.GetShape();
    if (coords_shape.size() != 2) {
        utility::LogError("TensorHashCUDA::Input coords shape must be (N, D).");
    }
    if (indices_shape.size() > 1) {
        utility::LogError(
                "CUDATensorHash::Input indices shape must be (N, ) or "
                "(N, 1).");
    }
    if (coords_shape[0] != indices_shape[0]) {
        utility::LogError(
                "CUDATensorHash::Input coords and indices size mismatch.");
    }

    // Store type and dim info
    key_type_ = coords.GetDtype();
    value_type_ = indices.GetDtype();
    key_dim_ = coords_shape[1];

    int64_t N = coords_shape[0];

    size_t key_size = DtypeUtil::ByteSize(key_type_) * key_dim_;
    if (key_size > MAX_KEY_BYTESIZE) {
        utility::LogError("CUDATensorHash::Unsupported key size: too large.");
    }
    size_t value_size = DtypeUtil::ByteSize(indices.GetDtype());

    // Create hashmap and reserve twice input size
    hashmap_ = CreateHashmap<DefaultHash>(N * 2, key_size, value_size,
                                          coords.GetDevice());
    hashmap_->Insert(static_cast<uint8_t*>(coords.GetBlob()->GetDataPtr()),
                     static_cast<uint8_t*>(indices.GetBlob()->GetDataPtr()), N);
}

__global__ void DispatchIteratorsKernel(iterator_t* iterators,
                                        uint8_t* masks,
                                        uint8_t* values,
                                        size_t key_size,
                                        size_t value_size,
                                        size_t N) {
    size_t tid = threadIdx.x + blockIdx.x * blockDim.x;

    // Valid queries
    if (tid < N && masks[tid]) {
        uint8_t* kv_pair_ptr = iterators[tid];
        uint8_t* src_value_ptr = kv_pair_ptr + key_size;
        uint8_t* dst_value_ptr = values + value_size * tid;

        // Byte-by-byte copy, can be improved
        for (int i = 0; i < value_size; ++i) {
            dst_value_ptr[i] = src_value_ptr[i];
        }
    }
}

std::pair<Tensor, Tensor> CUDATensorHash::Query(Tensor coords) {
    // Device check
    if (coords.GetDevice().GetType() != Device::DeviceType::CUDA) {
        utility::LogError("CUDATensorHash::Input tensors must be on CUDA.");
    }

    // Contiguous check to fit internal hashmap
    if (!coords.IsContiguous()) {
        utility::LogError("CUDATensorHash::Input tensors must be contiguous.");
    }

    // Type and shape check
    if (key_type_ != coords.GetDtype()) {
        utility::LogError("CUDATensorHash::Input coords key type mismatch.");
    }
    auto coords_shape = coords.GetShape();
    if (coords_shape.size() != 2 || coords_shape[1] != key_dim_) {
        utility::LogError("TensorHashCUDA::Input coords shape mismatch.");
    }
    int64_t N = coords.GetShape()[0];

    // Search
    auto result = hashmap_->Search(
            static_cast<uint8_t*>(coords.GetBlob()->GetDataPtr()), N);

    // Decode returned iterators
    auto iterators_buf = result.first;
    auto masks_buf = result.second;

    // Dispatch values
    const size_t num_threads = 32;
    const size_t num_blocks = (N + num_threads - 1) / num_threads;

    auto ret_value_tensor =
            Tensor(SizeVector({N}), value_type_, hashmap_->device_);
    DispatchIteratorsKernel<<<num_blocks, num_threads>>>(
            iterators_buf, masks_buf,
            static_cast<uint8_t*>(ret_value_tensor.GetBlob()->GetDataPtr()),
            hashmap_->dsize_key_, hashmap_->dsize_value_, N);
    OPEN3D_CUDA_CHECK(cudaDeviceSynchronize());
    OPEN3D_CUDA_CHECK(cudaGetLastError());

    // Dispatch masks
    // Copy mask to avoid duplicate data; dummy deleter avoids double free
    // TODO: more efficient memory reuse
    auto blob = std::make_shared<Blob>(hashmap_->device_,
                                       static_cast<void*>(masks_buf),
                                       [](void* dummy) -> void {});
    auto mask_tensor =
            Tensor(SizeVector({N}), SizeVector({1}),
                   static_cast<void*>(masks_buf), Dtype::UInt8, blob);
    auto ret_mask_tensor = mask_tensor.Copy(hashmap_->device_);

    return std::make_pair(ret_value_tensor, ret_mask_tensor);
}

namespace _factory {
std::shared_ptr<CUDATensorHash> CreateCUDATensorHash(Tensor coords,
                                                     Tensor indices) {
    return std::make_shared<CUDATensorHash>(coords, indices);
}
}  // namespace _factory
}  // namespace open3d
