#include <chrono>
#include <iostream>
#include <cassert>
#include <utility>
#include <memory>

#include <cuda.h>
#include <cuda_runtime_api.h>
#include <curand_kernel.h>
#include <iomanip>
#include "cuda_utils.h"

#include "common.h"
#include "ants.h"

#include "gpu_ants.h"
#include "tsp_ls_gpu.h"
#include "gpu_phmem.h"
#include "gpu_acs.h"

#define WARP_SIZE 32
//#define MAX_VISITED_SIZE 256
#define MAX_VISITED_SIZE 473 // Should allow to calc solution for d15112.tsp
                             // instance


__device__ void lock(int *mutex) {
    while( atomicCAS(mutex, 0, 1) != 0 )
        ;
}

__device__ void unlock(int *mutex) {
    atomicExch(mutex, 0); 
}


__device__ int get_global_id() {
    return blockIdx.x * blockDim.x + threadIdx.x;
}


/* Kernel to fill the array with the given value */
template<typename T>
__global__ void fill(T *buffer, uint32_t len, T value) {
    for (auto i = (uint32_t)threadIdx.x; i < len; i += blockDim.x) {
        buffer[i] = value;
    }
}


template<typename Phmem>
__global__ void phmem_init(Phmem phmem, float value) {
    auto num_threads = blockDim.x * gridDim.x;
    for (size_t i = threadIdx.x, n = phmem.size(); i < n; i += num_threads) {
        phmem[i] = value;
    }
}


__global__ void setup_kernel(gpu_rand_state_t *states, uint32_t *seeds) { 
    /* Each thread gets same seed, a different sequence number, no offset */
    int id = threadIdx.x + blockIdx.x * blockDim.x; 
    curand_init(seeds[0], id, 0, &states[id]); 
}


__global__ void setup_kernel(gpu_rand_state_t *states) { 
    /* Each thread gets same seed, a different sequence number, no offset */
    int id = threadIdx.x + blockIdx.x * blockDim.x; 
    curand_init(1234, id, 0, &states[id]); 
}



__global__
void acs_ant_init(gpu_rand_state_t *rnd_states,
                  uint32_t dimension, 
                  uint32_t ants_count,
                  float *ant_values,
                  uint32_t *ant_visited_count, 
                  uint32_t *ant_visited)
{
    const uint32_t ant_id = blockIdx.x * blockDim.x + threadIdx.x;
    if ( ant_id < ants_count ) {
        PRNG rng(&rnd_states[ant_id]);
        const uint32_t node = rng.rand_uint() % dimension;
        //const uint32_t node = ant_id % dimension;
        ant_visited_count[ant_id] = 1;
        uint32_t *visited = ant_visited + ant_id * dimension;
        visited[0] = node;
        ant_values[ant_id] = 0;
    }
}


__device__ bool is_node_visited(volatile const uint32_t *visited, int node) {
    return visited[ node >> 5 ] & (1 << (node & 31));
}


__device__ void set_node_visited(volatile uint32_t *visited, int node) {
    visited[ node >> 5 ] |= 1 << (node & 31);
}


/**
 * This build in parallel a set of complete solutions for the ants as in a
 * single iteration of the ACS.
 */
