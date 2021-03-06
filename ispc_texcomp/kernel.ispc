//
// BC1-BC5 encoding implementation.
//

//
//  Copyright (c) 2016 Intel Corporation
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy of this 
//  software and associated documentation files (the "Software"), to deal in the Software 
//  without restriction, including without limitation the rights to use, copy, modify, 
//  merge, publish, distribute, sublicense, and/or sell copies of the Software, and to 
//  permit persons to whom the Software is furnished to do so, subject to the following 
//  conditions: 
//
//  The above copyright notice and this permission notice shall be included in all copies 
//  or substantial portions of the Software.  
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, 
//  INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A 
//  PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT 
//  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF 
//  CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE 
//  OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

#include "kernel_shared.isph"

///////////////////////////////////////////////////////////
//				    BC1/BC2/BC3/BC4/BC5/BC7 shared

///////////////////////////////////////////////////////////
//					 BC1/BC2/BC3/BC4/BC5 encoding

inline int stb__Mul8Bit(int a, int b)
{
	int t = a*b + 128;
	return (t + (t >> 8)) >> 8;
}

inline unsigned int16 stb__As16Bit(int r, int g, int b)
{
	return (stb__Mul8Bit(r,31) << 11) + (stb__Mul8Bit(g,63) << 5) + stb__Mul8Bit(b,31);
}

inline unsigned int16 enc_rgb565(float c[3])
{
	return stb__As16Bit((int)c[0], (int)c[1], (int)c[2]);
}

inline void dec_rgb565(float c[3], int p)
{
	int c2 = (p>>0)&31;
	int c1 = (p>>5)&63;
	int c0 = (p>>11)&31;

	c[0] = (c0<<3)+(c0>>2);
	c[1] = (c1<<2)+(c1>>4);
	c[2] = (c2<<3)+(c2>>2);
}

inline void pick_endpoints_dc(int c0[3], int c1[3], int block[48], int iaxis[3])
{
	for (uniform int p=0; p<3; p++)
		for (uniform int y=0; y<4; y++)
			for (uniform int x=0; x<4; x++)
				c0[p] += block[p*16+y*4+x];

	for (uniform int p=0; p<3; p++)
		c0[p] >>= 4;
}

inline void pick_endpoints(float c0[3], float c1[3], float block[48], float axis[3], float dc[3])
{
	float min_dot = 256*256;
	float max_dot = 0;

	for (uniform int y=0; y<4; y++)
	{
		for (uniform int x=0; x<4; x++)
		{
			float dot = 0;
			for (uniform int p=0; p<3; p++)
				dot += (block[p*16+y*4+x]-dc[p])*axis[p];
	
			min_dot = min(min_dot, dot);
			max_dot = max(max_dot, dot);
		}
	}

	if (max_dot-min_dot < 1f)
	{
		min_dot -= 0.5f;
		max_dot += 0.5f;
	}

	float norm_sq = 0;
	for (uniform int p=0; p<3; p++)
		norm_sq += axis[p]*axis[p];

	float rnorm_sq = rcp(norm_sq);
	for (uniform int p=0; p<3; p++)
	{
		c0[p] = clamp(dc[p]+min_dot*rnorm_sq*axis[p], 0, 255);
		c1[p] = clamp(dc[p]+max_dot*rnorm_sq*axis[p], 0, 255);
	}
}

inline uint32 fast_quant(float block[48], int p0, int p1)
{
	float c0[3];
	float c1[3];
	dec_rgb565(c0, p0);
	dec_rgb565(c1, p1);

	float dir[3];
	for (uniform int p=0; p<3; p++)
		dir[p] = c1[p]-c0[p];
    
	float sq_norm = 0;
	for (uniform int p=0; p<3; p++)
		sq_norm += sq(dir[p]);

	float rsq_norm = rcp(sq_norm);

	for (uniform int p=0; p<3; p++)
		dir[p] *= rsq_norm*3;

	float bias = 0.5;
	for (uniform int p=0; p<3; p++)
		bias -= c0[p]*dir[p];

	uint32 bits = 0;    
	uint32 scaler = 1;
	for (uniform int k=0; k<16; k++)
	{
		float dot = 0;
		for (uniform int p=0; p<3; p++)
			dot += block[k+p*16]*dir[p];

		int q = clamp((int)(dot+bias), 0, 3);

		//bits += q<<(k*2);
		bits += q*scaler;
		scaler *= 4;
	}
	
	return bits;
}

