/* TEST-ONLY helper: quiesce one NVMe IO queue's blk-mq hctx via the
 * production ROCM_XIO_QUIESCE_NS ioctl.
 *
 * Usage: quiesce-qid <bdev> <qid>
 *   e.g. quiesce-qid /dev/nvme2n1 8
 *
 * Used by test-qid-quiesce-stress.sh. Mirrors resurrect-qid.c.
 */
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <unistd.h>
#include <linux/types.h>

#define ROCM_XIO_IOC_MAGIC 'R'
struct rocm_xio_quiesce_ns_req {
  __s32 bdev_fd;
  __u32 qid;
};
#define ROCM_XIO_QUIESCE_NS \
  _IOW(ROCM_XIO_IOC_MAGIC, 13, struct rocm_xio_quiesce_ns_req)

int main(int argc, char** argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s <bdev> <qid>\n", argv[0]);
    return 2;
  }
  const char* bdev = argv[1];
  unsigned int qid = (unsigned int)strtoul(argv[2], NULL, 0);

  int bdev_fd = open(bdev, O_RDONLY | O_CLOEXEC);
  if (bdev_fd < 0) {
    perror("open bdev");
    return 1;
  }
  int kfd = open("/dev/rocm-xio", O_RDWR | O_CLOEXEC);
  if (kfd < 0) {
    perror("open /dev/rocm-xio");
    close(bdev_fd);
    return 1;
  }
  struct rocm_xio_quiesce_ns_req req;
  req.bdev_fd = bdev_fd;
  req.qid = qid;
  if (ioctl(kfd, ROCM_XIO_QUIESCE_NS, &req) < 0) {
    perror("ioctl QUIESCE_NS");
    close(kfd);
    close(bdev_fd);
    return 1;
  }
  close(kfd);
  close(bdev_fd);
  printf("quiesced: bdev=%s qid=%u\n", bdev, qid);
  return 0;
}
