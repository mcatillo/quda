#include <copy_color_spinor.cuh>

namespace quda {
  
  void copyGenericColorSpinorSH(ColorSpinorField &dst, const ColorSpinorField &src, 
				QudaFieldLocation location, void *Dst, void *Src, 
				void *dstNorm, void *srcNorm) {
    CopyGenericColorSpinor(dst, src, location, (float*)Dst, (short*)Src, 0, (float*)srcNorm);
  }  

} // namespace quda
