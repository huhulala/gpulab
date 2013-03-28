/****************************************************************************\
*      --- Practical Course: GPU Programming in Computer Vision ---
 *
 * time:    winter term 2012/13 / March 11-18, 2013
 *
 * project: superresolution
 * file:    linearoperations.cu
 *
 *
 * implement all functions with ### implement me ### in the function body
 \****************************************************************************/

/*
 * linearoperations.cu
 *
 *  Created on: Aug 3, 2012
 *      Author: steinbrf
 */

#include <auxiliary/cuda_basic.cuh>
#include <iostream>

cudaChannelFormatDesc linearoperation_float_tex =
		cudaCreateChannelDesc<float>();
texture<float, 2, cudaReadModeElementType> tex_linearoperation;
bool linearoperation_textures_initialized = false;

#define MAXKERNELRADIUS     20    // maximum allowed kernel radius
#define MAXKERNELSIZE   21    // maximum allowed kernel radius + 1
__constant__ float constKernel[MAXKERNELSIZE];

void setTexturesLinearOperations(int mode)
{
	tex_linearoperation.addressMode[0] = cudaAddressModeClamp;
	tex_linearoperation.addressMode[1] = cudaAddressModeClamp;
	if (mode == 0)
		tex_linearoperation.filterMode = cudaFilterModePoint;
	else
		tex_linearoperation.filterMode = cudaFilterModeLinear;
	tex_linearoperation.normalized = false;
}

#define LO_TEXTURE_OFFSET 0.5f
#define LO_RS_AREA_OFFSET 0.0f

#ifdef DGT400
#define LO_BW 32
#define LO_BH 16
#else
#define LO_BW 16
#define LO_BH 16
#endif

#ifndef RESAMPLE_EPSILON
#define RESAMPLE_EPSILON 0.005f
#endif

#ifndef atomicAdd
__device__ float atomicAdd(float* address, double val)
{
	unsigned int* address_as_ull = (unsigned int*) address;
	unsigned int old = *address_as_ull, assumed;
	do
	{
		assumed = old;
		old = atomicCAS(address_as_ull, assumed,
				__float_as_int(val + __int_as_float(assumed)));
	} while (assumed != old);
	return __int_as_float(old);
}

#endif

//================================================================
// backward warping
//================================================================

// TODO: change global memory to texture
__global__ void backwardRegistrationBilinearValueTexKernel (
		const float* in_g,
		const float* flow1_g,
		const float* flow2_g,
		float* out_g,
		float value,
		int nx,
		int ny,
		int pitchf1_in,
		int pitchf1_out,
		float hx,
		float hy
	)
{
	// thread coordinates
	const int x = blockIdx.x * blockDim.x + threadIdx.x;
	const int y = blockIdx.y * blockDim.y + threadIdx.y;
	
	if( x < nx && y < ny )
	{
		float hx_1 = 1.0f / hx;
		float hy_1 = 1.0f / hy;
	
		float ii_fp = x + (flow1_g[y * nx + x] * hx_1);
		float jj_fp = y + (flow2_g[y * nx + x] * hy_1);
	
		if( (ii_fp < 0.0f) || (jj_fp < 0.0f)
					 || (ii_fp > (float)(nx - 1)) || (jj_fp > (float)(ny - 1)) )
		{
			out_g[y*nx+x] = value;
		}
		else if( !isfinite( ii_fp ) || !isfinite( jj_fp ) )
		{
			//fprintf(stderr,"!");
			out_g[ y * nx + x] = value;
		}
		else
		{
			int xx = (int)ii_fp;
			int yy = (int)jj_fp;
	
			int xx1 = xx == nx - 1 ? xx : xx + 1;
			int yy1 = yy == ny - 1 ? yy : yy + 1;
	
			float xx_rest = ii_fp - (float)xx;
			float yy_rest = jj_fp - (float)yy;
	
			out_g[y * nx + x] =
					(1.0f - xx_rest) * (1.0f - yy_rest) * in_g[yy * nx + xx]
					+ xx_rest * (1.0f - yy_rest)        * in_g[yy * nx + xx1]
					+ (1.0f - xx_rest) * yy_rest        * in_g[yy1 * nx + xx]
					+ xx_rest * yy_rest                 * in_g[yy1 * nx + xx1];
		}
	}
}


