/* mkextra.c - test vectors for the two-argument C functions the SWMM6 engine calls that the Lua port computes in its
   runtime (fmod through Lua's math.fmod; remainder and nextafter written in Lua, lua/rt/crt.lua), computed with the
   system libm, in the record format of tools/libm/test/mkvectors.c (name\0, n:u32, then n x (x, y, result) as raw
   doubles): every pair of 34 special values (zeros, ones, halves, infinities, quiet and signaling NaNs of both signs
   with payloads, the extreme subnormal and normal numbers, values near 2^52 and 2^1023), then N random pairs mixing
   any bit pattern, uniform ranges, wide exponent ranges, close magnitudes (x/y near an integer and a half-integer)
   and subnormals; and pow(x, 2) ("pow_y2"), which the port computes with glibc's translated pow (Lua's x ^ 2 is
   x * x). Linked against the system libm at the symbol versions the C++ engine uses.
   gcc -O2 -fno-builtin -o mkextra mkextra.c -lm && ./mkextra N out.bin
   Written by Claude (Anthropic) for Robert Dickinson's SWMM6 ports; see ../README.md. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
static uint64_t s = 0x9E3779B97F4A7C15ull;
static uint64_t xr(void){ s ^= s<<13; s ^= s>>7; s ^= s<<17; return s; }
static double asd(uint64_t u){ double d; memcpy(&d,&u,8); return d; }
static double uni(double a, double b){ return a + (b-a) * ((double)(xr()>>11) / 9007199254740992.0); }
static double lgu(int e0, int e1){ uint64_t r = xr(); return asd((r & 0x800fffffffffffffull) | ((uint64_t)(1023 + e0 + (int)((r>>52) % (uint64_t)(e1-e0))) << 52)); }
static double pick(long i) {
  switch (i % 6) {
  case 0: return asd(xr());                        /* any bit pattern */
  case 1: return uni(-1000, 1000);
  case 2: return lgu(-1074 + 52, 1023);             /* wide range, both signs */
  case 3: return lgu(-60, 60);
  case 4: return asd(xr() & 0x800fffffffffffffull);  /* subnormal */
  default: return (double)(int64_t)uni(-1e6, 1e6) + ((xr() & 1) ? 0.0 : 0.5);
  }
}
static double nexta(double x, double y) { return nextafter(x, y); }
static double (*fn[3])(double, double) = {fmod, remainder, nexta};
static const char *names[4] = {"fmod", "remainder", "nextafter", "pow_y2"};
int main(int argc, char **argv) {
  long n = atol(argv[1]);
  double sp[] = {0.0, -0.0, 1.0, -1.0, 0.5, -0.5, 1.5, 2.0, 3.0, -3.0, INFINITY, -INFINITY, NAN, -NAN,
    asd(0x7ff0000000000123ull), asd(0xfff0000000000456ull), asd(0x7ff8000000000789ull), asd(0xfff8000000000abcull),
    asd(1), asd(0x8000000000000001ull), asd(0x000fffffffffffffull), asd(0x0010000000000000ull), asd(0x7fefffffffffffffull), -1.7976931348623157e308,
    4503599627370496.0, 4503599627370495.5, 9007199254740992.0, 8.98846567431158e307, 1e-310, 0.1, -0.7, 7.0, 1e22, 6.0};
  int nsp = sizeof sp / sizeof *sp;
  FILE *o = fopen(argv[2], "wb");
  for (int f = 0; f < 3; f++) {
    uint32_t m = (uint32_t)(n + nsp * nsp);
    fwrite(names[f], 1, strlen(names[f]) + 1, o); fwrite(&m, 4, 1, o);
    for (int i = 0; i < nsp; i++) for (int j = 0; j < nsp; j++) { double r[3] = {sp[i], sp[j], fn[f](sp[i], sp[j])}; fwrite(r, 8, 3, o); }
    for (long i = 0; i < n; i++) {
      double x = pick(i), y;
      switch ((i / 6) % 4) {
      case 0: y = pick(i + 1); break;
      case 1: y = x / ((double)(int64_t)uni(1, 1e6) + ((xr() & 1) ? 0.0 : 0.5)); break;   /* x/y near (half-)integers */
      case 2: y = asd(((uint64_t)xr() & 0x800fffffffffffffull) | (((uint64_t)xr() % 2047) << 52)); break;
      default: y = x * uni(-2, 2); break;
      }
      double r[3] = {x, y, fn[f](x, y)};
      fwrite(r, 8, 3, o);
    }
    fprintf(stderr, "%s %u\n", names[f], m);
  }
  /* pow(x, 2): the Lua port's own code for the exponent 2 (Lua's ^ computes x * x there) */
  {
    uint32_t m = (uint32_t)(n + nsp);
    fwrite(names[3], 1, strlen(names[3]) + 1, o); fwrite(&m, 4, 1, o);
    for (int i = 0; i < nsp; i++) { double r[3] = {sp[i], 2.0, pow(sp[i], 2.0)}; fwrite(r, 8, 3, o); }
    for (long i = 0; i < n; i++) {
      double x;
      switch (i % 4) {
      case 0: x = asd(xr()); break;
      case 1: x = uni(-1e4, 1e4); break;
      case 2: x = lgu(-540, 513); break;                       /* squares near the overflow and underflow thresholds */
      default: x = lgu(-30, 30); break;
      }
      double r[3] = {x, 2.0, pow(x, 2.0)};
      fwrite(r, 8, 3, o);
    }
    fprintf(stderr, "%s %u\n", names[3], m);
  }
  fclose(o);
  return 0;
}
