// 最小 stdlib shim:stb 的 malloc/realloc/free/abs 全由宏劫持到 zig 侧,
// 此处只借 size_t。
#ifndef PIZ_SHIM_STDLIB_H
#define PIZ_SHIM_STDLIB_H
#include <stddef.h>
#endif
