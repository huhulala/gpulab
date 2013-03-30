/****************************************************************************\
*      --- Practical Course: GPU Programming in Computer Vision ---
*
* time:    winter term 2012/13 / March 11-18, 2013
*
* project: superresolution
* file:    superresolution.cu
*
*
* implement all functions with ### implement me ### in the function body
\****************************************************************************/

/*
 * superresolution.cu
 *
 *  Created on: May 16, 2012
 *      Author: steinbrf
 */
#include "superresolution.cuh"
#include <stdio.h>
//#include <cutil.h>
//#include <cutil_inline.h>
#include <auxiliary/cuda_basic.cuh>
#include <vector>
#include <list>

//#include <linearoperations.cuh>
#include <linearoperations/linearoperations.cuh>

#include "superresolution_definitions.h"

#include <auxiliary/debug.hpp>

#ifdef DGT400
#define SR_BW 32
#define SR_BH 16
#else
#define SR_BW 16
#define SR_BH 16
#endif

//shared mem flags
#define SHARED_MEM 0
#define GAUSS_TEXTURE_MEM 1

#include <linearoperations/linearoperations.h>

//TODO where the heck should this used
extern __shared__ float smem[];

//TODO write comment
// global memory version of dualL1Difference
__global__ void dualL1Difference_gm
(
	const float *primal,
	const float *constant,
	float *dual,
	int nx,
	int ny,
	int pitch,
	float factor_update,
	float factor_clipping,
	float huber_denom,
	float tau_d
)
{
	const int x = threadIdx.x + blockDim.x * blockIdx.x;
	const int y = threadIdx.y + blockDim.y * blockIdx.y;
	
	if (x < nx && y < ny)
	{
		int idx = x + pitch * y;
		dual[idx] = (dual[idx] + tau_d * factor_update * (primal[idx] - constant[idx])) / huber_denom;
		
		if (dual[idx] < -factor_clipping)
		{
			dual[idx] = -factor_clipping;
		}

		if (dual[idx] > factor_clipping)
		{
			dual[idx] = factor_clipping;
		}
	}
}

//TODO write comment
// shared memory version of dualL1Difference
__global__ void dualL1Difference_sm
	(
		const float *primal,
		const float *constant,
		float *dual,
		int nx,
		int ny,
		int pitch,
		float factor_update,
		float factor_clipping,
		float huber_denom,
		float tau_d
    )
{
	const int x = threadIdx.x + blockDim.x * blockIdx.x;
	const int y = threadIdx.y + blockDim.y * blockIdx.y;
	
	const int tx = threadIdx.x;
	const int ty = threadIdx.y;
	
	__shared__ float s_dual		[SR_BW][SR_BH];
	__shared__ float s_primal	[SR_BW][SR_BH];
	__shared__ float s_constant	[SR_BW][SR_BH];
	
	int idx = y * pitch + x;
	
	// loading the data in shared memory
	if (x < nx && y < ny)//guards
	{	
		if( tx < SR_BW && ty < SR_BH )
		{
			s_dual		[tx][ty] = dual		[idx];
			s_primal	[tx][ty] = primal	[idx];
			s_constant	[tx][ty] = constant	[idx];
		}
	}
	
	__syncthreads();
	
	if( x < nx && y < ny )//guards
	{
		// compute
		s_dual[tx][ty] =(s_dual[tx][ty] + tau_d * factor_update * 
						( s_primal[tx][ty] - s_constant[tx][ty])) / huber_denom;
		
		if( s_dual[tx][ty] < -factor_clipping)
		{
			dual[idx] = -factor_clipping;
		}
		else if ( s_dual[tx][ty] > factor_clipping)
		{
			dual[idx] = factor_clipping;
		}
		else
		{
			dual[idx] = s_dual[tx][ty];
		}
	}
}

//TODO write comment
// global memory version of primal1N
__global__ void primal1N_gm
	(
		const float *xi1,
		const float *xi2,
		const float *degraded,
		float *u,
		float *uor,
		int nx,
		int ny,
		int pitch,
		float factor_tv_update,
		float factor_degrade_update,
		float tau_p,
		float overrelaxation
	)
{
  const int x = threadIdx.x + blockDim.x * blockIdx.x;
  const int y = threadIdx.y + blockDim.y * blockIdx.y;

	if( x < nx && y < ny )
	{
		const int idx = y * pitch + x;

		float u_old = u[idx];
		
		float u_new = u[idx] + tau_p *
			(
				factor_tv_update *
				(xi1[idx] - ( x == 0 ? 0.0f : xi1[idx - 1] ) + xi2[idx] - ( y == 0 ? 0.0f : xi2[idx - pitch] )) - 
				factor_degrade_update * degraded[idx]
			);

		// write back to output image
		u[idx] = u_new;
		uor[idx] = overrelaxation * u_new + (1.0f - overrelaxation) * u_old;
	}
}

