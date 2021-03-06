//==================================================
// bvh.cu
//
//  Copyright (c) 2016 Benjamin Hepp.
//  Author: Benjamin Hepp
//  Created on: Jan 16, 2017
//==================================================
#include <bh/cuda_utils.h>
#include <vector>
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <iostream>
#include <bh/utilities.h>
#include "bvh.cuh"
#include <bh/cuda_utils.h>
#include <stdlib.h>
#include <assert.h>

using std::printf;

namespace bvh {

template <typename FloatT>
CudaTree<FloatT>* CudaTree<FloatT>::createCopyFromHostTree(
    NodeType* root,
    const std::size_t num_of_nodes,
    const std::size_t tree_depth) {
  CudaTree* cuda_tree = new CudaTree(tree_depth);
  const std::size_t memory_size = sizeof(NodeType) * num_of_nodes;
  std::cout << "Allocating " << (memory_size / 1024. / 1024.) << " MB of GPU memory" << std::endl;
  cuda_tree->d_nodes_ = bh::CudaUtils::template allocate<NodeType>(num_of_nodes);
  std::deque<NodeType*> node_queue;
  node_queue.push_front(root);
  std::size_t node_counter = 0;
  std::size_t copied_node_counter = 0;
  const std::size_t report_threshold = num_of_nodes / 20;
  std::size_t report_counter = 0;
  const std::size_t node_cache_size = num_of_nodes / 20;
  std::vector<CudaNode<FloatT>> node_cache;
  node_cache.reserve(node_cache_size);
  while (!node_queue.empty()) {
    NodeType* node = node_queue.back();
    node_queue.pop_back();

    CudaNode<FloatT> cuda_node;
    cuda_node.bounding_box_ = node->bounding_box_;
    cuda_node.ptr_ = static_cast<void*>(node);
    BH_ASSERT(cuda_node.ptr_ != nullptr);
    if (node->hasLeftChild()) {
      node_queue.push_front(node->getLeftChild());
      const std::size_t left_child_index = node_counter + node_queue.size();
      cuda_node.left_child_ = &cuda_tree->d_nodes_[left_child_index];
    }
    else {
      cuda_node.left_child_ = nullptr;
    }
    if (node->hasRightChild()) {
      node_queue.push_front(node->getRightChild());
      std::size_t right_child_index = node_counter + node_queue.size();
      cuda_node.right_child_ = &cuda_tree->d_nodes_[right_child_index];
    }
    else {
      cuda_node.right_child_ = nullptr;
    }
//    bh::CudaUtils::copyToDevice(cuda_node, &tree->d_nodes_[node_counter]);
    node_cache.push_back(cuda_node);
    if (node_cache.size() == node_cache_size) {
      bh::CudaUtils::copyArrayToDevice(node_cache, &cuda_tree->d_nodes_[copied_node_counter]);
      copied_node_counter += node_cache.size();
      node_cache.clear();
    }
    ++node_counter;
    ++report_counter;
    if (report_counter >= report_threshold) {
      std::cout << "Copied " << node_counter << " nodes [" << (100 * node_counter / (FloatT)num_of_nodes) << " %]" << std::endl;
      report_counter = 0;
    }
  }
  CUDA_DEVICE_SYNCHRONIZE();
  CUDA_CHECK_ERROR();
  return cuda_tree;
}

template <typename FloatT>
__device__ bool intersectsIterativeCuda(
    const typename CudaTree<FloatT>::CudaRayType& ray,
    const FloatT t_min,
    const FloatT t_max,
    typename CudaTree<FloatT>::CudaIntersectionIterativeStackEntry* stack,
    std::size_t stack_size,
    const std::size_t max_stack_size,
    typename CudaTree<FloatT>::CudaIntersectionResult* d_result) {
  CudaRayData<FloatT> ray_data;
  ray_data.origin = ray.origin;
  ray_data.direction = ray.direction;
  ray_data.inv_direction = ray.direction.cwiseInverse();
  while (stack_size > 0 && stack_size <= max_stack_size) {
    printf("stack_size=%d\n", stack_size);
    --stack_size;
    typename CudaTree<FloatT>::CudaIntersectionIterativeStackEntry &entry = stack[stack_size];
    FloatT t_ray;
    const bool intersects = entry.node->getBoundingBox().intersectsCuda(ray_data, &t_ray, t_min, t_max);
    if (!intersects) {
      continue;
    }
    FloatT intersection_dist_sq = t_ray * t_ray;
    if (intersection_dist_sq > d_result->dist_sq) {
      continue;
    }
    if (entry.node->isLeaf()) {
      const bool inside_bounding_box = entry.node->getBoundingBox().isInside(ray_data.origin);
      if (inside_bounding_box) {
        // If already inside the bounding box we want the intersection point to be the start of the ray.
        t_ray = 0;
        intersection_dist_sq = 0;
      }
      if (intersection_dist_sq <= d_result->dist_sq) {
        d_result->intersection = ray_data.origin + ray_data.direction * t_ray;
        d_result->node = static_cast<void *>(entry.node->getPtr());
        d_result->depth = entry.depth;
        d_result->dist_sq = intersection_dist_sq;
      }
    }
    else {
      if (entry.node->hasLeftChild()) {
        stack[stack_size].node = entry.node->getLeftChild();
        stack[stack_size].depth = entry.depth + 1;
        ++stack_size;
      }
      if (entry.node->hasRightChild()) {
        stack[stack_size].node = entry.node->getRightChild();
        stack[stack_size].depth = entry.depth + 1;
        ++stack_size;
      }
    }
  }
  const bool success = stack_size == 0;
  return success;

//    if (entry.state == CudaTree<FloatT>::CudaIntersectionIterativeStackEntry::NotVisited) {
//      entry.intersects = false;
//      const bool inside_bounding_box = entry.node->getBoundingBox().isInside(data.ray.origin);
//      if (inside_bounding_box) {
//
//      }
//      const bool outside_bounding_box = entry.node->getBoundingBox().isOutside(data.ray.origin);
//      CudaVector3<FloatT> intersection;
//      FloatT intersection_dist_sq;
//      bool early_break = false;
//      if (outside_bounding_box) {
//        // Check if ray intersects current node
//        const bool intersects = entry.node->getBoundingBox().intersectsCuda(data.ray, &intersection);
//    //      std::cout << "intersects: " << intersects << std::endl;
//        if (intersects) {
//          intersection_dist_sq = (data.ray.origin - intersection).squaredNorm();
//          if (intersection_dist_sq > d_result->dist_sq) {
//            early_break = true;
//          }
//        }
//        else {
//          early_break = true;
//        }
//      }
//      if (early_break) {
//        --stack_size;
//      }
//      else {
//        if (entry.node->isLeaf()) {
//          if (!outside_bounding_box) {
//            // If already inside the bounding box we want the intersection point to be the start of the ray.
//            intersection = data.ray.origin;
//            intersection_dist_sq = 0;
//          }
//          d_result->intersection = intersection;
//          d_result->node = static_cast<void*>(entry.node->getPtr());
//          d_result->depth = entry.depth;
//          d_result->dist_sq = intersection_dist_sq;
//          entry.intersects = true;
//          --stack_size;
//        }
//        else {
//          if (entry.node->hasLeftChild()) {
//            stack[stack_size].node = entry.node->getLeftChild();
//            stack[stack_size].depth = entry.depth + 1;
//            stack[stack_size].state = CudaTree<FloatT>::CudaIntersectionIterativeStackEntry::NotVisited;
//            ++stack_size;
//            entry.state = CudaTree<FloatT>::CudaIntersectionIterativeStackEntry::PushedLeftChild;
//          }
//        }
//      }
//    }
//    else if (entry.state == CudaTree<FloatT>::CudaIntersectionIterativeStackEntry::PushedLeftChild) {
//      // This stack entry was processed before. The next stack entries contain the child results
//      entry.intersects = stack[stack_size + 0].intersects;
//      if (entry.node->hasRightChild()) {
//        stack[stack_size].node = entry.node->getRightChild();
//        stack[stack_size].depth = entry.depth + 1;
//        stack[stack_size].state = CudaTree<FloatT>::CudaIntersectionIterativeStackEntry::NotVisited;
//        ++stack_size;
//        entry.state = CudaTree<FloatT>::CudaIntersectionIterativeStackEntry::PushedRightChild;
//      }
//    }
//    else if (entry.state == CudaTree<FloatT>::CudaIntersectionIterativeStackEntry::PushedRightChild) {
//      // This stack entry was processed before. The next stack entries contain the child results
//      if (!entry.intersects) {
//        entry.intersects = stack[stack_size].intersects;
//      }
//      --stack_size;
//    }
//  }
//  return stack[0].intersects;
}

#if WITH_CUDA_RECURSION
template <typename FloatT>
__device__ bool intersectsRecursiveCuda(
    const typename CudaTree<FloatT>::CudaIntersectionData data,
    typename CudaTree<FloatT>::NodeType* cur_node,
    const std::size_t cur_depth,
    typename CudaTree<FloatT>::CudaIntersectionResult* d_result) {
  bool outside_bounding_box = cur_node->getBoundingBox().isOutside(data.ray.origin);
  CudaVector3<FloatT> intersection;
  FloatT intersection_dist_sq;
  if (outside_bounding_box) {
    // Check if ray intersects current node
    const bool intersects = cur_node->getBoundingBox().intersectsCuda(data.ray, &intersection);
    if (intersects) {
      intersection_dist_sq = (data.ray.origin - intersection).squaredNorm();
      if (intersection_dist_sq > d_result->dist_sq) {
        return false;
      }
    }
    else {
      return false;
    }
  }
  if (cur_node->isLeaf()) {
    if (!outside_bounding_box) {
      // If already inside the bounding box we want the intersection point to be the start of the ray (if the bbox extent > min_dist).
      intersection = data.ray.origin;
      intersection_dist_sq = 0;
    }
    d_result->intersection = intersection;
    d_result->node = static_cast<void*>(cur_node->getPtr());
    d_result->depth = cur_depth;
    d_result->dist_sq = intersection_dist_sq;
    return true;
  }

  bool intersects_left = false;
  bool intersects_right = false;
  if (cur_node->hasLeftChild()) {
    intersects_left = intersectsRecursiveCuda<FloatT>(data, cur_node->getLeftChild(), cur_depth + 1, d_result);
  }
  if (cur_node->hasRightChild()) {
    intersects_right = intersectsRecursiveCuda<FloatT>(data, cur_node->getRightChild(), cur_depth + 1, d_result);
  }
  return intersects_left || intersects_right;
}
#endif

#if WITH_CUDA_RECURSION
template <typename FloatT>
__global__ void intersectsRecursiveCudaKernel(
    const typename CudaTree<FloatT>::CudaRayType* d_rays,
    const std::size_t num_of_rays,
    const FloatT min_range,
    const FloatT max_range,
    typename CudaTree<FloatT>::NodeType* d_root,
    typename CudaTree<FloatT>::CudaIntersectionResult* d_results) {
  const std::size_t index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index < num_of_rays) {
    const typename CudaTree<FloatT>::CudaRayType& ray = d_rays[index];
    typename CudaTree<FloatT>::CudaIntersectionData data;
    data.ray.origin = ray.origin;
    data.ray.direction = ray.direction;
    data.ray.inv_direction = ray.direction.cwiseInverse();
    data.min_range_sq = min_range * min_range;
    typename CudaTree<FloatT>::CudaIntersectionResult& result = d_results[index];
    result.dist_sq = max_range > 0 ? max_range * max_range : FLT_MAX;
    result.node = nullptr;
    const std::size_t cur_depth = 0;
  //  printf("Calling intersectsRecursiveCuda\n");
    intersectsRecursiveCuda<FloatT>(data, d_root, cur_depth, &result);
  }
}
#endif

