// Not a ported file. Counts malloc-family calls through dyld interposing (macOS only) and prints the
// counts to stderr at exit; tools/bench/allocs.py loads it with DYLD_INSERT_LIBRARIES to measure
// allocations per operation of the benchmark driver.
#include <malloc/malloc.h>
#include <stdlib.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
typedef unsigned long long malloc_type_id_t;
extern void *malloc_type_malloc(size_t, malloc_type_id_t);
extern void *malloc_type_calloc(size_t, size_t, malloc_type_id_t);
extern void *malloc_type_realloc(void *, size_t, malloc_type_id_t);
extern int malloc_type_posix_memalign(void **, size_t, size_t, malloc_type_id_t);
static _Atomic uint64_t c[8];
static const char *names[8] = {"malloc", "calloc", "realloc", "memalign", "t_malloc", "t_calloc", "t_realloc", "t_memalign"};
static void *my_malloc(size_t n) { atomic_fetch_add(&c[0], 1); return malloc(n); }
static void *my_calloc(size_t a, size_t b) { atomic_fetch_add(&c[1], 1); return calloc(a, b); }
static void *my_realloc(void *p, size_t n) { atomic_fetch_add(&c[2], 1); return realloc(p, n); }
static int my_memalign(void **p, size_t a, size_t n) { atomic_fetch_add(&c[3], 1); return posix_memalign(p, a, n); }
static void *my_tmalloc(size_t n, malloc_type_id_t t) { atomic_fetch_add(&c[4], 1); return malloc_type_malloc(n, t); }
static void *my_tcalloc(size_t a, size_t b, malloc_type_id_t t) { atomic_fetch_add(&c[5], 1); return malloc_type_calloc(a, b, t); }
static void *my_trealloc(void *p, size_t n, malloc_type_id_t t) { atomic_fetch_add(&c[6], 1); return malloc_type_realloc(p, n, t); }
static int my_tmemalign(void **p, size_t a, size_t n, malloc_type_id_t t) { atomic_fetch_add(&c[7], 1); return malloc_type_posix_memalign(p, a, n, t); }
#define INTERPOSE(r, o) __attribute__((used)) static struct { const void *a; const void *b; } _i_##o __attribute__((section("__DATA,__interpose"))) = { (const void *)r, (const void *)o };
INTERPOSE(my_malloc, malloc)
INTERPOSE(my_calloc, calloc)
INTERPOSE(my_realloc, realloc)
INTERPOSE(my_memalign, posix_memalign)
INTERPOSE(my_tmalloc, malloc_type_malloc)
INTERPOSE(my_tcalloc, malloc_type_calloc)
INTERPOSE(my_trealloc, malloc_type_realloc)
INTERPOSE(my_tmemalign, malloc_type_posix_memalign)
// Every call reaches both the plain and the typed entry point (one forwards to the other), so the total
// counts the plain ones only; the per-entry counts are printed too, for checking that this still holds.
__attribute__((destructor)) static void report(void) {
  uint64_t total = 0;
  for (int i = 0; i < 8; i++) {
    if (i < 4) total += c[i];
    fprintf(stderr, "count-%s\t%llu\n", names[i], (unsigned long long)c[i]);
  }
  fprintf(stderr, "malloc-count\t%llu\n", (unsigned long long)total);
}
