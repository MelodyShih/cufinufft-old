#include <helper_cuda.h>
#include <iostream>
#include <iomanip>

// try another library cub
#include <cub/device/device_radix_sort.cuh>
#include <cub/device/device_scan.cuh>

#include <cuComplex.h>
#include "spread.h"
#include "memtransfer.h"

using namespace std;

// This is a function only doing spread includes device memory allocation, transfer, free
int cufinufft_spread2d(int ms, int mt, int nf1, int nf2, CPX* h_fw, int M, FLT *h_kx,
		FLT *h_ky, CPX *h_c, spread_opts opts, cufinufft_plan* d_plan)
{
	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	int ier;
	
	d_plan->ms = ms;
        d_plan->mt = mt;
        d_plan->nf1 = nf1;
        d_plan->nf2 = nf2;
	d_plan->M = M;
        d_plan->h_kx = h_kx;
        d_plan->h_ky = h_ky;
        d_plan->h_c = h_c;
	d_plan->h_fw = h_fw;
	d_plan->h_fwkerhalf1 = NULL;
	d_plan->h_fwkerhalf2 = NULL;

	if(opts.pirange){
		for(int i=0; i<M; i++){
			h_kx[i]=RESCALE(h_kx[i], nf1, opts.pirange);
			h_ky[i]=RESCALE(h_ky[i], nf2, opts.pirange);
		}
	}
	cudaEventRecord(start);
	ier = allocgpumemory(opts, d_plan);
#ifdef TIME
	float milliseconds = 0;
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] Allocate GPU memory\t %.3g ms\n", milliseconds);
#endif
	cudaEventRecord(start);
	ier = copycpumem_to_gpumem(opts, d_plan);
#ifdef TIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] Copy memory HtoD\t %.3g ms\n", milliseconds);
#endif
	ier = cuspread2d(opts, d_plan);
#ifdef TIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] Spread\t\t\t %.3g ms\n", milliseconds);
#endif
	cudaEventRecord(start);
	ier = copygpumem_to_cpumem_fw(d_plan);
#ifdef TIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] Copy memory DtoH\t %.3g ms\n", milliseconds);
#endif
	cudaEventRecord(start);
	free_gpumemory(opts, d_plan);
#ifdef TIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] Free GPU memory\t %.3g ms\n", milliseconds);
#endif
	return ier;
}

// a wrapper of different methods of spreader
int cuspread2d( spread_opts opts, cufinufft_plan* d_plan)
{
	int nf1 = d_plan->nf1;
	int nf2 = d_plan->nf2;
	int fw_width = d_plan->fw_width;
	int M = d_plan->M;

	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	int ier;
	switch(opts.method)
	{
		case 1:
			{
				cudaEventRecord(start);
				ier = cuspread2d_idriven(nf1, nf2, fw_width, M, opts, d_plan);
				if(ier != 0 ){
					cout<<"error: cnufftspread2d_gpu_idriven"<<endl;
					return 1;
				}
			}
			break;
		case 2:
			{
				cudaEventRecord(start);
				ier = cuspread2d_idriven_sorted(nf1, nf2, fw_width, M, opts, d_plan);
			}
			break;
		case 4:
			{
				cudaEventRecord(start);
				ier = cuspread2d_hybrid(nf1, nf2, fw_width, M, opts, d_plan);
				if(ier != 0 ){
					cout<<"error: cnufftspread2d_gpu_hybrid"<<endl;
					return 1;
				}
			}
			break;
		case 5:
			{
				cudaEventRecord(start);
				ier = cuspread2d_subprob(nf1, nf2, fw_width, M, opts, d_plan);
				if(ier != 0 ){
					cout<<"error: cnufftspread2d_gpu_hybrid"<<endl;
					return 1;
				}
			}
			break;
		default:
			cout<<"error: incorrect method, should be 1,2,4 or 5"<<endl;
			return 2;
	}
#ifdef SPREADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	cout<<"[time  ]"<< " Spread " << milliseconds <<" ms"<<endl;
#endif
	return ier;
}

