# GPUnufftSpreader

This is an implementation of nufft spreader on GPU.

### Usage on ccblin019

```
  module load cuda
  make spread1d
  ./spread1d
``` 
### To-do List
 - Make both input/output algorithms works for large N1, N2, M
#### 2018/06/29
 - Finish 1D dir=1
#### 2018/07/02 
 - Finish 2D dir=1
 - Add timing codes for comparison
#### 2018/07/05
 - Add input driven algorithm (this is also what've been done in cunfft)
