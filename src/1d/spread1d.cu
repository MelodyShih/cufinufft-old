#include <iostream>
#include <math.h>
#include <helper_cuda.h>
#include "../../finufft/utils.h"
#include "../spreadinterp.h"

using namespace std;

#define RESCALE(x,N,p) (p ? \
                       ((x*M_1_2PI + (x<-PI ? 1.5 : (x>PI ? -0.5 : 0.5)))*N) : \
                       (x<0 ? x+N : (x>N ? x-N : x)))

#if !defined(__CUDA_ARCH__) || __CUDA_ARCH__ >= 600
#else
static __inline__ __device__ double atomicAdd(double* address, double val)
{
	unsigned long long int* address_as_ull =
		(unsigned long long int*)address;
	unsigned long long int old = *address_as_ull, assumed;

	do {
		assumed = old;
		old = atomicCAS(address_as_ull, assumed,
				__double_as_longlong(val +
					__longlong_as_double(assumed)));

		// Note: uses integer comparison to avoid hang in case of NaN (since NaN != NaN)
	} while (assumed != old);

	return __longlong_as_double(old);
}
#endif

static __forceinline__ __device__
FLT evaluate_kernel(FLT x, FLT es_c, FLT es_beta)
	/* ES ("exp sqrt") kernel evaluation at single real argument:
	   phi(x) = exp(beta.sqrt(1 - (2x/n_s)^2)),    for |x| < nspread/2
	   related to an asymptotic approximation to the Kaiser--Bessel, itself an
	   approximation to prolate spheroidal wavefunction (PSWF) of order 0.
	   This is the "reference implementation", used by eg common/onedim_* 2/17/17 */
{
	return exp(es_beta * (sqrt(1.0 - es_c*x*x)));
	//return x;
	//return 1.0;
}
#if 0
static __forceinline__ __device__
void evaluate_kernel_vector(FLT *ker, FLT xstart, FLT es_c, FLT es_beta, const int N)
	/* Evaluate ES kernel for a vector of N arguments; by Ludvig af K.
	   If opts.kerpad true, args and ker must be allocated for Npad, and args is
	   written to (to pad to length Npad), only first N outputs are correct.
	   Barnett 4/24/18 option to pad to mult of 4 for better SIMD vectorization.
	   Obsolete (replaced by Horner), but keep around for experimentation since
	   works for arbitrary beta. Formula must match reference implementation. */
{
	// Note (by Ludvig af K): Splitting kernel evaluation into two loops
	// seems to benefit auto-vectorization.
	// gcc 5.4 vectorizes first loop; gcc 7.2 vectorizes both loops
	for (int i = 0; i < N; i++) { // Loop 1: Compute exponential arguments
		ker[i] = exp(es_beta * sqrt(1.0 - es_c*(xstart+i)*(xstart+i)));
	}
	//for (int i = 0; i < Npad; i++) // Loop 2: Compute exponentials
		//ker[i] = exp(ker[i]);
}
#endif
static __inline__ __device__
void eval_kernel_vec_Horner(FLT *ker, const FLT x, const int w, const double upsampfac)
	/* Fill ker[] with Horner piecewise poly approx to [-w/2,w/2] ES kernel eval at
	   x_j = x + j,  for j=0,..,w-1.  Thus x in [-w/2,-w/2+1].   w is aka ns.
	   This is the current evaluation method, since it's faster (except i7 w=16).
	   Two upsampfacs implemented. Params must match ref formula. Barnett 4/24/18 */
{
	FLT z = 2*x + w - 1.0;         // scale so local grid offset z in [-1,1]
	// insert the auto-generated code which expects z, w args, writes to ker...
	if (upsampfac==2.0) {     // floating point equality is fine here
#include "../../finufft/ker_horner_allw_loop.c"
	}
}