inline void compute_covar_dc(float covar[6], float dc[3], float block[48])
{
	for (uniform int i=0; i<6; i++)
		covar[i] = 0;
	for (uniform int p=0; p<3; p++)
		dc[p] = 0;

	for (uniform int k=0; k<16; k++)
		for (uniform int p=0; p<3; p++)
			dc[p] += block[k+p*16];

	for (uniform int p=0; p<3; p++)
		dc[p] /= 16;
	
	for (uniform int k=0; k<16; k++)
	{
		float rgb[3];
		for (uniform int p=0; p<3; p++)
			rgb[p] = block[k+p*16]-dc[p];
		
		covar[0] += rgb[0]*rgb[0];
		covar[1] += rgb[0]*rgb[1];
		covar[2] += rgb[0]*rgb[2];
		
		covar[3] += rgb[1]*rgb[1];
		covar[4] += rgb[1]*rgb[2];

		covar[5] += rgb[2]*rgb[2];
	}
}

// ugly, but makes BC1 compression 20% faster overall
inline void compute_covar_dc_ugly(float covar[6], float dc[3], float block[48])
{
	for (uniform int p=0; p<3; p++)
	{
		float acc = 0;
		for (uniform int k=0; k<16; k++)
			acc += block[k+p*16];
		dc[p] = acc/16;
	}
	
	float covar0 = 0f;
	float covar1 = 0f;
	float covar2 = 0f;
	float covar3 = 0f;
	float covar4 = 0f;
	float covar5 = 0f;

	for (uniform int k=0; k<16; k++)
	{
		float rgb0, rgb1, rgb2;
		rgb0 = block[k+0*16]-dc[0];
		rgb1 = block[k+1*16]-dc[1];
		rgb2 = block[k+2*16]-dc[2];
		
		covar0 += rgb0*rgb0;
		covar1 += rgb0*rgb1;
		covar2 += rgb0*rgb2;
		
		covar3 += rgb1*rgb1;
		covar4 += rgb1*rgb2;

		covar5 += rgb2*rgb2;
	}

	covar[0] = covar0;
	covar[1] = covar1;
	covar[2] = covar2;
	covar[3] = covar3;
	covar[4] = covar4;
	covar[5] = covar5;
}

inline void bc1_refine(int pe[2], float block[48], unsigned int32 bits, float dc[3])
{
	float c0[3];
	float c1[3];

	if ((bits ^ (bits*4)) < 4)
	{
		// single color
		for (uniform int p=0; p<3; p++)
		{
			c0[p] = dc[p];
			c1[p] = dc[p];
		}
	}
	else
	{
		float Atb1[3] = {0,0,0};
		float sum_q = 0;
		float sum_qq = 0;
		unsigned int32 shifted_bits = bits;
               
		for (uniform int k=0; k<16; k++)
		{
			float q = (int)(shifted_bits&3);
			shifted_bits >>= 2;

			float x = 3-q;
			float y = q;
            
			sum_q += q;
			sum_qq += q*q;

			for (uniform int p=0; p<3; p++)
				Atb1[p] += x*block[k+p*16];
		}
        
		float sum[3];
		float Atb2[3];

		for (uniform int p=0; p<3; p++) 
		{
			sum[p] = dc[p]*16;
			Atb2[p] = 3*sum[p]-Atb1[p];
		}
        
		float Cxx = 16*sq(3)-2*3*sum_q+sum_qq;
		float Cyy = sum_qq;
		float Cxy = 3*sum_q-sum_qq;
		float scale = 3f * rcp(Cxx*Cyy - Cxy*Cxy);

		for (uniform int p=0; p<3; p++)
		{
			c0[p] = (Atb1[p]*Cyy - Atb2[p]*Cxy)*scale;
			c1[p] = (Atb2[p]*Cxx - Atb1[p]*Cxy)*scale;
			
			c0[p] = clamp(c0[p], 0, 255);
			c1[p] = clamp(c1[p], 0, 255);
		}
	}

	pe[0] = enc_rgb565(c0);
	pe[1] = enc_rgb565(c1);
}

