#include "directalignment.h"

//*****************
// Warping
//*****************
texture<float, cudaTextureType2D, cudaReadModeElementType> DirectTexToWarp;

__global__ void DirectWarpingKernel(int width, int height, int stride,
	const float2 *warpUV, float *out)
{
	const int ix = threadIdx.x + blockIdx.x * blockDim.x;
	const int iy = threadIdx.y + blockIdx.y * blockDim.y;

	const int pos = ix + iy * stride;

	if (ix >= width || iy >= height) return;

	float x = ((float)ix + warpUV[pos].x + 0.5f) / (float)width;
	float y = ((float)iy + warpUV[pos].y + 0.5f) / (float)height;

	out[pos] = tex2D(DirectTexToWarp, x, y);
}

void DirectAlignment::WarpImage(const float *src, int w, int h, int s,
	const float2 *warpUV, float *out)
{
	dim3 threads(BlockWidth, BlockHeight);
	dim3 blocks(iDivUp(w, threads.x), iDivUp(h, threads.y));

	// mirror if a coordinate value is out-of-range
	DirectTexToWarp.addressMode[0] = cudaAddressModeMirror;
	DirectTexToWarp.addressMode[1] = cudaAddressModeMirror;
	DirectTexToWarp.filterMode = cudaFilterModeLinear;
	DirectTexToWarp.normalized = true;

	cudaChannelFormatDesc desc = cudaCreateChannelDesc<float>();

	cudaBindTexture2D(0, DirectTexToWarp, src, w, h, s * sizeof(float));

	DirectWarpingKernel << <blocks, threads >> > (w, h, s, warpUV, out);
}


//*****************
// Image Converter
//*****************
__global__
void DirectCv8uToGrayKernel(uchar *d_iCv8u, float *d_iGray, int width, int height, int stride)
{
	int r = blockIdx.y * blockDim.y + threadIdx.y;        // current row 
	int c = blockIdx.x * blockDim.x + threadIdx.x;        // current column 

	if ((r < height) && (c < width))
	{
		int idx = c + stride * r;        // current pixel index 

		//d_iGray[idx] = 0.2126f * (float)pixel.x + 0.7152f * (float)pixel.y + 0.0722f * (float)pixel.z;
		d_iGray[idx] = (float)d_iCv8u[idx] / 256.0f;
	}
}

void DirectAlignment::Cv8uToGray(uchar * d_iCv8u, float *d_iGray, int w, int h, int s)
{
	dim3 threads(BlockWidth, BlockHeight);
	dim3 blocks(iDivUp(w, threads.x), iDivUp(h, threads.y));

	DirectCv8uToGrayKernel << < blocks, threads >> > (d_iCv8u, d_iGray, w, h, s);
}

__global__
void DirectCv8uc3ToGrayKernel(uchar3 *d_iRgb, float *d_iGray, int width, int height, int stride)
{
	int r = blockIdx.y * blockDim.y + threadIdx.y;        // current row 
	int c = blockIdx.x * blockDim.x + threadIdx.x;        // current column 

	if ((r < height) && (c < width))
	{
		int idx = c + stride * r;        // current pixel index 

		uchar3 pixel = d_iRgb[idx];

		//d_iGray[idx] = 0.2126f * (float)pixel.x + 0.7152f * (float)pixel.y + 0.0722f * (float)pixel.z;
		d_iGray[idx] = ((float)pixel.x + (float)pixel.y + (float)pixel.z) / 3;
		d_iGray[idx] = d_iGray[idx] / 256.0f;
	}
}

void DirectAlignment::Cv8uc3ToGray(uchar3 * d_iRgb, float *d_iGray, int w, int h, int s)
{
	dim3 threads(BlockWidth, BlockHeight);
	dim3 blocks(iDivUp(w, threads.x), iDivUp(h, threads.y));

	DirectCv8uc3ToGrayKernel << < blocks, threads >> > (d_iRgb, d_iGray, w, h, s);
}