template <typename FloatT>
__global__ void intersectsIterativeCudaKernel(
    const typename CudaTree<FloatT>::CudaRayType* d_rays,
    const std::size_t num_of_rays,
    const FloatT min_range,
    const FloatT max_range,
    typename CudaTree<FloatT>::NodeType* d_root,
    typename CudaTree<FloatT>::CudaIntersectionIterativeStackEntry* stacks,
    const std::size_t max_stack_size,
    bool* d_success,
    typename CudaTree<FloatT>::CudaIntersectionResult* d_results) {
  *d_success = true;
  const std::size_t index = blockIdx.x * blockDim.x + threadIdx.x;
  if (index < num_of_rays) {
    const typename CudaTree<FloatT>::CudaRayType& ray = d_rays[index];
    typename CudaTree<FloatT>::CudaIntersectionResult& result = d_results[index];
    result.dist_sq = max_range > 0 ? max_range * max_range : FLT_MAX;
    result.node = nullptr;
    typename CudaTree<FloatT>::CudaIntersectionIterativeStackEntry* stack = &stacks[index * max_stack_size];
    stack[0].depth = 0;
    stack[0].node = d_root;
    const std::size_t stack_size = 1;
//    for (std::size_t i = 0; i < max_stack_size; ++i) {
//      stack[i].state = CudaTree<FloatT>::CudaIntersectionIterativeStackEntry::NotVisited;
//    }
    const bool thread_success = intersectsIterativeCuda<FloatT>(ray, min_range, max_range, stack, stack_size, max_stack_size, &result);
    if (!thread_success) {
      *d_success = thread_success;
    }
    assert(thread_success);
  }
}

