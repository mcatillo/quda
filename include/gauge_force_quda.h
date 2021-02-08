#pragma once

namespace quda {

  /**
     @brief Compute the gauge-force contribution to the momentum
     @param[out] mom Momentum field
     @param[in] u Gauge field (extended when running no multiple GPUs)
     @param[in] coeff Step-size coefficient
     @param[in] input_path Host-array holding all path contributions for the gauge action
     @param[in] length Host array holding the length of all paths
     @param[in] path_coeff Coefficient of each path
     @param[in] num_paths Numer of paths
     @param[in] max_length Maximum length of each path
   */
  void gaugeForce(GaugeField& mom, const GaugeField& u, double coeff, int ***input_path,
		  int *length, double *path_coeff, int num_paths, int max_length);

  /**
     @brief Compute the gauge-force contribution to the momentum
     @param[out] mom Momentum field
     @param[in] u Gauge field (extended when running no multiple GPUs)
     @param[in] action_type Wilson/Symanzik/Luscher-Weiss
     @param[in] epsilon Step-size coefficient
     @param[in] path_coeff Coefficients of the various staples
  */
  void gaugeForceNew(GaugeField& mom, const GaugeField& u, const QudaGaugeActionType action_type, const double epsilon, void *path_coeff);
  
} // namespace quda
