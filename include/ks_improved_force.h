#pragma once

#include <quda_internal.h>
#include <quda.h>
#include <gauge_field.h>

namespace quda {
  namespace fermion_force {

  void hisqStaplesForce(const double path_coeff[6],
                        const QudaGaugeParam& param,
                        const cudaGaugeField& oprod,
                        const cudaGaugeField& link,
                        cudaGaugeField *newOprod,
                        long long* flops = NULL);

   void hisqLongLinkForce(double coeff,
                          const QudaGaugeParam& param,
                          const cudaGaugeField &oprod,
                          const cudaGaugeField &link,
                          cudaGaugeField *newOprod,
                          long long* flops = NULL);

   void hisqCompleteForce(const QudaGaugeParam &param,
                          const cudaGaugeField &oprod,
                          const cudaGaugeField &link,
                          cudaGaugeField *force,
                          long long* flops = NULL);

  void setUnitarizeForceConstants(double unitarize_eps, double hisq_force_filter, double max_det_error,
				     bool allow_svd, bool svd_only,
				     double svd_rel_error,
				     double svd_abs_error);

  void unitarizeForce(cudaGaugeField &newForce,
		      const cudaGaugeField &oldForce,
		      const cudaGaugeField &gauge,
		      int* unitarization_failed,
		      long long* flops = NULL);

  void unitarizeForceCPU( cpuGaugeField &newForce,
			  const cpuGaugeField &oldForce,
                          const cpuGaugeField &gauge);

 } // namespace fermion_force
}  // namespace quda
