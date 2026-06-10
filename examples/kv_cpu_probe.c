/* Copyright (c) 2026 IBM Corporation
 *
 * SPDX-License-Identifier: MIT
 *
 * kv_cpu_probe.c
 *
 * GPU-FREE validation of the NVMe Key-Value path: issues a KV Store then a KV
 * Retrieve through /dev/nvme0 using the kernel's NVMe IO passthrough ioctl. This
 * exercises everything the GPU path does EXCEPT the doorbell (which is already
 * proven for block I/O): guest enumeration of the KV controller, the exact KV
 * SQE encoding (key in CDW2/3/14/15, key length in CDW11, value size in CDW10),
 * SPDK kvdev command handling, and RADOS storage.
 *
 * Build (in guest): gcc -O2 -o kv_cpu_probe kv_cpu_probe.c
 * Usage: kv_cpu_probe [/dev/nvme0] [nsid] [key]
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <linux/nvme_ioctl.h>

#define KV_OPC_STORE 0x01
#define KV_OPC_RETRIEVE 0x02

/* Issue one KV command via NVMe IO passthrough. Returns the ioctl result:
 * 0 = success, >0 = NVMe status code, <0 = -errno. *result_out gets CQE DW0
 * (the returned value length for Retrieve). */
static int kv_cmd(int fd, uint8_t opcode, uint32_t nsid, const uint8_t *key,
                  uint8_t keylen, void *buf, uint32_t buflen,
                  uint32_t *result_out) {
  struct nvme_passthru_cmd c;
  memset(&c, 0, sizeof(c));
  c.opcode = opcode;
  c.nsid = nsid;
  c.addr = (uint64_t)(uintptr_t)buf;
  c.data_len = buflen;

  /* Key: low 8 bytes -> CDW2/CDW3, high 8 -> CDW14/CDW15 (flat little-endian). */
  uint32_t k[4] = {0, 0, 0, 0};
  memcpy(k, key, keylen > 16 ? 16 : keylen);
  c.cdw2 = k[0];
  c.cdw3 = k[1];
  c.cdw14 = k[2];
  c.cdw15 = k[3];

  c.cdw10 = buflen;        /* value size (store) / host buffer size (retrieve) */
  c.cdw11 = keylen & 0xFF; /* key length */
  c.timeout_ms = 5000;

  int rc = ioctl(fd, NVME_IOCTL_IO_CMD, &c);
  if (result_out) {
    *result_out = c.result;
  }
  return rc;
}

int main(int argc, char **argv) {
  const char *dev = argc > 1 ? argv[1] : "/dev/nvme0";
  uint32_t nsid = argc > 2 ? (uint32_t)atoi(argv[2]) : 1;
  const char *key = argc > 3 ? argv[3] : "cpukey01";
  size_t klen = strlen(key);
  if (klen < 1 || klen > 16) {
    fprintf(stderr,
            "FATAL: key '%s' is %zu bytes; NVMe-KV inline keys must be 1..16 "
            "bytes\n",
            key, klen);
    return 2;
  }
  uint8_t keylen = (uint8_t)klen;

  int fd = open(dev, O_RDWR);
  if (fd < 0) {
    fprintf(stderr, "FATAL: open %s: %s\n", dev, strerror(errno));
    fprintf(stderr, "  -> the guest did NOT bring up the KV controller char dev\n");
    return 2;
  }

  uint32_t vlen = 4096;
  uint8_t *wbuf = aligned_alloc(4096, vlen);
  uint8_t *rbuf = aligned_alloc(4096, vlen);
  if (!wbuf || !rbuf) {
    fprintf(stderr, "FATAL: aligned_alloc(%u) failed\n", vlen);
    free(wbuf);
    free(rbuf);
    close(fd);
    return 2;
  }
  for (uint32_t i = 0; i < vlen; i++) {
    wbuf[i] = (uint8_t)('A' + (i % 26));
  }
  memset(rbuf, 0, vlen);

  printf("dev=%s nsid=%u key='%s' (keylen=%u) value=%u bytes\n", dev, nsid, key,
         keylen, vlen);

  uint32_t res = 0;
  int rc = kv_cmd(fd, KV_OPC_STORE, nsid, (const uint8_t *)key, keylen, wbuf,
                  vlen, &res);
  printf("[STORE]    ioctl rc=%d (0=ok, >0=nvme-status) ", rc);
  if (rc < 0) {
    printf("errno=%d (%s)\n", errno, strerror(errno));
  } else {
    printf("status=0x%x result=%u\n", rc, res);
  }

  res = 0;
  rc = kv_cmd(fd, KV_OPC_RETRIEVE, nsid, (const uint8_t *)key, keylen, rbuf, vlen,
              &res);
  printf("[RETRIEVE] ioctl rc=%d ", rc);
  if (rc < 0) {
    printf("errno=%d (%s)\n", errno, strerror(errno));
  } else {
    printf("status=0x%x returned_value_len=%u\n", rc, res);
  }

  int ok = 0;
  if (rc == 0) {
    int match = (memcmp(wbuf, rbuf, vlen) == 0);
    printf("  data match: %s   (retrieved first 16 bytes: '%.16s')\n",
           match ? "YES" : "NO", rbuf);
    ok = match;
  }

  printf("\nVERDICT: %s\n",
         ok ? "KV Store+Retrieve WORK from the guest CPU -> guest enumerates the "
              "KV controller and the KV SQE format is correct; only the GPU "
              "doorbell remains (already proven for block)."
            : "KV path did NOT complete from the guest CPU -- see status/errno "
              "above (controller enumeration or KV command handling).");
  close(fd);
  return ok ? 0 : 1;
}