/*
__global__
void CalcBinSize_1d(int M, int nf1, int  bin_size_x, int nbinx,
                    int* bin_size, double *x, int* sortidx)
{
  int i = blockDim.x*blockIdx.x + threadIdx.x;
  int binidx, binx;
  int oldidx;
  double x_rescaled;
  if (i < M){
    x_rescaled = RESCALE(x[i],nf1,1);
    binx = floor(x_rescaled/bin_size_x)+1;
    binidx = binx;
    oldidx = atomicAdd(&bin_size[binidx], 1);
    sortidx[i] = oldidx;
  }
}

__global__
void FillGhostBin_1d(int bin_size_x, int nbinx, int*bin_size)
{
  int ix = blockDim.x*blockIdx.x + threadIdx.x;
  if ( ix < nbinx ){
    if(ix == 0)
      bin_size[ix] = bin_size[(nbinx-2)];
    if(ix == nbinx-1)
      bin_size[ix] = bin_size[1];
  }
}

// An exclusive scan of bin_size, only works for 1 block (!)
__global__
void BinsStartPts_1d(int M, int totalnumbins, int* bin_size, int* bin_startpts)
{
  __shared__ int temp[max_shared_plan];
  int i = threadIdx.x;
  //temp[i] = (i > 0) ? bin_size[i-1] : 0;
  if ( i < totalnumbins){
    temp[i] = (i<totalnumbins) ? bin_size[i]:0;
    __syncthreads();
    for(int offset = 1; offset < totalnumbins; offset*=2){
      if( i >= offset)
        temp[i] += temp[i - offset];
      else
        temp[i] = temp[i];
      __syncthreads();
    }
    bin_startpts[i+1] = temp[i];
    if(i == 0)
      bin_startpts[i] = 0;
  }
}

__global__
void PtsRearrage_1d(int M, int nf1, int bin_size_x, int nbinx,
                    int* bin_startpts, int* sortidx, double *x, double *x_sorted,
                    double *c, double *c_sorted)
{
  int i = blockDim.x*blockIdx.x + threadIdx.x;
  int binx;
  int binidx;
  double x_rescaled;
  if( i < M){
    x_rescaled = RESCALE(x[i],nf1,1);
    binx = floor(x_rescaled/bin_size_x)+1;
    binidx = binx;

    x_sorted[bin_startpts[binidx]+sortidx[i]]       = x_rescaled;

    if( binx == 1 ){
      binidx = (nbinx-1);
      x_sorted[ bin_startpts[binidx]+sortidx[i] ] = x_rescaled + nf1;
    }
    if( binx == nbinx-2 ){
      binidx = 0;
      x_sorted[ bin_startpts[binidx]+sortidx[i] ] = x_rescaled - nf1;
    }
    c_sorted[ 2*(bin_startpts[binidx]+sortidx[i]) ] = c[2*i];
    c_sorted[ 2*(bin_startpts[binidx]+sortidx[i])+1 ] = c[2*i+1];
  }
}

__global__
void Spread_1d(int nbin_block_x, int nbinx, int *bin_startpts,
               double *x_sorted, double *c_sorted, double *fw, int ns,
               int nf1, double es_c, double es_beta)
{
  __shared__ double xshared[max_shared_plan/4];
  __shared__ double cshared[2*max_shared_plan/4];

  int ix = blockDim.x*blockIdx.x+threadIdx.x;// output index, coord of the index
  int outidx = ix;
  int tid = threadIdx.x;
  int binxLo = blockIdx.x*nbin_block_x;
  int binxHi = binxLo+nbin_block_x+1;
  int start, end, j, bx, bin;
  // run through all bins
  if( ix < nf1 ){
      for(bx=binxLo; bx<=binxHi; bx++){
        bin = bx;
        start = bin_startpts[bin];
        end   = bin_startpts[bin+1];
        if( tid < end-start){
          xshared[tid] = x_sorted[start+tid];
          cshared[2*tid]   = c_sorted[2*(start+tid)];
          cshared[2*tid+1] = c_sorted[2*(start+tid)+1];
        }
        __syncthreads();
        for(j=0; j<end-start; j++){
          double disx = abs(xshared[j]-ix);
          if( disx < ns/2.0 ){
             fw[2*outidx] ++;
             fw[2*outidx+1] ++;
             //double kervalue = evaluate_kernel(disx, es_c, es_beta);
             //fw[2*outidx]   += cshared[2*j]*kervalue;
             //fw[2*outidx+1] += cshared[2*j+1]*kervalue;
          }
        }
      }
  }
}
*/
__global__
void RescaleXY_1d(int M, int nf1, FLT* x)
{
	for(int i=blockDim.x*blockIdx.x+threadIdx.x; i<M; i+=blockDim.x*gridDim.x){
		x[i] = RESCALE(x[i], nf1, 1);
	}
}

