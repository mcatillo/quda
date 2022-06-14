#pragma once

#include <gauge_field_order.h>
#include <quda_matrix.h>
#include <index_helper.cuh>
#include <kernel.h>
#include <shared_memory_cache_helper.cuh>

namespace quda {

  struct paths {
    const int num_paths;
    const int max_length;
    int *input_path[4];
    const int *length;
    const double *path_coeff;
    int *buffer;
    int count;

    paths(int ***input_path, int *length_h, double *path_coeff_h, int num_paths, int max_length) :
      num_paths(num_paths),
      max_length(max_length),
      count(0)
    {
      // create path struct in a single allocation
      size_t bytes = 4 * num_paths * max_length * sizeof(int) + num_paths * sizeof(int);
      int pad = ((sizeof(double) - bytes % sizeof(double)) % sizeof(double))/sizeof(int);
      bytes += pad*sizeof(int) + num_paths*sizeof(double);

      buffer = static_cast<int*>(pool_device_malloc(bytes));
      int *path_h = static_cast<int*>(safe_malloc(bytes));
      memset(path_h, 0, bytes);

      for (int dir=0; dir<4; dir++) {
        // flatten the input_path array for copying to the device
        for (int i=0; i < num_paths; i++) {
          for (int j=0; j < length_h[i]; j++) {
            path_h[dir*num_paths*max_length + i*max_length + j] = input_path[dir][i][j];
            if (dir==0) count++;
          }
        }
      }

      // length array
      memcpy(path_h + 4 * num_paths * max_length, length_h, num_paths*sizeof(int));

      // path_coeff array
      memcpy(path_h + 4 * num_paths * max_length + num_paths + pad, path_coeff_h, num_paths*sizeof(double));

      qudaMemcpy(buffer, path_h, bytes, qudaMemcpyHostToDevice);
      host_free(path_h);

      // finally set the pointers to the correct offsets in the buffer
      for (int d=0; d < 4; d++) this->input_path[d] = buffer + d*num_paths*max_length;
      length = buffer + 4*num_paths*max_length;
      path_coeff = reinterpret_cast<double*>(buffer + 4 * num_paths * max_length + num_paths + pad);
    }

    void free() {
      pool_device_free(buffer);
    }
  };

  constexpr int flipDir(int dir) { return (7-dir); }
  constexpr bool isForwards(int dir) { return (dir <= 3); }

  /**
     @brief Calculates an arbitary gauge path, returning the product matrix

     @return The product of the gauge path
     @param[in] arg Kernel argumnt
     @param[in] x Full index array
     @param[in] parity Parity index (note: assumes that an offset from a non-zero dx is baked in)
     @param[in] path Gauge link path
     @param[in] length Length of gauge path
     @param[in] dx Temporary shared memory storage for relative coordinate shift
  */
  template <typename Arg>
  __device__ __host__ inline typename Arg::Link
  computeGaugePath(const Arg &arg, int x[4], int parity, const int* path, int length, thread_array<int, 4>& dx)
  {
    using real = typename Arg::Float;
    using Link = typename Arg::Link;

    // linkA: current matrix
    // linkB: the loaded matrix in this round
    Link linkA, linkB;
    setIdentity(&linkA);

    int nbr_oddbit = parity;

    for (int j = 0; j < length; j++) {

      int pathj = path[j];
      int lnkdir = isForwards(pathj) ? pathj : flipDir(pathj);

      if (isForwards(pathj)) {
        linkB = arg.u(lnkdir, linkIndexShift(x,dx,arg.E), nbr_oddbit);
        linkA = linkA * linkB;
        dx[lnkdir]++; // now have to update to new location
        nbr_oddbit = nbr_oddbit^1;
      } else {
        dx[lnkdir]--; // if we are going backwards the link is on the adjacent site
        nbr_oddbit = nbr_oddbit^1;
        linkB = arg.u(lnkdir, linkIndexShift(x,dx,arg.E), nbr_oddbit);
        linkA = linkA * conj(linkB);
      }
    } //j

    return linkA;
  }

}

