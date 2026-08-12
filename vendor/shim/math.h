// 最小 math shim:stb_image_write 只用 frexp(HDR 写路径)。
// 劫持到 zig 侧 @frexp。
#ifndef PIZ_SHIM_MATH_H
#define PIZ_SHIM_MATH_H
float piz_frexp(float x, int *exp);
#define frexp piz_frexp
#endif
