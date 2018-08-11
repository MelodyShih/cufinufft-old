#include "cufinufft.h"

int cufinufft_default_opts(cufinufft_opts &opts,FLT eps,FLT upsampfac)
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
	opts.spreadonly = 0;

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