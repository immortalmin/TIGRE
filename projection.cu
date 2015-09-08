/*
 * Code that uses texture memory to compute a 3D projection of CBCT 
 *
 * IMPORTANT!!! CAUTION!! This code is designed for a Tesla 40k GPU.
 * It is a safe assumption to say that this code wont work in other GPUs as expected
 * or at all. Some of the involved reasons: float/double arithmetic.
 *
 * Ander Biguri
 */

#include <algorithm>
#include <cuda_runtime_api.h>
#include <cuda.h>
#include "projection.hpp"
#include "mex.h"
#include <math.h>

#define cudaCheckErrors(msg) \
    do { \
        cudaError_t __err = cudaGetLastError(); \
        if (__err != cudaSuccess) { \
            mexPrintf("%s \n",msg);\
            mexErrMsgIdAndTxt("CBCT:CUDA:interpolation",cudaGetErrorString(__err));\
		        } \
	    } while (0)
            

// Declare the texture reference.
texture<float, cudaTextureType3D , cudaReadModeElementType> tex; 

#define MAXTREADS 1024
/*GEOMETRY DEFINITION
 *               
 *                Detector plane, behind
 *            |-----------------------------| 
 *            |                             | 
 *            |                             | 
 *            |                             | 
 *            |                             | 
 *            |      +--------+             |
              |     /        /|             |
     A Z      |    /        / |*D           |
     |        |   +--------+  |             |
     |        |   |        |  |             |
     |        |   |     *O |  +             |
     *--->y   |   |        | /              |
    /         |   |        |/               |
   V X        |   +--------+                |
 *            |-----------------------------|
 *   
 *           *S
 *
 *
 *
 *
 *
 **/


__global__ void kernelPixelDetector( Geometry geo,
                                    double* detector,
                                    Point3D source ,
                                    Point3D deltaU, 
                                    Point3D deltaV,
                                    Point3D uvOrigin){
   
    size_t idx = threadIdx.x + blockIdx.x * blockDim.x;
    if (idx>= geo.nDetecU* geo.nDetecV)
        return;
    
    
   

    /////////////////////////////// Get pixel coords
    int pixelU = idx % geo.nDetecU;
    int pixelV = idx / geo.nDetecU;
    

    double vectX,vectY,vectZ;
    Point3D P;
    P.x=(uvOrigin.x+pixelU*deltaU.x+pixelV*deltaV.x);
    P.y=(uvOrigin.y+pixelU*deltaU.y+pixelV*deltaV.y);
    P.z=(uvOrigin.z+pixelU*deltaU.z+pixelV*deltaV.z);
    vectX=(P.x -source.x)/(geo.maxLength); 
    vectY=(P.y -source.y)/(geo.maxLength); 
    vectZ=(P.z -source.z)/(geo.maxLength); 
//     //here comes the deal
    double x,y,z;
    double sum=0;
    double i;

    for (i=0; i<=geo.maxLength; i=i+0.5){
        x=vectX*(double)i+source.x;
        y=vectY*(double)i+source.y;
        z=vectZ*(double)i+source.z;
        // Make sure we have an image for the index we are looking for. Check if out of image.
        //if(x<0 | y<0 | z<0 | x> (double)geo.nVoxelX-1.0 | y> (double)geo.nVoxelY-1.0 | z> (double)geo.nVoxelZ-1.0){
        //    continue;   
        //}
        sum += (double)tex3D(tex, x+0.5, y+0.5, z+0.5);
    }
    detector[idx]=sum*(sqrt((source.x-P.x)*(source.x-P.x)+(source.y-P.y)*(source.y-P.y)+(source.z-P.z)*(source.z-P.z))/geo.maxLength);
}



