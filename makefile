CC=gcc
CXX=g++
NVCC=nvcc
CXXFLAGS=-DNEED_EXTERN_C -fPIC -Ofast -funroll-loops -march=native -g
#NVCCFLAGS=-DINFO -DDEBUG -DRESULT -DTIME
NVCCFLAGS=-arch=sm_50 -DTIME
INC=-I/mnt/xfs1/flatiron-sw/pkg/devel/cuda/8.0.61/samples/common/inc/ \
    -I/mnt/home/yshih/cub/ \
    -I/mnt/xfs1/flatiron-sw/pkg/devel/cuda/8.0.61/include/
LIBS_PATH=
LIBS=-lm -lfftw3 -lcudart -lstdc++
LIBS_CUFINUFFT=-lcufft

-include make.inc

%.o: %.cpp
	$(CXX) -c $(CXXFLAGS) $(INC) $< -o $@
%.o: %.cu
	$(NVCC) -c $(NVCCFLAGS) $(INC) $< -o $@

spread2d: examples/main_2d.o src/spread2d_wrapper.o src/spread2d.o src/finufft/utils.o src/memtransfer_wrapper.o
	$(NVCC) $(NVCCFLAGS) -o $@ $^

interp2d: examples/interp_2d.o src/spread2d_wrapper.o src/spread2d.o src/interp2d_wrapper.o src/interp2d.o \
          src/finufft/utils.o src/memtransfer_wrapper.o
	$(NVCC) $(NVCCFLAGS) -o $@ $^

compare: examples/compare_2d.o src/spread2d_wrapper.o src/spread2d.o src/finufft/utils.o src/memtransfer_wrapper.o
	$(NVCC) $(NVCCFLAGS) -o $@ $^

accuracy: test/accuracycheck_2d.o src/spread2d_wrapper.o src/spread2d.o src/finufft/utils.o \
          src/finufft/cnufftspread.o src/memtransfer_wrapper.o src/interp2d_wrapper.o src/interp2d.o
	$(NVCC) $(NVCCFLAGS) -o $@ $^

finufft2d_test: test/finufft2d_test.o src/finufft/finufft2d.o src/finufft/utils.o src/finufft/cnufftspread.o \
                src/finufft/dirft2d.o src/finufft/common.o \
                src/finufft/contrib/legendre_rule_fast.o src/spread2d_wrapper.o src/spread2d.o \
                src/cufinufft2d.o src/deconvolve_wrapper.o src/memtransfer_wrapper.o \
                src/interp2d_wrapper.o src/interp2d.o
	$(CXX) $^ $(LIBS_PATH) $(LIBS) $(LIBS_CUFINUFFT) -o $@

cufinufft2d1_test: examples/cufinufft2d1_test.o src/finufft/utils.o src/finufft/dirft2d.o src/finufft/common.o \
                   src/finufft/cnufftspread.o src/finufft/contrib/legendre_rule_fast.o src/spread2d_wrapper.o src/spread2d.o \
                   src/cufinufft2d.o src/deconvolve_wrapper.o src/memtransfer_wrapper.o
	$(NVCC) $^ $(NVCCFLAGS) $(LIBS_PATH) $(LIBS) $(LIBS_CUFINUFFT) -o $@

cufinufft2d2_test: examples/cufinufft2d2_test.o src/finufft/utils.o src/finufft/dirft2d.o src/finufft/common.o \
                   src/finufft/cnufftspread.o src/finufft/contrib/legendre_rule_fast.o src/spread2d_wrapper.o src/spread2d.o \
                   src/cufinufft2d.o src/deconvolve_wrapper.o src/memtransfer_wrapper.o src/interp2d_wrapper.o src/interp2d.o
	$(NVCC) $^ $(NVCCFLAGS) $(LIBS_PATH) $(LIBS) $(LIBS_CUFINUFFT) -o $@
all: spread2d interp2d compare accuracy finufft2d_test cufinufft2d1_test cufinufft2d2_test
clean:
	rm -f *.o
	rm -f examples/*.o
	rm -f src/*.o
	rm -f src/finufft/*.o
	rm -f src/finufft/contrib/*.o
	rm -f spread2d
	rm -f accuracy
	rm -f compare
	rm -f finufft2d_test
	rm -f cufinufft2d_test