template<typename PhmemT>
__global__ void
acs_calc_solution(gpu_rand_state_t *rnd_states,
                  const GPU_ACSParams acs_params,
                  uint32_t dimension,
                  PhmemT phmem,
                  const float * __restrict__ heuristic_matrix,
                  const float * __restrict__ dist_matrix,
                  const uint32_t * __restrict__ nn_lists,
                  float *ant_values,
                  uint32_t *ant_visited_count,
                  uint32_t *ant_visited,
                  int pher_mem_update_freq) {

    const uint32_t tid = threadIdx.x;
    const uint32_t ant_id = blockIdx.x;
    const uint32_t num_warps = blockDim.x / WARP_SIZE;
    const bool is_first_in_warp = (tid & (WARP_SIZE-1)) == 0;

    PRNG rng(&rnd_states[ant_id]);

    __shared__ volatile uint32_t cand_set[4];
    __shared__ volatile float know[4];
    __shared__ volatile uint32_t curr_pos[1];
    __shared__ volatile uint32_t next_pos[1];
    __shared__ volatile uint32_t was_visited[MAX_VISITED_SIZE];
    const float initial_pheromone = acs_params.initial_pheromone_;

    uint32_t *route = ant_visited + ant_id * dimension;

    for (uint32_t i = tid; i < MAX_VISITED_SIZE; i += blockDim.x) {
        was_visited[i] = 0;
    }
    __syncthreads();

    const uint32_t first_node = curr_pos[0] = route[0];
    if (tid == 0) {
        set_node_visited(was_visited, first_node);
    }

    for (uint32_t iter = 1; iter < dimension; ++iter) {
        __syncthreads();

        if (tid < WARP_SIZE) {
            const uint32_t curr = curr_pos[0];
            next_pos[0] = dimension;

            const uint32_t *nn = nn_lists + curr * NN_SIZE;
            const uint32_t nn_id = nn[tid];
            const auto nn_unvisited = !is_node_visited(was_visited, nn_id);

            if (__any(nn_unvisited)) {
                const auto k = dimension * curr + nn_id;
                const float nn_know = nn_unvisited 
                    ? heuristic_matrix[k] * phmem.get(k)
                    : 0;
                const float q = rng.rand_uniform();

                if (q < acs_params.q0_) {
                    uint32_t best_nn_id = warp_reduce_arg_max<uint32_t, float, WARP_SIZE>(nn_id, nn_know);
                    if (tid == 0) {
                        next_pos[0] = best_nn_id;
                    }
                } else { // Now select using roulette wheel
                    // Calculate prefix sums in log2(32) steps
                    const float my_sum = warp_scan<float, WARP_SIZE>(nn_know);
                    const float total_sum = warp_bcast(my_sum, WARP_SIZE-1);
                    const float t = rng.rand_uniform() * total_sum;
                    const uint32_t best_idx = min(WARP_SIZE-1, __popc(__ballot(my_sum <= t)));
                    const uint32_t best_nn = warp_bcast(nn_id, best_idx);
                    next_pos[0] = is_node_visited(was_visited, best_nn) ?  dimension : best_nn;
                }
            }
        }

        __syncthreads();

        if (next_pos[0] == dimension) {
            auto offset = dimension * *curr_pos;
            const float *curr_heur = heuristic_matrix + offset;
            float my_max = 0;
            uint32_t my_best_id = dimension;
            for (int i = tid; i < dimension; i += blockDim.x) {
                if ( !is_node_visited(was_visited, i) ) {
                    const float product = curr_heur[i] * phmem.get(i + offset);
                    my_best_id = (my_max < product) ? i : my_best_id; 
                    my_max = max(my_max, product);
                }
            }
            // Now perform warp reduce
            my_best_id = warp_reduce_arg_max_ext<uint32_t, float, WARP_SIZE>(my_best_id, my_max, &my_max);
            // Now first threads in each warp have indices of best warp elements
            if (is_first_in_warp) {
                know[ tid / WARP_SIZE ] = my_max;
                cand_set[ tid / WARP_SIZE ] = my_best_id;
            }
            // Now know[0..4] have max total values
            // and cand_set[0..4] respective indices of the max nodes
            __syncthreads();
            if (tid < num_warps) {
                my_max = know[tid];
                my_best_id = cand_set[tid];
                my_best_id = warp_reduce_arg_max<uint32_t, float, 4>(my_best_id, my_max);
                if (tid == 0) {
                    next_pos[0] = my_best_id;
                }
            }
        }

        if (tid == 0) { // Main thread only
            // move ant to the next node
            const uint32_t next_node = next_pos[0];
            set_node_visited(was_visited, next_node);
            route[iter] = next_node;

            const uint32_t v = route[iter-1];
            const uint32_t u = next_node;

            if (iter % pher_mem_update_freq == 0) {
                phmem.update(u, v, acs_params.phi_, initial_pheromone);
            }
            curr_pos[0] = next_node;
        }
    }
    // Local update on the closing edge
    if (dimension % pher_mem_update_freq == 0) {
        phmem.update(route[dimension - 1], route[0],
                     acs_params.phi_, initial_pheromone);
    }

    // Parallel calculation of the route length
    float my_sum = 0;
    for (uint32_t i = tid; i < dimension; i += blockDim.x) {
        my_sum += dist_matrix[route[i] * dimension + route[(i + 1) % dimension] ];
    }
    // Now perform warp level reduce
    my_sum = warp_reduce<float, WARP_SIZE>(my_sum);
    if (is_first_in_warp) {
        know[ tid / WARP_SIZE ] = my_sum;
    }
    __syncthreads();

    if (tid == 0) { // only main thread
        float total = 0;
        for (uint32_t i = 0; i < num_warps; ++i) {
            total += know[i];
        }
        ant_values[ant_id] = total; // Route len
        ant_visited_count[ant_id] = dimension;
    }
}