int projection(float const * const img, Geometry geo, double** result,double const * const alphas,int nalpha){
//     clock_t begin, end;
//     begin = clock();

   
    // BEFORE DOING ANYTHING: Use the proper CUDA enabled GPU: Tesla K40c
    
    int deviceCount = 0;
    cudaGetDeviceCount(&deviceCount);
     if (deviceCount == 0)
    {
        mexErrMsgIdAndTxt("CBCT:CUDA:Ax:cudaGetDeviceCount","No CUDA enabled NVIDIA GPUs found");
    }
    bool found=false;
    for (int dev = 0; dev < deviceCount; ++dev)
    {
        cudaSetDevice(dev);
        cudaDeviceProp deviceProp;
        cudaGetDeviceProperties(&deviceProp, dev);

        if (strcmp(deviceProp.name, "Tesla K40c") == 0){
            found=true;
            break;
        }
    }
    if (!found)
        mexErrMsgIdAndTxt("CBCT:CUDA:Ax:cudaDevice","No Tesla K40c found");
    // DONE, Tesla found
       
//     end = clock();
//     double time_tesla = (double)(end - begin) / CLOCKS_PER_SEC;
//     mexPrintf("Device check time: %lf ms\n" ,time_tesla*1000);
 
//     begin=clock();
    // copy data to CUDA memory
    cudaArray *d_imagedata = 0;

    const cudaExtent extent = make_cudaExtent(geo.nVoxelX, geo.nVoxelY, geo.nVoxelZ);
    cudaChannelFormatDesc channelDesc = cudaCreateChannelDesc<float>();
	cudaMalloc3DArray(&d_imagedata, &channelDesc, extent);
	cudaCheckErrors("cudaMalloc3D error 3D tex");
    
    cudaMemcpy3DParms copyParams = { 0 };
	copyParams.srcPtr = make_cudaPitchedPtr((void*)img, extent.width*sizeof(float), extent.width, extent.height);
	copyParams.dstArray = d_imagedata;
	copyParams.extent = extent;
	copyParams.kind = cudaMemcpyHostToDevice;
	cudaMemcpy3D(&copyParams);
    
	cudaCheckErrors("cudaMemcpy3D fail");
    
    // Configure texture options
    tex.normalized = false;
	tex.filterMode = cudaFilterModeLinear;
	tex.addressMode[0] = cudaAddressModeBorder;
	tex.addressMode[1] = cudaAddressModeBorder;
	tex.addressMode[2] = cudaAddressModeBorder;
    
    cudaBindTextureToArray(tex, d_imagedata, channelDesc);    
       
	cudaCheckErrors("3D texture memory bind fail"); 
    
//     end = clock();
//     double time_text = (double)(end - begin) / CLOCKS_PER_SEC;
//     mexPrintf("Texture memory allocation: %lf ms\n" ,time_text*1000);
    //Done! Image put into texture memory.
    
    // allocate projection memory
//     begin=clock();

    size_t num_bytes = geo.nDetecU*geo.nDetecV * sizeof(double);
    double* dProjection;
    cudaMalloc((void**)&dProjection, num_bytes);
    cudaCheckErrors("cudaMalloc fail");
    
//     end = clock();
//     double time_malloc = (double)(end - begin) / CLOCKS_PER_SEC;
//     mexPrintf("CUDA memory allocation: %lf ms\n" ,time_malloc*1000);
    
//     begin=clock();  
//     cudaEvent_t start, stop;
//     float elapsedTime;
    
    
    Point3D source, deltaU, deltaV, uvOrigin;
  
    for (int i=0;i<nalpha;i++){
        
        geo.alpha=alphas[i];
            // Sx is for the kernel

        geo.maxLength=computeMaxLength(geo,geo.alpha);
        
        computeDeltas(geo,geo.alpha, &uvOrigin, &deltaU, &deltaV, &source);
        

//             cudaEventCreate(&start);
//             cudaEventRecord(start,0); 
        
         kernelPixelDetector<<<(geo.nDetecU*geo.nDetecV + MAXTREADS-1) / MAXTREADS,MAXTREADS>>>(geo,dProjection, source, deltaU, deltaV, uvOrigin);
//          cudaEventCreate(&stop);
//          cudaEventRecord(stop,0);
//          cudaEventSynchronize(stop);
//          cudaEventElapsedTime(&elapsedTime, start,stop);
//          mexPrintf("%f " ,elapsedTime);
         

        cudaCheckErrors("Kernel fail");
         // copy result to host
        cudaMemcpy(result[i], dProjection, num_bytes, cudaMemcpyDeviceToHost);
        cudaCheckErrors("cudaMemcpy fail");
        

    }
//     end = clock();
//     double time_math = (double)(end - begin) / CLOCKS_PER_SEC;
//     mexPrintf("kernelkall+copyresult: %lf ms\n" ,time_math*1000);
    
    
//     begin=clock();

     cudaUnbindTexture(tex);
     cudaCheckErrors("Unbind  fail");
     
     cudaFree(dProjection);
     cudaFreeArray(d_imagedata);
     cudaCheckErrors("cudaFree d_imagedata fail");
     cudaDeviceReset();
//      end = clock();
//      double time_free = (double)(end - begin) / CLOCKS_PER_SEC;
//      mexPrintf("Free and reset device: %lf ms\n" ,time_free*1000);
//   
  

     
     
     
 return 0;   
}