int cuspread2d_simple(int nf1, int nf2, int fw_width, CUCPX* d_fw, int M, FLT *d_kx,
		FLT *d_ky, CUCPX *d_c, spread_opts opts, int binx, int biny)
{
	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	dim3 threadsPerBlock;
	dim3 blocks;

	int ns=opts.nspread;   // psi's support in terms of number of cells
	FLT es_c=opts.ES_c;
	FLT es_beta=opts.ES_beta;
	int bin_size_x=opts.bin_size_x;
	int bin_size_y=opts.bin_size_y;

	// assume that bin_size_x > ns/2;
	cudaEventRecord(start);
	threadsPerBlock.x = opts.nthread_x;
	threadsPerBlock.y = opts.nthread_y;
	blocks.x = 1;
	blocks.y = 1;
	size_t sharedplanorysize = (bin_size_x+2*ceil(ns/2.0))*(bin_size_y+2*ceil(ns/2.0))*sizeof(CUCPX);
	if(sharedplanorysize > 49152){
		cout<<"error: not enough shared memory"<<endl;
		return 1;
	}
	// blockSize must be a multiple of bin_size_x
	Spread_2d_Simple<<<blocks, threadsPerBlock, sharedplanorysize>>>(d_kx, d_ky, d_c, 
			d_fw, M, ns, nf1, nf2, 
			es_c, es_beta, fw_width, 
			M, bin_size_x, bin_size_y, 
			binx, biny);
#ifdef SPREADTIME
	float milliseconds = 0;
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel Spread_2d_Simple \t\t%.3g ms\n", milliseconds);
#endif
	return 0;
}

int cuspread2d_idriven(int nf1, int nf2, int fw_width, int M, spread_opts opts, cufinufft_plan *d_plan)
{
	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	dim3 threadsPerBlock;
	dim3 blocks;

	int ns=opts.nspread;   // psi's support in terms of number of cells
	FLT es_c=opts.ES_c;
	FLT es_beta=opts.ES_beta;

	FLT* d_kx = d_plan->kx;
	FLT* d_ky = d_plan->ky;
	CUCPX* d_c = d_plan->c;
	CUCPX* d_fw = d_plan->fw;

	threadsPerBlock.x = 16;
	threadsPerBlock.y = 1;
	blocks.x = (M + threadsPerBlock.x - 1)/threadsPerBlock.x;
	blocks.y = 1;
	cudaEventRecord(start);
	if(opts.Horner){
		Spread_2d_Idriven_Horner<<<blocks, threadsPerBlock>>>(d_kx, d_ky, d_c, d_fw, M, ns,
				nf1, nf2, es_c, es_beta, fw_width);
	}else{
		Spread_2d_Idriven<<<blocks, threadsPerBlock>>>(d_kx, d_ky, d_c, d_fw, M, ns,
				nf1, nf2, es_c, es_beta, fw_width);
	}

#ifdef SPREADTIME
	float milliseconds = 0;
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel Spread_2d_Idriven \t%.3g ms\n", milliseconds);
#endif
	return 0;
}

