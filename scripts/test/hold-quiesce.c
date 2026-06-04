/* TEST-ONLY helper: hold one NVMe IO queue's blk-mq hctx quiesced for a
 * fixed window via the production ROCM_XIO_QUIESCE_NS ioctl.
 *
 * Usage: hold-quiesce <bdev> <qid> <seconds>
 *   e.g. hold-quiesce /dev/nvme2n1 8 5
 *
 * One process keeps the /dev/rocm-xio fd open for the whole window so the
 * char-device release auto-restart does not fire early. Mirrors
 * quiesce-qid.c. Pairs QUIESCE_NS with an explicit UNQUIESCE_NS.
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
#define ROCM_XIO_UNQUIESCE_NS \
  _IOW(ROCM_XIO_IOC_MAGIC, 14, struct rocm_xio_quiesce_ns_req)

int main(int argc, char** argv) {
  if (argc != 4) {
    fprintf(stderr, "usage: %s <bdev> <qid> <seconds>\n", argv[0]);
    return 2;
  }
  const char* bdev = argv[1];
  unsigned int qid = (unsigned int)strtoul(argv[2], NULL, 0);
  unsigned int seconds = (unsigned int)strtoul(argv[3], NULL, 0);

  int bdev_fd = open(bdev, O_RDONLY | O_CLOEXEC);
  if (bdev_fd < 0) {
    perror("open bdev");
    return 1;
  }
  int kfd = open("/dev/rocm-xio", O_RDWR);
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
  printf("held: bdev=%s qid=%u seconds=%u\n", bdev, qid, seconds);
  fflush(stdout);

  sleep(seconds);

  if (ioctl(kfd, ROCM_XIO_UNQUIESCE_NS, &req) < 0) {
    perror("ioctl UNQUIESCE_NS");
    close(kfd);
    close(bdev_fd);
    return 1;
  }
  close(kfd);
  close(bdev_fd);
  printf("released: qid=%u\n", qid);
  return 0;
}