double computeMaxLength(Geometry geo, double alpha){ // Ander: I like alpha as an argument tomake sure the programer puts it in. Explicit call. 
    
    //Start point
    Point3D S;
    S.x=geo.DSO;
    S.y=0;
    S.z=0;
    
    //End point
    Point3D P;
    P.x=-(geo.DSD-geo.DSO);
    P.y= geo.dDetecU*(0-(double)(geo.nDetecU/2)+0.5);
    P.z= geo.dDetecV*((double)(geo.nDetecV/2)+0.5-0);
    
    // Geomtric trasnformations:
    
    //1: Offset detector
       
    //P.x
    P.y=P.y+geo.offDetecU;
    P.z=P.z+geo.offDetecV;
    //S doesnt need to chagne
    
    //2: Offset image (instead of offseting image, -offset everything else)
    
    P.x=P.x-geo.offOrigX;
    P.y=P.y-geo.offOrigY;
    P.z=P.z-geo.offOrigZ;
    
    S.x=S.x-geo.offOrigX;
    S.y=S.y-geo.offOrigY;
    S.z=S.z-geo.offOrigZ;
    
    //3: Rotate (around z)!
    Point3D P2;   
    P2.x=P.x*cos(alpha)-P.y*sin(alpha);
    P2.y=P.y*cos(alpha)+P.x*sin(alpha);
    P2.z=P.z;
    Point3D S2; 
    S2.x=S.x*cos(alpha)-S.y*sin(alpha);
    S2.y=S.y*cos(alpha)+S.x*sin(alpha);
    S2.z=S.z;
    // As we want the (0,0,0) to be in a corner of the image, we need to translate everything (after rotation);
    P2.x=P2.x+geo.sVoxelX/2;
    P2.y=P2.y+geo.sVoxelY/2;
    P2.z=P2.z+geo.sVoxelZ/2;
    
    S2.x=S2.x+geo.sVoxelX/2;
    S2.y=S2.y+geo.sVoxelY/2;
    S2.z=S2.z+geo.sVoxelZ/2;
    
    //4. Scale everything so dVoxel==1
    P2.x=P2.x/geo.dVoxelX;
    P2.y=P2.y/geo.dVoxelY;
    P2.z=P2.z/geo.dVoxelZ;
    S2.x=S2.x/geo.dVoxelX;
    S2.y=S2.y/geo.dVoxelY;
    S2.z=S2.z/geo.dVoxelZ;
    
    
    return sqrt((P2.x-S2.x)*(P2.x-S2.x)   +    (P2.y-S2.y)*(P2.y-S2.y) +(P2.z-S2.z)*(P2.z-S2.z) );
}