__global__ void
acs_spm_calc_solution(gpu_rand_state_t *rnd_states,
                   const GPU_ACSParams acs_params,
                   uint32_t dimension,
                   SelectivePhmem memory,
                   const float * __restrict__ heuristic_matrix,
                   const float * __restrict__ dist_matrix,
                   const uint32_t * __restrict__ nn_lists,
                   float *ant_values,
                   uint32_t *ant_visited_count, 
                   uint32_t *ant_visited,
                   const int pher_mem_update_freq) {

    const uint32_t ant_id = blockIdx.x;

    PRNG rng(&rnd_states[ant_id]);

    const uint32_t num_warps = blockDim.x / WARP_SIZE;
    const uint32_t tid = threadIdx.x;
    __shared__ volatile uint32_t cand_set[4];
    __shared__ volatile float know[4];
    __shared__ volatile uint32_t curr_pos[1];
    __shared__ volatile uint32_t next_pos[1];
    __shared__ volatile uint32_t was_visited[MAX_VISITED_SIZE];

    #define WAS_VISITED(node) (was_visited[ node >> 5 ] & (1 << (node & 31)))

    uint32_t *route = ant_visited + ant_id * dimension;

    for (uint32_t i = threadIdx.x; i < MAX_VISITED_SIZE; i += blockDim.x) {
        was_visited[i] = 0;
    }
    __syncthreads();

    const uint32_t first_node = curr_pos[0] = route[0];
    if (tid == 0) {
        was_visited[ first_node >> 5 ] |= 1 << (first_node & 31);
    }
    const float initial_pheromone = memory.default_pheromone();

    for (uint32_t iter = 1; iter < dimension; ++iter) {
        __syncthreads();

        if (threadIdx.x < WARP_SIZE) {
            const uint32_t curr = curr_pos[0];
            next_pos[0] = dimension;

            const uint32_t *nn = nn_lists + curr * NN_SIZE;
            const uint32_t nn_id = nn[threadIdx.x];
            const uint32_t is_nn_unvisited = !WAS_VISITED(nn_id);

            if (__any(is_nn_unvisited)) {
                const float q = rng.rand_uniform();
                const float *heuristic_ptr = heuristic_matrix + dimension * curr;

                if (q < acs_params.q0_) {
                    auto *node_ids = memory.get_indices(curr);
                    auto *trails = memory.get_pheromone(curr);
                    float my_product = 0;
                    uint32_t my_node;
                    if (tid < memory.capacity()) {
                        my_node = node_ids[tid];
                        if (my_node < dimension && !WAS_VISITED(my_node)) {
                            my_product = trails[tid] * heuristic_ptr[my_node];
                        }
                    }
                    float max_product;
                    uint32_t best_node = warp_reduce_arg_max_ext<uint32_t, float, WARP_SIZE>(
                            my_node, my_product, &max_product);

                    uint32_t first_unvisited_idx = __ffs( __ballot(is_nn_unvisited) ) - 1;
                    uint32_t closest_unvisited_nn = warp_bcast(nn_id, first_unvisited_idx);
                    float nn_product = initial_pheromone * heuristic_ptr[closest_unvisited_nn];
                    
                    if (tid == 0) {
                        assert(nn_product > 0 || max_product > 0);
                        uint32_t t = next_pos[0] = (nn_product > max_product) ? closest_unvisited_nn : best_node;
                        assert(!WAS_VISITED(t));
                    }
                } else { // Now select using roulette wheel
                    // Calculate prefix sums in log2(32) steps
                    float nn_know = WAS_VISITED(nn_id) ? 0 : heuristic_ptr[nn_id] * memory.get(curr, nn_id);
                    float my_sum = warp_scan<float, WARP_SIZE>(nn_know);
                    const float all_sum = warp_bcast(my_sum, WARP_SIZE-1);
                    const float r = rng.rand_uniform() * all_sum;
                    const uint32_t best_idx = min(WARP_SIZE-1, __popc(__ballot(my_sum <= r)));
                    const uint32_t best_nn = warp_bcast(nn_id, best_idx);
                    const uint32_t is_best_nn_unvisited = !WAS_VISITED(best_nn);
                    next_pos[0] = is_best_nn_unvisited ? best_nn : dimension;
                }
            }
        }

        __syncthreads();

        if (next_pos[0] == dimension) {
            const uint32_t curr = curr_pos[0];
            const float *heuristic_ptr = heuristic_matrix + dimension * curr;
            float my_product = 0;
            uint32_t my_node;

            for (int i = threadIdx.x; i < dimension; i += blockDim.x) {
                const float node_total = (!WAS_VISITED(i)) * heuristic_ptr[i];
                my_node = (my_product < node_total) ? i : my_node; 
                my_product = max(my_product, node_total);
            }
            my_product *= initial_pheromone;

            // Only these nodes have non-initial pheromone level
            if (tid < memory.capacity()) {
                auto *node_ids = memory.get_indices(curr);
                auto *trails = memory.get_pheromone(curr);
                auto node = node_ids[tid];
                if (node < dimension && !WAS_VISITED(node)) {
                    float product = trails[tid] * heuristic_ptr[node];
                    my_node = (my_product < product) ? node : my_node;
                    my_product = max(my_product, product);
                }
            }
            // Now perform warp reduce
            my_node = warp_reduce_arg_max_ext<uint32_t, float, WARP_SIZE>(my_node, my_product, &my_product);
            
            // Now first threads in each warp have indices of best warp elements
            if ( (tid & (WARP_SIZE-1)) == 0 ) {
                know[ threadIdx.x / WARP_SIZE ] = my_product;
                cand_set[ threadIdx.x / WARP_SIZE ] = my_node;
            }
            // Now know[0..4] have max total values
            // and cand_set[0..4] respective indices of the max nodes
            __syncthreads();
            
            if (tid < num_warps) {
                my_product = know[tid];
                my_node = cand_set[tid];
                my_node = warp_reduce_arg_max<uint32_t, float, 4>(my_node, my_product);
                if (tid == 0) {
                    next_pos[0] = my_node;
                }
            }
        }

        if (tid < WARP_SIZE) { // Main thread only
            // move ant to the next node
            const uint32_t next_node = next_pos[0];
            route[iter] = next_node;
            was_visited[ next_node >> 5 ] |= 1 << (next_node & 31);

            curr_pos[0] = next_node;
            
            const uint32_t v = route[iter-1];
            const uint32_t u = next_node;

            if (iter % pher_mem_update_freq == 0) {
                memory.unsafe_warp_update(u, v, acs_params.phi_, initial_pheromone);
            }
        }
    }
    // Parallel calculation of the route length
    float my_sum = 0;
    for (uint32_t i = tid; i < dimension; i += blockDim.x) {
        my_sum += dist_matrix[route[i] * dimension + route[(i + 1) % dimension] ];
    }
    // Now perform warp level reduce
    my_sum = warp_reduce<float, WARP_SIZE>(my_sum);

    if ( (tid & (WARP_SIZE-1)) == 0 ) {
        know[ threadIdx.x / WARP_SIZE ] = my_sum;
    }
    __syncthreads();

    if (tid == 0) { // only main thread
        float total = 0;
        for (uint32_t i = 0; i < num_warps; ++i) {
            total += know[i];
        }
        ant_values[ant_id] = total; // Route len
        ant_visited_count[ant_id] = dimension;
    }
}


/**
  Instead of building a whole solution this version appends only a single
  node to the current partial solution.
 */
