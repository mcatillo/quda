#include <color_spinor_field.h>
#include <contract_quda.h>

#include <tunable_nd.h>
#include <tunable_reduction.h>
#include <instantiate.h>
#include <kernels/contraction.cuh>

namespace quda {

  // Summed contraction type kernels.
  //----------------------------------------------------------------------------
  template <typename Float, int nColor> class ContractionSummed : TunableMultiReduction<1>
  {
  protected:
    const ColorSpinorField &x;
    const ColorSpinorField &y;
    std::vector<Complex> &result_global;
    const QudaContractType cType;
    const int *const source_position;
    const int *const mom_mode;
    const size_t s1;
    const size_t b1;
    
  public:
    ContractionSummed(const ColorSpinorField &x, const ColorSpinorField &y,
		      std::vector<Complex> &result_global,
		      const QudaContractType cType,
		      const int *const source_position,
		      const int *const mom_mode,
		      const size_t s1, const size_t b1) :
      TunableMultiReduction(x, x.X()[cType == QUDA_CONTRACT_TYPE_DR_FT_Z ||
				     cType == QUDA_CONTRACT_TYPE_OPEN_SUM_Z ? 2 : 3]),
      x(x),
      y(y),
      result_global(result_global),
      cType(cType),
      source_position(source_position),
      mom_mode(mom_mode),
      s1(s1),
      b1(b1)
    {
      switch (cType) {
      case QUDA_CONTRACT_TYPE_OPEN_SUM_T: strcat(aux, "open-sum-t,"); break;
      case QUDA_CONTRACT_TYPE_OPEN_SUM_Z: strcat(aux, "open-sum-z,"); break;
      case QUDA_CONTRACT_TYPE_DR_FT_T: strcat(aux, "degrand-rossi-ft-t,"); break;
      case QUDA_CONTRACT_TYPE_DR_FT_Z: strcat(aux, "degrand-rossi-ft-z,"); break;
      default: errorQuda("Unexpected contraction type %d", cType);
      }
      apply(device::get_default_stream());
    }

    void apply(const qudaStream_t &stream)
    {
      TuneParam tp = tuneLaunch(*this, getTuning(), getVerbosity());

      int reduction_dim = 3;
      const int nSpinSq = x.Nspin()*x.Nspin();
      
      if (cType == QUDA_CONTRACT_TYPE_DR_FT_Z) reduction_dim = 2;      
      std::vector<double> result_local(2*nSpinSq * x.X()[reduction_dim], 0.0);      
      
      // Pass the integer value of the reduction dim as a template arg
      // Here we pass a null reducer to launch to prevent the `complete` step
      // From summing data from other nodes into the Z/T dim buckets
      if (cType == QUDA_CONTRACT_TYPE_DR_FT_T) {
	ContractionSummedArg<Float, nColor, 3> arg(x, y, source_position, mom_mode, s1, b1);
	launch<DegrandRossiContractFT, double, comm_reduce_null<double>>(result_local, tp, stream, arg);
      } else if(cType == QUDA_CONTRACT_TYPE_DR_FT_Z) {
	ContractionSummedArg<Float, nColor, 2> arg(x, y, source_position, mom_mode, s1, b1);
	launch<DegrandRossiContractFT, double, comm_reduce_null<double>>(result_local, tp, stream, arg);
      } else {
	errorQuda("Unexpected contraction type %d", cType);
      }

      // Copy results back to host array
      if(!activeTuning()) {
	for(int i=0; i<nSpinSq * x.X()[reduction_dim]; i++) {
	  result_global[nSpinSq * x.X()[reduction_dim] * comm_coord(reduction_dim) + i].real(result_local[2*i]);
	  result_global[nSpinSq * x.X()[reduction_dim] * comm_coord(reduction_dim) + i].imag(result_local[2*i+1]);
	}
      }
    }
    
    long long flops() const
    {
      return ((x.Nspin() * x.Nspin() * x.Ncolor() * 6ll) + (x.Nspin() * x.Nspin() * (x.Nspin() + x.Nspin()*x.Ncolor()))) * x.Volume();
    }
    
    long long bytes() const
    {
      return x.Bytes() + y.Bytes() + x.Nspin() * x.Nspin() * x.Volume() * sizeof(complex<Float>);
    }
  };
  
#ifdef GPU_CONTRACT
  void contractSummedQuda(const ColorSpinorField &x, const ColorSpinorField &y,
			  std::vector<Complex> &result_global,
			  const QudaContractType cType,
			  const int *const source_position, const int *const mom_mode,
			  const size_t s1, const size_t b1)
  {
    checkPrecision(x, y);
    
    if (x.GammaBasis() != QUDA_DEGRAND_ROSSI_GAMMA_BASIS || y.GammaBasis() != QUDA_DEGRAND_ROSSI_GAMMA_BASIS)
      errorQuda("Unexpected gamma basis x=%d y=%d", x.GammaBasis(), y.GammaBasis());
    if (x.Ncolor() != N_COLORS || y.Ncolor() != N_COLORS) errorQuda("Unexpected number of colors x=%d y=%d", x.Ncolor(), y.Ncolor());
    if (x.Nspin() != 4 || y.Nspin() != 4) errorQuda("Unexpected number of spins x=%d y=%d", x.Nspin(), y.Nspin());
    
    instantiate<ContractionSummed>(x, y, result_global, cType, source_position, mom_mode, s1, b1);
  }
#else
  void contractSummedQuda(const ColorSpinorField &, const ColorSpinorField &,
			  std::vector<Complex> &, const QudaContractType,
			  const int *const, const int *const,
			  const size_t, const size_t)
  {
    errorQuda("Contraction code has not been built");
  }
#endif
  //----------------------------------------------------------------------------
  