template <typename FloatT>
__device__ CudaVector3<FloatT> getCameraRay(
    const CudaMatrix4x4<FloatT>& intrinsics,
    const FloatT x,
    const FloatT y) {
  CudaVector3<FloatT> ray_direction;
  ray_direction(0) = (x - intrinsics(0, 2)) / intrinsics(0, 0);
  ray_direction(1) = (y - intrinsics(1, 2)) / intrinsics(1, 1);
  ray_direction(2) = 1;
  return ray_direction;
}

template <typename FloatT>
__device__ CudaRay<FloatT> getCameraRay(
    const CudaMatrix4x4<FloatT>& intrinsics,
    const CudaMatrix3x4<FloatT>& extrinsics,
    const FloatT x,
    const FloatT y) {
  CudaRay<FloatT> ray;
  ray.origin = extrinsics.col(3);
  CudaVector3<FloatT> direction_camera = getCameraRay(intrinsics, x, y);
  CudaMatrix3x3<FloatT> rotation = extrinsics.template block<0, 0, 3, 3>();
  ray.direction = rotation * direction_camera;
  return ray;
}

template <typename FloatT>
__global__ void raycastIterativeCudaKernel(
    const CudaMatrix4x4<FloatT> intrinsics,
    const CudaMatrix3x4<FloatT> extrinsics,
    typename CudaTree<FloatT>::CudaRayType* d_rays,
    const std::size_t num_of_rays,
    const std::size_t x_start, const std::size_t x_end,
    const std::size_t y_start, const std::size_t y_end,
    const FloatT min_range,
    const FloatT max_range,
    typename CudaTree<FloatT>::NodeType* d_root,
    typename CudaTree<FloatT>::CudaIntersectionIterativeStackEntry* stacks,
    const std::size_t max_stack_size,
    bool* d_success,
    typename CudaTree<FloatT>::CudaIntersectionResult* d_results) {
  *d_success = true;
  const std::size_t index = blockIdx.x * blockDim.x + threadIdx.x;
  const std::size_t yi = index / (x_end - x_start);
  const std::size_t xi = index % (x_end - x_start);
//  const std::size_t yi = blockIdx.x;
//  const std::size_t xi = threadIdx.x;
  const FloatT yf = y_start + yi;
  const FloatT xf = x_start + xi;
  if (xi < (x_end - x_start) && yi < (y_end - y_start)) {
    typename CudaTree<FloatT>::CudaRayType& ray = d_rays[index];
    ray = getCameraRay(intrinsics, extrinsics, xf, yf);
    typename CudaTree<FloatT>::CudaIntersectionResult& result = d_results[index];
    result.dist_sq = max_range > 0 ? max_range * max_range : FLT_MAX;
    result.node = nullptr;
  //  printf("Calling intersectsRecursiveCuda\n");
    typename CudaTree<FloatT>::CudaIntersectionIterativeStackEntry* stack = &stacks[index * max_stack_size];
    stack[0].depth = 0;
    stack[0].node = d_root;
    const std::size_t stack_size = 1;
//    for (std::size_t i = 0; i < max_stack_size; ++i) {
//      stack[i].state = CudaTree<FloatT>::CudaIntersectionIterativeStackEntry::NotVisited;
//    }
    const bool thread_success = intersectsIterativeCuda<FloatT>(ray, min_range, max_range, stack, stack_size, max_stack_size, &result);
    if (!thread_success) {
      *d_success = thread_success;
    }
    assert(thread_success);
  }
}

