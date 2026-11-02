#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <sys/stat.h>
#include <unistd.h>
#include "moonbit.h"

/* No truncation, symlink following, or blocking on a FIFO. The descriptor
   remains open until the caller releases the lock. Never unlink this file. */
int32_t moon_binstall_open_lock(moonbit_bytes_t path) {
  int fd = open((const char *)path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0600);
  if (fd < 0) return -1;
  struct stat st;
  if (fstat(fd, &st) < 0) { int e = errno; close(fd); errno = e; return -1; }
  if (!S_ISREG(st.st_mode) || st.st_nlink != 1) {
    close(fd); errno = EINVAL; return -1;
  }
  return fd;
}

/* Confirm that the locked descriptor still names the lock path. */
int32_t moon_binstall_lock_matches(int32_t fd, moonbit_bytes_t path) {
  struct stat a, b;
  if (fstat(fd, &a) < 0 || lstat((const char *)path, &b) < 0) return 0;
  return S_ISREG(b.st_mode) && a.st_nlink == 1 &&
         a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}