//**********************
// TVL1 Direct Alignment
//**********************
// Solve Problem1A - Thresholding
__global__ void DirectThresholdingL1MaskedKernel(float* mask, float2* u, float2* u_med, float* Ix, float* Iy, float* Iz,
	float lambda, float theta, int width, int height, int stride)
{
	int iy = blockIdx.y * blockDim.y + threadIdx.y;        // current row 
	int ix = blockIdx.x * blockDim.x + threadIdx.x;        // current column 

	if ((iy >= height) && (ix >= width)) return;
	int pos = ix + iy * stride;
	if (mask[pos] == 0.0f) return;

	// Thresholding
	float du_med = (u[pos].x - u_med[pos].x);
	float dv_med = (u[pos].y - u_med[pos].y);

	float Ixs = Ix[pos];
	float Iys = Iy[pos];
	float Izs = Iz[pos];

	float divisor = Ixs * Ixs + Iys * Iys;
	float rho = Ixs * du_med + Iys * dv_med + Izs;
	float upper = lambda * theta * divisor;
	float lower = -lambda * theta * divisor;
	
	float du;
	float dv;

	if ((rho <= upper) && (rho >= lower)) {
		if (divisor == 0) {
			du = du_med;
			dv = dv_med;
		}
		else {
			du = du_med - rho * Ixs / divisor;
			dv = dv_med - rho * Iys / divisor;
		}
	}
	else if (rho < lower) {
		du = du_med + lambda * theta * Ixs;
		dv = dv_med + lambda * theta * Iys;
	}
	else if (rho > upper) {
		du = du_med - lambda * theta *Ixs;
		dv = dv_med - lambda * theta *Iys;
	}

	u[pos].x = u_med[pos].x + du;
	u[pos].y = u_med[pos].y + dv;
}

void DirectAlignment::ThresholdingL1Masked(float* mask, float2* u, float2* u_med, float* Ix, float* Iy, float* Iz,
	float lambda, float theta, int w, int h, int s)
{
	dim3 threads(BlockWidth, BlockHeight);
	dim3 blocks(iDivUp(w, threads.x), iDivUp(h, threads.y));

	DirectThresholdingL1MaskedKernel << < blocks, threads >> > (mask, u, u_med, Ix, Iy, Iz, lambda, theta,
		w, h, s);
}

__global__ void DirectSparsePriorL1Kernel(float* mask, float* u, float* u_, float* usparse, float* Iu, float* Iz, float lambda, float l2lambda,
	float* lambdaMask, float theta,
	int width, int height, int stride, float* us)
{
	int iy = blockIdx.y * blockDim.y + threadIdx.y;        // current row 
	int ix = blockIdx.x * blockDim.x + threadIdx.x;        // current column 

	if ((iy >= height) && (ix >= width)) return;
	int pos = ix + iy * stride;
	if (mask[pos] == 0.0f) return;

	// Thresholding
	float u_pos = u_[pos];
	float dun = (u[pos] - u_pos);
	float Ius = Iu[pos];
	float rho = Ius * dun + Iz[pos];

	float upper = lambda * theta * (Ius * Ius);
	float lower = -lambda * theta *(Ius * Ius);
	float du;

	if ((rho <= upper) && (rho >= lower)) {
		if (Ius == 0) {
			du = dun;
		}
		else {
			du = dun - rho / Ius;
		}
	}
	else if (rho < lower) {
		du = dun + lambda * theta *Ius;
	}
	else if (rho > upper) {
		du = dun - lambda * theta *Ius;
	}

	float ul1 = u_pos + du;
	float usparsepos = usparse[pos];
	/*if (abs(ul1 - usparsepos) > 5.0f) {
		usparsepos = ul1;
	}*/

	if (lambdaMask[pos] == 0.0f) {
		us[pos] = ul1;
	}
	else {
		us[pos] = (ul1 + l2lambda * usparsepos) / (1.0f + l2lambda);
	}
}

void DirectAlignment::SparsePriorL1(float* fisheyeMask, float* u, float* u_, float * usparse, float* Iu, float* Iz,
	float lambda, float l2lambda, float* lambdaMask, float theta,
	float* us, int w, int h, int s)
{
	dim3 threads(BlockWidth, BlockHeight);
	dim3 blocks(iDivUp(w, threads.x), iDivUp(h, threads.y));

	DirectSparsePriorL1Kernel << < blocks, threads >> > (fisheyeMask, u, u_, usparse, Iu, Iz, lambda, l2lambda,
		lambdaMask, theta,
		w, h, s, us);
}