template <typename FloatT>
__global__ void raycastWithScreenCoordinatesIterativeCudaKernel(
        const CudaMatrix4x4<FloatT> intrinsics,
        const CudaMatrix3x4<FloatT> extrinsics,
        typename CudaTree<FloatT>::CudaRayType* d_rays,
        const std::size_t num_of_rays,
        const std::size_t x_start, const std::size_t x_end,
        const std::size_t y_start, const std::size_t y_end,
        const FloatT min_range,
        const FloatT max_range,
        typename CudaTree<FloatT>::NodeType* d_root,
        typename CudaTree<FloatT>::CudaIntersectionIterativeStackEntry* stacks,
        const std::size_t max_stack_size,
        bool* d_success,
        typename CudaTree<FloatT>::CudaIntersectionResultWithScreenCoordinates* d_results_with_screen_coordinates) {
  *d_success = true;
  const std::size_t index = blockIdx.x * blockDim.x + threadIdx.x;
  const std::size_t yi = index / (x_end - x_start);
  const std::size_t xi = index % (x_end - x_start);
//  const std::size_t yi = blockIdx.x;
//  const std::size_t xi = threadIdx.x;
  const FloatT yf = y_start + yi;
  const FloatT xf = x_start + xi;
  if (xi < (x_end - x_start) && yi < (y_end - y_start)) {
    typename CudaTree<FloatT>::CudaRayType& ray = d_rays[index];
    ray = getCameraRay(intrinsics, extrinsics, xf, yf);
    typename CudaTree<FloatT>::CudaIntersectionResultWithScreenCoordinates& result = d_results_with_screen_coordinates[index];
    result.intersection_result.dist_sq = max_range > 0 ? max_range * max_range : FLT_MAX;
    result.intersection_result.node = nullptr;
    //  printf("Calling intersectsRecursiveCuda\n");
    typename CudaTree<FloatT>::CudaIntersectionIterativeStackEntry* stack = &stacks[index * max_stack_size];
    stack[0].depth = 0;
    stack[0].node = d_root;
    const std::size_t stack_size = 1;
//    for (std::size_t i = 0; i < max_stack_size; ++i) {
//      stack[i].state = CudaTree<FloatT>::CudaIntersectionIterativeStackEntry::NotVisited;
//    }
    result.screen_coordinates(0) = xf;
    result.screen_coordinates(1) = yf;
    const bool thread_success = intersectsIterativeCuda<FloatT>(ray, min_range, max_range, stack, stack_size, max_stack_size, &result.intersection_result);
    printf("index=%d, success=%d\n", index, thread_success);
    if (!thread_success) {
      *d_success = thread_success;
    }
    assert(thread_success);
  }
}