inline uint32 fix_qbits(uint32 qbits)
{
	uniform const uint32 mask_01b = 0x55555555;
	uniform const uint32 mask_10b = 0xAAAAAAAA;

	uint32 qbits0 = qbits&mask_01b;
	uint32 qbits1 = qbits&mask_10b;
	qbits = (qbits1>>1) + (qbits1 ^ (qbits0<<1));

	return qbits;
}


///////////////////////////////////////////////////////////
// Low level per block handling
//
inline void CompressBlockBC1_core( float BlockInput[48], uint32 BlockOutput[2], bool AllowSecondaryMode )
{
	uniform const int powerIterations = 4;
	uniform const int refineIterations = 1;
    
	float covar[6];
	float dc[3];
	compute_covar_dc_ugly(covar, dc, BlockInput);
	
	float eps = 0.001;
	covar[0] += eps;
	covar[3] += eps;
	covar[5] += eps;
	
	float axis[3];
	compute_axis3(axis, covar, powerIterations);
		
	float c0[3];
	float c1[3];
	pick_endpoints(c0, c1, BlockInput, axis, dc);
	
	int p[2];
	p[0] = enc_rgb565(c0);
	p[1] = enc_rgb565(c1);
	if (p[0]<p[1])
		swap_ints(&p[0], &p[1], 1);
	
	BlockOutput[0] = (1<<16)*p[1]+p[0];
	BlockOutput[1] = fast_quant(BlockInput, p[0], p[1]);
    	
	// refine
	for (uniform int i=0; i<refineIterations; i++)
	{
		bc1_refine(p, BlockInput, BlockOutput[1], dc);
		if (p[0]<p[1])
			swap_ints(&p[0], &p[1], 1);
		BlockOutput[0] = (1<<16)*p[1]+p[0];
		BlockOutput[1] = fast_quant(BlockInput, p[0], p[1]);
	}
	
	BlockOutput[1] = fix_qbits(BlockOutput[1]);
}

///////////////////////////////////////////////////////////
// BC2 quantization routine.
//
// BC2 stores a 4 bit unsigned normalized integer for each alpha value.
//

// Maps alpha values into [0,15] and rounds to nearest integer.
inline void QuantizeBlockBC2_alpha( float AlphaInput[16], uint32 AlphaOutput[2] )
{
	int32 Rows[4];

	for ( uniform int Row=0; Row<4; Row++ )
	{
		Rows[Row] = ((((int32)round(AlphaInput[4*Row+0]/255.f*15.f))&0xF)<< 0)
							| ((((int32)round(AlphaInput[4*Row+1]/255.f*15.f))&0xF)<< 4)
							| ((((int32)round(AlphaInput[4*Row+2]/255.f*15.f))&0xF)<< 8)
							| ((((int32)round(AlphaInput[4*Row+3]/255.f*15.f))&0xF)<<12);
	}

	AlphaOutput[0] = (Rows[0]<<0) | (Rows[1]<<16);
	AlphaOutput[1] = (Rows[2]<<0) | (Rows[3]<<16);
}


///////////////////////////////////////////////////////////
// BC3 alpha/BC4/BC5 compression routine.
//
// References:
//  https://www.khronos.org/registry/OpenGL/extensions/EXT/EXT_texture_compression_s3tc.txt
//  https://www.khronos.org/registry/OpenGL/extensions/ARB/ARB_texture_compression_rgtc.txt
//  https://msdn.microsoft.com/de-de/library/windows/desktop/bb694531(v=vs.85).aspx
//
// The format stores two 1 byte integer endpoints (alpha_0 and alpha) which are used to 
// create a 3-bit/8 value palette. It offers two modes which are selected depending on 
// whether alpha_0 > alpha_1.
//
// The endpoints are followed by 16 3-bit values for each pixel.
// 
// The endpoints are signed/unsigned byte depending on whether the format is either
// signed or unsigned. The BC3 alpha is regarded as unsigned.
//
// Depending on mode, folowing values are used for the palette (code taken off above msdn link):
//
// if( alpha_0 > alpha_1 )
// {
//   // 6 interpolated alpha values.
//   alpha_2 = 6/7*alpha_0 + 1/7*alpha_1; // bit code 010
//   alpha_3 = 5/7*alpha_0 + 2/7*alpha_1; // bit code 011
//   alpha_4 = 4/7*alpha_0 + 3/7*alpha_1; // bit code 100
//   alpha_5 = 3/7*alpha_0 + 4/7*alpha_1; // bit code 101
//   alpha_6 = 2/7*alpha_0 + 5/7*alpha_1; // bit code 110
//   alpha_7 = 1/7*alpha_0 + 6/7*alpha_1; // bit code 111
// }
// else
// {
//   // 4 interpolated alpha values.
//   alpha_2 = 4/5*alpha_0 + 1/5*alpha_1; // bit code 010
//   alpha_3 = 3/5*alpha_0 + 2/5*alpha_1; // bit code 011
//   alpha_4 = 2/5*alpha_0 + 3/5*alpha_1; // bit code 100
//   alpha_5 = 1/5*alpha_0 + 4/5*alpha_1; // bit code 101
//   alpha_6 = 0.0;                       // bit code 110, for an unsigned format
//   alpha_6 =-1.0;                       // bit code 110, for a signed format
//   alpha_7 = 1.0;                       // bit code 111
// }
//
// In either of them:
//   bit code 000 will be alpha_0
//   bit code 001 will be alpha_1
//