  // Mark for deletion
  //----------------------------------------------------------------------------
  template <typename Float, int nColor> class Contraction : TunableKernel2D
  {
    complex<Float> *result;
    const ColorSpinorField &x;
    const ColorSpinorField &y;
    const QudaContractType cType;
    unsigned int minThreads() const { return x.VolumeCB(); }

public:
    Contraction(const ColorSpinorField &x, const ColorSpinorField &y, void *result, const QudaContractType cType) :
      TunableKernel2D(x, 2),
      result(static_cast<complex<Float>*>(result)),
      x(x),
      y(y),
      cType(cType)
    {
      switch (cType) {
      case QUDA_CONTRACT_TYPE_OPEN: strcat(aux, "open,"); break;
      case QUDA_CONTRACT_TYPE_DR: strcat(aux, "degrand-rossi,"); break;
      default: errorQuda("Unexpected contraction type %d", cType);
      }
      apply(device::get_default_stream());
    }

    void apply(const qudaStream_t &stream)
    {
      TuneParam tp = tuneLaunch(*this, getTuning(), getVerbosity());
      ContractionArg<Float, nColor> arg(x, y, result);
      switch (cType) {
      case QUDA_CONTRACT_TYPE_OPEN: launch<ColorContract>(tp, stream, arg); break;
      case QUDA_CONTRACT_TYPE_DR:   launch<DegrandRossiContract>(tp, stream, arg); break;
      default: errorQuda("Unexpected contraction type %d", cType);
      }
    }

    long long flops() const
    {
      if (cType == QUDA_CONTRACT_TYPE_OPEN)
        return x.Nspin()*x.Nspin() * x.Ncolor() * 6ll * x.Volume();
      else
        return ((x.Nspin()*x.Nspin() * x.Ncolor() * 6ll) + (x.Nspin()*x.Nspin() * (x.Nspin() + x.Nspin()*x.Ncolor()))) * x.Volume();
    }

    long long bytes() const
    {
      return x.Bytes() + y.Bytes() + x.Nspin() * x.Nspin() * x.Volume() * sizeof(complex<Float>);
    }
  };

#ifdef GPU_CONTRACT
  void contractQuda(const ColorSpinorField &x, const ColorSpinorField &y, void *result, const QudaContractType cType)
  {
    checkPrecision(x, y);
    if (x.GammaBasis() != QUDA_DEGRAND_ROSSI_GAMMA_BASIS || y.GammaBasis() != QUDA_DEGRAND_ROSSI_GAMMA_BASIS)
      errorQuda("Unexpected gamma basis x=%d y=%d", x.GammaBasis(), y.GammaBasis());
    if (x.Nspin() != 4 || y.Nspin() != 4) errorQuda("Unexpected number of spins x=%d y=%d", x.Nspin(), y.Nspin());

    instantiate<Contraction>(x, y, result, cType);
  }
#else
  void contractQuda(const ColorSpinorField &, const ColorSpinorField &, void *, const QudaContractType)
  {
    errorQuda("Contraction code has not been built");
  }
#endif
  //----------------------------------------------------------------------------
} // namespace quda