__global__
void Spread_1d_Idriven(FLT *x, CUCPX *c, CUCPX *fw, int M, const int ns,
		int nf1, FLT es_c, FLT es_beta, int fw_width)
{
	int xstart,xend;
	int xx, ix;
	int outidx;

	FLT x_rescaled;
	for(int i=blockDim.x*blockIdx.x+threadIdx.x; i<M; i+=blockDim.x*gridDim.x){
		x_rescaled=x[i];
		xstart = ceil(x_rescaled - ns/2.0);
		xend = floor(x_rescaled + ns/2.0);

			for(xx=xstart; xx<=xend; xx++){
				ix = xx < 0 ? xx+nf1 : (xx>nf1-1 ? xx-nf1 : xx);
				outidx = ix;
				FLT disx=abs(x_rescaled-xx);
				FLT kervalue1 = evaluate_kernel(disx, es_c, es_beta);
				atomicAdd(&fw[outidx].x, c[i].x*kervalue1);
				atomicAdd(&fw[outidx].y, c[i].y*kervalue1);
				//atomicAdd(&fw[outidx].x, kervalue1*kervalue2);
				//atomicAdd(&fw[outidx].y, kervalue1*kervalue2);
			}

	}

}

__global__
void Spread_1d_Idriven_Horner(FLT *x, CUCPX *c, CUCPX *fw, int M, const int ns,
		int nf1, FLT es_c, FLT es_beta, int fw_width)
{
	int xx, ix;
	int outidx;
	FLT ker1[MAX_NSPREAD];
	FLT ker1val;
	double sigma=2.0;

	FLT x_rescaled;
	for(int i=blockDim.x*blockIdx.x+threadIdx.x; i<M; i+=blockDim.x*gridDim.x){
		x_rescaled=x[i];
		int xstart = ceil(x_rescaled - ns/2.0);
		int xend = floor(x_rescaled + ns/2.0);

		FLT x1=(FLT)xstart-x_rescaled;
		eval_kernel_vec_Horner(ker1,x1,ns,sigma);
		//evaluate_kernel_vector(ker1, x1, es_c, es_beta, ns);
		for(xx=xstart; xx<=xend; xx++){
			ix = xx < 0 ? xx+nf1 : (xx>nf1-1 ? xx-nf1 : xx);
			outidx = ix;
			ker1val=ker1[xx-xstart];
			FLT kervalue=ker1val;
			atomicAdd(&fw[outidx].x, c[i].x*kervalue);
			atomicAdd(&fw[outidx].y, c[i].y*kervalue);
		}
	}
}