void backwardRegistrationBilinearValueTex (
		const float* in_g,		// _u_overrelaxed
		const float* flow1_g,	// flow->u1
		const float* flow2_g,	// flow->u2
		float* out_g,			// _help1
		float value,			// 0.0f
		int nx,
		int ny,
		int pitchf1_in,
		int pitchf1_out,
		float hx,				// 1.0f
		float hy				// 1.0f
	)
{
	// block and grid size
	int ngx = ((nx - 1) / LO_BW) + 1;
	int ngy = ((ny - 1) / LO_BH) + 1;

	dim3 dimGrid( ngx, ngy );
	dim3 dimBlock( LO_BW, LO_BH );
	
	// TODO: binding of texture

	//call warp method on gpu
	backwardRegistrationBilinearValueTexKernel<<<dimGrid, dimBlock>>>(
			in_g,
			flow1_g,
			flow2_g,
			out_g,
			value,
			nx,
			ny,
			pitchf1_in,
			pitchf1_out,
			hx,
			hy
		);
	
	// TODO: release texture
}







// gpu warping kernel
__global__ void backwardRegistrationBilinearFunctionGlobalGpu(const float *in_g,
		const float *flow1_g, const float *flow2_g, float *out_g,
		const float *constant_g, int nx, int ny, int pitchf1_in,
		int pitchf1_out, float hx, float hy)
{
	const int x = blockIdx.x * blockDim.x + threadIdx.x;
	const int y = blockIdx.y * blockDim.y + threadIdx.y;

	// check if x is within the boundaries
	if (x < nx && y < ny)
	{
		const float xx = (float) x + flow1_g[y * pitchf1_in + x] / hx;
		const float yy = (float) y + flow2_g[y * pitchf1_in + x] / hy;

		int xxFloor = (int) floor(xx);
		int yyFloor = (int) floor(yy);

		int xxCeil = xxFloor == nx - 1 ? xxFloor : xxFloor + 1;
		int yyCeil = yyFloor == ny - 1 ? yyFloor : yyFloor + 1;

		float xxRest = xx - (float) xxFloor;
		float yyRest = yy - (float) yyFloor;

		//same weird expression as in cpp
		out_g[y * pitchf1_out + x] =
				(xx < 0.0f || yy < 0.0f || xx > (float) (nx - 1)
						|| yy > (float) (ny - 1)) ?
						constant_g[y * pitchf1_in + x] :
						(1.0f - xxRest) * (1.0f - yyRest)
								* in_g[yyFloor * pitchf1_in + xxFloor]
								+ xxRest * (1.0f - yyRest)
										* in_g[yyFloor * pitchf1_in + xxCeil]
								+ (1.0f - xxRest) * yyRest
										* in_g[yyCeil * pitchf1_in + xxFloor]
								+ xxRest * yyRest
										* in_g[yyCeil * pitchf1_in + xxCeil];

	}
}

// initialize cuda warping kernel
void backwardRegistrationBilinearFunctionGlobal(const float *in_g,
		const float *flow1_g, const float *flow2_g, float *out_g,
		const float *constant_g, int nx, int ny, int pitchf1_in,
		int pitchf1_out, float hx, float hy)
{
	// block and grid size
	int ngx = ((nx - 1) / LO_BW) + 1;
	int ngy = ((ny - 1) / LO_BH) + 1;

	dim3 dimGrid( ngx, ngy );
	dim3 dimBlock( LO_BW, LO_BH );

	//call warp method on gpu
	backwardRegistrationBilinearFunctionGlobalGpu<<<dimGrid, dimBlock>>>(in_g,
			flow1_g, flow2_g, out_g, constant_g, nx, ny, pitchf1_in,
			pitchf1_out, hx, hy);
}

void backwardRegistrationBilinearFunctionTex(const float *in_g,
		const float *flow1_g, const float *flow2_g, float *out_g,
		const float *constant_g, int nx, int ny, int pitchf1_in,
		int pitchf1_out, float hx, float hy)
{
	// ### Implement me, if you want ###
}



//================================================================
// forward warping
//================================================================


