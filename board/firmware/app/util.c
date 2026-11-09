/* util.c - memcpy/memset: прошивка собирается без стандартной библиотеки (-nostdlib),
 * а GCC может сам вставлять вызовы этих функций. */
#include <stddef.h>

void *memcpy(void *dst, const void *src, size_t n)
{
    unsigned char *d = dst;
    const unsigned char *s = src;
    while (n--) *d++ = *s++;
    return dst;
}

void *memset(void *dst, int c, size_t n)
{
    unsigned char *d = dst;
    while (n--) *d++ = (unsigned char)c;
    return dst;
}