// __global__
// void CalcBinSize_noghost_1d(int M, int nf1, int nf2, int  bin_size_x, int bin_size_y, int nbinx,
// 		int nbiny, int* bin_size, FLT *x, FLT *y, int* sortidx)
// {
// 	int binidx, binx, biny;
// 	int oldidx;
// 	FLT x_rescaled,y_rescaled;
// 	for(int i=threadIdx.x+blockIdx.x*blockDim.x; i<M; i+=gridDim.x*blockDim.x){
// 		//x_rescaled = RESCALE(x[i],nf1,1);
// 		//y_rescaled = RESCALE(y[i],nf2,1);
// 		x_rescaled=x[i];
// 		y_rescaled=y[i];
// 		binx = floor(x_rescaled/bin_size_x);
// 		biny = floor(y_rescaled/bin_size_y);
// 		binidx = binx+biny*nbinx;
// 		oldidx = atomicAdd(&bin_size[binidx], 1);
// 		sortidx[i] = oldidx;
// 	}
// }
//
// __global__
// void PtsRearrage_noghost_1d(int M, int nf1, int nf2, int bin_size_x, int bin_size_y, int nbinx,
// 		int nbiny, int* bin_startpts, int* sortidx, FLT *x, FLT *x_sorted,
// 		FLT *y, FLT *y_sorted, CUCPX *c, CUCPX *c_sorted)
// {
// 	//int i = blockDim.x*blockIdx.x + threadIdx.x;
// 	int binx, biny;
// 	int binidx;
// 	FLT x_rescaled, y_rescaled;
// 	for(int i=threadIdx.x+blockIdx.x*blockDim.x; i<M; i+=gridDim.x*blockDim.x){
// 		//x_rescaled = RESCALE(x[i],nf1,1);
// 		//y_rescaled = RESCALE(y[i],nf2,1);
// 		x_rescaled=x[i];
// 		y_rescaled=y[i];
// 		binx = floor(x_rescaled/bin_size_x);
// 		biny = floor(y_rescaled/bin_size_y);
// 		binidx = binx+biny*nbinx;
//
// 		x_sorted[bin_startpts[binidx]+sortidx[i]] = x_rescaled;
// 		y_sorted[bin_startpts[binidx]+sortidx[i]] = y_rescaled;
// 		c_sorted[bin_startpts[binidx]+sortidx[i]] = c[i];
// 	}
// }
//
// __global__
// void CalcInvertofGlobalSortIdx_1d(int M, int bin_size_x, int bin_size_y, int nbinx,
// 			          int nbiny, int* bin_startpts, int* sortidx,
//                                   FLT *x, FLT *y, int* index)
// {
// 	int binx, biny;
// 	int binidx;
// 	FLT x_rescaled, y_rescaled;
// 	for(int i=threadIdx.x+blockIdx.x*blockDim.x; i<M; i+=gridDim.x*blockDim.x){
// 		x_rescaled=x[i];
// 		y_rescaled=y[i];
// 		binx = floor(x_rescaled/bin_size_x);
// 		biny = floor(y_rescaled/bin_size_y);
// 		binidx = binx+biny*nbinx;
//
// 		index[bin_startpts[binidx]+sortidx[i]] = i;
// 	}
// }
//
// __global__
// void CalcSubProb_1d(int* bin_size, int* num_subprob, int maxsubprobsize, int numbins)
// {
// 	for(int i=threadIdx.x+blockIdx.x*blockDim.x; i<numbins; i+=gridDim.x*blockDim.x){
// 		num_subprob[i]=ceil(bin_size[i]/(float) maxsubprobsize);
// 	}
// }
//
// __global__
// void MapBintoSubProb_1d(int* d_subprob_to_bin, int* d_subprobstartpts, int* d_numsubprob,
//                         int numbins)
// {
// 	for(int i=threadIdx.x+blockIdx.x*blockDim.x; i<numbins; i+=gridDim.x*blockDim.x){
// 		for(int j=0; j<d_numsubprob[i]; j++){
// 			d_subprob_to_bin[d_subprobstartpts[i]+j]=i;
// 		}
// 	}
// }
//
// __global__
// void CreateSortIdx(int M, int nf1, int nf2, FLT *x, FLT *y, int* sortidx)
// {
// 	int i = blockDim.x*blockIdx.x + threadIdx.x;
// 	FLT x_rescaled,y_rescaled;
// 	if (i < M){
// 		//x_rescaled = RESCALE(x[i],nf1,1);
// 		//y_rescaled = RESCALE(y[i],nf2,1);
// 		x_rescaled=x[i];
// 		y_rescaled=y[i];
// 		sortidx[i] = floor(x_rescaled) + floor(y_rescaled)*nf1;
// 	}
// }
//
// __global__
// void Spread_1d_Subprob(FLT *x, FLT *y, CUCPX *c, CUCPX *fw, int M, const int ns,
// 		          int nf1, int nf2, FLT es_c, FLT es_beta, FLT sigma, int fw_width, int* binstartpts,
// 		          int* bin_size, int bin_size_x, int bin_size_y, int* subprob_to_bin,
// 		          int* subprobstartpts, int* numsubprob, int maxsubprobsize, int nbinx, int nbiny,
//                           int* idxnupts)
// {
// 	extern __shared__ CUCPX fwshared[];
//
// 	int xstart,ystart,xend,yend;
// 	int subpidx=blockIdx.x;
// 	int bidx=subprob_to_bin[subpidx];
// 	int binsubp_idx=subpidx-subprobstartpts[bidx];
// 	int ix, iy;
// 	int outidx;
// 	int ptstart=binstartpts[bidx]+binsubp_idx*maxsubprobsize;
// 	int nupts=min(maxsubprobsize, bin_size[bidx]-binsubp_idx*maxsubprobsize);
//
// 	int xoffset=(bidx % nbinx)*bin_size_x;
// 	int yoffset=(bidx / nbinx)*bin_size_y;
//
// 	int N = (bin_size_x+2*ceil(ns/2.0))*(bin_size_y+2*ceil(ns/2.0));
//
//
// 	for(int i=threadIdx.x; i<N; i+=blockDim.x){
// 		fwshared[i].x = 0.0;
// 		fwshared[i].y = 0.0;
// 	}
// 	__syncthreads();
//
// 	FLT x_rescaled, y_rescaled;
// 	CUCPX cnow;
// 	for(int i=threadIdx.x; i<nupts; i+=blockDim.x){
// 		int idx = ptstart+i;
// 		x_rescaled = x[idxnupts[idx]];
// 		y_rescaled = y[idxnupts[idx]];
// 		cnow = c[idxnupts[idx]];
//
// 		xstart = ceil(x_rescaled - ns/2.0)-xoffset;
// 		ystart = ceil(y_rescaled - ns/2.0)-yoffset;
// 		xend   = floor(x_rescaled + ns/2.0)-xoffset;
// 		yend   = floor(y_rescaled + ns/2.0)-yoffset;
// 		/*
// 		FLT ker1[MAX_NSPREAD];
// 		FLT x1=(FLT) xstart+xoffset-x_rescaled;
//         	for (int j = 0; j < ns; j++) { // Loop 1: Compute exponential arguments
//                 	ker1[j] = j;
//         	}*/
// 		//evaluate_kernel_vector(ker1, x1, es_c, es_beta, ns);
// 		for(int yy=ystart; yy<=yend; yy++){
// 			FLT disy=abs(y_rescaled-(yy+yoffset));
// 			FLT kervalue2 = evaluate_kernel(disy, es_c, es_beta);
// 			for(int xx=xstart; xx<=xend; xx++){
// 				ix = xx+ceil(ns/2.0);
// 				iy = yy+ceil(ns/2.0);
// 				outidx = ix+iy*(bin_size_x+ceil(ns/2.0)*2);
// 				FLT disx=abs(x_rescaled-(xx+xoffset));
// 				//FLT kervalue1 = ker1[xx-xstart];
// 				FLT kervalue1 = evaluate_kernel(disx, es_c, es_beta);
// 				atomicAdd(&fwshared[outidx].x, cnow.x*kervalue1*kervalue2);
// 				atomicAdd(&fwshared[outidx].y, cnow.y*kervalue1*kervalue2);
// 			}
// 		}
// 	}
// 	__syncthreads();
// 	/* write to global memory */
// 	for(int k=threadIdx.x; k<N; k+=blockDim.x){
// 		int i = k % (int) (bin_size_x+2*ceil(ns/2.0) );
// 		int j = k /( bin_size_x+2*ceil(ns/2.0) );
// 		ix = xoffset-ceil(ns/2.0)+i;
// 		iy = yoffset-ceil(ns/2.0)+j;
// 		if(ix < (nf1+ceil(ns/2.0)) && iy < (nf2+ceil(ns/2.0))){
// 			ix = ix < 0 ? ix+nf1 : (ix>nf1-1 ? ix-nf1 : ix);
// 			iy = iy < 0 ? iy+nf2 : (iy>nf2-1 ? iy-nf2 : iy);
// 			outidx = ix+iy*fw_width;
// 			int sharedidx=i+j*(bin_size_x+ceil(ns/2.0)*2);
// 			atomicAdd(&fw[outidx].x, fwshared[sharedidx].x);
// 			atomicAdd(&fw[outidx].y, fwshared[sharedidx].y);
// 		}
// 	}
// }