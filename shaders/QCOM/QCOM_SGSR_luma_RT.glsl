// 文档 https://github.com/hooke007/mpv_PlayKit/wiki/4_GLSL

//============================================================================================================
//
//
//                  Copyright (c) 2023, Qualcomm Innovation Center, Inc. All rights reserved.
//                              SPDX-License-Identifier: BSD-3-Clause
//
//============================================================================================================

// Snapdragon Game Super Resolution (GSR) v1 by Qualcomm
// ported to mpv by agyild

// Changelog
// 2025-07-13 - Initial release
// - Now operates on the luma channel (instead of green) for improved accuracy.
// - Removed the redundant "Operation mode" variable.
// - Optimized code for readability and a minor performance gain.


//!PARAM SHARP
//!DESC Controls the strength of the sharpening effect applied to detected edges. Higher values create a sharper, more pronounced image but can introduce "ringing" or halo artifacts if set too high. This setting has no impact on performance.
//!TYPE CONSTANT float
//!MINIMUM 1.0
//!MAXIMUM 8.0
2.0

//!PARAM ET
//!DESC Controls the sensitivity of the edge detection. The sharpening logic is only applied to areas considered an "edge". Higher values increase performance by processing fewer pixels but may miss subtle details. Lower values process more of the image, increasing detail at the cost of performance and potentially amplifying noise.
//!TYPE CONSTANT float
//!MINIMUM 0.0
//!MAXIMUM 32.0
8.0


//!HOOK LUMA
//!BIND HOOKED
//!DESC [QCOM_SGSR_luma_RT] v1.0.0
//!WHEN OUTPUT.w OUTPUT.h * HOOKED.w HOOKED.h * / 1.0 >
//!WIDTH OUTPUT.w
//!HEIGHT OUTPUT.h
//!COMPONENTS 1

// Shader code

#define UseEdgeDirection 1

float fastLanczos2(float x)
{
	float wA = x - 4.0;
	float wB = x * wA - wA;
	wA *= wA;
	return wB * wA;
}

#if (UseEdgeDirection == 1)
vec2 weightY(float dx, float dy, float c, vec3 data)
#else
vec2 weightY(float dx, float dy, float c, float data)
#endif
{
#if (UseEdgeDirection == 1)
	float std = data.x;
	vec2 dir = data.yz;

	float edgeDis = ((dx * dir.y) + (dy * dir.x));
	float x = fma(edgeDis * edgeDis, (clamp(c * c * std, 0.0, 1.0) * 0.7 - 1.0), (dx * dx + dy * dy));
#else
	float std = data;
	float x = fma((dx * dx + dy * dy), 0.55, clamp(abs(c) * std, 0.0, 1.0));
#endif

	float w = fastLanczos2(x);
	return vec2(w, w * c);
}

vec2 edgeDirection(vec4 left, vec4 right)
{
	vec2 delta;
	delta.x = (right.x - left.z) + (right.w - left.y);
	delta.y = (right.x - left.z) - (right.w - left.y);
	return delta * inversesqrt(dot(delta, delta) + 3.075740e-05);
}

vec4 hook()
{
	vec4 color = HOOKED_texOff(0);

	vec2 imgCoord = ((HOOKED_pos * HOOKED_size) + vec2(-0.5, 0.5));
	vec2 imgCoordPixel = floor(imgCoord);
	vec2 coord = (imgCoordPixel * HOOKED_pt);
	vec2 pl = (imgCoord + (-imgCoordPixel));
	vec4 left = HOOKED_gather(coord, 0);

	float edgeVote = abs(left.z - left.y) + abs(color.x - left.y)  + abs(color.x - left.z) ;
	if (edgeVote > (ET / 255))
	{
		coord.x += HOOKED_pt.x;

		vec4 right = HOOKED_gather(coord + vec2(HOOKED_pt.x, 0.0), 0);
		vec4 upDown;
		upDown.xy = HOOKED_gather(coord + vec2(0.0, -HOOKED_pt.y), 0).wz;
		upDown.zw  = HOOKED_gather(coord+ vec2(0.0, HOOKED_pt.y), 0).yx;

		float mean = (left.y + left.z + right.x + right.w) * 0.25;
		left -= vec4(mean);
		right -= vec4(mean);
		upDown -= vec4(mean);
		color.w = color.x - mean;

		float sum = dot(abs(left) + abs(right) + abs(upDown), vec4(1.0));

		float sumMean = 1.014185e+01 / sum;
		float std = sumMean * sumMean;

#if (UseEdgeDirection == 1)
		vec3 data = vec3(std, edgeDirection(left, right));
#else
		float data = std;
#endif
		vec2 aWY  = weightY(pl.x,       pl.y + 1.0, upDown.x, data);
		     aWY += weightY(pl.x - 1.0, pl.y + 1.0, upDown.y, data);
		     aWY += weightY(pl.x - 1.0, pl.y - 2.0, upDown.z, data);
		     aWY += weightY(pl.x,       pl.y - 2.0, upDown.w, data);
		     aWY += weightY(pl.x + 1.0, pl.y - 1.0,   left.x, data);
		     aWY += weightY(pl.x,       pl.y - 1.0,   left.y, data);
		     aWY += weightY(pl.x,       pl.y,         left.z, data);
		     aWY += weightY(pl.x + 1.0, pl.y,         left.w, data);
		     aWY += weightY(pl.x - 1.0, pl.y - 1.0,  right.x, data);
		     aWY += weightY(pl.x - 2.0, pl.y - 1.0,  right.y, data);
		     aWY += weightY(pl.x - 2.0, pl.y,        right.z, data);
		     aWY += weightY(pl.x - 1.0, pl.y,        right.w, data);

		float finalY = aWY.y / aWY.x;
		float maxY = max(max(left.y, left.z), max(right.x, right.w));
		float minY = min(min(left.y, left.z), min(right.x, right.w));
		float deltaY = clamp(SHARP * finalY, minY, maxY) - color.w;

		//smooth high contrast input
		deltaY = clamp(deltaY, -23.0 / 255.0, 23.0 / 255.0);

		color.x = clamp((color.x + deltaY), 0.0, 1.0);
	}

	color.w = 1.0;

	return color;
}