template<typename PhmemT>
__global__ void 
acs_select_next_node( gpu_rand_state_t *rnd_states, 
                      const GPU_ACSParams acs_params,
                      uint32_t dimension,
                      PhmemT phmem,
                      const float * __restrict__ heuristic_matrix,
                      const float * __restrict__ dist_matrix,
                      const uint32_t * __restrict__ nn_lists,
                      float *ant_values,
                      uint32_t *ants_visited_count, 
                      uint32_t *ants_solutions,
                      int8_t *ants_marked_nodes,
                      int pher_mem_update_freq,
                      uint32_t *stats ) {

    const uint32_t tid = threadIdx.x;
    const uint32_t ant_id = blockIdx.x;
    const uint32_t num_warps = blockDim.x / WARP_SIZE;
    const bool is_first_in_warp = (tid & (WARP_SIZE-1)) == 0;

    PRNG rng(&rnd_states[ant_id]);

    __shared__ volatile uint32_t cand_set[4];
    __shared__ volatile float know[4];
    __shared__ volatile uint32_t curr_pos[1];
    __shared__ volatile uint32_t next_pos[1];

    auto *route = ants_solutions + ant_id * dimension;
    int8_t *was_visited = ants_marked_nodes + ant_id * dimension;
    auto *visited_count = ants_visited_count + ant_id;
    auto route_len = *visited_count;

    assert( route_len > 0 && route_len < dimension );

    auto pos = curr_pos[0] = route[ route_len - 1 ];
    assert( *curr_pos < dimension );

    was_visited[pos] = 1;

    __syncthreads();

    const uint32_t curr = pos;

    if (tid < WARP_SIZE) {
        *next_pos = dimension;

        const uint32_t *nn = nn_lists + curr * NN_SIZE;
        const uint32_t nn_id = nn[tid];
        const auto nn_unvisited = !was_visited[nn_id];

        if (__any(nn_unvisited)) {
            const auto k = dimension * curr + nn_id;
            const float nn_know = nn_unvisited 
                ? heuristic_matrix[k] * phmem.get(k)
                : 0;
            const float q = rng.rand_uniform();

            if (q < acs_params.q0_) {
                uint32_t best_nn_id = warp_reduce_arg_max<uint32_t, float, WARP_SIZE>(nn_id, nn_know);
                if (tid == 0) {
                    *next_pos = best_nn_id;
                }
            } else { // Now select using roulette wheel
                // Calculate prefix sums in log2(32) steps
                const float my_sum = warp_scan<float, WARP_SIZE>(nn_know);
                const float total_sum = warp_bcast(my_sum, WARP_SIZE-1);
                const float t = rng.rand_uniform() * total_sum;
                const uint32_t best_idx = min(WARP_SIZE-1, __popc(__ballot(my_sum <= t)));
                const uint32_t best_nn = warp_bcast(nn_id, best_idx);
                *next_pos = was_visited[best_nn] ?  dimension : best_nn;
            }
        }
    }

    __syncthreads();

    if ( *next_pos == dimension ) { // if all nearest neighbours were visited
        auto offset = dimension * curr;
        const float *curr_heur = heuristic_matrix + offset;
        float my_max = 0;
        uint32_t my_best_id = dimension;
        for (int i = tid; i < dimension; i += blockDim.x) {
            const float product = was_visited[i] 
                ? 0
                : curr_heur[i] * phmem.get(i + offset);
            my_best_id = (my_max < product) ? i : my_best_id; 
            my_max = max(my_max, product);
        }
        // Now perform warp reduce
        my_best_id = warp_reduce_arg_max_ext<uint32_t, float, WARP_SIZE>(my_best_id, my_max, &my_max);

        // Now first threads in each warp have indices of best warp elements
        if (is_first_in_warp) {
            know[ tid / WARP_SIZE ] = my_max;
            cand_set[ tid / WARP_SIZE ] = my_best_id;
        }
        // Now know[0..4] have max total values
        // and cand_set[0..4] respective indices of the max nodes
        __syncthreads();

        if (tid < num_warps) {
            my_max = know[tid];
            my_best_id = cand_set[tid];
            my_best_id = warp_reduce_arg_max<uint32_t, float, 4>(my_best_id, my_max);
            if (tid == 0) {
                *next_pos = my_best_id;
                assert( my_best_id != dimension );
                if (stats != nullptr) {
                    atomicInc( &stats[0], 1000000000 );
                }
            }
        }
    }

    if (tid == 0) { // Main thread only
        // move ant to the next node
        const uint32_t next_node = *next_pos;
        was_visited[next_node] = 1;
        route[route_len] = next_node;
        *visited_count = ++route_len;

        // Local pheromone update        
        phmem.update( pos, next_node, acs_params.phi_,
                      acs_params.initial_pheromone_ );

         if ( route_len == dimension ) {
            // Pheromone update for the closing edge, i.e. connecting the last
            // and the first nodes
            phmem.update( next_node, route[0], acs_params.phi_,
                          acs_params.initial_pheromone_ );
        }
    }
}


__global__
void eval_ants_solutions( uint32_t dimension,
                          const float *dist_matrix,
                          float *ant_values,
                          uint32_t *ants_visited_count, 
                          uint32_t *ants_solutions ) {

    assert( blockDim.x == WARP_SIZE );

    const uint32_t tid = threadIdx.x;
    const uint32_t ant_id = blockIdx.x;

    auto *route = ants_solutions + ant_id * dimension;
    auto *visited_count = ants_visited_count + ant_id;
    auto route_len = *visited_count;

    assert( route_len == dimension );
    assert( blockDim.x <= WARP_SIZE ); // Assuming a single warp

    // Parallel calculation of the route length
    float my_sum = 0;
    for (uint32_t i = tid; i < route_len; i += blockDim.x) {
        my_sum += dist_matrix[route[i] * dimension + route[(i + 1) % dimension] ];
    }
    // Now perform warp level reduce
    my_sum = warp_reduce<float, WARP_SIZE>(my_sum);

    if (tid == 0) { // only main thread
        ant_values[ant_id] = my_sum;
    }
}