int cuspread2d_idriven_sorted(int nf1, int nf2, int fw_width, int M, spread_opts opts, cufinufft_plan *d_plan)
{
	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	dim3 threadsPerBlock;
	dim3 blocks;

	int ns=opts.nspread;   // psi's support in terms of number of cells
	FLT es_c=opts.ES_c;
	FLT es_beta=opts.ES_beta;

	int bin_size_x=opts.bin_size_x;
	int bin_size_y=opts.bin_size_y;
	int numbins[2];
	numbins[0] = ceil((FLT) nf1/bin_size_x);
	numbins[1] = ceil((FLT) nf2/bin_size_y);

	FLT* d_kx = d_plan->kx;
	FLT* d_ky = d_plan->ky;
	CUCPX* d_c = d_plan->c;
	CUCPX* d_fw = d_plan->fw;

	FLT *d_kxsorted = d_plan->kxsorted;
	FLT *d_kysorted = d_plan->kysorted;
	CUCPX *d_csorted = d_plan->csorted;

	int *d_binsize = d_plan->binsize;
	int *d_binstartpts = d_plan->binstartpts;
	int *d_sortidx = d_plan->sortidx;
	d_plan->temp_storage = NULL;
	void*d_temp_storage = d_plan->temp_storage;

	cudaEventRecord(start);
	checkCudaErrors(cudaMemset(d_binsize,0,numbins[0]*numbins[1]*sizeof(int)));
	CalcBinSize_noghost_2d<<<(M+1024-1)/1024, 1024>>>(M,nf1,nf2,bin_size_x,bin_size_y,
			numbins[0],numbins[1],d_binsize,
			d_kx,d_ky,d_sortidx);
#ifdef SPREADTIME
	float milliseconds = 0;
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel CalcBinSize_noghost_2d \t\t%.3g ms\n", milliseconds);
#endif
	cudaEventRecord(start);
	int n=numbins[0]*numbins[1];
	size_t temp_storage_bytes = 0;
	CubDebugExit(cub::DeviceScan::ExclusiveSum(d_temp_storage, temp_storage_bytes, d_binsize, d_binstartpts, n));
	checkCudaErrors(cudaMalloc(&d_temp_storage, temp_storage_bytes));
	CubDebugExit(cub::DeviceScan::InclusiveSum(d_temp_storage, temp_storage_bytes, d_binsize, d_binstartpts+1, n));
#ifdef SPREADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel BinStartPts_2d \t\t\t%.3g ms\n", milliseconds);
#endif
	cudaEventRecord(start);
	PtsRearrage_noghost_2d<<<(M+1024-1)/1024,1024>>>(M, nf1, nf2, bin_size_x, bin_size_y, numbins[0],
			numbins[1], d_binstartpts, d_sortidx, d_kx, d_kxsorted,
			d_ky, d_kysorted, d_c, d_csorted);
#ifdef SPREADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel PtsRearrange_noghost_2d \t\t%.3g ms\n", milliseconds);
#endif
	cudaEventRecord(start);
	threadsPerBlock.x = 16;
	threadsPerBlock.y = 1;
	blocks.x = (M + threadsPerBlock.x - 1)/threadsPerBlock.x;
	blocks.y = 1;
	Spread_2d_Idriven<<<blocks, threadsPerBlock>>>(d_kxsorted, d_kysorted, d_csorted, d_fw, M, ns,
			nf1, nf2, es_c, es_beta, fw_width);
#ifdef SPREADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel Spread_2d_Idriven \t\t%.3g ms\n", milliseconds);
#endif
	return 0;
}