/* This code precomputes The location of the source and the Delta U and delta V (in the warped space) 
 * to compute the locations of the x-rays. While it seems verbose and overly-optimized, 
 * it does saves about 30% of each of the kernel calls. Thats something!
 **/
void computeDeltas(Geometry geo, double alpha, Point3D* uvorigin, Point3D* deltaU, Point3D* deltaV, Point3D* source){
    Point3D S;
    S.x=geo.DSO;
    S.y=0;
    S.z=0;
    
    //End point
    Point3D P,Pu0,Pv0;
    P.x=-(geo.DSD-geo.DSO);
    P.y= geo.dDetecU*(0-(double)(geo.nDetecU/2)+0.5);
    P.z= geo.dDetecV*((double)(geo.nDetecV/2)+0.5-0);
    
    Pu0.x=-(geo.DSD-geo.DSO);
    Pu0.y= geo.dDetecU*(1-(double)(geo.nDetecU/2)+0.5);
    Pu0.z= geo.dDetecV*((double)(geo.nDetecV/2)+0.5-0);
    
    Pv0.x=-(geo.DSD-geo.DSO);
    Pv0.y= geo.dDetecU*(0-(double)(geo.nDetecU/2)+0.5);
    Pv0.z= geo.dDetecV*((double)(geo.nDetecV/2)+0.5-1);
    // Geomtric trasnformations:
    
    //1: Offset detector
       
    //P.x
    P.y=P.y+geo.offDetecU;
    P.z=P.z+geo.offDetecV;
    Pu0.y=Pu0.y+geo.offDetecU;
    Pu0.z=Pu0.z+geo.offDetecV;
    Pv0.y=Pv0.y+geo.offDetecU;
    Pv0.z=Pv0.z+geo.offDetecV;
    //S doesnt need to chagne
    
    //2: Offset image (instead of offseting image, -offset everything else)
    
    P.x=P.x-geo.offOrigX;
    P.y=P.y-geo.offOrigY;
    P.z=P.z-geo.offOrigZ;
    Pu0.x=Pu0.x-geo.offOrigX;
    Pu0.y=Pu0.y-geo.offOrigY;
    Pu0.z=Pu0.z-geo.offOrigZ;
    Pv0.x=Pv0.x-geo.offOrigX;
    Pv0.y=Pv0.y-geo.offOrigY;
    Pv0.z=Pv0.z-geo.offOrigZ;
    
    S.x=S.x-geo.offOrigX;
    S.y=S.y-geo.offOrigY;
    S.z=S.z-geo.offOrigZ;
    
    //3: Rotate (around z)!
    Point3D Pfinal, Pfinalu0, Pfinalv0;   
    Pfinal.x=P.x*cos(geo.alpha)-P.y*sin(geo.alpha);
    Pfinal.y=P.y*cos(geo.alpha)+P.x*sin(geo.alpha);
    Pfinal.z=P.z;
    
    Pfinalu0.x=Pu0.x*cos(geo.alpha)-Pu0.y*sin(geo.alpha);
    Pfinalu0.y=Pu0.y*cos(geo.alpha)+Pu0.x*sin(geo.alpha);
    Pfinalu0.z=Pu0.z;
    Pfinalv0.x=Pv0.x*cos(geo.alpha)-Pv0.y*sin(geo.alpha);
    Pfinalv0.y=Pv0.y*cos(geo.alpha)+Pv0.x*sin(geo.alpha);
    Pfinalv0.z=Pv0.z;
    
    Point3D S2; 
    S2.x=S.x*cos(geo.alpha)-S.y*sin(geo.alpha);
    S2.y=S.y*cos(geo.alpha)+S.x*sin(geo.alpha);
    S2.z=S.z;
    // As we want the (0,0,0) to be in a corner of the image, we need to translate everything (after rotation);
    Pfinal.x=Pfinal.x+geo.sVoxelX/2;
    Pfinal.y=Pfinal.y+geo.sVoxelY/2;
    Pfinal.z=Pfinal.z+geo.sVoxelZ/2;
    
    Pfinalu0.x=Pfinalu0.x+geo.sVoxelX/2;
    Pfinalu0.y=Pfinalu0.y+geo.sVoxelY/2;
    Pfinalu0.z=Pfinalu0.z+geo.sVoxelZ/2;
    
    Pfinalv0.x=Pfinalv0.x+geo.sVoxelX/2;
    Pfinalv0.y=Pfinalv0.y+geo.sVoxelY/2;
    Pfinalv0.z=Pfinalv0.z+geo.sVoxelZ/2;
    
    
    S2.x=S2.x+geo.sVoxelX/2;
    S2.y=S2.y+geo.sVoxelY/2;
    S2.z=S2.z+geo.sVoxelZ/2;
    
    //4. Scale everything so dVoxel==1
    Pfinal.x=Pfinal.x/geo.dVoxelX;
    Pfinal.y=Pfinal.y/geo.dVoxelY;
    Pfinal.z=Pfinal.z/geo.dVoxelZ;
    Pfinalu0.x=Pfinalu0.x/geo.dVoxelX;
    Pfinalu0.y=Pfinalu0.y/geo.dVoxelY;
    Pfinalu0.z=Pfinalu0.z/geo.dVoxelZ;
    Pfinalv0.x=Pfinalv0.x/geo.dVoxelX;
    Pfinalv0.y=Pfinalv0.y/geo.dVoxelY;
    Pfinalv0.z=Pfinalv0.z/geo.dVoxelZ;
    
    
    S2.x=S2.x/geo.dVoxelX;
    S2.y=S2.y/geo.dVoxelY;
    S2.z=S2.z/geo.dVoxelZ;   
    
    // return
    
    *uvorigin=Pfinal;
    
    deltaU->x=Pfinalu0.x-Pfinal.x;
    deltaU->y=Pfinalu0.y-Pfinal.y;
    deltaU->z=Pfinalu0.z-Pfinal.z;
    
    deltaV->x=Pfinalv0.x-Pfinal.x;
    deltaV->y=Pfinalv0.y-Pfinal.y;
    deltaV->z=Pfinalv0.z-Pfinal.z;
    
    *source=S2;
}






