/* Copyright (c) 2026 IBM Corporation
 *
 * SPDX-License-Identifier: MIT
 *
 * create_rbd.c
 *
 * Test fixture: create an RBD image in a Ceph pool and fill it with a
 * recognizable LBA pattern, so the nvme-ep block path can be validated against
 * an RBD-backed NVMe namespace.
 *
 * Requirements:
 *   - A reachable Ceph cluster (ceph.conf + keyring for an admin-capable user).
 *   - librados / librbd development headers and libraries. These ship with
 *     upstream Ceph; on Debian/Ubuntu: `apt install librados-dev librbd-dev`,
 *     on Fedora/RHEL: `dnf install librados-devel librbd-devel`. No special
 *     KV-enabled Ceph build is needed -- the stock librbd C API is sufficient
 *     (Ceph Reef/Squid or any release with the stable librbd ABI works).
 *
 * Build: gcc -O2 -o create_rbd create_rbd.c -lrbd -lrados
 * Usage: create_rbd <ceph.conf> <keyring> <pool> <image> <size-MiB>
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <rados/librados.h>
#include <rbd/librbd.h>
int main(int argc, char** argv) {
  if (argc < 6) {
    fprintf(stderr,
            "usage: %s <ceph.conf> <keyring> <pool> <image> <size-MiB>\n",
            argv[0]);
    return 2;
  }
  const char *conf = argv[1], *keyring = argv[2], *pool = argv[3],
             *img = argv[4];
  uint64_t sz = (uint64_t)atoll(argv[5]) * 1024 * 1024;
  rados_t cl;
  if (rados_create(&cl, "admin")) {
    fprintf(stderr, "create\n");
    return 1;
  }
  rados_conf_read_file(cl, conf);
  rados_conf_set(cl, "keyring", keyring);
  if (rados_connect(cl)) {
    fprintf(stderr, "connect FAIL\n");
    return 1;
  }
  rados_ioctx_t io;
  if (rados_ioctx_create(cl, pool, &io)) {
    fprintf(stderr, "ioctx\n");
    return 1;
  }
  int order = 22;
  rbd_remove(io, img);
  if (rbd_create(io, img, sz, &order)) {
    fprintf(stderr, "rbd_create FAIL\n");
    return 1;
  }
  rbd_image_t image;
  if (rbd_open(io, img, &image, NULL)) {
    fprintf(stderr, "rbd_open\n");
    return 1;
  }
  char* buf = calloc(1, sz);
  for (uint64_t off = 0; off < sz; off += 512) {
    char s[48];
    int n = snprintf(s, sizeof s, "RADOS-LBA-%08llu-",
                     (unsigned long long)(off / 512));
    for (int i = 0; i < 512; i++)
      buf[off + i] = s[i % n];
  }
  if (rbd_write(image, 0, sz, buf) < 0) {
    fprintf(stderr, "rbd_write FAIL\n");
    return 1;
  }
  rbd_close(image);
  free(buf);
  rados_ioctx_destroy(io);
  rados_shutdown(cl);
  printf("OK: rbd %s/%s created+written %llu bytes\n", pool, img,
         (unsigned long long)sz);
  return 0;
}