template<typename PhmemT>
__device__ 
void global_pheromone_update(
                   uint32_t dimension, 
                   float rho,
                   PhmemT phmem,
                   float *best_value,
                   uint32_t *best_route)
{
    const float delta = 1.0f / *best_value;
    for (uint32_t i = 0; i < dimension; i++) {
        const uint32_t u = best_route[i];
        const uint32_t v = best_route[ (i + 1) % dimension ];
        phmem.update(u, v, rho, delta);
    }
}



__global__ 
void acs_global_pheromone_update(
                   uint32_t dimension, 
                   float rho,
                   float *pheromone_matrix,
                   float *best_value,
                   uint32_t *best_route)
{
    const float delta = 1.0f / *best_value;
    const uint32_t num_threads = blockDim.x * gridDim.x;
    for (uint32_t i = threadIdx.x; i < dimension; i += num_threads) {
        const uint32_t u = best_route[i];
        const uint32_t v = best_route[ (i + 1) % dimension ];

        const float val = (1 - rho) * pheromone_matrix[u * dimension + v] 
                        + rho * delta;
        pheromone_matrix[u * dimension + v] = val;
        pheromone_matrix[v * dimension + u] = val;
    }
}


template<typename Phmem>
__global__ 
void acs_global_pheromone_update(
                   uint32_t dimension, 
                   float rho,
                   Phmem phmem,
                   float *best_value,
                   uint32_t *best_route)
{
    const float delta = 1.0f / *best_value;
    const uint32_t num_threads = blockDim.x * gridDim.x;
    for (uint32_t i = threadIdx.x; i < dimension; i += num_threads) {
        const uint32_t u = best_route[i];
        const uint32_t v = best_route[ (i + 1) % dimension ];

        phmem.update_lockfree(u, v, rho, delta);
    }
}




__global__ 
void acs_global_pheromone_update(
                   uint32_t dimension, 
                   float rho,
                   SelectivePhmem memory,
                   float *best_value,
                   uint32_t *best_route)
{
    const float delta = 1.0f / *best_value;
    // One element per block
    for (uint32_t i = blockIdx.x; i < dimension; i += gridDim.x) {
        const uint32_t u = best_route[i];
        const uint32_t v = best_route[ (i + 1) % dimension ];
        assert( u < dimension && v < dimension );

        //memory->warp_update(u, v, rho, delta);
        memory.unsafe_warp_update(u, v, rho, delta);
    }
}





struct DeviceTSPData {
    uint32_t dimension_; 
    DeviceVector<float> heuristic_matrix_;
    DeviceVector<float> dist_matrix_;
    DeviceVector<uint32_t> nn_lists_;

    DeviceTSPData(TSPData &data) 
        : dimension_(data.nn_lists_.size()),
          heuristic_matrix_(data.heuristic_matrix_),
          dist_matrix_(data.dist_matrix_),
          nn_lists_(data.nn_lists_)
    {
    }
};


/**
  This (abstract) class is responsible for initializing and managing the GPU
  context necessary for the ACS execution. Its methods also start kernels
  corresponding to elements of the ACS.
 */
class BaseGPUACS {
public:

    struct RunContext {
        std::vector<float> ant_values_;
        DeviceVector<float> dev_ant_values_;

        std::vector<uint32_t> ant_visited_count_;
        DeviceVector<uint32_t> dev_ant_visited_count_;

        std::vector<uint32_t> ant_routes_;
        DeviceVector<uint32_t> dev_ant_routes_;

        std::vector<float> best_value_;
        DeviceVector<float> dev_best_value_;

        std::vector<uint32_t> best_route_;
        DeviceVector<uint32_t> dev_best_route_;

        std::vector<int> route_node_indices_;
        DeviceVector<int> dev_route_node_indices_;

        DeviceVector<gpu_rand_state_t> dev_prng_states_;

        int pher_mem_update_freq_ = 1;
        uint32_t threads_per_block_ = WARP_SIZE;

        RunContext(uint32_t dimension, int ants_count, std::mt19937 &rng) 
            : ant_values_(ants_count),
              dev_ant_values_(ants_count),

              ant_visited_count_(ants_count, 0),
              dev_ant_visited_count_(ants_count),

              ant_routes_(ants_count * dimension, 0),
              dev_ant_routes_( ants_count * dimension ),

              best_value_(1, std::numeric_limits<float>::max()),
              dev_best_value_(best_value_),

              best_route_(dimension),
              dev_best_route_(best_route_),

              route_node_indices_(dimension * ants_count),
              dev_route_node_indices_(route_node_indices_),

              dev_prng_states_( std::max(32, ants_count) )
        {
            init_pseudo_random_number_generator( rng );
        }


        void init_pseudo_random_number_generator( std::mt19937 &rng ) {
            std::vector<uint32_t> seeds( dev_prng_states_.size() );
            std::uniform_int_distribution<> random(0, std::numeric_limits<int>::max());
            for (auto &e : seeds) {
                e = (uint32_t)random( rng );
            }
            DeviceVector<uint32_t> dev_seeds( seeds );
            setup_kernel<<<dev_prng_states_.size(), 1>>>(dev_prng_states_.data(),
                                                         dev_seeds.data());
        }
    };

public:
    BaseGPUACS(TSPData &problem,
               std::mt19937 &rng,
               ACSParams &params
               )
        : problem_(problem),
          rng_(rng),
          acs_params_(params) 
    {
    }

    virtual ~BaseGPUACS() {}

    virtual std::map<std::string, pj> run( int pher_mem_update_freq,
                                           StopCondition *stop_cond,
                                           uint32_t threads_per_block );

    virtual void init_pheromone() = 0;

    virtual void build_ant_solutions() = 0;

    virtual void local_search();

    virtual void local_pheromone_update() = 0;

    virtual void global_pheromone_update() = 0;

    virtual void init_run_context();

    /* Useful for performing tasks just before the run() method finishes */
    virtual void on_run_finish() {}

protected:

    template<typename T>
    void record( const std::string &label, const T &value ) {
        record_[ label ] = pj( value );
    }

    TSPData problem_;
    std::mt19937 &rng_;
    ACSParams acs_params_;
    std::shared_ptr<DeviceTSPData> dev_problem_ = nullptr;
    std::shared_ptr<RunContext> run_ctx_ = nullptr;
    std::map<std::string, pj> record_; // for reporting / evaluating algorithm
                                       // execution
};



void BaseGPUACS::init_run_context() {

    std::cout << "Initializing context..." << std::endl;

    const int ants_count = acs_params_.ants_count_;
    const uint32_t dimension = problem_.nn_lists_.size();

    run_ctx_.reset( new RunContext(dimension, ants_count, rng_) );

    std::cout << "...context initialized." << std::endl;
}


/*
   threads_per_block - how many threads per block should be used when building
                       ants solutions. The number of blocks is equal to the
                       number of ants.
*/
std::map<std::string, pj>
BaseGPUACS::run( int pher_mem_update_freq,
                 StopCondition *stop_cond,
                 uint32_t threads_per_block ) {
    using namespace std;

    // Lazy initialization of problem data
    if (dev_problem_ == nullptr) {
        dev_problem_ = make_shared<DeviceTSPData>(problem_);

        std::cout << dev_problem_->dimension_ << std::endl
                  << dev_problem_->heuristic_matrix_.size() << std::endl; 
    }

    init_run_context();

    run_ctx_->pher_mem_update_freq_ = pher_mem_update_freq;
    run_ctx_->threads_per_block_ = threads_per_block;

    const int ants_count = acs_params_.ants_count_;
    const uint32_t dimension = problem_.nn_lists_.size();

    vector<uint32_t> temp_route(dimension);

    GPUIntervalTimer sol_timer;
    GPUIntervalTimer ls_timer;
    GPUIntervalTimer global_update_timer;
    IntervalTimer move_timer;
    IntervalTimer total_timer;
    total_timer.start_interval();

    bool validate_routes = false;

    GPU_ACSParams gpu_acs_params;
    gpu_acs_params = acs_params_;

    std::cout << "Initializing pheromone memory..." << std::flush;
    init_pheromone();
    std::cout << "memory initialized" << std::endl;

    uint32_t best_found_iteration = 0;

    for (stop_cond->init(); !stop_cond->is_reached();
         stop_cond->next_iteration()) {

        acs_ant_init<<<ants_count, 32>>>(
                run_ctx_->dev_prng_states_.data(),
                dimension,
                ants_count,
                run_ctx_->dev_ant_values_.data(),
                run_ctx_->dev_ant_visited_count_.data(),
                run_ctx_->dev_ant_routes_.data()
                );

        move_timer.start_interval();
        sol_timer.start_interval();

        build_ant_solutions();

        sol_timer.stop_interval();

        if (acs_params_.use_local_search_) {
            ls_timer.start_interval();
            local_search();
            ls_timer.stop_interval();
        }

        move_timer.stop_interval();

        // Check if better global solution was found
        run_ctx_->dev_ant_values_.copyTo(run_ctx_->ant_values_);

        if (validate_routes) {
            run_ctx_->dev_ant_routes_.copyTo(run_ctx_->ant_routes_);
        }

        uint32_t best_index = 0;
        for (uint32_t i = 0; i < ants_count; ++i) {
            if (run_ctx_->ant_values_[i] < run_ctx_->ant_values_[best_index]) {
                best_index = i;
            }
            if (validate_routes) {
                temp_route.resize(dimension);
                copy(run_ctx_->ant_routes_.begin() + i * dimension,
                     run_ctx_->ant_routes_.begin() + (i+1) * dimension,
                     temp_route.begin());

                if (!is_valid_route(temp_route, dimension)) {
                    cout << "Invalid route: " << i << endl;
                    cout << temp_route << endl;
                    exit(1);
                }
            }
        }
        if (run_ctx_->ant_values_[best_index] < run_ctx_->best_value_[0]) {

            run_ctx_->best_value_[0] = run_ctx_->ant_values_[best_index]; 

            //cout << "New global best found: " << global_best_value << endl;

            run_ctx_->dev_ant_routes_.copyTo(run_ctx_->ant_routes_);
            copy(run_ctx_->ant_routes_.begin() + best_index * dimension,
                 run_ctx_->ant_routes_.begin() + (best_index+1) * dimension,
                 run_ctx_->best_route_.begin());

            assert(is_valid_route(run_ctx_->best_route_, dimension));

            run_ctx_->dev_best_route_.copyFrom(run_ctx_->best_route_);
            run_ctx_->dev_best_value_.copyFrom(run_ctx_->best_value_);

            best_found_iteration = stop_cond->get_iteration();
        }

        global_update_timer.start_interval();

        global_pheromone_update();

        global_update_timer.stop_interval();
    }
    
    std::cout << "Final solution: " << run_ctx_->best_value_[0] << endl
              << "Sol. construction time: " << move_timer.get_total_time() << " sec" << std::endl;

    total_timer.stop_interval();
    auto total_calc_time = total_timer.get_total_time();
    auto iterations = stop_cond->get_iteration();
    auto iter_time = total_calc_time / iterations;
    auto total_sol_time = sol_timer.get_total_time_ms();
    auto sol_calc_time = total_sol_time / iterations;

    std::cout << "GPU Calc. time: " << total_calc_time << " sec" << std::endl
              << "GPU iteration time [s]: " << iter_time << std::endl
              << "GPU sol. construction time [ms]: " << sol_calc_time << std::endl;

    record( "iterations_made", (int64_t)stop_cond->get_iteration() );
    record( "best_value", run_ctx_->best_value_[0] );
    record( "best_solution", sequence_to_string(run_ctx_->best_route_.begin(),
                                                  run_ctx_->best_route_.end()) );
    record( "best_found_iteration", pj( (int64_t)best_found_iteration ) );
    record( "sol_calc_time_msec", sol_calc_time );
    record( "total_sol_calc_time", total_calc_time );
    record( "iteration_time", iter_time );
    record( "total_local_search_time", ls_timer.get_total_time() );
    record( "global_update_time_ms", global_update_timer.get_total_time_ms() / iterations );

    on_run_finish(); // Additional tasks

    return record_;
}