inline void CompressBlockBC3_alpha( float AlphaInput[16], uint32 AlphaOutput[2] )
{
	float MinValue = 255;
	float MaxValue = 0;

	// Find min and max float values in block.
	for ( uniform int k=0; k<16; k++ )
	{
		MinValue = min( MinValue, AlphaInput[k] );
		MaxValue = max( MaxValue, AlphaInput[k] );
	}

	// Pick endpoints beeing integer values in [0,255].
	float Endpoints[2];
	Endpoints[0] = min(ceil(MaxValue),255f); // alpha_0.
	Endpoints[1] = max(0f,floor(MinValue));  // alpha_1.

	// Make sure alpha0 > alpha1 to stay in the same mode.
	if ( Endpoints[0]==Endpoints[1] )
	{
		if ( Endpoints[0]<255f )
			Endpoints[0] += 1f;
		else
			Endpoints[1] -= 1f;
	}

	uint32 qblock[2] = { 0, 0 }; // Stores 24-bit/8 indices per element.
	float scale = 7f/(Endpoints[0]-Endpoints[1]);

	for ( uniform int k=0; k<16; k++ )
	{
		// Projection into [alpha_1,alpha_0], so that: alpha = q/7*alpha_0 + (7-q)/7*alpha_1
		float v = AlphaInput[k];
		float proj = (v-Endpoints[1])*scale+0.5f; // Maybe round instead?
		int q = clamp( (int)proj, 0, 7 );

		// Remap projection ordering into alpha_0 > alpha_1 mode ordering.
		q = 7-q;
		if (q > 0)
			q++;
		if (q==8)
			q = 1;

		// Set index aside.
		qblock[k/8] |= q << ((k%8)*3);
	}

	// (could be improved by refinement)
	AlphaOutput[0]  = clamp((int)Endpoints[0],0,255) + clamp((int)Endpoints[1],0,255)*256;
	AlphaOutput[0] |= qblock[0]<<16;
	AlphaOutput[1]  = qblock[0]>>16;
	AlphaOutput[1] |= qblock[1]<<8;
}


///////////////////////////////////////////////////////////
// High level per block handling.
//
// BlockInput[]:
//   0-15: Red
//  16-31: Green
//  32-47: Blue
//  48-63: Alpha
//

inline void CompressBlockBC1( float BlockInput[48], uint32 BlockOutput[2] )
{
	CompressBlockBC1_core( BlockInput, BlockOutput, false );
}

// !! I'm using this for secondary mode testing for now.
inline void CompressBlockBC1PA( float BlockInput[48], uint32 BlockOutput[2] )
{
	CompressBlockBC1_core ( &BlockInput[ 0], &BlockOutput[2], true );
}

inline void CompressBlockBC2( float BlockInput[64], uint32 BlockOutput[4] )
{
	QuantizeBlockBC2_alpha( &BlockInput[48], &BlockOutput[0] );
	CompressBlockBC1_core ( &BlockInput[ 0], &BlockOutput[2], false );
}

inline void CompressBlockBC3( float BlockInput[64], uint32 BlockOutput[4] )
{
	CompressBlockBC3_alpha( &BlockInput[48], &BlockOutput[0] );
	CompressBlockBC1_core ( &BlockInput[ 0], &BlockOutput[2], false );
}