__global__ void primal1N_sm
	(
		const float *xi1,
		const float *xi2,
		const float *degraded,
		float *u,
		float *uor,
		int nx,
		int ny,
		int pitch,
		float factor_tv_update,
		float factor_degrade_update,
		float tau_p,
		float overrelaxation
    )
{
	const int x = threadIdx.x + blockDim.x * blockIdx.x;
	const int y = threadIdx.y + blockDim.y * blockIdx.y;

	if (x < nx && y < ny)
	{
		//TODO implement me
	}
}

//TODO write comment
// global memory version of primal1N
__global__ void dualTVHuber_gm
	(
		float 	*uor_g,								// Field of overrelaxed primal variables
		float 	*xi1_g, 							// Dual Variable for TV regularization in X direction
		float 	*xi2_g,								// Dual Variable for TV regularization in Y direction
		int   	nx,									// New High-Resolution Width
		int   	ny,									// New High-Resolution Height
		int   	pitchf1,							// GPU pitch (padded width) of the superresolution high-res fields
		float   factor_update,
		float   factor_clipping,
		float   huber_denom,
		float   tau_d
	)
{
	int x = threadIdx.x + blockIdx.x * blockDim.x;
	int y = threadIdx.y + blockIdx.y * blockDim.y;
	
	if( x < nx && y < ny ) // guards
	{
		//DONT FORGET TO USE THE PITCH
		
		int x1 = x + 1;
		if( x1 >= nx ){	x1 = nx-1; }	// at x boundary
		
		int y1 = y+1; 
		if( y1 >= ny ){ y1 = ny-1; }	// at y boundary
		
		// do xi1_g, xi2_g & uor_g have same pitch ? confirm - YES
	
		const int p = y * pitchf1 + x;
		
		float dx = (xi1_g[p] + tau_d * factor_update * (uor_g[y*pitchf1+x1] - uor_g[p])) / huber_denom;
		float dy = (xi2_g[p] + tau_d * factor_update * (uor_g[y1*pitchf1+x] - uor_g[p])) / huber_denom;
		float denom = sqrtf( dx * dx + dy * dy ) / factor_clipping;
		
		if(denom < 1.0f) denom = 1.0f;
		xi1_g[p] = dx / denom;
		xi2_g[p] = dy / denom;
	}
}

//TODO write comment
// shared memory version of primal1N
__global__ void dualTVHuber_sm
(
		float 	*uor_g,								// Field of overrelaxed primal variables
		float 	*xi1_g, 							// Dual Variable for TV regularization in X direction
		float 	*xi2_g,								// Dual Variable for TV regularization in Y direction
		int   	nx,									// New High-Resolution Width
		int   	ny,									// New High-Resolution Height
		int   	pitchf1,							// GPU pitch (padded width) of the superresolution high-res fields
		float   factor_update,
		float   factor_clipping,
		float   huber_denom,
		float   tau_d
)
{
	int x = threadIdx.x + blockIdx.x * blockDim.x;
	int y = threadIdx.y + blockIdx.y * blockDim.y;
	
	int tx = threadIdx.x;
	int ty = threadIdx.y;
	
	__shared__ float xi1[SR_BW][SR_BH];
	__shared__ float xi2[SR_BW][SR_BH];
	__shared__ float uor[SR_BW+1][SR_BH+1];
	
	int idx = y * pitchf1 + x;

	// load data into shared memory
	if( x < nx && y < ny ) // guards
	{
		if( tx < SR_BW && ty < SR_BH )
		{
			xi1[tx][ty] = xi1_g[idx];
			xi2[tx][ty] = xi2_g[idx];
			uor[tx][ty] = uor_g[idx];
		}
		
		if( x == nx -1 )
		{
			uor[tx+1][ty] = uor[tx][ty];
		}
		else if( threadIdx.x == SR_BW - 1 )
		{
			uor[tx+1][ty] = uor_g[idx+1];
		}
		
		if( y == ny -1 )
		{
			uor[tx][ty+1] = uor[tx][ty];
		}
		else if( threadIdx.y == SR_BH -1 )
		{
			uor[tx][ty+1] = uor_g[idx+pitchf1];
		}
	}
	
	__syncthreads();
	
	if(x < nx && y < ny)// guards
	{
		// compute
		float dx = (xi1[tx][ty] + tau_d * factor_update * (uor[tx+1][ty] - uor[tx][ty])) / huber_denom;
		float dy = (xi2[tx][ty] + tau_d * factor_update * (uor[tx][ty+1] - uor[tx][ty])) / huber_denom;
		
		float denom = sqrtf( dx * dx + dy * dy ) / factor_clipping;
		
		if(denom < 1.0f) denom = 1.0f;
		xi1_g[idx] = dx / denom;
		xi2_g[idx] = dy / denom;
	}
}