__global__ void DirectL2Kernel(float* mask, float* u, float* u_, float l2lambda, float* lambdaMask,
	int width, int height, int stride, float* us)
{
	int iy = blockIdx.y * blockDim.y + threadIdx.y;        // current row 
	int ix = blockIdx.x * blockDim.x + threadIdx.x;        // current column 

	if ((iy >= height) && (ix >= width)) return;
	int pos = ix + iy * stride;
	if (mask[pos] == 0.0f) return;

	if (lambdaMask[pos] == 0.0f) {
		us[pos] = u_[pos];
	}
	else {
		us[pos] = (u_[pos] + l2lambda * u[pos]) / (1.0f + l2lambda);
	}
}

void DirectAlignment::SimpleL2(float* mask, float* u, float* u_, float l2lambda, float* lambdaMask,
	float* us, int w, int h, int s)
{
	dim3 threads(BlockWidth, BlockHeight);
	dim3 blocks(iDivUp(w, threads.x), iDivUp(h, threads.y));

	DirectL2Kernel << < blocks, threads >> > (mask, u, u_, l2lambda, lambdaMask, w, h, s, us);
}

// Solve Problem1B
__global__ void DirectSolveProblem1bMaskedKernel(float* mask, float2* u, float2 *pu, float2* pv, float theta,
	int width, int height, int stride, float2* umed)
{
	int iy = blockIdx.y * blockDim.y + threadIdx.y;        // current row 
	int ix = blockIdx.x * blockDim.x + threadIdx.x;        // current column 

	if ((iy >= height) && (ix >= width)) return;
	int pos = ix + iy * stride;
	if (mask[pos] == 0.0f) return;

	int left = (ix - 1) + iy * stride;
	int up = ix + (iy - 1) * stride;

	float maskLeft, maskUp;
	if (ix - 1 < 0) {
		maskLeft = 0.0f;
	}
	else maskLeft = mask[left];

	if (iy - 1 < 0) {
		maskUp = 0.0f;
	}
	else maskUp = mask[up];

	float divpu, divpv;
	float2 pupos = pu[pos];
	float2 pvpos = pv[pos];
	if (maskLeft == 0.0f) {
		if (maskUp == 0.0f) {
			//divp = ppos.x + ppos.y;
			divpu = 0.0f;
			divpv = 0.0f;
		}
		else {
			//divp = ppos.x + ppos.y - p[up].y;
			divpu = pupos.y - pu[up].y;
			divpv = pvpos.y - pv[up].y;
		}
	}
	else {
		if (maskUp == 0.0f) {
			//divp = ppos.x - p[left].x + ppos.y;
			divpu = pupos.x - pu[left].x;
			divpv = pvpos.x - pv[left].x;
		}
		else {
			divpu = pupos.x - pu[left].x + pupos.y - pu[up].y;
			divpv = pvpos.x - pv[left].x + pvpos.y - pv[up].y;
		}
	}

	umed[pos].x = u[pos].x + theta * divpu;
	umed[pos].y = u[pos].y + theta * divpv;
}

void DirectAlignment::SolveProblem1bMasked(float* mask, float2* u, float2 *pu, float2* pv, float theta,
	float2* umed, int w, int h, int s)
{
	dim3 threads(BlockWidth, BlockHeight);
	dim3 blocks(iDivUp(w, threads.x), iDivUp(h, threads.y));

	DirectSolveProblem1bMaskedKernel << < blocks, threads >> > (mask, u, pu, pv, theta,
		w, h, s, umed);
}

