/*
Query voxel centers for each point
Written by Jiageng Mao
*/


#include <math.h>
#include <stdio.h>
#include <stdlib.h>

#include "voxel_to_point_simple_gpu.h"
#include "pv_cuda_utils.h"

// simple hash, only use % op
__device__ int hash_s(int k, int max_hash_size) {
    return k % max_hash_size;
}

__global__ void voxel_to_point_query_simple_kernel(float x_size, float y_size, float z_size, int x_max, int y_max, int z_max,
                                                    int x_step, int y_step, int z_step, int x_dilate, int y_dilate, int z_dilate,
                                                    int x_divide, int y_divide, int z_divide,
                                                    int num_total_points, int num_total_voxels, int num_samples, int max_hash_size, 
                                                    const int *p_bs_cnt, const float *xyz, const int *xyz_to_vidx, 
                                                    int *p_map, int *p_mask, int *p_bin) {
    /*
        xyz: [N1+N2, 4] xyz coordinates of points
        xyz_to_vidx: [B, max_hash_size, 2] voxel coordinates to voxel indices
        p_bs_cnt: [B]
        p_map: [N1+N2, num_samples] voxel indices for each point
        p_bin: [N1+N2, num_bins, num_samples] voxel indices for each point
        p_mask: [N1+N2, 1] num_voxels for each point
    */

    int th_idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (th_idx >= num_total_points) return;
    int bs_idx = (int) xyz[th_idx * 4 + 0];
    float x = xyz[th_idx * 4 + 1];
    float y = xyz[th_idx * 4 + 2];
    float z = xyz[th_idx * 4 + 3];
    float x_res = x / x_size - 0.5;
    float y_res = y / y_size - 0.5;
    float z_res = z / z_size - 0.5;                                   
    int x_f_idx = floor(x_res);                                             
    int y_f_idx = floor(y_res);                                            
    int z_f_idx = floor(z_res);
    int x_c_idx = ceil(x_res);                                            
    int y_c_idx = ceil(y_res);                                            
    int z_c_idx = ceil(z_res);
    int x_min_range = x_f_idx - (x_step - 1);                                                        
    int y_min_range = y_f_idx - (y_step - 1);                                                        
    int z_min_range = z_f_idx - (z_step - 1);                                                        
    //int x_max_range = x_c_idx + (x_step - 1);                                                        
    //int y_max_range = y_c_idx + (y_step - 1);                                                        
    //int z_max_range = z_c_idx + (z_step - 1);
    int x_divide_step =  2 * x_step / x_divide;                                                        
    int y_divide_step =  2 * y_step / y_divide;
    int z_divide_step =  2 * z_step / z_divide;                                                        

    xyz_to_vidx += bs_idx * max_hash_size * 2;
    int p_sum = 0;
    int bs_cnt = bs_idx - 1;
    while(bs_cnt >= 0){
        p_sum += p_bs_cnt[bs_cnt];
        bs_cnt--;
    }
    int pt_idx = th_idx - p_sum; // pt_idx for this sample
    int num_bins = x_divide * y_divide * z_divide;
    p_map += p_sum * num_samples;
    p_mask += p_sum * 1;
    p_bin += p_sum * num_bins * num_samples;

    // collect points in each bin
    for (int z_di = 0; z_di < z_divide; ++z_di) {
    for (int y_di = 0; y_di < y_divide; ++y_di) {
    for (int x_di = 0; x_di < x_divide; ++x_di) {
    int bin_idx = x_di * y_divide * z_divide + y_di * z_divide + z_di;
    int x_min_idx = x_min_range + x_di * x_divide_step;
    int x_max_idx = x_min_range + (x_di + 1) * x_divide_step;
    int y_min_idx = y_min_range + y_di * y_divide_step;
    int y_max_idx = y_min_range + (y_di + 1) * y_divide_step;
    int z_min_idx = z_min_range + z_di * z_divide_step;
    int z_max_idx = z_min_range + (z_di + 1) * z_divide_step;

    int sample_idx = 0;
    for (int z_idx = z_min_idx; z_idx < z_max_idx; z_idx += z_dilate) {
        if (z_idx < 0 || z_idx >= z_max) continue;
        if (sample_idx >= num_samples) break;
        for (int y_idx = y_min_idx; y_idx < y_max_idx; y_idx += y_dilate) {
            if (y_idx < 0 || y_idx >= y_max) continue;
            if (sample_idx >= num_samples) break;
            for (int x_idx = x_min_idx; x_idx < x_max_idx; x_idx += x_dilate) {
                if (x_idx >= x_max || x_idx < 0) continue; // out of bound
                if (sample_idx >= num_samples) break;

                // key -> [x_max, y_max, z_max] value -> v_idx
                int key = x_idx * y_max * z_max + y_idx * z_max + z_idx;
                int hash_idx = hash_s(key, max_hash_size);
                int v_idx = -1;
                int prob_cnt = 0;
                while (true) {
                    // found
                    if (xyz_to_vidx[hash_idx * 2 + 0] == key) {
                        v_idx = xyz_to_vidx[hash_idx * 2 + 1];
                        break;
                    }
                    // empty, not found
                    if (xyz_to_vidx[hash_idx * 2 + 0] == EMPTY_KEY) {
                        break;
                    }
                    // linear probing
                    //hash_idx = (hash_idx + 1) & (max_hash_size - 1);
                    hash_idx = (hash_idx + 1) % max_hash_size;

                    // security in case of dead loop
                    prob_cnt += 1;
                    if (prob_cnt >= max_hash_size) break;
                }
            
                if (v_idx < 0) continue; // -1 not found
                p_bin[pt_idx * num_bins * num_samples + bin_idx * num_samples + sample_idx] = v_idx;
                sample_idx += 1;
            }
        }
    }
    }}}

    // uniformly sample in each bin
    int real_sample_idx = 0;
    for (int level_idx = 0; level_idx < num_samples; ++level_idx) {
        if (real_sample_idx >= num_samples) break;
        for (int z_di = 0; z_di < z_divide; ++z_di) {
            if (real_sample_idx >= num_samples) break;
            for (int y_di = 0; y_di < y_divide; ++y_di) {
                if (real_sample_idx >= num_samples) break;
                for (int x_di = 0; x_di < x_divide; ++x_di) {
                    if (real_sample_idx >= num_samples) break;

                    int sample_bin_idx = x_di * y_divide * z_divide + y_di * z_divide + z_di;
                    int sample_v_idx = p_bin[pt_idx * num_bins * num_samples + sample_bin_idx * num_samples + level_idx];
                    if (sample_v_idx < 0) continue;
                    if (real_sample_idx == 0) {
                        for (int i = 0; i < num_samples; ++i) {
                            p_map[pt_idx * num_samples + i] = sample_v_idx;
                        }
                    } else {
                        p_map[pt_idx * num_samples + real_sample_idx] = sample_v_idx;
                    }
                    real_sample_idx += 1;
                }
            }   
        }
    }
    p_mask[pt_idx] = real_sample_idx;
    return;
}


