#include <quda_internal.h>
#include <quda_matrix.h>
#include <su3_project.cuh>
#include <tune_quda.h>
#include <gauge_field.h>
#include <gauge_field_order.h>
#include <index_helper.cuh>

#define  DOUBLE_TOL	1e-15
#define  SINGLE_TOL	2e-6

namespace quda {

#ifdef GPU_GAUGE_TOOLS

  template <typename Float, typename GaugeOr, typename GaugeDs>
  struct GaugeSTOUTArg {
    int threads; // number of active threads required
    int X[4]; // grid dimensions
    int border[4];
    GaugeOr origin;
    const Float rho;
    const Float tolerance;
    
    GaugeDs dest;

    GaugeSTOUTArg(GaugeOr &origin, GaugeDs &dest, const GaugeField &data, const Float rho, const Float tolerance) 
      : threads(1), origin(origin), dest(dest), rho(rho), tolerance(tolerance) {
      for ( int dir = 0; dir < 4; ++dir ) {
        border[dir] = data.R()[dir];
        X[dir] = data.X()[dir] - border[dir] * 2;
	threads *= X[dir];
      } 
      threads /= 2;
    }
  };

  
  template <typename Float, typename GaugeOr, typename GaugeDs, typename Float2>
  __host__ __device__ void computeStaple(GaugeSTOUTArg<Float,GaugeOr,GaugeDs>& arg, int idx, int parity, int dir, Matrix<Float2,3> &staple) {
    
    typedef Matrix<complex<Float>,3> Link;
    // compute spacetime dimensions and parity

    int X[4];
    for(int dr=0; dr<4; ++dr) X[dr] = arg.X[dr];

    int x[4];
    getCoords(x, idx, X, parity);
    for(int dr=0; dr<4; ++dr) {
      x[dr] += arg.border[dr];
      X[dr] += 2*arg.border[dr];
    }

    setZero(&staple);

    // I believe most users won't want to include time staples in smearing
    for (int mu=0; mu<3; mu++) {

      //identify directions orthogonal to the link.
      if (mu != dir) {
	
	int nu = dir;
	{
	  int dx[4] = {0, 0, 0, 0};
	  Link U1, U2, U3, U4, tmpS;
	  
	  //Get link U_{\mu}(x)
	  U1 = arg.origin(mu, linkIndexShift(x,dx,X), parity);
	  
	  dx[mu]++;
	  //Get link U_{\nu}(x+\mu)
	  U2 = arg.origin(nu, linkIndexShift(x,dx,X), 1-parity);
	  
	  dx[mu]--;
	  dx[nu]++;
	  //Get link U_{\mu}(x+\nu)
	  U3 = arg.origin(mu, linkIndexShift(x,dx,X), 1-parity);
	  
	  // staple += U_{\mu}(x) * U_{\nu}(x+\mu) * U^\dag_{\mu}(x+\nu)
	  staple = staple + U1 * U2 * conj(U3);
	  
	  dx[mu]--;
	  dx[nu]--;
	  //Get link U_{\mu}(x-\mu)
	  U1 = arg.origin(mu, linkIndexShift(x,dx,X), 1-parity);
	  //Get link U_{\nu}(x-\mu)
	  U2 = arg.origin(nu, linkIndexShift(x,dx,X), 1-parity);
	  
	  dx[nu]++;
	  //Get link U_{\mu}(x-\mu+\nu)
	  U3 = arg.origin(mu, linkIndexShift(x,dx,X), parity);
	  
	  // staple += U^\dag_{\mu}(x-\mu) * U_{\nu}(x-\mu) * U_{\mu}(x-\mu+\nu)
	  staple = staple + conj(U1) * U2 * U3;
	}
      }
    }
  }
  