#if WITH_CUDA_RECURSION
template <typename FloatT>
__global__ void raycastRecursiveCudaKernel(
    const CudaMatrix4x4<FloatT> intrinsics,
    const CudaMatrix3x4<FloatT> extrinsics,
    typename CudaTree<FloatT>::CudaRayType* d_rays,
    const std::size_t num_of_rays,
    const std::size_t x_start, const std::size_t x_end,
    const std::size_t y_start, const std::size_t y_end,
    const FloatT min_range,
    const FloatT max_range,
    typename CudaTree<FloatT>::NodeType* d_root,
    typename CudaTree<FloatT>::CudaIntersectionResult* d_results) {
  const std::size_t index = blockIdx.x * blockDim.x + threadIdx.x;
  const std::size_t yi = index / (x_end - x_start);
  const std::size_t xi = index % (x_end - x_start);
//  const std::size_t yi = blockIdx.x;
//  const std::size_t xi = threadIdx.x;
  const FloatT yf = y_start + yi;
  const FloatT xf = x_start + xi;
  if (xi < (x_end - x_start) && yi < (y_end - y_start)) {
    typename CudaTree<FloatT>::CudaRayType& ray = d_rays[index];
    ray = getCameraRay(intrinsics, extrinsics, xf, yf);
    typename CudaTree<FloatT>::CudaIntersectionData data;
    data.ray.origin = ray.origin;
    data.ray.direction = ray.direction;
    data.ray.inv_direction = ray.direction.cwiseInverse();
    data.min_range_sq = min_range * min_range;
    typename CudaTree<FloatT>::CudaIntersectionResult& result = d_results[index];
    result.dist_sq = max_range > 0 ? max_range * max_range : FLT_MAX;
    result.node = nullptr;
    const std::size_t cur_depth = 0;
  //  printf("Calling intersectsRecursiveCuda\n");
    intersectsRecursiveCuda<FloatT>(data, d_root, cur_depth, &result);
  }
}

template <typename FloatT>
__global__ void raycastWithScreenCoordinatesRecursiveCudaKernel(
    const CudaMatrix4x4<FloatT> intrinsics,
    const CudaMatrix3x4<FloatT> extrinsics,
    typename CudaTree<FloatT>::CudaRayType* d_rays,
    const std::size_t num_of_rays,
    const std::size_t x_start, const std::size_t x_end,
    const std::size_t y_start, const std::size_t y_end,
    const FloatT min_range,
    const FloatT max_range,
    typename CudaTree<FloatT>::NodeType* d_root,
    typename CudaTree<FloatT>::CudaIntersectionResultWithScreenCoordinates* d_results_with_screen_coordinates) {
  const std::size_t index = blockIdx.x * blockDim.x + threadIdx.x;
  const std::size_t yi = index / (x_end - x_start);
  const std::size_t xi = index % (x_end - x_start);
//  const std::size_t yi = blockIdx.x;
//  const std::size_t xi = threadIdx.x;
  const FloatT yf = y_start + yi;
  const FloatT xf = x_start + xi;
  if (xi < (x_end - x_start) && yi < (y_end - y_start)) {
    typename CudaTree<FloatT>::CudaRayType& ray = d_rays[index];
    ray = getCameraRay(intrinsics, extrinsics, xf, yf);
    typename CudaTree<FloatT>::CudaIntersectionData data;
    data.ray.origin = ray.origin;
    data.ray.direction = ray.direction;
    data.ray.inv_direction = ray.direction.cwiseInverse();
    data.min_range_sq = min_range * min_range;
    typename CudaTree<FloatT>::CudaIntersectionResultWithScreenCoordinates& result = d_results_with_screen_coordinates[index];
    result.intersection_result.dist_sq = max_range > 0 ? max_range * max_range : FLT_MAX;
    result.intersection_result.node = nullptr;
    const std::size_t cur_depth = 0;
  //  printf("Calling intersectsRecursiveCuda\n");
    result.screen_coordinates(0) = xf;
    result.screen_coordinates(1) = yf;
    intersectsRecursiveCuda<FloatT>(data, d_root, cur_depth, &result.intersection_result);
  }
}
#endif