__global__ void foreward_warp_kernel_atomic (
		const float *flow1_g,	// flow.u
		const float *flow2_g,	// flow.v
		const float *in_g,		// temp2_g
		float *out_g,			// temp1_g
		int nx,
		int ny,
		int pitchf1
	)
{
	// get thread coordinates and index
	const int x = blockIdx.x * blockDim.x + threadIdx.x;
	const int y = blockIdx.y * blockDim.y + threadIdx.y;
	const unsigned int idx = y * pitchf1 + x;
			
	// reset shared memory to zero
	out_g[idx] = 0.0f;
		
	// calculate target coordinates: coords + flow values
	const float xx = (float)x + flow1_g[idx];
	const float yy = (float)y + flow2_g[idx];
	
	// continue only if target area inside image
	if(
			xx >= 0.0f &&
			xx <= (float)(nx - 2) &&
			yy >= 0.0f &&
			yy <= (float)(ny - 2))
	{
		float xxf = floor(xx);
		float yyf = floor(yy);
		
		// target pixel coordinates
		const int xxi = (int)xxf;
		const int yyi = (int)yyf;
		
		xxf = xx - xxf;
		yyf = yy - yyf;
		
		// distribute input pixel value to adjacent pixels of target pixel
		float out_xy   = in_g[idx] * (1.0f - xxf) * (1.0f - yyf);
		float out_x1y  = in_g[idx] * xxf * (1.0f - yyf);
		float out_xy1  = in_g[idx] * (1.0f - xxf) * yyf;
		float out_x1y1 = in_g[idx] * xxf * yyf;		
				
		// eject the warp core!
		// avoid race conditions by use of atomic operations
		atomicAdd( out_g + (yyi * nx + xxi),           out_xy );
		atomicAdd( out_g + (yyi * nx + xxi + 1),       out_x1y );
		atomicAdd( out_g + ((yyi + 1) * nx + xxi),     out_xy1 );
		atomicAdd( out_g + ((yyi + 1) * nx + xxi + 1), out_x1y1 );
		
		// TODO: think about hierarchical atomics
		// problem: target coordinates can be anywhere on image,
		// so shared memory per block is limited reasonable
		
	}

}



/*
 * Forward warping
 */
void forewardRegistrationBilinearAtomic (
		const float *flow1_g,
		const float *flow2_g,
		const float *in_g,
		float *out_g,
		int nx,
		int ny,
		int pitchf1
	)
{
	// block and grid size
	int blocksize_x = ((nx - 1) / LO_BW) + 1;
	int blocksize_y = ((ny - 1) / LO_BH) + 1;

	dim3 dimGrid( blocksize_x, blocksize_y );
	dim3 dimBlock( LO_BW, LO_BH );

	// invoke atomic warp kernel on gpu
	foreward_warp_kernel_atomic <<< dimGrid, dimBlock >>> ( flow1_g, flow2_g, in_g, out_g, nx, ny, pitchf1 );
}



//================================================================
// gaussian blur (mirrored)
//================================================================

/*
 * gaussian blur with mirrored border
 * 
 * global memory
 */
__global__ void gaussBlurSeparateMirrorGpuKernel_global (
		float* in_g,
		float* out_g,
		int nx,
		int ny,
		int pitchf1,
		float sigmax,
		float sigmay,
		int radius,
		float* temp_g,
		float* mask
	)
{
	// get thread coordinates and index
	const int x = blockIdx.x * blockDim.x + threadIdx.x;
	const int y = blockIdx.y * blockDim.y + threadIdx.y;
	//const unsigned int idx = y * pitchf1 + x;
	
	float result, sum;

	// todo: currently assuming that temp_g is given
	//bool selfalloctemp = temp_g == NULL;
	//if( selfalloctemp )
	//	temp_g = new float[nx*ny];

	bool selfallocmask = mask == NULL;
	if(selfallocmask)
		mask = new float[radius + 1];
	
	sigmax = 1.0f / (sigmax * sigmax);
	sigmay = 1.0f / (sigmay * sigmay);

	//---------------------
	// gauss in x direction
	//---------------------

	// prepare gaussian kernel (1D)
	// todo: move to shared memory, if computed in threads
	mask[0] = sum = 1.0f;
	for( int gx = 1; gx <= radius; ++gx )
	{
		mask[gx] = exp( -0.5f * ((float)(gx * gx) * sigmax) );
		sum += 2.0f * mask[gx];
	}
	// normalize kernel
	for(int gx = 0; gx <= radius; ++gx )
	{
		mask[gx] /= sum;
	}

	// convolution x
	result = mask[0] * in_g[y * pitchf1 + x];

	for( int i = 1; i <= radius; i++ )
	{
		result += mask[i] * (
				( (x - i >= 0) ? ( in_g[y * pitchf1 + (x - i)] ) : ( in_g[y * pitchf1 + (-1 - (x-i))] ) ) +
				( (x + i < nx) ? ( in_g[y * pitchf1 + (x + i)] ) : ( in_g[y * pitchf1 + (nx - (x+i - nx-1))]) )
			);
	}
	
	temp_g[y * pitchf1 + x] = result;
	
	//---------------------
	// gauss in y direction
	//---------------------

	mask[0] = sum = 1.0f;

	// prepare gaussian kernel (1D)
	// todo: move to shared memory, if computed in threads
	for( int gx = 1; gx <= radius; ++gx )
	{
		mask[gx] = exp( -0.5f * ( (float)(gx * gx) * sigmay) );
		sum += 2.0f * mask[gx];
	}
	// normalize kernel
	for(int gx = 0; gx <= radius; ++gx )
	{
		mask[gx] /= sum;
	}

	// convolution y
	result = mask[0] * temp_g[y * pitchf1 + x];

	for( int i = 1; i <= radius; ++i )
	{
		result += mask[i]*(
				( (y-i >= 0) ? temp_g[(y-i) * pitchf1 + x] : temp_g[(-1 - (y-i)) * pitchf1 + x]) +
				( (y+i < ny) ? temp_g[(y+i) * pitchf1 + x] : temp_g[(ny - (y+i - ny-1)) * pitchf1 + x])
			);
	}

	out_g[y * pitchf1 + x] = result;


	// free memory?
	//if(selfallocmask) delete [] mask;
	//if(selfalloctemp) delete [] temp;
}