  template<typename Float, typename GaugeOr, typename GaugeDs>
    __global__ void computeSTOUTStep(GaugeSTOUTArg<Float,GaugeOr,GaugeDs> arg){

      int idx = threadIdx.x + blockIdx.x*blockDim.x;
      int parity = threadIdx.y + blockIdx.y*blockDim.y;
      int dir = threadIdx.z + blockIdx.z*blockDim.z;
      if (idx >= arg.threads) return;
      if (dir >= 3) return;
      typedef complex<Float> Complex;
      typedef Matrix<complex<Float>,3> Link;

      int X[4];
      for(int dr=0; dr<4; ++dr) X[dr] = arg.X[dr];

      int x[4];
      getCoords(x, idx, X, parity);
      for(int dr=0; dr<4; ++dr) {
	x[dr] += arg.border[dr];
	X[dr] += 2*arg.border[dr];
      }

      int dx[4] = {0, 0, 0, 0};
      //Only spatial dimensions are smeared
      {
        Link U, UDag, Stap, Omega, OmegaDiff, ODT, Q, exp_iQ;
	Complex OmegaDiffTr;
	Complex i_2(0,0.5);

	//This function gets stap = S_{mu,nu} i.e., the staple of length 3,
        computeStaple<Float,GaugeOr,GaugeDs,Complex>(arg,idx,parity,dir,Stap);
	//
	// |- > -|                /- > -/                /- > -
	// ^     v               ^     v                ^
	// |     |              /     /                /- < -
	//         + |     |  +         +  /     /  +         +  - > -/
	//           v     ^              v     ^                    v 
	//           |- > -|             /- > -/                - < -/

	// Get link U
        U = arg.origin(dir, linkIndexShift(x,dx,X), parity);

	//Compute Omega_{mu}=[Sum_{mu neq nu}rho_{mu,nu}C_{mu,nu}]*U_{mu}^dag

	//Get U^{\dagger}
	computeMatrixInverse(U,&UDag);
	
	//Compute \Omega = \rho * S * U^{\dagger}
	Omega = (arg.rho * Stap) * UDag;

	//Compute \Q_{mu} = i/2[Omega_{mu}^dag - Omega_{mu} 
	//                      - 1/3 Tr(Omega_{mu}^dag - Omega_{mu})]

	OmegaDiff = conj(Omega) - Omega;

	Q = OmegaDiff;
	OmegaDiffTr = getTrace(OmegaDiff);
	OmegaDiffTr = (1.0/3.0) * OmegaDiffTr;

	//Matrix proportional to OmegaDiffTr
	setIdentity(&ODT);

	Q = Q - OmegaDiffTr * ODT;
	Q = i_2 * Q;
	//Q is now defined.

#ifdef HOST_DEBUG
	//Test for Tracless:
	//reuse OmegaDiffTr
	OmegaDiffTr = getTrace(Q);
	double error;
	error = OmegaDiffTr.real();
	printf("Trace test %d %d %.15e\n", idx, dir, error);

	//Test for hemiticity:
	Link Q_diff = conj(Q);
	Q_diff -= Q; //This should be the zero matrix. Test by ReTr(Q_diff^2);
	Q_diff *= Q_diff;
	//reuse OmegaDiffTr
	OmegaDiffTr = getTrace(Q_diff);
	error = OmegaDiffTr.real();
	printf("Herm test %d %d %.15e\n", idx, dir, error);
#endif

	exponentiate_iQ(Q,&exp_iQ);

#ifdef HOST_DEBUG
	//Test for expiQ unitarity:
	error = ErrorSU3(exp_iQ);
	printf("expiQ test %d %d %.15e\n", idx, dir, error);
#endif

	U = exp_iQ * U;
#ifdef HOST_DEBUG
	//Test for expiQ*U unitarity:
	error = ErrorSU3(U);
	printf("expiQ*u test %d %d %.15e\n", idx, dir, error);
#endif

        arg.dest(dir, linkIndexShift(x,dx,X), parity) = U;
    }
  }

  template<typename Float, typename GaugeOr, typename GaugeDs>
  class GaugeSTOUT : TunableVectorYZ {
      GaugeSTOUTArg<Float,GaugeOr,GaugeDs> arg;
      const GaugeField &meta;

      private:
      bool tuneGridDim() const { return false; } // Don't tune the grid dimensions.
      unsigned int minThreads() const { return arg.threads; }

      public:
    // (2,3) --- 2 for parity in the y thread dim, 3 corresponds to mapping direction to the z thread dim
    GaugeSTOUT(GaugeSTOUTArg<Float,GaugeOr,GaugeDs> &arg, const GaugeField &meta)
      : TunableVectorYZ(2,3), arg(arg), meta(meta) {}
      virtual ~GaugeSTOUT () {}

      void apply(const cudaStream_t &stream){
        if (meta.Location() == QUDA_CUDA_FIELD_LOCATION) {
          TuneParam tp = tuneLaunch(*this, getTuning(), getVerbosity());
          computeSTOUTStep<<<tp.grid,tp.block,tp.shared_bytes>>>(arg);
        } else {
          errorQuda("CPU not supported yet\n");
          //computeSTOUTStepCPU(arg);
        }
      }

      TuneKey tuneKey() const {
        std::stringstream aux;
        aux << "threads=" << arg.threads << ",prec="  << sizeof(Float);
        return TuneKey(meta.VolString(), typeid(*this).name(), aux.str().c_str());
      }

      long long flops() const { return 3*(2+2*4)*198ll*arg.threads; } // just counts matrix multiplication
      long long bytes() const { return 3*((1+2*6)*arg.origin.Bytes()+arg.dest.Bytes())*arg.threads; }
    }; // GaugeSTOUT

  template<typename Float,typename GaugeOr, typename GaugeDs>
  void STOUTStep(GaugeOr origin, GaugeDs dest, const GaugeField& dataOr, Float rho) {
    GaugeSTOUTArg<Float,GaugeOr,GaugeDs> arg(origin, dest, dataOr, rho, dataOr.Precision() == QUDA_DOUBLE_PRECISION ? DOUBLE_TOL : SINGLE_TOL);
    GaugeSTOUT<Float,GaugeOr,GaugeDs> gaugeSTOUT(arg,dataOr);
    gaugeSTOUT.apply(0);
    cudaDeviceSynchronize();
  }