inline void CompressBlockBC4( float BlockInput[16], uint32 BlockOutput[2] )
{
	CompressBlockBC3_alpha( BlockInput, BlockOutput );
}

inline void CompressBlockBC5( float BlockInput[32], uint32 BlockOutput[4] )
{
	CompressBlockBC3_alpha( &BlockInput[ 0], &BlockOutput[0] );
	CompressBlockBC3_alpha( &BlockInput[16], &BlockOutput[2] );
}


///////////////////////////////////////////////////////////
// Dispatcher from input surface to block level.
//
// Templates would be nice here, but not in ispc, maybe preprocessor macros?
// Are there function pointers available in ispc?
// 

#define COMPRESSION_ENTRY_POINT(export_name,compress_routine,surface_type,load_routine,num_floats,num_block_dwords) \
	export void export_name( uniform surface_type InputSurface[], uniform uint8 OutputBlocks[] ) \
	{	\
		uniform int NumHorizontalBlocks = InputSurface->Width/4; \
		uniform int NumVerticalBlocks   = InputSurface->Height/4; \
		 \
		for ( uniform int VerticalBlockIndex=0; VerticalBlockIndex<NumVerticalBlocks; VerticalBlockIndex++ ) \
		{ \
			foreach ( HorizontalBlockIndex=0...NumHorizontalBlocks ) \
			{ \
				float BlockInput[num_floats]; \
				uint32 BlockOutput[num_block_dwords]; \
				 \
				load_routine( BlockInput, InputSurface, HorizontalBlockIndex, VerticalBlockIndex ); \
				compress_routine( BlockInput, BlockOutput ); \
				StoreCompressedBlock( OutputBlocks, InputSurface->Width, HorizontalBlockIndex, VerticalBlockIndex, BlockOutput, num_block_dwords ); \
			} \
		} \
	}

// BC1.
COMPRESSION_ENTRY_POINT(BC1CompressRGBA8,CompressBlockBC1,Surface_RGBA8,LoadUncompressed4x4BlockInterleavedNoAlpha_RGBA8,48,2)
COMPRESSION_ENTRY_POINT(BC1CompressRGBA16,CompressBlockBC1,Surface_RGBA16,LoadUncompressed4x4BlockInterleavedNoAlpha_RGBA16,48,2)

// BC1 PA.
COMPRESSION_ENTRY_POINT(BC1PACompressRGBA8,CompressBlockBC1PA,Surface_RGBA8,LoadUncompressed4x4BlockInterleavedNoAlpha_RGBA8,48,2)
COMPRESSION_ENTRY_POINT(BC1PACompressRGBA16,CompressBlockBC1PA,Surface_RGBA16,LoadUncompressed4x4BlockInterleavedNoAlpha_RGBA16,48,2)

// BC2.
COMPRESSION_ENTRY_POINT(BC2CompressRGBA8,CompressBlockBC2,Surface_RGBA8,LoadUncompressed4x4BlockInterleaved_RGBA8,64,4)
COMPRESSION_ENTRY_POINT(BC2CompressRGBA16,CompressBlockBC2,Surface_RGBA16,LoadUncompressed4x4BlockInterleaved_RGBA16,64,4)

// BC3.
COMPRESSION_ENTRY_POINT(BC3CompressRGBA8,CompressBlockBC3,Surface_RGBA8,LoadUncompressed4x4BlockInterleaved_RGBA8,64,4)
COMPRESSION_ENTRY_POINT(BC3CompressRGBA16,CompressBlockBC3,Surface_RGBA16,LoadUncompressed4x4BlockInterleaved_RGBA16,64,4)

// BC4.
COMPRESSION_ENTRY_POINT(BC4CompressR8,CompressBlockBC4,Surface_R8,LoadUncompressed4x4Block_R8,16,2)
COMPRESSION_ENTRY_POINT(BC4CompressR16,CompressBlockBC4,Surface_R16,LoadUncompressed4x4Block_R16,16,2)

// BC5.
COMPRESSION_ENTRY_POINT(BC5CompressRG8,CompressBlockBC5,Surface_RG8,LoadUncompressed4x4BlockInterleaved_RG8,32,4)
COMPRESSION_ENTRY_POINT(BC5CompressRG16,CompressBlockBC5,Surface_RG16,LoadUncompressed4x4BlockInterleaved_RG16,32,4)