// Solve Problem 2
__global__ void DirectSolveProblem2MaskedKernel(float* mask, float2* u, float2 *pu, float2* pv, float theta, float tau,
	int width, int height, int stride, float2* pus, float2* pvs)
{
	int iy = blockIdx.y * blockDim.y + threadIdx.y;        // current row 
	int ix = blockIdx.x * blockDim.x + threadIdx.x;        // current column 

	if ((iy >= height) && (ix >= width)) return;
	int pos = ix + iy * stride;
	if (mask[pos] == 0.0f) return;

	int right = (ix + 1) + iy * stride;
	int down = ix + (iy + 1) * stride;
	int left = (ix - 1) + iy * stride;
	int up = ix + (iy - 1) * stride;
	float maskRight, maskDown;
	if (ix + 1 >= width) {
		maskRight = 0.0f;
	}
	else maskRight = mask[right];
	if (iy + 1 >= height) {
		maskDown = 0.0f;
	}
	else maskDown = mask[down];

	float dux, duy;
	float dvx, dvy;
	if (maskRight == 0.0f) {
		dux = 0;
		dvx = 0;
	}
	else {
		dux = u[right].x - u[pos].x;
		dvx = u[right].y - u[pos].y;
	}
	if (maskDown == 0.0f) {
		duy = 0;
		dvy = 0;
	}
	else {
		duy = u[down].x - u[pos].x;
		dvy = u[down].y - u[pos].y;
	}

	float magdu = sqrt(dux * dux + duy * duy);
	float magdv = sqrt(dvx * dvx + dvy * dvy);
	float fac = tau / theta;

	float2 pusub = pu[pos];
	float2 pvsub = pv[pos];

	pus[pos].x = (pusub.x + fac * dux) / (1 + fac * magdu);
	pus[pos].y = (pusub.y + fac * duy) / (1 + fac * magdu);
	pvs[pos].x = (pvsub.x + fac * dvx) / (1 + fac * magdv);
	pvs[pos].y = (pvsub.y + fac * dvy) / (1 + fac * magdv);
}

void DirectAlignment::SolveProblem2Masked(float* mask, float2* u, float2 *pu, float2 *pv, float theta, float tau,
	float2* pus, float2* pvs, int w, int h, int s)
{
	dim3 threads(BlockWidth, BlockHeight);
	dim3 blocks(iDivUp(w, threads.x), iDivUp(h, threads.y));

	DirectSolveProblem2MaskedKernel	<< < blocks, threads >> > (mask, u, pu, pv, theta, tau, w, h, s, pus, pvs);
}


//********************
// COMPUTE DERIVATIVES
//********************

texture<float, cudaTextureType2D, cudaReadModeElementType> texI0;
texture<float, cudaTextureType2D, cudaReadModeElementType> texI1;

__global__ void DirectComputeDerivativesKernel(int width, int height, int stride,
	float *Ix, float *Iy, float *Iz)
{
	const int ix = threadIdx.x + blockIdx.x * blockDim.x;
	const int iy = threadIdx.y + blockIdx.y * blockDim.y;

	const int pos = ix + iy * stride;

	if (ix >= width || iy >= height) return;

	float dx = 1.0f / (float)width;
	float dy = 1.0f / (float)height;

	float x = ((float)ix + 0.5f) * dx;
	float y = ((float)iy + 0.5f) * dy;

	float t0, t1;
	// x derivative
	t0 = tex2D(texI0, x - 2.0f * dx, y);
	t0 -= tex2D(texI0, x - 1.0f * dx, y) * 8.0f;
	t0 += tex2D(texI0, x + 1.0f * dx, y) * 8.0f;
	t0 -= tex2D(texI0, x + 2.0f * dx, y);
	t0 /= 12.0f;

	t1 = tex2D(texI1, x - 2.0f * dx, y);
	t1 -= tex2D(texI1, x - 1.0f * dx, y) * 8.0f;
	t1 += tex2D(texI1, x + 1.0f * dx, y) * 8.0f;
	t1 -= tex2D(texI1, x + 2.0f * dx, y);
	t1 /= 12.0f;

	Ix[pos] = (t0 + t1) * 0.5f;

	// t derivative
	Iz[pos] = tex2D(texI1, x, y) - tex2D(texI0, x, y);

	// y derivative
	t0 = tex2D(texI0, x, y - 2.0f * dy);
	t0 -= tex2D(texI0, x, y - 1.0f * dy) * 8.0f;
	t0 += tex2D(texI0, x, y + 1.0f * dy) * 8.0f;
	t0 -= tex2D(texI0, x, y + 2.0f * dy);
	t0 /= 12.0f;

	t1 = tex2D(texI1, x, y - 2.0f * dy);
	t1 -= tex2D(texI1, x, y - 1.0f * dy) * 8.0f;
	t1 += tex2D(texI1, x, y + 1.0f * dy) * 8.0f;
	t1 -= tex2D(texI1, x, y + 2.0f * dy);
	t1 /= 12.0f;

	Iy[pos] = (t0 + t1) * 0.5f;
}