#if WITH_CUDA_RECURSION
template <typename FloatT>
std::vector<typename CudaTree<FloatT>::CudaIntersectionResult>
CudaTree<FloatT>::intersectsRecursive(const std::vector<CudaRayType>& rays, FloatT min_range /*= 0*/, FloatT max_range /*= -1*/) {
  if (rays.empty()) {
    return std::vector<CudaIntersectionResult>();
  }
  reserveDeviceRaysAndResults(rays.size());
  bh::CudaUtils::copyArrayToDevice(rays, d_rays_);
  const std::size_t grid_size = (rays.size() + kThreadsPerBlock - 1) / kThreadsPerBlock;
  const std::size_t block_size = std::min(kThreadsPerBlock, rays.size());
  BH_ASSERT(grid_size > 0);
  BH_ASSERT(block_size > 0);
  BH_ASSERT(getRoot() != nullptr);
//  std::cout << "grid_size=" << grid_size << ", block_size=" << block_size << std::endl;
  intersectsRecursiveCudaKernel<FloatT><<<grid_size, block_size>>>(
      d_rays_, rays.size(),
      min_range, max_range,
      getRoot(),
      d_results_);
  CUDA_DEVICE_SYNCHRONIZE();
  CUDA_CHECK_ERROR();
  std::vector<CudaIntersectionResult> cuda_results(rays.size());
  bh::CudaUtils::copyArrayFromDevice(d_results_, &cuda_results);
  return cuda_results;
}
#endif

template <typename FloatT>
std::vector<typename CudaTree<FloatT>::CudaIntersectionResult>
CudaTree<FloatT>::intersectsIterative(const std::vector<CudaRayType>& rays, FloatT min_range /*= 0*/, FloatT max_range /*= -1*/) {
  if (rays.empty()) {
    return std::vector<CudaIntersectionResult>();
  }
  reserveDeviceRaysAndResults(rays.size());
  bh::CudaUtils::copyArrayToDevice(rays, d_rays_);
  bool* d_success = bh::CudaUtils::allocate<bool>();
  const std::size_t grid_size = (rays.size() + kThreadsPerBlock - 1) / kThreadsPerBlock;
  const std::size_t block_size = std::min(kThreadsPerBlock, rays.size());
  BH_ASSERT(grid_size > 0);
  BH_ASSERT(block_size > 0);
  BH_ASSERT(getRoot() != nullptr);
//  std::cout << "grid_size=" << grid_size << ", block_size=" << block_size << std::endl;
  intersectsIterativeCudaKernel<FloatT><<<grid_size, block_size>>>(
      d_rays_, rays.size(),
      min_range, max_range,
      getRoot(),
      d_stacks_,
      2 * (tree_depth_ + 1),
      d_success,
      d_results_);
  CUDA_DEVICE_SYNCHRONIZE();
  CUDA_CHECK_ERROR();
  const bool success = bh::CudaUtils::copyFromDevice(d_success);
  bh::CudaUtils::deallocate(&d_success);
  if (!success) {
    throw bh::Error("Iterative raycast failed. Maximum stack size was exceeded.");
  }
  std::vector<CudaIntersectionResult> cuda_results(rays.size());
  bh::CudaUtils::copyArrayFromDevice(d_results_, &cuda_results);
  return cuda_results;
}

#if WITH_CUDA_RECURSION
template <typename FloatT>
std::vector<typename CudaTree<FloatT>::CudaIntersectionResult>
CudaTree<FloatT>::raycastRecursive(
    const CudaMatrix4x4<FloatT>& intrinsics,
    const CudaMatrix3x4<FloatT>& extrinsics,
    const std::size_t x_start, const std::size_t x_end,
    const std::size_t y_start, const std::size_t y_end,
    FloatT min_range /*= 0*/, FloatT max_range /*= -1*/,
    const bool fail_on_error /*= false*/) {
  const std::size_t num_of_rays = (y_end - y_start) * (x_end - x_start);
  reserveDeviceRaysAndResults(num_of_rays);
  const std::size_t grid_size = y_end - y_start;
  const std::size_t block_size = x_end - x_start;
  BH_ASSERT(grid_size > 0);
  BH_ASSERT(block_size > 0);
  BH_ASSERT(getRoot() != nullptr);
  //  std::cout << "grid_size=" << grid_size << ", block_size=" << block_size << std::endl;
  NodeType* root = getRoot();
  raycastRecursiveCudaKernel<FloatT><<<grid_size, block_size>>>(
      intrinsics, extrinsics,
      d_rays_, num_of_rays,
      x_start, x_end,
      y_start, y_end,
      min_range, max_range,
      root,
      d_results_);
  if (fail_on_error) {
    CUDA_DEVICE_SYNCHRONIZE();
    CUDA_CHECK_ERROR();
  }
  else {
    cudaError err = cudaDeviceSynchronize();
    if (cudaSuccess != err) { \
      fprintf(stderr, "CUDA error in file '%s' in line %i: %s\n",
          __FILE__, __LINE__, cudaGetErrorString(err));
      throw bh::CudaError(err);
    }
  }
  std::vector<CudaIntersectionResult> cuda_results(num_of_rays);
  bh::CudaUtils::copyArrayFromDevice(d_results_, &cuda_results);
  return cuda_results;
}