void gaussBlurSeparateMirrorGpu (
		float* in_g,
		float* out_g,
		int nx,
		int ny,
		int pitchf1,
		float sigmax,
		float sigmay,
		int radius,
		float* temp_g,
		float* mask
	)
{
	// block and grid size
	int blocksize_x = ((nx - 1) / LO_BW) + 1;
	int blocksize_y = ((ny - 1) / LO_BH) + 1;

	dim3 dimGrid( blocksize_x, blocksize_y );
	dim3 dimBlock( LO_BW, LO_BH );


	// todo: necessary? => copy memory? (swaping pointers here not possible)
	// if( sigmax <= 0.0f || sigmay <= 0.0f || radius < 0 )
	//	 return;
	
	if( radius == 0 )
	{
		int maxsigma = (sigmax > sigmay) ? sigmax : sigmay;
		radius = (int)( 3.0f * maxsigma );
	}
	
	// todo: allocate gpu memory, if necessary (bind texture)

	
	// todo: try performance with prepared mask
	
	// invoke gauss kernel on gpu
	gaussBlurSeparateMirrorGpuKernel_global <<< dimGrid, dimBlock >>> ( in_g, out_g, nx, ny, pitchf1, sigmax, sigmay, radius, temp_g, mask );
	
	// todo: free gpu memory, if necessary
}



//================================================================
// resample separate
//================================================================

__global__ void resampleAreaParallelSeparate_x
	(
		const float* in_g,
		float* out_g,
		int nx,
		int ny,
		float hx,
		int pitchf1_in,
		int pitchf1_out,
		float factor = 0.0f
	)
{
	const int ix = threadIdx.x + blockIdx.x * blockDim.x;
	const int iy = threadIdx.y + blockIdx.y * blockDim.y;
	const int index = ix + iy * pitchf1_out; // global index for out image
	
	if( factor == 0.0f )
		factor = 1 / hx;

	if( ix < nx && iy < ny)
	{
		// initialising out
		out_g[ index ] = 0.0f;
		
		float px = (float)ix * hx;
		
		float left = ceil(px) - px;
		if(left > hx) left = hx;
		
		float midx  = hx - left;
		float right = midx - floorf(midx);
		
		midx = midx - right;
		
		if( left > 0.0f )
		{
			// using pitchf1_in instead of nx_orig in original code
			out_g[index] += in_g[ iy * pitchf1_in + (int)floor(px) ] * left * factor; // look out for conversion of coordinates
			px += 1.0f;
		}
		while( midx > 0.0f )
		{
			// using pitchf1_in instead of nx_orig in original code
			out_g[index] += in_g[ iy * pitchf1_in + (int)floor(px) ] * factor;
			px += 1.0f;
			midx -= 1.0f;
		}
		if( right > RESAMPLE_EPSILON )
		{
			// using pitchf1_in instead of nx_orig in original code
			out_g[index] += in_g[ iy * pitchf1_in + (int)floor(px) ] * right * factor;
		}
	}
}