///CUDA CALL FUNCTIONS ***********************************************************
void DirectAlignment::ComputeDerivatives(float *I0, float *I1,
	int w, int h, int s,
	float *Ix, float *Iy, float *Iz)
{
	dim3 threads(BlockWidth, BlockHeight);
	dim3 blocks(iDivUp(w, threads.x), iDivUp(h, threads.y));

	// mirror if a coordinate value is out-of-range
	texI0.addressMode[0] = cudaAddressModeMirror;
	texI0.addressMode[1] = cudaAddressModeMirror;
	texI0.filterMode = cudaFilterModeLinear;
	texI0.normalized = true;

	texI1.addressMode[0] = cudaAddressModeMirror;
	texI1.addressMode[1] = cudaAddressModeMirror;
	texI1.filterMode = cudaFilterModeLinear;
	texI1.normalized = true;

	//cudaChannelFormatDesc desc = cudaCreateChannelDesc<float>();

	cudaBindTexture2D(0, texI0, I0, w, h, s * sizeof(float));
	cudaBindTexture2D(0, texI1, I1, w, h, s * sizeof(float));

	DirectComputeDerivativesKernel << < blocks, threads >> > (w, h, s, Ix, Iy, Iz);
}

//****************
// Gradient
//****************

texture<float, 2, cudaReadModeElementType> texForGradient;

__global__ void DirectGradientKernel(float* output, int width, int height, int stride) {
	int iy = blockIdx.y * blockDim.y + threadIdx.y;        // current row 
	int ix = blockIdx.x * blockDim.x + threadIdx.x;        // current column 

	if ((iy < height) && (ix < width))
	{
		int pos = ix + iy * stride;

		float dx = 1.0f / (float)width;
		float dy = 1.0f / (float)height;

		float x = ((float)ix + 0.5f) * dx;
		float y = ((float)iy + 0.5f) * dy;

		float2 grad;
		float t0;
		// x derivative
		t0 = tex2D(texForGradient, x + 1.0f * dx, y);
		t0 -= tex2D(texForGradient, x, y);
		t0 = tex2D(texForGradient, x + 1.0f * dx, y + 1.0f * dy);
		t0 -= tex2D(texForGradient, x, y + 1.0f * dy);
		grad.x = t0;

		// y derivative
		t0 = tex2D(texForGradient, x, y + 1.0f * dy);
		t0 -= tex2D(texForGradient, x, y);
		t0 = tex2D(texForGradient, x + 1.0f * dx, y + 1.0f * dy);
		t0 -= tex2D(texForGradient, x + 1.0f * dx, y);
		grad.y = t0;

		output[pos] = sqrtf(grad.x * grad.x + grad.y * grad.y);
	}
}


void DirectAlignment::Gradient(float* input, int w, int h, int s, float* output) {
	dim3 threads(BlockWidth, BlockHeight);
	dim3 blocks(iDivUp(width, threads.x), iDivUp(height, threads.y));

	// mirror if a coordinate value is out-of-range
	texForGradient.addressMode[0] = cudaAddressModeMirror;
	texForGradient.addressMode[1] = cudaAddressModeMirror;
	texForGradient.filterMode = cudaFilterModeLinear;
	texForGradient.normalized = true;
	cudaChannelFormatDesc desc = cudaCreateChannelDesc<float>();
	cudaBindTexture2D(0, texForGradient, input, w, h, s * sizeof(float));

	DirectGradientKernel << < blocks, threads >> > (output, w, h, s);
}