void BaseGPUACS::local_search() {
    opt2<<<acs_params_.ants_count_, 32>>>(
            dev_problem_->dist_matrix_.data(),
            dev_problem_->dimension_,
            run_ctx_->dev_ant_routes_.data(),
            run_ctx_->dev_ant_values_.data(),
            dev_problem_->dimension_,
            dev_problem_->nn_lists_.data(),
            run_ctx_->dev_route_node_indices_.data()
            );
}



template<typename TPhmem>
class GPUACS : public BaseGPUACS {
public:

    GPUACS( TSPData &problem,
                    std::mt19937 &rng,
                    ACSParams &params )
        : BaseGPUACS(problem, rng, params),
          dev_nn_hot_cache_( problem_.dimension_ )
    {}


    virtual void init_pheromone();
    virtual void build_ant_solutions();
    virtual void local_pheromone_update();
    virtual void global_pheromone_update();

protected:

    std::shared_ptr<TPhmem> phmem_;
    DeviceVector<uint32_t> dev_nn_hot_cache_;
};


template<typename TPhmem>
void GPUACS<TPhmem>::init_pheromone() {
    phmem_.reset( new TPhmem( dev_problem_->dimension_ ) );
    // Initialize using GPU
    phmem_init<<<1, 128>>>( *phmem_, (float)acs_params_.initial_pheromone_ );
}



template<typename TPhmem>
void GPUACS<TPhmem>::build_ant_solutions() {

    GPU_ACSParams gpu_acs_params;
    gpu_acs_params = acs_params_;

    fill<<< 1, 128 >>>(dev_nn_hot_cache_.data(), dev_problem_->dimension_, dev_problem_->dimension_);

    acs_calc_solution<<< acs_params_.ants_count_, run_ctx_->threads_per_block_ >>>(
            run_ctx_->dev_prng_states_.data(),
            gpu_acs_params,
            dev_problem_->dimension_,
            *phmem_,
            //d_phmem_cells,
            dev_problem_->heuristic_matrix_.data(),
            dev_problem_->dist_matrix_.data(),
            dev_problem_->nn_lists_.data(),
            run_ctx_->dev_ant_values_.data(),
            run_ctx_->dev_ant_visited_count_.data(),
            run_ctx_->dev_ant_routes_.data(),
            //dev_nn_hot_cache_.data(),
            run_ctx_->pher_mem_update_freq_
            );
}


template<typename TPhmem>
void GPUACS<TPhmem>::local_pheromone_update() {
    // Empty -- all update is performed inside solution calc. kernel
}


template<typename TPhmem>
void GPUACS<TPhmem>::global_pheromone_update() {
    acs_global_pheromone_update<<<1,128>>>(
            dev_problem_->dimension_,
            acs_params_.rho_,
            *phmem_,
            run_ctx_->dev_best_value_.data(),
            run_ctx_->dev_best_route_.data()
            );
}


/**
 * This is the fastest version of the ACS in which ants' solutions are
 * constructed during a single kernel execution.
 */
std::map<std::string, pj> 
gpu_run_acs_alt( TSPData &problem,
             std::mt19937 &rng,
             ACSParams &params,
             int pher_mem_update_freq,
             uint32_t threads_per_block,
             StopCondition *stop_cond ) {

    std::unique_ptr<GPUACS<MatrixPhmemDevice>> alg( 
            new GPUACS<MatrixPhmemDevice>( problem, rng, params ) );

    return alg->run( pher_mem_update_freq, stop_cond, threads_per_block );
}



/*
 * ACS implementation in which atomic CAS instructions are used during solutions
 * construction to ensure the updated values are not lost due to concurrent
 * execution.
 */
std::map<std::string, pj> 
gpu_run_acs_atomic( TSPData &problem,
                    std::mt19937 &rng,
                    ACSParams &params,
                    int pher_mem_update_freq,
                    uint32_t threads_per_block,
                    StopCondition *stop_cond ) {
    std::unique_ptr<GPUACS<MatrixPhmemAtomic>> alg( 
            new GPUACS<MatrixPhmemAtomic>( problem, rng, params ) );

    return alg->run( pher_mem_update_freq, stop_cond, threads_per_block );
}


/*
   ACS impl. which uses selective pheromone memory defined by the SelectivePhmem
   class.
 */
class GPUACSSelectiveMemory : public BaseGPUACS {
public:

    GPUACSSelectiveMemory( TSPData &problem,
                           std::mt19937 &rng,
                           ACSParams &params )
        : BaseGPUACS(problem, rng, params) 
    {}


    virtual void init_pheromone();
    virtual void build_ant_solutions();
    virtual void local_pheromone_update() { /* EMPTY */}
    virtual void global_pheromone_update();

private:

    SelectivePhmem dev_phmem_;
};


