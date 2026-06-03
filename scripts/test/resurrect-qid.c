/* TEST-ONLY helper: trigger the rocm-xio kernel-queue resurrect path
 * for a given (bdf, qid) via the ROCM_XIO_DEBUG_RESURRECT_QID ioctl.
 *
 * Usage: resurrect-qid <bdf-hex> <qid>
 *   e.g. resurrect-qid 0x0500 8
 *
 * Used by test-qid8-ring-wrap-stress.sh to exercise the resurrect code
 * path without the GPU/xio-tester hijack (needed on hosts where the
 * Navi 21 GPU is wedged by the AMD reset bug).
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <linux/types.h>

#define ROCM_XIO_IOC_MAGIC 'R'
struct rocm_xio_debug_resurrect_req {
  __u16 bdf;
  __u16 qid;
};
#define ROCM_XIO_DEBUG_RESURRECT_QID \
  _IOW(ROCM_XIO_IOC_MAGIC, 15, struct rocm_xio_debug_resurrect_req)

int main(int argc, char** argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s <bdf-hex> <qid>\n", argv[0]);
    return 2;
  }
  struct rocm_xio_debug_resurrect_req req;
  req.bdf = (unsigned short)strtoul(argv[1], NULL, 0);
  req.qid = (unsigned short)strtoul(argv[2], NULL, 0);

  int fd = open("/dev/rocm-xio", O_RDWR);
  if (fd < 0) {
    perror("open /dev/rocm-xio");
    return 1;
  }
  if (ioctl(fd, ROCM_XIO_DEBUG_RESURRECT_QID, &req) < 0) {
    perror("ioctl DEBUG_RESURRECT_QID");
    close(fd);
    return 1;
  }
  close(fd);
  printf("resurrect requested: bdf=0x%04x qid=%u\n", req.bdf, req.qid);
  return 0;
}