__global__ void DirectFilterGradient(float* gradient, float2* u, float2* umed, float threshold, 
	int width, int height, int stride) {
	int iy = blockIdx.y * blockDim.y + threadIdx.y;        // current row 
	int ix = blockIdx.x * blockDim.x + threadIdx.x;        // current column 

	if ((iy < height) && (ix < width))
	{
		int pos = ix + iy * stride;
		if (gradient[pos] <= threshold) {
			umed[pos].x = 0.0f;
			umed[pos].y = 0.0f;
			u[pos].x = 0.0f;
			u[pos].y = 0.0f;
		}
	}
}

void DirectAlignment::FilterGradient(float* gradient, float2* u, float2* umed, float threshold, int w, int h, int s)
{
	dim3 threads(BlockWidth, BlockHeight);
	dim3 blocks(iDivUp(w, threads.x), iDivUp(h, threads.y));

	//flowToHSVKernel << < blocks, threads >> >(u, v, w, h, s, uRGB, flowscale);
	DirectFilterGradient << < blocks, threads >> > (gradient, u, umed, threshold, w, h, s);
}


__global__
void DirectComputeColorKernel(float2 *uv, int width, int height, int stride, float3 *uvRGB, float flowscale) {
	int r = blockIdx.y * blockDim.y + threadIdx.y;        // current row 
	int c = blockIdx.x * blockDim.x + threadIdx.x;        // current column 

	if ((r < height) && (c < width))
	{
		int pos = c + stride * r;
		float du = uv[pos].x / flowscale;
		float dv = uv[pos].y / flowscale;

		int ncols = 55;
		float rad = sqrtf(du * du + dv * dv);
		float a = atan2(-dv, -du) / 3.14159f;
		float fk = (a + 1) / 2 * ((float)ncols - 1) + 1;
		int k0 = floorf(fk); //colorwheel index lower bound
		int k1 = k0 + 1; //colorwheel index upper bound
		if (k1 == ncols + 1) {
			k1 = 1;
		}
		float f = fk - (float)k0;

		float colorwheelR[55] = { 255, 255,	255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
			255, 213, 170, 128, 85, 43, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 19, 39, 58, 78, 98, 117, 137, 156,
			176, 196, 215, 235, 255, 255, 255, 255, 255, 255 };
		float colorwheelG[55] = { 0, 17, 34, 51, 68, 85, 102, 119, 136, 153, 170, 187, 204, 221, 238,
			255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 232, 209, 186, 163,
			140, 116, 93, 70, 47, 24, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
		float colorwheelB[55] = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
			0, 0, 0, 0, 0, 0, 0, 63, 127, 191, 255, 255, 255, 255, 255,
			255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255,
			255, 255, 255, 255, 255, 213, 170, 128, 85, 43 };

		float colR = (1 - f) * (colorwheelR[k0] / 255.0f) + f * (colorwheelR[k1] / 255.0f);
		float colG = (1 - f) * (colorwheelG[k0] / 255.0f) + f * (colorwheelG[k1] / 255.0f);
		float colB = (1 - f) * (colorwheelB[k0] / 255.0f) + f * (colorwheelB[k1] / 255.0f);

		if (rad <= 1) {
			colR = 1 - rad * (1 - colR);
			colG = 1 - rad * (1 - colG);
			colB = 1 - rad * (1 - colB);
		}
		else {
			colR = colR * 0.75;
			colG = colG * 0.75;
			colB = colB * 0.75;
		}

		uvRGB[pos].z = (colR);
		uvRGB[pos].y = (colG);
		uvRGB[pos].x = (colB);
	}
}

void DirectAlignment::FlowToHSV(float2* uv, int w, int h, int s, float3 * uRGB, float flowscale)
{
	dim3 threads(BlockWidth, BlockHeight);
	dim3 blocks(iDivUp(w, threads.x), iDivUp(h, threads.y));

	//flowToHSVKernel << < blocks, threads >> >(u, v, w, h, s, uRGB, flowscale);
	DirectComputeColorKernel << < blocks, threads >> > (uv, w, h, s, uRGB, flowscale);
}

