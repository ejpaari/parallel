/* Udacity Homework 3
   HDR Tone-mapping

   Background HDR
   ==============

   A High Dynamic Range (HDR) image contains a wider variation of intensity
   and color than is allowed by the RGB format with 1 byte per channel that we
   have used in the previous assignment.  

   To store this extra information we use single precision floating point for
   each channel.  This allows for an extremely wide range of intensity values.

   In the image for this assignment, the inside of church with light coming in
   through stained glass windows, the raw input floating point values for the
   channels range from 0 to 275.  But the mean is .41 and 98% of the values are
   less than 3!  This means that certain areas (the windows) are extremely bright
   compared to everywhere else.  If we linearly map this [0-275] range into the
   [0-255] range that we have been using then most values will be mapped to zero!
   The only thing we will be able to see are the very brightest areas - the
   windows - everything else will appear pitch black.

   The problem is that although we have cameras capable of recording the wide
   range of intensity that exists in the real world our monitors are not capable
   of displaying them.  Our eyes are also quite capable of observing a much wider
   range of intensities than our image formats / monitors are capable of
   displaying.

   Tone-mapping is a process that transforms the intensities in the image so that
   the brightest values aren't nearly so far away from the mean.  That way when
   we transform the values into [0-255] we can actually see the entire image.
   There are many ways to perform this process and it is as much an art as a
   science - there is no single "right" answer.  In this homework we will
   implement one possible technique.

   Background Chrominance-Luminance
   ================================

   The RGB space that we have been using to represent images can be thought of as
   one possible set of axes spanning a three dimensional space of color.  We
   sometimes choose other axes to represent this space because they make certain
   operations more convenient.

   Another possible way of representing a color image is to separate the color
   information (chromaticity) from the brightness information.  There are
   multiple different methods for doing this - a common one during the analog
   television days was known as Chrominance-Luminance or YUV.

   We choose to represent the image in this way so that we can remap only the
   intensity channel and then recombine the new intensity values with the color
   information to form the final image.

   Old TV signals used to be transmitted in this way so that black & white
   televisions could display the luminance channel while color televisions would
   display all three of the channels.
  

   Tone-mapping
   ============

   In this assignment we are going to transform the luminance channel (actually
   the log of the luminance, but this is unimportant for the parts of the
   algorithm that you will be implementing) by compressing its range to [0, 1].
   To do this we need the cumulative distribution of the luminance values.

   Example
   -------

   input : [2 4 3 3 1 7 4 5 7 0 9 4 3 2]
   min / max / range: 0 / 9 / 9

   histo with 3 bins: [4 7 3]

   cdf : [4 11 14]


   Your task is to calculate this cumulative distribution by following these
   steps.

*/

#include "utils.h"

__global__
void minValue(float* min_logLum, const float* const d_logLuminance, int length)
{
    extern __shared__ float s_data[];
    int myId = threadIdx.x + blockDim.x * blockIdx.x;
    int tid = threadIdx.x;
    int bid = blockIdx.x;

    s_data[tid] = myId < length ? d_logLuminance[myId] : 999.0f;

    __syncthreads();

    for (unsigned int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) {
            s_data[tid] = min(s_data[tid], s_data[tid + s]);
        }
        __syncthreads();
    }

    if (tid == 0) {
        min_logLum[bid] = s_data[0];
    }
}

__global__
void maxValue(float* max_logLum, const float* const d_logLuminance, int length)
{
    extern __shared__ float s_data[];
    int myId = threadIdx.x + blockDim.x * blockIdx.x;
    int tid = threadIdx.x;
    int bid = blockIdx.x;

    s_data[tid] = myId < length ? d_logLuminance[myId] : 999.0f;

    __syncthreads();

    for (unsigned int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) {
            s_data[tid] = max(s_data[tid], s_data[tid + s]);
        }
        __syncthreads();
    }

    if (tid == 0) {
        max_logLum[bid] = s_data[0];
    }
}

__global__
void histogram(const float* const d_logLuminance, unsigned int* const d_out, int numBins, 
               size_t numPixels, float lumMin, float lumRange)
{
    int myId = threadIdx.x + blockDim.x * blockIdx.x;
    if (myId >= numPixels) {
        return;
    }
    if (myId < numBins) {
        d_out[myId] = 0;
    }

    __syncthreads();

    int bin = (d_logLuminance[myId] - lumMin) / lumRange * numBins;
    bin = min(bin, numBins - 1);
    atomicAdd(&d_out[bin], 1);
}

__global__
void exclusiveSumScan(unsigned int* const d_cdf, int numBins)
{
	int tid = threadIdx.x;
	if (tid >= numBins) {
        return;
    }

    // Inclusive Hillis-Steele scan
    unsigned int value = 0;
	for (int i = 1; i < numBins; i <<= 1) {
        value = tid >= i ? d_cdf[tid-i] + d_cdf[tid] : d_cdf[tid];
		__syncthreads();
		d_cdf[tid] = value;
		__syncthreads();
	}

    // Make exclusive
    unsigned int exclusiveValue = tid == 0 ? 0 : d_cdf[tid-1];
    __syncthreads();
    d_cdf[tid] = exclusiveValue;
}

void your_histogram_and_prefixsum(const float* const d_logLuminance,
                                  unsigned int* const d_cdf,
                                  float &min_logLum,
                                  float &max_logLum,
                                  const size_t numRows,
                                  const size_t numCols,
                                  const size_t numBins)
{
    size_t numPixels = numRows * numCols;
    const int threads = 1024;
    const int blocks = ceil(static_cast<float>(numPixels) / static_cast<float>(threads));

    int floatSize = sizeof(float);
    float* d_cache;
    checkCudaErrors(cudaMalloc((void**) &d_cache, floatSize));

    minValue<<<blocks, threads, threads * floatSize>>>(d_cache, d_logLuminance, numPixels);
    minValue<<<1, blocks, blocks * floatSize>>>(d_cache, d_cache, blocks);
    checkCudaErrors(cudaMemcpy(&min_logLum, d_cache, floatSize, cudaMemcpyDeviceToHost));

    maxValue<<<blocks, threads, threads * floatSize>>>(d_cache, d_logLuminance, numPixels);
    maxValue<<<1, blocks, blocks * floatSize>>>(d_cache, d_cache, blocks);
    checkCudaErrors(cudaMemcpy(&max_logLum, d_cache, floatSize, cudaMemcpyDeviceToHost));

    histogram<<<blocks, threads>>>(d_logLuminance, d_cdf, numBins, numPixels, min_logLum, max_logLum-min_logLum);

    exclusiveSumScan<<<1, numBins>>>(d_cdf, numBins);

    checkCudaErrors(cudaFree(d_cache));
}