int cuspread2d_hybrid(int nf1, int nf2, int fw_width, int M, spread_opts opts, cufinufft_plan *d_plan)
{
	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	dim3 threadsPerBlock;
	dim3 blocks;

	int ns=opts.nspread;   // psi's support in terms of number of cells
	FLT es_c=opts.ES_c;
	FLT es_beta=opts.ES_beta;

	int bin_size_x=opts.bin_size_x;
	int bin_size_y=opts.bin_size_y;
	int numbins[2];
	numbins[0] = ceil((FLT) nf1/bin_size_x);
	numbins[1] = ceil((FLT) nf2/bin_size_y);
#ifdef INFO
	cout<<"[info  ] Dividing the uniform grids to bin size["
		<<opts.bin_size_x<<"x"<<opts.bin_size_y<<"]"<<endl;
	cout<<"[info  ] numbins = ["<<numbins[0]<<"x"<<numbins[1]<<"]"<<endl;
#endif

	FLT* d_kx = d_plan->kx;
	FLT* d_ky = d_plan->ky;
	CUCPX* d_c = d_plan->c;
	CUCPX* d_fw = d_plan->fw;

	int *d_binsize = d_plan->binsize;
	int *d_binstartpts = d_plan->binstartpts;
	int *d_sortidx = d_plan->sortidx;

	// assume that bin_size_x > ns/2;
	FLT *d_kxsorted = d_plan->kxsorted;
	FLT *d_kysorted = d_plan->kysorted;
	CUCPX *d_csorted = d_plan->csorted;
	d_plan->temp_storage = NULL;
	void *d_temp_storage = d_plan->temp_storage;

	cudaEventRecord(start);
	checkCudaErrors(cudaMemset(d_binsize,0,numbins[0]*numbins[1]*sizeof(int)));
	CalcBinSize_noghost_2d<<<(M+1024-1)/1024, 1024>>>(M,nf1,nf2,bin_size_x,bin_size_y,
			numbins[0],numbins[1],d_binsize,
			d_kx,d_ky,d_sortidx);
#ifdef SPREADTIME
	float milliseconds = 0;
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel CalcBinSize_noghost_2d \t\t%.3g ms\n", milliseconds);
#endif
#ifdef DEBUG
	int *h_binsize;// For debug
	h_binsize     = (int*)malloc(numbins[0]*numbins[1]*sizeof(int));
	checkCudaErrors(cudaMemcpy(h_binsize,d_binsize,numbins[0]*numbins[1]*sizeof(int),
				cudaMemcpyDeviceToHost));
	cout<<"[debug ] bin size:"<<endl;
	for(int j=0; j<numbins[1]; j++){
		cout<<"[debug ] ";
		for(int i=0; i<numbins[0]; i++){
			if(i!=0) cout<<" ";
			cout <<" bin["<<setw(3)<<i<<","<<setw(3)<<j<<"]="<<h_binsize[i+j*numbins[0]];
		}
		cout<<endl;
	}
	free(h_binsize);
	cout<<"[debug ] --------------------------------------------------------------"<<endl;
#endif

	cudaEventRecord(start);
	int n=numbins[0]*numbins[1];
	size_t temp_storage_bytes = 0;
	CubDebugExit(cub::DeviceScan::InclusiveSum(d_temp_storage, temp_storage_bytes, d_binsize, d_binstartpts+1, n));
	checkCudaErrors(cudaMalloc(&d_temp_storage, temp_storage_bytes)); // Allocate temporary storage for inclusive prefix scan
	CubDebugExit(cub::DeviceScan::InclusiveSum(d_temp_storage, temp_storage_bytes, d_binsize, d_binstartpts+1, n));
	checkCudaErrors(cudaMemset(d_binstartpts,0,sizeof(int)));
#ifdef SPREADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel BinStartPts_2d \t\t\t%.3g ms\n", milliseconds);
#endif

#ifdef DEBUG
	int *h_binstartpts;
	h_binstartpts = (int*)malloc((numbins[0]*numbins[1]+1)*sizeof(int));
	checkCudaErrors(cudaMemcpy(h_binstartpts,d_binstartpts,(numbins[0]*numbins[1]+1)*sizeof(int),
				cudaMemcpyDeviceToHost));
	cout<<"[debug ] Result of scan bin_size array:"<<endl;
	for(int j=0; j<numbins[1]; j++){
		cout<<"[debug ] ";
		for(int i=0; i<numbins[0]; i++){
			if(i!=0) cout<<" ";
			cout <<"bin["<<setw(3)<<i<<","<<setw(3)<<j<<"] = "<<setw(2)<<h_binstartpts[i+j*numbins[0]];
		}
		cout<<endl;
	}
	cout<<"[debug ] Total number of nonuniform pts (include those in ghost bins) = "
		<< setw(4)<<h_binstartpts[numbins[0]*numbins[1]]<<endl;
	free(h_binstartpts);
	cout<<"[debug ] --------------------------------------------------------------"<<endl;
#endif

	cudaEventRecord(start);
	PtsRearrage_noghost_2d<<<(M+1024-1)/1024,1024>>>(M, nf1, nf2, bin_size_x, bin_size_y, numbins[0],
			numbins[1], d_binstartpts, d_sortidx, d_kx, d_kxsorted,
			d_ky, d_kysorted, d_c, d_csorted);
#ifdef SPREADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel PtsRearrange_noghost_2d \t\t%.3g ms\n", milliseconds);
#endif
#ifdef DEBUG
	FLT *h_kxsorted, *h_kysorted;
	CPX *h_csorted;
	h_kxsorted = (FLT*)malloc(M*sizeof(FLT));
	h_kysorted = (FLT*)malloc(M*sizeof(FLT));
	h_csorted  = (CPX*)malloc(M*sizeof(CPX));
	checkCudaErrors(cudaMemcpy(h_kxsorted,d_kxsorted,M*sizeof(FLT),
				cudaMemcpyDeviceToHost));
	checkCudaErrors(cudaMemcpy(h_kysorted,d_kysorted,M*sizeof(FLT),
				cudaMemcpyDeviceToHost));
	checkCudaErrors(cudaMemcpy(h_csorted,d_csorted,M*sizeof(CPX),
				cudaMemcpyDeviceToHost));
	for (int i=0; i<10; i++){
		cout <<"[debug ] (x,y) = ("<<setw(10)<<h_kxsorted[i]<<","
			<<setw(10)<<h_kysorted[i]<<"), bin# =  "
			<<(floor(h_kxsorted[i]/bin_size_x))+numbins[0]*(floor(h_kysorted[i]/bin_size_y))<<endl;
	}
	free(h_kysorted);
	free(h_kxsorted);
	free(h_csorted);
#endif

	cudaEventRecord(start);
	threadsPerBlock.x = 16;
	threadsPerBlock.y = 16;
	blocks.x = numbins[0];
	blocks.y = numbins[1];
	size_t sharedplanorysize = (bin_size_x+2*ceil(ns/2.0))*(bin_size_y+2*ceil(ns/2.0))*sizeof(CUCPX);
	if(sharedplanorysize > 49152){
		cout<<"error: not enough shared memory"<<endl;
		return 1;
	}
	// blockSize must be a multiple of bin_size_x
	Spread_2d_Hybrid<<<blocks, threadsPerBlock, sharedplanorysize>>>(d_kxsorted, d_kysorted, d_csorted, 
			d_fw, M, ns, nf1, nf2, 
			es_c, es_beta, fw_width, 
			d_binstartpts, d_binsize, 
			bin_size_x, bin_size_y);
#ifdef SPREADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel Spread_2d_Hybrid \t\t%.3g ms\n", milliseconds);
#endif
	return 0;
}

