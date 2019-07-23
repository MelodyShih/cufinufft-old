#include <iostream>
#include <iomanip>
#include <math.h>
#include <helper_cuda.h>
#include <complex>

#include "../src/spreadinterp.h"
#include "../src/cufinufft.h"
#include "../finufft/utils.h"

using namespace std;

int main(int argc, char* argv[])
{
	FLT sigma = 2.0;
	int N1, N2, N3, M, N;
	int ntransf=1;
	if (argc<4) {
		fprintf(stderr,"Usage: cufinufft3d1_test [method [N1 N2 N3 [M [tol]]]]\n");
		fprintf(stderr,"Details --\n");
		fprintf(stderr,"method 1: input driven without sorting\n");
		fprintf(stderr,"method 2: input driven with sorting\n");
		fprintf(stderr,"method 4: hybrid\n");
		fprintf(stderr,"method 5: subprob\n");
		return 1;
	}  
	double w;
	int method;
	sscanf(argv[1],"%d",&method);
	sscanf(argv[2],"%lf",&w); N1 = (int)w;  // so can read 1e6 right!
	sscanf(argv[3],"%lf",&w); N2 = (int)w;  // so can read 1e6 right!
	sscanf(argv[4],"%lf",&w); N3 = (int)w;  // so can read 1e6 right!
	
	M = N1*N2*N3;// let density always be 1
	if(argc>5){
		sscanf(argv[5],"%lf",&w); M  = (int)w;  // so can read 1e6 right!
	}

	FLT tol=1e-6;
	if(argc>6){
		sscanf(argv[6],"%lf",&w); tol  = (FLT)w;  // so can read 1e6 right!
	}
	int iflag=1;


	cout<<scientific<<setprecision(3);
	int ier;


	FLT *x, *y, *z;
	CPX *c, *fk;
	cudaMallocHost(&x, M*sizeof(FLT));
	cudaMallocHost(&y, M*sizeof(FLT));
	cudaMallocHost(&z, M*sizeof(FLT));
	cudaMallocHost(&c, M*sizeof(CPX));
	cudaMallocHost(&fk,N1*N2*N3*sizeof(CPX));

	// Making data
	for (int i = 0; i < M; i++) {
		x[i] = M_PI*randm11();// x in [-pi,pi)
		y[i] = M_PI*randm11();
		z[i] = M_PI*randm11();
		c[i].real() = randm11();
		c[i].imag() = randm11();
	}

	cudaEvent_t start, stop;
	float milliseconds = 0;
	float totaltime = 0;
	cudaEventCreate(&start);
	cudaEventCreate(&stop);

	/*warm up gpu*/
	cudaEventRecord(start);
	char *a;
	checkCudaErrors(cudaMalloc(&a,1));
#ifdef TIME
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	printf("[time  ] \tWarm up GPU \t\t %.3g s\n", milliseconds/1000);
#endif

	cufinufft_plan dplan;
	cufinufft_opts opts;
	ier=cufinufft_default_opts(opts,tol,sigma);
	opts.method=method;

	cudaEventRecord(start);
	ier=cufinufft3d_plan(M, N1, N2, N3, ntransf, ntransf, iflag, opts, &dplan);
	if (ier!=0){
		printf("err: cufinufft2d_plan\n");
	}
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	totaltime += milliseconds;
	printf("[time  ] cufinufft plan:\t\t %.3g s\n", milliseconds/1000);

	cudaEventRecord(start);
	ier=cufinufft3d_setNUpts(x, y, z, opts, &dplan);
	if (ier!=0){
		printf("err: cufinufft3d_setNUpts\n");
	}
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	totaltime += milliseconds;
	printf("[time  ] cufinufft setNUpts:\t\t %.3g s\n", milliseconds/1000);

	cudaEventRecord(start);
	ier=cufinufft3d1_exec(c, fk, opts, &dplan);
	if (ier!=0){
		printf("err: cufinufft3d1_exec\n");
	}
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	totaltime += milliseconds;
	printf("[time  ] cufinufft exec:\t\t %.3g s\n", milliseconds/1000);

	cudaEventRecord(start);
	ier=cufinufft3d_destroy(opts, &dplan);
	cudaEventRecord(stop);
	cudaEventSynchronize(stop);
	cudaEventElapsedTime(&milliseconds, start, stop);
	totaltime += milliseconds;
	printf("[time  ] cufinufft destroy:\t\t %.3g s\n", milliseconds/1000);

	printf("[Method %d] %ld NU pts to #%d U pts in %.3g s (\t%.3g NU pts/s)\n",
			opts.method,M,N1*N2*N3,totaltime/1000,M/totaltime*1000);
	int nt1 = (int)(0.37*N1), nt2 = (int)(0.26*N2), nt3 = (int) (0.13*N3);  // choose some mode index to check
	CPX Ft = CPX(0,0), J = IMA*(FLT)iflag;
	for (BIGINT j=0; j<M; ++j)
		Ft += c[j] * exp(J*(nt1*x[j]+nt2*y[j]+nt3*z[j]));   // crude direct
	int it = N1/2+nt1 + N1*(N2/2+nt2) + N1*N2*(N3/2+nt3);   // index in complex F as 1d array
	N = N1*N2*N3;
	printf("[gpu   ] one mode: abs err in F[%ld,%ld,%ld] is %.3g\n",(int)nt1,(int)nt2, (int)nt3, (abs(Ft-fk[it])));
	printf("[gpu   ] one mode: rel err in F[%ld,%ld,%ld] is %.3g\n",(int)nt1,(int)nt2, (int)nt3, abs(Ft-fk[it])/infnorm(N,fk));
#if 0
	cout<<"[result-input]"<<endl;
	for(int j=0; j<nf2; j++){
		//        if( j % opts.bin_size_y == 0)
		//                printf("\n");
		for (int i=0; i<nf1; i++){
			//                if( i % opts.bin_size_x == 0 && i!=0)
			//                        printf(" |");
			printf(" (%2.3g,%2.3g)",fw[i+j*nf1].real(),fw[i+j*nf1].imag() );
		}
		cout<<endl;
	}
#endif	
	cudaFreeHost(x);
	cudaFreeHost(y);
	cudaFreeHost(c);
	cudaFreeHost(fk);
	return 0;
}