void voxel_to_point_query_simple_kernel_launcher(float x_size, float y_size, float z_size, int x_max, int y_max, int z_max,
                                                int x_step, int y_step, int z_step, int x_dilate, int y_dilate, int z_dilate,
                                                int x_divide, int y_divide, int z_divide,
                                                int num_total_points, int num_total_voxels, int num_samples, int max_hash_size,
                                                const int *p_bs_cnt, const float *xyz, const int *xyz_to_vidx,
                                                int *p_map, int *p_mask, int *p_bin) {

    cudaError_t err;

    dim3 blocks(DIVUP(num_total_points, THREADS_PER_BLOCK));  // blockIdx.x(col), blockIdx.y(row)
    dim3 threads(THREADS_PER_BLOCK);

    voxel_to_point_query_simple_kernel<<<blocks, threads>>>(x_size, y_size, z_size, x_max, y_max, z_max,
                                                            x_step, y_step, z_step, x_dilate, y_dilate, z_dilate,
                                                            x_divide, y_divide, z_divide,
                                                            num_total_points, num_total_voxels, num_samples, max_hash_size,
                                                            p_bs_cnt, xyz, xyz_to_vidx, p_map, p_mask, p_bin);

    // cudaDeviceSynchronize();  // for using printf in kernel function
    err = cudaGetLastError();
    if (cudaSuccess != err) {
        fprintf(stderr, "CUDA kernel failed : %s\n", cudaGetErrorString(err));
        exit(-1);
    }
}
