/* The static build's dlopen (scripts/static-musl.sh): FreePascal 3.2.2's
   cthreads loads the whole pthread API with dlopen("libpthread.so.0") and
   dlsym, which a static binary linked with musl cannot do (musl's static
   dlopen fails, and cthreads then calls a nil pointer as it starts). These
   four functions take their place in that binary only: every name cthreads
   asks for is found in the table below, from the binary's own musl.

   Why musl and not glibc: Android's seccomp filter for apps (Android 11)
   kills a process that calls set_robust_list or rseq, which glibc's startup
   always does, static or not. musl calls neither, so its static binary runs
   in Termux as on any Linux arm64. */
#define _GNU_SOURCE
#include <pthread.h>
#include <semaphore.h>
#include <signal.h>
#include <string.h>

#define F(n) { #n, (void *)n }
static const struct { const char *name; void *fn; } table[] = {
  F(pthread_atfork), F(pthread_attr_destroy), F(pthread_attr_getdetachstate),
  F(pthread_attr_getinheritsched), F(pthread_attr_getschedparam),
  F(pthread_attr_getschedpolicy), F(pthread_attr_getscope), F(pthread_attr_init),
  F(pthread_attr_setdetachstate), F(pthread_attr_setinheritsched),
  F(pthread_attr_setschedparam), F(pthread_attr_setschedpolicy),
  F(pthread_attr_setscope), F(pthread_attr_setstacksize), F(pthread_cancel),
  F(pthread_cond_broadcast), F(pthread_cond_destroy), F(pthread_cond_init),
  F(pthread_cond_signal), F(pthread_cond_timedwait), F(pthread_cond_wait),
  F(pthread_condattr_destroy), F(pthread_condattr_init), F(pthread_condattr_setclock),
  F(pthread_create), F(pthread_detach), F(pthread_equal), F(pthread_exit),
  F(pthread_getschedparam), F(pthread_getspecific), F(pthread_join),
  F(pthread_key_create), F(pthread_key_delete), F(pthread_kill),
  F(pthread_mutex_destroy), F(pthread_mutex_init), F(pthread_mutex_lock),
  F(pthread_mutex_trylock), F(pthread_mutex_unlock), F(pthread_mutexattr_destroy),
  F(pthread_mutexattr_init), F(pthread_mutexattr_settype), F(pthread_self),
  F(pthread_setcancelstate), F(pthread_setcanceltype), F(pthread_setname_np),
  F(pthread_setschedparam), F(pthread_setspecific), F(pthread_sigmask),
  F(pthread_testcancel),
  F(sem_close), F(sem_destroy), F(sem_getvalue), F(sem_init), F(sem_post),
  F(sem_timedwait), F(sem_trywait), F(sem_unlink), F(sem_wait),
};

static int self;

void *dlopen(const char *file, int mode) { (void)file; (void)mode; return &self; }

/* a name not in the table (glibc's old *_np functions: cthreads does
   without them) is not found, as with a real libpthread lacking it */
void *dlsym(void *handle, const char *name) {
  (void)handle;
  for (unsigned i = 0; i < sizeof table / sizeof table[0]; i++)
    if (strcmp(table[i].name, name) == 0) return table[i].fn;
  return 0;
}

int dlclose(void *handle) { (void)handle; return 0; }

char *dlerror(void) { return 0; }
