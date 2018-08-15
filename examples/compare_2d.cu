#include <iostream>
#include <iomanip>
#include <math.h>
#include <helper_cuda.h>
#include <complex>
#include "../src/spreadinterp.h"
#include "../src/memtransfer.h"
#include "../finufft/utils.h"

using namespace std;

int main(int argc, char* argv[])
{
	int nf1, nf2;
	FLT sigma = 2.0;
	int N1, N2, M;
	if (argc<5) {
		fprintf(stderr,"Usage: compare [method [nupts_dis [nf1 nf2 [M [tol]]]]]\n");
		fprintf(stderr,"Details --\n");
		fprintf(stderr,"method 1: input driven without sorting\n");
		fprintf(stderr,"method 2: input driven with sorting\n");
		fprintf(stderr,"method 4: hybrid\n");
		fprintf(stderr,"method 5: subprob\n");
		return 1;
	}  
	double w;
	int method, nupts_distribute;
	sscanf(argv[1],"%d",&method);
	sscanf(argv[2],"%d",&nupts_distribute);
	sscanf(argv[3],"%lf",&w); nf1 = (int)w;  // so can read 1e6 right!
	sscanf(argv[4],"%lf",&w); nf2 = (int)w;  // so can read 1e6 right!

	N1 = (int) nf1/sigma;
	N2 = (int) nf2/sigma;
	M = N1*N2;// let density always be 1
	if(argc>5){
		sscanf(argv[5],"%lf",&w); M  = (int)w;  // so can read 1e6 right!
		if(M==0.0){
			M = N1*N2;
		}
	}

	FLT tol=1e-6;
	if(argc>6){
		sscanf(argv[6],"%lf",&w); tol  = (FLT)w;  // so can read 1e6 right!
	}

	int ier;
	int ns=std::ceil(-log10(tol/10.0));
	cufinufft_opts opts;
	FLT upsampfac=2.0;
	ier = cufinufft_default_opts(opts,tol,upsampfac);
        if(ier != 0 ){
                cout<<"error: cufinufft_default_opts"<<endl;
                return 0;
        }
	opts.method=method;

	cufinufft_plan dplan;
	cout<<scientific<<setprecision(3);


	FLT *x, *y;
	CPX *c, *fw;
	cudaMallocHost(&x, M*sizeof(CPX));
	cudaMallocHost(&y, M*sizeof(CPX));
	cudaMallocHost(&c, M*sizeof(CPX));
	cudaMallocHost(&fw,nf1*nf2*sizeof(CPX));

	dplan.ms = N1;
	dplan.mt = N2;
	dplan.nf1 = nf1;
	dplan.nf2 = nf2;
	dplan.M = M;
	dplan.h_kx = x;
	dplan.h_ky = y;
	dplan.h_c = c;
	dplan.h_fw = fw;
	dplan.h_fwkerhalf1 = NULL;
	dplan.h_fwkerhalf2 = NULL;

	opts.pirange=0;
	switch(nupts_distribute){
		// Making data
		case 1: //uniform
			{
				for (int i = 0; i < M; i++) {
					x[i] = RESCALE(M_PI*randm11(), nf1, 1);// x in [-pi,pi)
					y[i] = RESCALE(M_PI*randm11(), nf2, 1);
					c[i].real() = randm11();
					c[i].imag() = randm11();
				}
			}
			break;
		case 2: // concentrate on a small region
			{
				printf("nonuniform case\n");
				for (int i = 0; i < M; i++) {
					x[i] = RESCALE(M_PI*rand01()/(nf1*2/32), nf1, 1);// x in [-pi,pi)
					y[i] = RESCALE(M_PI*rand01()/(nf2*2/32), nf2, 1);
					c[i].real() = randm11();
					c[i].imag() = randm11();
				}
			}
			break;
	}
	cudaEvent_t start, stop;
	float milliseconds;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

#ifdef INFO
	cout<<"[info  ] Spreading "<<M<<" pts to ["<<nf1<<"x"<<nf2<<"] uniform grids"<<endl;
#endif

	char *a;
	cudaEventRecord(start);
	checkCudaErrors(cudaMalloc(&a,1));
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] (warm up) First cudamalloc call \t %.3g ms\n", milliseconds);
	switch(opts.method)
	{
		case 2:
		{
			opts.bin_size_x=16;
			opts.bin_size_y=16;
		}
		break;
		case 4:
		{
			opts.bin_size_x=32;
			opts.bin_size_y=32;
		}
		break;
		case 5:
		{
			opts.bin_size_x=32;
			opts.bin_size_y=32;
		}
		break;
	}

	cudaEventRecord(start);
	ier = allocgpumemory(opts, &dplan);
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] Allocate GPU memory\t %.3g ms\n", milliseconds);

	cudaEventRecord(start);
	ier = copycpumem_to_gpumem(opts, &dplan);
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] Copy memory HtoD\t %.3g ms\n", milliseconds);

	ier = cuspread2d(opts, &dplan);
	if(ier != 0 ){
		cout<<"error: cuspread2d, method("<<opts.method<<")"<<endl;
		return 0;
	}
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] Spread (%d)\t\t %.3g ms\n", opts.method, milliseconds);

	cudaEventRecord(start);
	ier = copygpumem_to_cpumem_fw(&dplan);
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] Copy memory DtoH\t %.3g ms\n", milliseconds);

	cudaEventRecord(start);
	free_gpumemory(opts, &dplan);
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] Free GPU memory\t %.3g ms\n", milliseconds);

#ifdef RESULT
	switch(method)
	{
		case 2:
			opts.bin_size_x=16;
			opts.bin_size_y=16;
		case 4:
			opts.bin_size_x=32;
			opts.bin_size_y=32;
		case 5:
			opts.bin_size_x=32;
			opts.bin_size_y=32;
		default:
			opts.bin_size_x=nf1;
			opts.bin_size_y=nf2;
	}
	cout<<"[result-input]"<<endl;
	for(int j=0; j<nf2; j++){
		if( j % opts.bin_size_y == 0)
			printf("\n");
		for (int i=0; i<nf1; i++){
			if( i % opts.bin_size_x == 0 && i!=0)
				printf(" |");
			printf(" (%2.3g,%2.3g)",fw[i+j*nf1].real(),fw[i+j*nf1].imag() );
		}
		cout<<endl;
	}
	cout<<endl;
#endif

	cudaFreeHost(x);
	cudaFreeHost(y);
	cudaFreeHost(c);
	cudaFreeHost(fw);
	return 0;
}