  template<typename Float>
  void STOUTStep(GaugeField &dataDs, const GaugeField& dataOr, Float rho) {

    if(dataDs.Reconstruct() == QUDA_RECONSTRUCT_NO) {
      typedef typename gauge_mapper<Float,QUDA_RECONSTRUCT_NO>::type GDs;

      if(dataOr.Reconstruct() == QUDA_RECONSTRUCT_NO) {
	typedef typename gauge_mapper<Float,QUDA_RECONSTRUCT_NO>::type GOr;
	STOUTStep(GOr(dataOr), GDs(dataDs), dataOr, rho);
      }else if(dataOr.Reconstruct() == QUDA_RECONSTRUCT_12){
	typedef typename gauge_mapper<Float,QUDA_RECONSTRUCT_12>::type GOr;
	STOUTStep(GOr(dataOr), GDs(dataDs), dataOr, rho);
      }else if(dataOr.Reconstruct() == QUDA_RECONSTRUCT_8){
	typedef typename gauge_mapper<Float,QUDA_RECONSTRUCT_8>::type GOr;
	STOUTStep(GOr(dataOr), GDs(dataDs), dataOr, rho);
      }else{
	errorQuda("Reconstruction type %d of origin gauge field not supported", dataOr.Reconstruct());
      }
    } else if(dataDs.Reconstruct() == QUDA_RECONSTRUCT_12){
      typedef typename gauge_mapper<Float,QUDA_RECONSTRUCT_12>::type GDs;
      if(dataOr.Reconstruct() == QUDA_RECONSTRUCT_NO){
	typedef typename gauge_mapper<Float,QUDA_RECONSTRUCT_NO>::type GOr;
	STOUTStep(GOr(dataOr), GDs(dataDs), dataOr, rho);
      }else if(dataOr.Reconstruct() == QUDA_RECONSTRUCT_12){
	typedef typename gauge_mapper<Float,QUDA_RECONSTRUCT_12>::type GOr;
	STOUTStep(GOr(dataOr), GDs(dataDs), dataOr, rho);
      }else if(dataOr.Reconstruct() == QUDA_RECONSTRUCT_8){
	typedef typename gauge_mapper<Float,QUDA_RECONSTRUCT_8>::type GOr;
	STOUTStep(GOr(dataOr), GDs(dataDs), dataOr, rho);
      }else{
	errorQuda("Reconstruction type %d of origin gauge field not supported", dataOr.Reconstruct());
      }
    } else if(dataDs.Reconstruct() == QUDA_RECONSTRUCT_8){
      typedef typename gauge_mapper<Float,QUDA_RECONSTRUCT_8>::type GDs;
      if(dataOr.Reconstruct() == QUDA_RECONSTRUCT_NO){
	typedef typename gauge_mapper<Float,QUDA_RECONSTRUCT_NO>::type GOr;
	STOUTStep(GOr(dataOr), GDs(dataDs), dataOr, rho);
      }else if(dataOr.Reconstruct() == QUDA_RECONSTRUCT_12){
	typedef typename gauge_mapper<Float,QUDA_RECONSTRUCT_12>::type GOr;
	STOUTStep(GOr(dataOr), GDs(dataDs), dataOr, rho);
      }else if(dataOr.Reconstruct() == QUDA_RECONSTRUCT_8){
	typedef typename gauge_mapper<Float,QUDA_RECONSTRUCT_8>::type GOr;
	STOUTStep(GOr(dataOr), GDs(dataDs), dataOr, rho);
      }else{
	errorQuda("Reconstruction type %d of origin gauge field not supported", dataOr.Reconstruct());
            }
    } else {
      errorQuda("Reconstruction type %d of destination gauge field not supported", dataDs.Reconstruct());
    }

  }

#endif

  void STOUTStep(GaugeField &dataDs, const GaugeField& dataOr, double rho) {

#ifdef GPU_GAUGE_TOOLS

    if(dataOr.Precision() != dataDs.Precision()) {
      errorQuda("Origin and destination fields must have the same precision\n");
    }

    if(dataDs.Precision() == QUDA_HALF_PRECISION){
      errorQuda("Half precision not supported\n");
    }

    if (!dataOr.isNative())
      errorQuda("Order %d with %d reconstruct not supported", dataOr.Order(), dataOr.Reconstruct());

    if (!dataDs.isNative())
      errorQuda("Order %d with %d reconstruct not supported", dataDs.Order(), dataDs.Reconstruct());

    if (dataDs.Precision() == QUDA_SINGLE_PRECISION){
      STOUTStep<float>(dataDs, dataOr, (float) rho);
    } else if(dataDs.Precision() == QUDA_DOUBLE_PRECISION) {
      STOUTStep<double>(dataDs, dataOr, rho);
    } else {
      errorQuda("Precision %d not supported", dataDs.Precision());
    }
    return;
#else
  errorQuda("Gauge tools are not build");
#endif
  }

}