///////////////////// The code below is not used.

// This function scales the geometrical data so all the image voxels are 1x1x1
Geometry nomralizeGeometryImage(Geometry geo){
    
    Geometry nGeo; //Normalized geometry
    //Copy input values
    nGeo=geo;
    
    // This is why we are doing this stuff
    nGeo.dVoxelX=1;
    nGeo.dVoxelY=1;
    nGeo.dVoxelZ=1;
    // Change total size
    nGeo.sVoxelX=geo.sVoxelX/geo.dVoxelX; //This shoudl be == geo.nVoxelX;
    nGeo.sVoxelY=geo.sVoxelY/geo.dVoxelY; //This shoudl be == geo.nVoxelY;
    nGeo.sVoxelZ=geo.sVoxelZ/geo.dVoxelZ; //This shoudl be == geo.nVoxelZ;
    
    // As in the beggining U is alinged with Y and V with Z, they also need to be modified.
    
    nGeo.dDetecU=geo.dDetecU/geo.dVoxelY;
    nGeo.dDetecV=geo.dDetecV/geo.dVoxelZ;

    //Modify DSO and DSD w.r.t. X
    
    nGeo.DSO=geo.DSO/geo.dVoxelX;
    nGeo.DSD=geo.DSD/geo.dVoxelX;
    
    // The new "units" have this real size
    nGeo.unitX=geo.dVoxelX;
    nGeo.unitY=geo.dVoxelY;
    nGeo.unitZ=geo.dVoxelZ;

    //Compute maxlength
    nGeo.maxLength=sqrt(nGeo.DSD*nGeo.DSD+sqrt(nGeo.sDetecU/2*nGeo.sDetecU/2+nGeo.sDetecV/2*nGeo.sDetecV/2));

    return nGeo;
    
}