template <typename FloatT>
std::vector<typename CudaTree<FloatT>::CudaIntersectionResultWithScreenCoordinates>
CudaTree<FloatT>::raycastWithScreenCoordinatesRecursive(
    const CudaMatrix4x4<FloatT>& intrinsics,
    const CudaMatrix3x4<FloatT>& extrinsics,
    const std::size_t x_start, const std::size_t x_end,
    const std::size_t y_start, const std::size_t y_end,
    FloatT min_range /*= 0*/, FloatT max_range /*= -1*/,
    const bool fail_on_error /*= false*/) {
  const std::size_t num_of_rays = (y_end - y_start) * (x_end - x_start);
  reserveDeviceRaysAndResults(num_of_rays);
  const std::size_t grid_size = bh::CudaUtils::computeGridSize(num_of_rays, kThreadsPerBlock);
  const std::size_t block_size = bh::CudaUtils::computeBlockSize(num_of_rays, kThreadsPerBlock);
  BH_ASSERT(grid_size > 0);
  BH_ASSERT(block_size > 0);
  BH_ASSERT(getRoot() != nullptr);
  //  std::cout << "grid_size=" << grid_size << ", block_size=" << block_size << std::endl;
  NodeType* root = getRoot();
  raycastWithScreenCoordinatesRecursiveCudaKernel<FloatT><<<grid_size, block_size>>>(
      intrinsics, extrinsics,
      d_rays_, num_of_rays,
      x_start, x_end,
      y_start, y_end,
      min_range, max_range,
      root,
      d_results_with_screen_coordinates_);
  if (fail_on_error) {
    CUDA_DEVICE_SYNCHRONIZE();
    CUDA_CHECK_ERROR();
  }
  else {
    cudaError err = cudaDeviceSynchronize();
    if (cudaSuccess != err) {
      fprintf(stderr, "CUDA error in file '%s' in line %i: %s\n",
          __FILE__, __LINE__, cudaGetErrorString(err));
      fprintf(stderr, "grid_size=%d, block_size=%d\n", grid_size, block_size);
      for (size_t row = 0; row < intrinsics.Rows; ++row) {
        fprintf(stderr, "intrinsics(%d)=", row);
        for (size_t col = 0; col < intrinsics.Cols; ++col) {
          if (col > 0) {
            fprintf(stderr, ", ");
          }
          fprintf(stderr, "%f", intrinsics(row, col));
        }
        fprintf(stderr, "\n");
      }
      for (size_t row = 0; row < extrinsics.Rows; ++row) {
        fprintf(stderr, "extrinsics(%d)=", row);
        for (size_t col = 0; col < extrinsics.Cols; ++col) {
          if (col > 0) {
            fprintf(stderr, ", ");
          }
          fprintf(stderr, "%f", extrinsics(row, col));
        }
        fprintf(stderr, "\n");
      }
      fprintf(stderr, "x_start=%l, x_end=%l, y_start=%l, y_end=%l\n", x_start, x_end, y_start, y_end);
      fprintf(stderr, "min_range=%f, fail_on_error=%d\n", min_range, fail_on_error);
      throw bh::CudaError(err);
    }
  }
  std::vector<CudaIntersectionResultWithScreenCoordinates> cuda_results(num_of_rays);
  bh::CudaUtils::copyArrayFromDevice(d_results_with_screen_coordinates_, &cuda_results);
  return cuda_results;
}
#endif

template <typename FloatT>
std::vector<typename CudaTree<FloatT>::CudaIntersectionResult>
CudaTree<FloatT>::raycastIterative(
    const CudaMatrix4x4<FloatT>& intrinsics,
    const CudaMatrix3x4<FloatT>& extrinsics,
    const std::size_t x_start, const std::size_t x_end,
    const std::size_t y_start, const std::size_t y_end,
    FloatT min_range /*= 0*/, FloatT max_range /*= -1*/,
    const bool fail_on_error /*= false*/) {
  const std::size_t num_of_rays = (y_end - y_start) * (x_end - x_start);
  reserveDeviceRaysAndResults(num_of_rays);
  const std::size_t grid_size = y_end - y_start;
  const std::size_t block_size = x_end - x_start;
  BH_ASSERT(grid_size > 0);
  BH_ASSERT(block_size > 0);
  BH_ASSERT(getRoot() != nullptr);
  //  std::cout << "grid_size=" << grid_size << ", block_size=" << block_size << std::endl;
  bool* d_success = bh::CudaUtils::allocate<bool>();
  NodeType* root = getRoot();
  raycastIterativeCudaKernel<FloatT><<<grid_size, block_size>>>(
      intrinsics,
      extrinsics,
      d_rays_, num_of_rays,
      x_start, x_end,
      y_start, y_end,
      min_range, max_range,
      root,
      d_stacks_,
      2 * (tree_depth_ + 1),
      d_success,
      d_results_);
  if (fail_on_error) {
    CUDA_DEVICE_SYNCHRONIZE();
    CUDA_CHECK_ERROR();
  }
  else {
    cudaError err = cudaDeviceSynchronize();
    if (cudaSuccess != err) { \
      fprintf(stderr, "CUDA error in file '%s' in line %i: %s\n",
              __FILE__, __LINE__, cudaGetErrorString(err));
      throw bh::CudaError(err);
    }
  }
  const bool success = bh::CudaUtils::copyFromDevice(d_success);
  bh::CudaUtils::deallocate(&d_success);
  if (!success) {
    throw bh::Error("Iterative raycast failed. Maximum stack size was exceeded.");
  }
  std::vector<CudaIntersectionResult> cuda_results(num_of_rays);
  bh::CudaUtils::copyArrayFromDevice(d_results_, &cuda_results);
  return cuda_results;
}

