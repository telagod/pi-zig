// stb 实现单元:无 stdlib 模式,内存走 zig 侧回调。
// 不链接 libc —— stb_image 只需要 malloc/realloc/free/memcpy/memmove,
// 全部由 piz_* 导出函数供给(见 src/imgx.zig 的 export)。
#include <stddef.h>

// 声明 zig 侧供给(实现于 src/imgx.zig)。必须在 include stb 头之前:
// stb 的实现体里会直接调用这些函数。
void *piz_malloc(size_t sz);
void *piz_realloc(void *p, size_t sz);
void piz_free(void *p);
void *piz_memcpy(void *dst, const void *src, size_t n);
void *piz_memmove(void *dst, const void *src, size_t n);
void *piz_memset(void *dst, int c, size_t n);
int piz_memcmp(const void *a, const void *b, size_t n);
int piz_abs(int x);
double piz_floor(double x);
double piz_ceil(double x);

#define STB_IMAGE_IMPLEMENTATION
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STBI_NO_STDIO
#define STBI_NO_STDLIB
#define STBI_NO_HDR      // 不需要 HDR 解码
#define STBI_NO_LINEAR   // 避免 math.h 依赖
#define STBI_NO_THREAD_LOCALS
#define STBI_NO_GIF      // 需要 GIF?先禁,动画帧无意义
#define STBI_NO_PIC
#define STBI_NO_PNM
#define STBI_NO_PSD
#define STBI_NO_TGA
#define STBI_NO_FAILURE_STRINGS
#define STBI_MALLOC(sz)        piz_malloc(sz)
#define STBI_REALLOC(p, sz)    piz_realloc(p, sz)
#define STBI_FREE(p)           piz_free(p)
#define STBI_MEMCPY(d, s, n)   piz_memcpy(d, s, n)
#define STBI_MEMMOVE(d, s, n)  piz_memmove(d, s, n)
#define STBI_ASSERT(x)         ((void)0)
#define STBI_FAIL(msg)         ((void)0)
// 裸调用的 memset/memcmp/memcpy/abs 无 STBI 宏可替,预处理器直接劫持到 zig 侧。
#define memset piz_memset
#define memcmp piz_memcmp
#define memcpy piz_memcpy
#define abs piz_abs
#include "stb_image.h"
#undef memset
#undef memcmp
#undef memcpy
#undef abs

#define STBI_WRITE_NO_STDIO
#define STBIW_ASSERT(x)        ((void)0)
#define STBIW_MALLOC(sz)       piz_malloc(sz)
#define STBIW_REALLOC_SIZED(p, oldsz, newsz) piz_realloc(p, newsz)
#define STBIW_FREE(p)          piz_free(p)
#define STBIW_MEMMOVE(a, b, s) piz_memmove(a, b, s)
// write 头里的裸 memcpy/memset/memcmp 无宏可替(PNG 行过滤器硬编码调用),
// 预处理器直接劫持。
#define memcpy piz_memcpy
#define memset piz_memset
#define memcmp piz_memcmp
#define abs piz_abs
#include "stb_image_write.h"
#undef memcpy
#undef memset
#undef memcmp
#undef abs

// stb_image_resize2:高质量 RGBA 缩放。
#define STB_IMAGE_RESIZE_IMPLEMENTATION
#define STBIR_ASSERT(x)          ((void)0)
#define STBIR_MALLOC(size, ud)   piz_malloc(size)
#define STBIR_FREE(ptr, ud)      piz_free(ptr)
#define memcpy piz_memcpy
#define floor piz_floor
#define ceil piz_ceil
#include "stb_image_resize2.h"
#undef memcpy
#undef floor
#undef ceil
