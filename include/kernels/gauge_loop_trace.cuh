#pragma once

#include <gauge_field_order.h>
#include <quda_matrix.h>
#include <index_helper.cuh>
#include <kernel.h>
#include <shared_memory_cache_helper.cuh>
#include <array.h>
#include <reduce_helper.h>
#include <reduction_kernel.h>
#include <gauge_path_helper.cuh>

namespace quda {

  /**
    @brief Return the batch block size used for multi reductions.
  */
  constexpr unsigned int max_n_batch_block_loop_trace() { return 8; }

  // to-do: also compute the determinant?
  template <typename Float_, int nColor_, QudaReconstructType recon_>
  struct GaugeLoopTraceArg : public ReduceArg<array<double, 2>>  {
    using Float = Float_;
    using reduce_t = array<double, 2>;
    static constexpr unsigned int max_n_batch_block = max_n_batch_block_loop_trace();
    static constexpr int nColor = nColor_;
    static constexpr QudaReconstructType recon = recon_;
    using Link = Matrix<complex<Float>, nColor>;
    static_assert(nColor == 3, "Only nColor=3 enabled at this time");
    typedef typename gauge_mapper<Float,recon>::type Gauge;

    const Gauge u;

    const int length_cb;
    static constexpr int nParity = 2; // always true for gauge fields
    int X[4]; // the regular volume parameters
    int E[4]; // the extended volume parameters
    int border[4]; // radius of border

    const paths p;

    GaugeLoopTraceArg(const GaugeField &u, const paths &p) :
      ReduceArg<reduce_t>(dim3(2 * u.LocalVolumeCB(), 1, p.num_paths), p.num_paths),
      u(u),
      length_cb(u.LocalVolumeCB()),
      p(p)
    {
      for (int dir = 0; dir < 4; dir++) {
        border[dir] = u.R()[dir];
      	E[dir] = u.X()[dir];
      	X[dir] = u.X()[dir] - border[dir]*2;
      }
    }
  };

  template <typename Arg> struct GaugeLoop : plus<typename Arg::reduce_t>
  {
    using reduce_t = typename Arg::reduce_t;
    using plus<reduce_t>::operator();
    static constexpr int reduce_block_dim = 1; // x_cb and parity are mapped to x
    const Arg &arg;
    constexpr GaugeLoop(const Arg &arg) : arg(arg) {}
    static constexpr const char *filename() { return KERNEL_FILE; }

    __device__ __host__ inline reduce_t operator()(reduce_t &value, int idx, int, int path_id)
    {
      using real = typename Arg::Float;
      using Link = typename Arg::Link;

      reduce_t loop_trace{0, 0};

      int parity = idx > arg.length_cb ? 1 : 0;
      int x_cb = idx - parity * arg.length_cb;

      if (parity >= 2) return operator()(loop_trace, value);

      int x[4] = {0, 0, 0, 0};
      getCoords(x, x_cb, arg.X, parity);
      for (int dr=0; dr<4; ++dr) x[dr] += arg.border[dr]; // extended grid coordinates

      thread_array<int, 4> dx{0};

      real coeff = arg.p.path_coeff[path_id];
      if (coeff == 0) return operator()(loop_trace, value);

      // clean up input path, no need for `dir`...
      const int* path = arg.p.input_path[0] + path_id * arg.p.max_length;

      // compute the path
      Link link_prod = computeGaugePath<Arg>(arg, x, parity, path, arg.p.length[path_id], dx);

      // compute trace
      auto trace = getTrace(link_prod);

      loop_trace[0] = coeff * trace.real();
      loop_trace[1] = coeff * trace.imag();

      return operator()(loop_trace, value);
    }
  };

}