template <typename FloatT>
std::vector<typename CudaTree<FloatT>::CudaIntersectionResultWithScreenCoordinates>
CudaTree<FloatT>::raycastWithScreenCoordinatesIterative(
        const CudaMatrix4x4<FloatT>& intrinsics,
        const CudaMatrix3x4<FloatT>& extrinsics,
        const std::size_t x_start, const std::size_t x_end,
        const std::size_t y_start, const std::size_t y_end,
        FloatT min_range /*= 0*/, FloatT max_range /*= -1*/,
        const bool fail_on_error /*= false*/) {
  const std::size_t num_of_rays = (y_end - y_start) * (x_end - x_start);
  reserveDeviceRaysAndResults(num_of_rays);
  const std::size_t grid_size = y_end - y_start;
  const std::size_t block_size = x_end - x_start;
  BH_ASSERT(grid_size > 0);
  BH_ASSERT(block_size > 0);
  BH_ASSERT(getRoot() != nullptr);
  //  std::cout << "grid_size=" << grid_size << ", block_size=" << block_size << std::endl;
  bool* d_success = bh::CudaUtils::allocate<bool>();
  NodeType* root = getRoot();
  raycastWithScreenCoordinatesIterativeCudaKernel<FloatT><<<grid_size, block_size>>>(
          intrinsics,
          extrinsics,
          d_rays_, num_of_rays,
          x_start, x_end,
          y_start, y_end,
          min_range, max_range,
          root,
          d_stacks_,
          2 * (tree_depth_ + 1),
          d_success,
          d_results_with_screen_coordinates_);
  if (fail_on_error) {
    CUDA_DEVICE_SYNCHRONIZE();
    CUDA_CHECK_ERROR();
  }
  else {
    cudaError err = cudaDeviceSynchronize();
    if (cudaSuccess != err) { \
      fprintf(stderr, "CUDA error in file '%s' in line %i: %s\n",
              __FILE__, __LINE__, cudaGetErrorString(err));
      throw bh::CudaError(err);
    }
  }
  const bool success = bh::CudaUtils::copyFromDevice(d_success);
  bh::CudaUtils::deallocate(&d_success);
  if (!success) {
    throw bh::Error("Iterative raycast failed. Maximum stack size was exceeded.");
  }
  std::vector<CudaIntersectionResultWithScreenCoordinates> cuda_results(num_of_rays);
  bh::CudaUtils::copyArrayFromDevice(d_results_with_screen_coordinates_, &cuda_results);
  return cuda_results;
}

template <typename FloatT>
void CudaTree<FloatT>::reserveDeviceRaysAndResults(const std::size_t num_of_rays) {
  if (num_of_rays > d_rays_size_) {
    if (d_rays_ != nullptr) {
      bh::CudaUtils::deallocate(&d_rays_);
      CUDA_DEVICE_SYNCHRONIZE();
      CUDA_CHECK_ERROR();
    }
    d_rays_ = bh::CudaUtils::template allocate<CudaRayType>(num_of_rays);
    CUDA_DEVICE_SYNCHRONIZE();
    CUDA_CHECK_ERROR();
    d_rays_size_ = num_of_rays;
  }
  if (num_of_rays > d_results_size_) {
    if (d_results_ != nullptr) {
      bh::CudaUtils::deallocate(&d_results_);
      CUDA_DEVICE_SYNCHRONIZE();
      CUDA_CHECK_ERROR();
    }
    d_results_ = bh::CudaUtils::template allocate<CudaIntersectionResult>(num_of_rays);
    d_results_with_screen_coordinates_ = bh::CudaUtils::template allocate<CudaIntersectionResultWithScreenCoordinates>(num_of_rays);
    CUDA_DEVICE_SYNCHRONIZE();
    CUDA_CHECK_ERROR();
    d_results_size_ = num_of_rays;
  }
  if (num_of_rays > d_stacks_size_) {
    if (d_stacks_ != nullptr) {
      bh::CudaUtils::deallocate(&d_stacks_);
    }
    d_stacks_ = bh::CudaUtils::template allocate<CudaIntersectionIterativeStackEntry>(num_of_rays * 2 * (tree_depth_ + 1));
    CUDA_DEVICE_SYNCHRONIZE();
    CUDA_CHECK_ERROR();
    d_stacks_size_ = num_of_rays;
  }
}

template
class CudaTree<float>;

}