__global__ void resampleAreaParallelSeparate_y
	(
		const float* in_g,
		float* out_g,
		int nx,
		int ny,
		float hy,
		int pitchf1_out,
		float factor = 0.0f // need
	)
{
	const int ix = threadIdx.x + blockIdx.x * blockDim.x;
	const int iy = threadIdx.y + blockIdx.y * blockDim.y;
	const int index = ix + iy * pitchf1_out; // global index for out image
	// used pitch instead  of blockDim.x
	
	if( factor == 0.0f )
		factor = 1.0f / hy;
	
	if( ix < nx && iy < ny ) // guards
	{
		out_g[index] = 0.0f;
		
		float py = (float)iy * hy;
		float top = ceil(py) - py;
		
		if( top > hy )
			top = hy;
		
		float midy = hy - top;
		
		float bottom = midy - floorf(midy);
		midy = midy - bottom;
		
		if( top > 0.0f )
		{
			// using pitch for helper array since these all arrays have same pitch
			out_g[index] += in_g[(int)floor(py) * pitchf1_out + ix ] * top * factor;
			py += 1.0f;
		}
		while( midy > 0.0f )
		{
			out_g[index] += in_g[(int)floor(py) * pitchf1_out + ix ] * factor;
			py += 1.0f;
			midy -= 1.0f;
		}
		if( bottom > RESAMPLE_EPSILON )
		{
			out_g[index] += in_g[(int)floor(py) * pitchf1_out + ix ] * bottom * factor;
		}
	}
}


void resampleAreaParallelSeparate (
		const float *in_g,
		float *out_g,
		int nx_in,
		int ny_in,
		int pitchf1_in,
		int nx_out,
		int ny_out,
		int pitchf1_out,
		float *help_g,
		float scalefactor
	)
{
	// helper array is already allocated on the GPU as _b1, now help_g

	// can reduce no of blocks for first pass
	int blocksize_x = ((nx_out - 1) / LO_BW) + 1;
	int blocksize_y = ((ny_in - 1) / LO_BH) + 1;
	
	dim3 dimGrid( blocksize_x, blocksize_y );
	dim3 dimBlock( LO_BW, LO_BH );
	
	
	float hx = (float)nx_in / (float)nx_out;
	float factor = (float)(nx_out)/(float)(nx_in);
	
	resampleAreaParallelSeparate_x<<< dimGrid, dimBlock >>>( in_g, help_g, nx_out, ny_in,
				hx, pitchf1_in, pitchf1_out, factor);
	
	// this cost us a lot of time -> resize grid to y_out
	blocksize_y = (ny_out % LO_BH) ? ((ny_out / LO_BH)+1) : (ny_out / LO_BH);
	dimGrid = dim3( blocksize_x, blocksize_y );
	
	float hy = (float)ny_in / (float)ny_out;
	factor = scalefactor*(float)ny_out / (float)ny_in;
	
	resampleAreaParallelSeparate_y<<< dimGrid, dimBlock >>>( help_g, out_g, nx_out, ny_out,
			hy, pitchf1_out, factor );
}

//================================================================
// resample adjoined
//================================================================

void resampleAreaParallelSeparateAdjoined(const float *in_g, float *out_g,
		int nx_in, int ny_in, int pitchf1_in, int nx_out, int ny_out,
		int pitchf1_out, float *help_g, float scalefactor)
{
	// ### Implement me ###
}



//================================================================
// simple add sub and set kernels
//================================================================


__global__ void addKernel(const float *increment_g, float *accumulator_g,
		int nx, int ny, int pitchf1)
{
	const int x = blockIdx.x * blockDim.x + threadIdx.x;
	const int y = blockIdx.y * blockDim.y + threadIdx.y;
	const int idx = y * pitchf1 + x;
	
	if( x < nx && y < ny )
	{
		accumulator_g[idx] += increment_g[idx];
	}
}

__global__ void subKernel(const float *increment_g, float *accumulator_g,
		int nx, int ny, int pitchf1)
{
	const int x = blockIdx.x * blockDim.x + threadIdx.x;
	const int y = blockIdx.y * blockDim.y + threadIdx.y;
	const int idx = y * pitchf1 + x;
	
	if( x < nx && y < ny )
	{
		accumulator_g[idx] -= increment_g[idx];
	}
}

__global__ void setKernel(float *field_g, int nx, int ny, int pitchf1,
		float value)
{
	const int x = blockIdx.x * blockDim.x + threadIdx.x;
	const int y = blockIdx.y * blockDim.y + threadIdx.y;
	const int idx = y * pitchf1 + x;
	
	if( x < nx && y < ny )
	{
		field_g[idx] = value;
	}
}
