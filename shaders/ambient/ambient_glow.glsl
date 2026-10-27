// 环境光晕（Ambient Glow）
//
// 亮部提取 → 两级降采样 + 可分离高斯 → 加性合成，给画面高光加一层柔和的
// 溢出光，接近播放器里常见的 "ambient mode / bloom" 观感。
//
// 只能写成单个文件：SAVE 与 BIND 的中间纹理只在同一个 .glsl 内部传递，
// 拆成两个文件无法共享模糊结果。注意注释里不要写出带感叹号的指令原文，
// libplacebo 会把它当成真的着色器指令来解析。
//
// 挂载方式是 change-list glsl-shaders toggle，而不是 profile：
// 着色器配置组（如 [动画]、[AnimeJaNai]）用 glsl-shaders= 整体替换列表，
// 会把 append 进去的着色器冲掉，而 change-list 是独立的运行时开关。
//
// 关于色彩空间：MAIN hook 拿到的是尚未 tone mapping 的画面。SDR 与
// HDR2SDR 路径下阈值语义一致，可以直接用；HDR 直通（HDR-PASS）下 PQ 编码值
// 的亮度分布与 SDR 不同，需要把 THRESHOLD 调低并适当降低 STR，否则泛光会过曝。
//
// 结构：1/2 分辨率做 2x2 盒式降采样提取亮部，避免逐像素提取产生闪烁；
// 两级可分离高斯分别给出近层锐利光晕与远层大面积晕开。
//
// 注意：PARAM 参数区与第一个 HOOK 之间不能出现普通 // 注释行，
// libplacebo 把它当作最后一个参数的数据来解析，会报
// "Failed parsing variable data"。说明文字只能放在 PARAM 之前。

//!PARAM STR
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 2.0
0.55

//!PARAM THRESHOLD
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 1.0
0.72

//!PARAM SOFT_KNEE
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 1.0
0.5

//!PARAM RADIUS
//!TYPE float
//!MINIMUM 0.5
//!MAXIMUM 4.0
1.6

//!PARAM TINT_R
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 2.0
1.0

//!PARAM TINT_G
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 2.0
1.0

//!PARAM TINT_B
//!TYPE float
//!MINIMUM 0.0
//!MAXIMUM 2.0
1.0


//!HOOK MAIN
//!BIND HOOKED
//!SAVE GLOW_HALF
//!DESC [ambient_glow] bright pass
//!WIDTH HOOKED.w 2 /
//!HEIGHT HOOKED.h 2 /
//!WHEN STR

vec4 hook() {

	vec4 c = (HOOKED_texOff(vec2(-0.5, -0.5)) + HOOKED_texOff(vec2(0.5, -0.5))
		+ HOOKED_texOff(vec2(-0.5, 0.5)) + HOOKED_texOff(vec2(0.5, 0.5))) * 0.25;

	float luma = dot(c.rgb, vec3(0.2126, 0.7152, 0.0722));

	// 软膝阈值的做法：阈值附近平滑过渡，避免高光边缘出现硬边和色阶
	float knee = max(THRESHOLD * SOFT_KNEE, 1e-5);
	float soft = clamp(luma - THRESHOLD + knee, 0.0, 2.0 * knee);
	soft = soft * soft / (4.0 * knee);
	float contribution = max(soft, luma - THRESHOLD) / max(luma, 1e-5);

	return vec4(c.rgb * contribution, 1.0);

}


// 半分辨率水平模糊
//!HOOK MAIN
//!BIND GLOW_HALF
//!SAVE GLOW_H1
//!DESC [ambient_glow] blur half h
//!WIDTH GLOW_HALF.w
//!HEIGHT GLOW_HALF.h
//!WHEN STR

vec4 hook() {

	const vec2 DIR = vec2(1.0, 0.0) * RADIUS;
	const float w[4] = float[](0.2707, 0.2167, 0.1113, 0.0366);
	vec4 sum = GLOW_HALF_texOff(vec2(0.0)) * w[0];
	for (int i = 1; i < 4; i++) {
		sum += GLOW_HALF_texOff(DIR * float(i)) * w[i];
		sum += GLOW_HALF_texOff(DIR * -float(i)) * w[i];
	}
	return sum;

}


// 半分辨率垂直模糊
//!HOOK MAIN
//!BIND GLOW_H1
//!SAVE GLOW_H2
//!DESC [ambient_glow] blur half v
//!WIDTH GLOW_H1.w
//!HEIGHT GLOW_H1.h
//!WHEN STR

vec4 hook() {

	const vec2 DIR = vec2(0.0, 1.0) * RADIUS;
	const float w[4] = float[](0.2707, 0.2167, 0.1113, 0.0366);
	vec4 sum = GLOW_H1_texOff(vec2(0.0)) * w[0];
	for (int i = 1; i < 4; i++) {
		sum += GLOW_H1_texOff(DIR * float(i)) * w[i];
		sum += GLOW_H1_texOff(DIR * -float(i)) * w[i];
	}
	return sum;

}


// 继续降到 1/4，得到半径更大的一层光晕
//!HOOK MAIN
//!BIND GLOW_H2
//!SAVE GLOW_Q1
//!DESC [ambient_glow] blur quarter h
//!WIDTH GLOW_H2.w 2 /
//!HEIGHT GLOW_H2.h 2 /
//!WHEN STR

vec4 hook() {

	const vec2 DIR = vec2(1.0, 0.0) * RADIUS;
	const float w[4] = float[](0.2707, 0.2167, 0.1113, 0.0366);
	vec4 sum = GLOW_H2_texOff(vec2(0.0)) * w[0];
	for (int i = 1; i < 4; i++) {
		sum += GLOW_H2_texOff(DIR * float(i)) * w[i];
		sum += GLOW_H2_texOff(DIR * -float(i)) * w[i];
	}
	return sum;

}


//!HOOK MAIN
//!BIND GLOW_Q1
//!SAVE GLOW_Q2
//!DESC [ambient_glow] blur quarter v
//!WIDTH GLOW_Q1.w
//!HEIGHT GLOW_Q1.h
//!WHEN STR

vec4 hook() {

	const vec2 DIR = vec2(0.0, 1.0) * RADIUS;
	const float w[4] = float[](0.2707, 0.2167, 0.1113, 0.0366);
	vec4 sum = GLOW_Q1_texOff(vec2(0.0)) * w[0];
	for (int i = 1; i < 4; i++) {
		sum += GLOW_Q1_texOff(DIR * float(i)) * w[i];
		sum += GLOW_Q1_texOff(DIR * -float(i)) * w[i];
	}
	return sum;

}


// 合成：两层加性叠加，近层给锐利光晕，远层给大面积晕开
//!HOOK MAIN
//!BIND HOOKED
//!BIND GLOW_H2
//!BIND GLOW_Q2
//!DESC [ambient_glow] composite
//!WHEN STR

vec4 hook() {

	vec4 base = HOOKED_tex(HOOKED_pos);

	vec3 near_glow = GLOW_H2_tex(GLOW_H2_pos).rgb;
	vec3 far_glow = GLOW_Q2_tex(GLOW_Q2_pos).rgb;

	// 远层权重低一些，避免整幅画面发灰
	vec3 glow = near_glow * 0.65 + far_glow * 0.35;
	glow *= vec3(TINT_R, TINT_G, TINT_B);

	// 加性合成只抬高亮部，不改变黑位，比 screen 混合更可控
	return vec4(base.rgb + glow * STR, base.a);

}