int cuspread2d_subprob(int nf1, int nf2, int fw_width, int M, spread_opts opts, cufinufft_plan *d_plan)
{
	cudaEvent_t start, stop;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	dim3 threadsPerBlock;
	dim3 blocks;

	int ns=opts.nspread;   // psi's support in terms of number of cells
	FLT es_c=opts.ES_c;
	FLT es_beta=opts.ES_beta;
	int maxsubprobsize=opts.maxsubprobsize;

	// assume that bin_size_x > ns/2;
	int bin_size_x=opts.bin_size_x;
	int bin_size_y=opts.bin_size_y;
	int numbins[2];
	numbins[0] = ceil((FLT) nf1/bin_size_x);
	numbins[1] = ceil((FLT) nf2/bin_size_y);
#ifdef INFO
	cout<<"[info  ] Dividing the uniform grids to bin size["
		<<opts.bin_size_x<<"x"<<opts.bin_size_y<<"]"<<endl;
	cout<<"[info  ] numbins = ["<<numbins[0]<<"x"<<numbins[1]<<"]"<<endl;
#endif

	FLT* d_kx = d_plan->kx;
	FLT* d_ky = d_plan->ky;
	CUCPX* d_c = d_plan->c;
	CUCPX* d_fw = d_plan->fw;

	int *d_binsize = d_plan->binsize;
	int *d_binstartpts = d_plan->binstartpts;
	int *d_sortidx = d_plan->sortidx;
	int *d_numsubprob = d_plan->numsubprob;
	int *d_subprobstartpts = d_plan->subprobstartpts;
	int *d_idxnupts = d_plan->idxnupts;
	d_plan->subprob_to_bin = NULL;
	int *d_subprob_to_bin = d_plan->subprob_to_bin;
	d_plan->temp_storage = NULL;
	void *d_temp_storage = d_plan->temp_storage;

	cudaEventRecord(start);
	checkCudaErrors(cudaMemset(d_binsize,0,numbins[0]*numbins[1]*sizeof(int)));
	CalcBinSize_noghost_2d<<<(M+1024-1)/1024, 1024>>>(M,nf1,nf2,bin_size_x,bin_size_y,
			numbins[0],numbins[1],d_binsize,
			d_kx,d_ky,d_sortidx);
#ifdef SPREADTIME
	float milliseconds = 0;
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel CalcBinSize_noghost_2d \t\t%.3g ms\n", milliseconds);
#endif
#ifdef DEBUG
	int *h_binsize;// For debug
	h_binsize     = (int*)malloc(numbins[0]*numbins[1]*sizeof(int));
	checkCudaErrors(cudaMemcpy(h_binsize,d_binsize,numbins[0]*numbins[1]*sizeof(int),
				cudaMemcpyDeviceToHost));
	cout<<"[debug ] bin size:"<<endl;
	for(int j=0; j<numbins[1]; j++){
		cout<<"[debug ] ";
		for(int i=0; i<numbins[0]; i++){
			if(i!=0) cout<<" ";
			cout <<" bin["<<setw(3)<<i<<","<<setw(3)<<j<<"]="<<h_binsize[i+j*numbins[0]];
		}
		cout<<endl;
	}
	free(h_binsize);
	cout<<"[debug ] --------------------------------------------------------------"<<endl;
#endif

	cudaEventRecord(start);
	int n=numbins[0]*numbins[1];
	size_t temp_storage_bytes = 0;
	CubDebugExit(cub::DeviceScan::ExclusiveSum(d_temp_storage, temp_storage_bytes, d_binsize, d_binstartpts, n));
	checkCudaErrors(cudaMalloc(&d_temp_storage, temp_storage_bytes)); // Allocate temporary storage for inclusive prefix scan
	CubDebugExit(cub::DeviceScan::ExclusiveSum(d_temp_storage, temp_storage_bytes, d_binsize, d_binstartpts, n));
#ifdef SPREADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel BinStartPts_2d \t\t\t%.3g ms\n", milliseconds);
#endif

#ifdef DEBUG
	int *h_binstartpts;
	h_binstartpts = (int*)malloc((numbins[0]*numbins[1])*sizeof(int));
	checkCudaErrors(cudaMemcpy(h_binstartpts,d_binstartpts,(numbins[0]*numbins[1])*sizeof(int),
				cudaMemcpyDeviceToHost));
	cout<<"[debug ] Result of scan bin_size array:"<<endl;
	for(int j=0; j<numbins[1]; j++){
		cout<<"[debug ] ";
		for(int i=0; i<numbins[0]; i++){
			if(i!=0) cout<<" ";
			cout <<"bin["<<setw(3)<<i<<","<<setw(3)<<j<<"] = "<<setw(2)<<h_binstartpts[i+j*numbins[0]];
		}
		cout<<endl;
	}
	free(h_binstartpts);
	cout<<"[debug ] --------------------------------------------------------------"<<endl;
#endif

	cudaEventRecord(start);
	CalcInvertofGlobalSortIdx_2d<<<(M+1024-1)/1024,1024>>>(M,bin_size_x,bin_size_y,numbins[0],
			numbins[1],d_binstartpts,d_sortidx,
			d_kx,d_ky,d_idxnupts);
#ifdef DEBUG
	int *h_idxnupts;
	h_idxnupts = (int*)malloc(M*sizeof(int));
	checkCudaErrors(cudaMemcpy(h_idxnupts,d_idxnupts,M*sizeof(int),cudaMemcpyDeviceToHost));
	for (int i=0; i<M; i++){
		cout <<"[debug ] idx="<< h_idxnupts[i]<<endl;
	}
	free(h_idxnupts);
#endif
#ifdef SPREADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel CalcInvertofGlobalSortIdx_2d \t%.3g ms\n", milliseconds);
#endif

	/* --------------------------------------------- */
	//        Determining Subproblem properties      //
	/* --------------------------------------------- */
	cudaEventRecord(start);
	CalcSubProb_2d<<<(M+1024-1)/1024, 1024>>>(d_binsize,d_numsubprob,maxsubprobsize,numbins[0]*numbins[1]);
#ifdef DEBUG
	int* h_numsubprob;
	h_numsubprob = (int*) malloc(n*sizeof(int));
	checkCudaErrors(cudaMemcpy(h_numsubprob,d_numsubprob,numbins[0]*numbins[1]*sizeof(int),
				cudaMemcpyDeviceToHost));
	for(int j=0; j<numbins[1]; j++){
		cout<<"[debug ] ";
		for(int i=0; i<numbins[0]; i++){
			if(i!=0) cout<<" ";
			cout <<"nsub["<<setw(3)<<i<<","<<setw(3)<<j<<"] = "<<setw(2)<<h_numsubprob[i+j*numbins[0]];
		}
		cout<<endl;
	}
	free(h_numsubprob);
#endif
	// Scanning the same length array, so we don't need calculate temp_storage_bytes here
	CubDebugExit(cub::DeviceScan::InclusiveSum(d_temp_storage, temp_storage_bytes, d_numsubprob, d_subprobstartpts+1, n));
	checkCudaErrors(cudaMemset(d_subprobstartpts,0,sizeof(int)));

#ifdef DEBUG
	printf("[debug ] Subproblem start points\n");
	int* h_subprobstartpts;
	h_subprobstartpts = (int*) malloc((n+1)*sizeof(int));
	checkCudaErrors(cudaMemcpy(h_subprobstartpts,d_subprobstartpts,(n+1)*sizeof(int),
				cudaMemcpyDeviceToHost));
	for(int j=0; j<numbins[1]; j++){
		cout<<"[debug ] ";
		for(int i=0; i<numbins[0]; i++){
			if(i!=0) cout<<" ";
			cout <<"nsub["<<setw(3)<<i<<","<<setw(3)<<j<<"] = "<<setw(2)<<h_subprobstartpts[i+j*numbins[0]];
		}
		cout<<endl;
	}
	printf("[debug ] Total number of subproblems = %d\n", h_subprobstartpts[n]);
	free(h_subprobstartpts);
#endif

	int totalnumsubprob;
	checkCudaErrors(cudaMemcpy(&totalnumsubprob,&d_subprobstartpts[n],sizeof(int),
				cudaMemcpyDeviceToHost));
	checkCudaErrors(cudaMalloc(&d_subprob_to_bin,totalnumsubprob*sizeof(int)));
	MapBintoSubProb_2d<<<(numbins[0]*numbins[1]+1024-1)/1024, 1024>>>(d_subprob_to_bin, 
			d_subprobstartpts,
			d_numsubprob,
			numbins[0]*numbins[1]);
#ifdef DEBUG
	printf("[debug ] Map Subproblem to Bins\n");
	int* h_subprob_to_bin;
	h_subprob_to_bin = (int*) malloc((totalnumsubprob)*sizeof(int));
	checkCudaErrors(cudaMemcpy(h_subprob_to_bin,d_subprob_to_bin,(totalnumsubprob)*sizeof(int),
				cudaMemcpyDeviceToHost));
	for(int j=0; j<totalnumsubprob; j++){
		cout<<"[debug ] ";
		cout <<"nsub["<<j<<"] = "<<setw(2)<<h_subprob_to_bin[j];
		cout<<endl;
	}
	free(h_subprob_to_bin);
#endif
#ifdef SPREADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel Subproblem to Bin map\t\t%.3g ms\n", milliseconds);
#endif
	FLT sigma=opts.upsampfac;
	cudaEventRecord(start);
	size_t sharedplanorysize = (bin_size_x+2*ceil(ns/2.0))*(bin_size_y+2*ceil(ns/2.0))*sizeof(CUCPX);
	if(sharedplanorysize > 49152){
		cout<<"error: not enough shared memory"<<endl;
		return 1;
	}

	Spread_2d_Subprob<<<totalnumsubprob, 256, sharedplanorysize>>>(d_kx, d_ky, d_c,
			d_fw, M, ns, nf1, nf2,
			es_c, es_beta, sigma, fw_width,
			d_binstartpts, d_binsize,
			bin_size_x, bin_size_y,
			d_subprob_to_bin, d_subprobstartpts,
			d_numsubprob, maxsubprobsize,
			numbins[0], numbins[1], d_idxnupts);
#ifdef SPREADTIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tKernel Spread_2d_Subprob_V2 \t\t%.3g ms\n", milliseconds);
#endif
	return 0;
}