void computeSuperresolutionUngerGPU
(
		float *xi1_g, 							// Dual Variable for TV regularization in X direction
		float *xi2_g,							// Dual Variable for TV regularization in Y direction
		float *temp1_g,							// Helper array
		float *temp2_g,
		float *temp3_g,
		float *temp4_g,
		float *uor_g,							// Field of overrelaxed primal variables
		float *u_g,								// GPU memory for the result image
		std::vector<float*> &q_g,				// Dual variables for L1 difference penalization
		std::vector<float*> &images_g,			// Dual variables for L1 difference penalization
		std::list<FlowGPU> &flowsGPU,			// GPU memory for the displacement fields
												//   class FlowGPU { void clear(); float *u_g; float *v_g; int nx; int ny; }
		int   &nx,								// New High-Resolution Width
		int   &ny,								// New High-Resolution Height
		int   &pitchf1,							// GPU pitch (padded width) of the superresolution high-res fields
		int   &nx_orig,							// Original Low-Resolution Width
		int   &ny_orig,							// Original Low-Resolution Height
		int   &pitchf1_orig,					// GPU pitch (padded width) of the original low-res images
		int   &oi,								// Number of Iterations
		float &tau_p,							// Primal Update Step Size
		float &tau_d,							// Dual Update Step Size
		float &factor_tv,						// The weight of Total Variation Penalization
		float &huber_epsilon,					// Parameter for Huber norm regularization
		float &factor_rescale_x,				// High-Resolution Width divided by Low-Resolution Width
		float &factor_rescale_y,				// High-Resolution Height divided by Low-Resolution Height
		float &blur,							// The amount of Gaussian Blur present in the degrading process
		float &overrelaxation,					// Overrelaxation parameter in the range of [1,2]
		int   debug								// Debug Flag, if activated the class produces Debug output.
)
{
	// replacing u by u_g ( pointer to resultant data)

	// grid and block dimensions
	int gridsize_x = ((nx - 1) / SR_BW) + 1;
	int gridsize_y = ((ny - 1) / SR_BH) + 1;
	dim3 dimGrid ( gridsize_x, gridsize_y );
	dim3 dimBlock ( SR_BW, SR_BH );

	// initialise xi1_g and xi2_g to zero
	setKernel <<<dimGrid, dimBlock>>>( xi1_g, nx, ny, pitchf1, 0.0f );
	setKernel <<<dimGrid, dimBlock>>>( xi2_g, nx, ny, pitchf1, 0.0f );
	
	// initialise u_g and uor_g to 64.0f
	setKernel <<<dimGrid, dimBlock>>>( u_g,   nx, ny, pitchf1, 64.0f );
	setKernel <<<dimGrid, dimBlock>>>( uor_g, nx, ny, pitchf1, 64.0f );
	
	// initialise all elements of q_g to zero
	for(unsigned int k = 0; k < q_g.size(); k++ )
	{
		setKernel <<<dimGrid, dimBlock>>>( q_g[k], nx_orig, ny_orig, pitchf1_orig, 0.0f );
	}
	
	float factorquad              = factor_rescale_x * factor_rescale_x * factor_rescale_y * factor_rescale_y;
	float factor_degrade_update   = pow( factorquad, CLIPPING_TRADEOFF_DEGRADE_1N );
	
	float factor_degrade_clipping = factorquad / factor_degrade_update;
	float huber_denom_degrade     = 1.0f + huber_epsilon * tau_d / factor_degrade_clipping;

	float factor_tv_update        = pow( factor_tv, CLIPPING_TRADEOFF_TV );
	float factor_tv_clipping      = factor_tv / factor_tv_update;
	float huber_denom_tv          = 1.0f + huber_epsilon * tau_d / factor_tv;
	
	for( int i = 0; i < oi; ++i )
	{
		fprintf(stderr," %i",i);

		// calculate dual tv

#if SHARED_MEM
		dualTVHuber_sm<<<dimGrid,dimBlock>>>
				( uor_g, xi1_g, xi2_g, nx, ny, pitchf1, factor_tv_update, factor_tv_clipping, huber_denom_tv, tau_d );
#else
		dualTVHuber_gm<<<dimGrid,dimBlock>>>
				( uor_g, xi1_g, xi2_g, nx, ny, pitchf1, factor_tv_update, factor_tv_clipping, huber_denom_tv, tau_d );
#endif

		// DUAL DATA
		
		// iterating over all images
		std::vector<float*>::iterator image = images_g.begin();
		std::list<FlowGPU>::iterator flow   = flowsGPU.begin();
		for( unsigned int k = 0; image != images_g.end() && flow != flowsGPU.end() && k < q_g.size(); ++k, ++flow, ++image )		
		{
				// call backward warping
				backwardRegistrationBilinearValueTex ( uor_g, flow->u_g, flow->v_g, temp1_g, 0.0f, nx, ny, pitchf1, pitchf1, 1.0f, 1.0f );

				if( blur > 0.0f )
				{
					// blur image
#if GAUSS_TEXTURE_MEM
					gaussBlurSeparateMirrorGpu ( temp1_g, temp2_g, nx, ny, pitchf1, blur, blur, (int)(3.0f * blur), temp4_g, 0 );
#else
					gaussBlurSeparateMirrorGpu_gm ( temp1_g, temp2_g, nx, ny, pitchf1, blur, blur, (int)(3.0f * blur), temp4_g, 0 );
#endif
				}
				else
				{
					// swap the helper array pointers
					float *temp = temp1_g;
					temp1_g = temp2_g;
					temp2_g = temp;
				}
		
				if( factor_rescale_x > 1.0f || factor_rescale_y > 1.0f )
				{
					resampleAreaParallelSeparate(
							temp2_g,			// input image
							temp1_g,			// output image
							nx, ny,				// input size
							pitchf1,			// input pitch
							nx_orig, ny_orig,	// output size
							pitchf1_orig,		// output pitch
							temp4_g				// helper array
						);
				}
				else
				{
					// swap the helper array pointers
					float *temp = temp1_g;
					temp1_g = temp2_g;
					temp2_g = temp;
				}
				
#if SHARED_MEM
		// TODO: review parameters
		dualL1Difference_sm<<<dimGrid,dimBlock>>>
				( temp1_g, *image, q_g[k], nx_orig, ny_orig, pitchf1_orig ,
							  factor_degrade_update, factor_degrade_clipping, huber_denom_degrade, tau_d);
#else
		dualL1Difference_gm<<<dimGrid, dimBlock>>>
				(temp1_g, *image, q_g[k], nx_orig, ny_orig, pitchf1_orig,
					          factor_degrade_update, factor_degrade_clipping, huber_denom_degrade, tau_d);
#endif

		}
		
		// set 3rd helper array to zero
		setKernel <<<dimGrid, dimBlock>>>( temp3_g, nx, ny, pitchf1, 0.0f );

		// iterating over all images
		image = images_g.begin();
		flow   = flowsGPU.begin();
		for( unsigned int k = 0; image != images_g.end() && flow != flowsGPU.end() && k < q_g.size(); ++k, ++flow, ++image )
		{
			if( factor_rescale_x > 1.0f || factor_rescale_y > 1.0f )
			{
				/*
				 *  Assuming it resamples a image from q_g[k] from size nx_orig*ny_orig(pitch- pitchf1_orig) to
				 *  new size nx*ny (pitch- pitchf1) and stores it in temp1_g with the help of helper array
				 *  temp4_g. The image in temp1_g is then used for gaussian Blurring
				 */

				resampleAreaParallelSeparateAdjoined( q_g[k], temp1_g, nx_orig, ny_orig, pitchf1_orig, nx, ny, pitchf1, temp4_g );
			}
			else
			{
				// copy q_g[k] to temp1_g
				cudaMemcpy( temp1_g, q_g[k], ny * pitchf1, cudaMemcpyDeviceToDevice ); 	
			}
			
			if( blur > 0.0f )
			{
				// blur image

#if GAUSS_TEXTURE_MEM
				gaussBlurSeparateMirrorGpu ( temp1_g, temp2_g, nx, ny, pitchf1, blur, blur, (int)(3.0f * blur), temp4_g, 0 );
#else
				gaussBlurSeparateMirrorGpu_gm ( temp1_g, temp2_g, nx, ny, pitchf1, blur, blur, (int)(3.0f * blur), temp4_g, 0 );
#endif

			}
			else
			{
				// swap the helper array pointers
				float *temp = temp1_g;
				temp1_g = temp2_g;
				temp2_g = temp;
			}
			
			// foreward warping
			forewardRegistrationBilinearAtomic (
					flow->u_g, flow->v_g,
					temp2_g, temp1_g,
					nx, ny,
					pitchf1
				);

			// add 1st to 3rd helper array
			addKernel <<<dimGrid, dimBlock>>>( temp1_g, temp3_g, nx, ny, pitchf1 );
		}
	
#if SHARED_MEM
		primal1N_sm<<< dimGrid, dimBlock>>>(xi1_g, xi2_g, temp3_g, u_g, uor_g, nx, ny, pitchf1, factor_tv_update, factor_degrade_update, tau_p, overrelaxation);
#else
	    primal1N_gm<<< dimGrid, dimBlock>>>(xi1_g, xi2_g, temp3_g, u_g, uor_g, nx, ny, pitchf1, factor_tv_update, factor_degrade_update, tau_p, overrelaxation);
#endif

	}
}