void GPUACSSelectiveMemory::init_pheromone() {
    auto dimension  = dev_problem_->dimension_;
    std::unique_ptr<SelectivePhmem> memory ( new SelectivePhmem( dimension+1, 8, true) );
    memory->set_default_pheromone( acs_params_.initial_pheromone_ );
    memory->init();

    dev_phmem_ = *memory;

    gpuErrchk( cudaMalloc( &dev_phmem_.trails_,
                           sizeof(SelectivePhmem::Trails) * (dimension + 1)) );
    
    gpuErrchk( cudaMemcpy( dev_phmem_.trails_, memory->trails_,
                           sizeof(SelectivePhmem::Trails) * (dimension + 1),
                           cudaMemcpyHostToDevice) );
}


void GPUACSSelectiveMemory::build_ant_solutions() {
    // We ignore run_ctx_->threads_per_block intentionally
    const auto threads_per_block = 32u;

    GPU_ACSParams gpu_acs_params;
    gpu_acs_params = acs_params_;

    acs_spm_calc_solution<<< acs_params_.ants_count_, threads_per_block >>>(
            run_ctx_->dev_prng_states_.data(),
            gpu_acs_params,
            dev_problem_->dimension_,
            dev_phmem_,
            dev_problem_->heuristic_matrix_.data(),
            dev_problem_->dist_matrix_.data(),
            dev_problem_->nn_lists_.data(),
            run_ctx_->dev_ant_values_.data(),
            run_ctx_->dev_ant_visited_count_.data(),
            run_ctx_->dev_ant_routes_.data(),
            run_ctx_->pher_mem_update_freq_
            );
}


void GPUACSSelectiveMemory::global_pheromone_update() {
    acs_global_pheromone_update<<<1, 128>>>(
            dev_problem_->dimension_,
            acs_params_.rho_,
            dev_phmem_,
            run_ctx_->dev_best_value_.data(),
            run_ctx_->dev_best_route_.data()
            );
}


std::map<std::string, pj> 
gpu_run_acs_spm( TSPData &problem,
                 std::mt19937 &rng,
                 ACSParams &params,
                 int pher_mem_update_freq,
                 uint32_t threads_per_block,
                 StopCondition *stop_cond ) {

    std::unique_ptr<GPUACSSelectiveMemory> alg(
            new GPUACSSelectiveMemory( problem, rng, params ) );

    return alg->run( pher_mem_update_freq, stop_cond, threads_per_block );
}



/**
 *This version executes ants' node selection in separate kernel executions.
 */
class GPUACSSeparate : public GPUACS<MatrixPhmemAtomic> {
public:

    GPUACSSeparate( TSPData &problem,
               std::mt19937 &rng,
               ACSParams &params )
        : GPUACS<MatrixPhmemAtomic>(problem, rng, params),
          ants_marked_nodes_( params.ants_count_ * problem.nn_lists_.size(), 0 ),
          dev_ants_marked_nodes_( ants_marked_nodes_ ),
          stats_(16, 0),
          dev_stats_( stats_ )
    {}

    void build_ant_solutions();
    void on_run_finish();

private:

    std::vector<int8_t> ants_marked_nodes_;
    DeviceVector<int8_t> dev_ants_marked_nodes_;
    GPUIntervalTimer select_node_timer_;
    int iterations_ = 0;
    std::vector<uint32_t> stats_;
    DeviceVector<uint32_t> dev_stats_;
};




void GPUACSSeparate::build_ant_solutions() {
    GPU_ACSParams gpu_acs_params;
    gpu_acs_params = acs_params_;

    fill<<<1, 128>>>( dev_ants_marked_nodes_.data(),
                      (uint32_t)(dev_problem_->dimension_ * acs_params_.ants_count_),
                      (int8_t)0 );

    select_node_timer_.start_interval();
    for (auto i = 1u; i < dev_problem_->dimension_; ++i) {

        acs_select_next_node<<< acs_params_.ants_count_,
                                run_ctx_->threads_per_block_ >>>(
                run_ctx_->dev_prng_states_.data(),
                gpu_acs_params,
                dev_problem_->dimension_,
                *phmem_,
                //d_phmem_cells,
                dev_problem_->heuristic_matrix_.data(),
                dev_problem_->dist_matrix_.data(),
                dev_problem_->nn_lists_.data(),
                run_ctx_->dev_ant_values_.data(),
                run_ctx_->dev_ant_visited_count_.data(),
                run_ctx_->dev_ant_routes_.data(),
                dev_ants_marked_nodes_.data(),
                run_ctx_->pher_mem_update_freq_,
                dev_stats_.data()
                );
    }
    select_node_timer_.stop_interval();

    gpuErrchk( cudaDeviceSynchronize() );

    eval_ants_solutions<<< acs_params_.ants_count_,
                           WARP_SIZE >>>(
                dev_problem_->dimension_,
                dev_problem_->dist_matrix_.data(),
                run_ctx_->dev_ant_values_.data(),
                run_ctx_->dev_ant_visited_count_.data(),
                run_ctx_->dev_ant_routes_.data() );
    ++iterations_;
}


void GPUACSSeparate::on_run_finish() {
    record( "select_node_time_ms", select_node_timer_.get_total_time_ms() /
                                  ( dev_problem_->dimension_ * iterations_ ) );
    std::vector<uint32_t> stats(1);
    dev_stats_.copyTo(stats);
    record( "stats_0", (int64_t)stats[0] );
    std::cout << "stats_0: " << stats[0] << std::endl;
    iterations_ = 0;
}


/*
   An impl. of the standard ACS in which each node is selected in a
   separate kernel launch.
 */
std::map<std::string, pj> 
gpu_run_acs(TSPData &problem,
            std::mt19937 &rng,
            ACSParams &params,
            int pher_mem_update_freq,
            uint32_t threads_per_block,
            StopCondition *stop_cond ) {
    std::unique_ptr<GPUACSSeparate> alg( new GPUACSSeparate( problem, rng, params ) );

    return alg->run( pher_mem_update_freq, stop_cond, threads_per_block );
}