int setup_cuspreader(spread_opts &opts,FLT eps,FLT upsampfac)
{
	// defaults... (user can change after this function called)
	opts.pirange = 1;             // user also should always set this
	opts.upsampfac = upsampfac;

	// for gpu
	opts.method = 5;
	opts.bin_size_x = 32;
	opts.bin_size_y = 32;
	opts.Horner = 0;
	opts.maxsubprobsize = 1000;
	opts.nthread_x = 16;
	opts.nthread_y = 16;

	// Set kernel width w (aka ns) and ES kernel beta parameter, in opts...
	int ns = std::ceil(-log10(eps/10.0));   // 1 digit per power of ten
	if (upsampfac!=2.0)           // override ns for custom sigma
		ns = std::ceil(-log(eps) / (PI*sqrt(1-1/upsampfac)));  // formula, gamma=1
	ns = max(2,ns);               // we don't have ns=1 version yet
	if (ns>MAX_NSPREAD) {         // clip to match allocated arrays
		fprintf(stderr,"setup_spreader: warning, kernel width ns=%d was clipped to max %d; will not match tolerance!\n",ns,MAX_NSPREAD);
		ns = MAX_NSPREAD;
	}
	opts.nspread = ns;
	opts.ES_halfwidth=(FLT)ns/2;   // constants to help ker eval (except Horner)
	opts.ES_c = 4.0/(FLT)(ns*ns);

	FLT betaoverns = 2.30;         // gives decent betas for default sigma=2.0
	if (ns==2) betaoverns = 2.20;  // some small-width tweaks...
	if (ns==3) betaoverns = 2.26;
	if (ns==4) betaoverns = 2.38;
	if (upsampfac!=2.0) {          // again, override beta for custom sigma
		FLT gamma=0.97;              // must match devel/gen_all_horner_C_code.m
		betaoverns = gamma*PI*(1-1/(2*upsampfac));  // formula based on cutoff
	}
	opts.ES_beta = betaoverns * (FLT)ns;    // set the kernel beta parameter
	//fprintf(stderr,"setup_spreader: sigma=%.6f, chose ns=%d beta=%.6f\n",(double)upsampfac,ns,(double)opts.ES_beta); // user hasn't set debug yet
	return 0;

}
