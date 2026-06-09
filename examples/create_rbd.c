/* Copyright (c) 2026 IBM Corporation
 *
 * SPDX-License-Identifier: MIT
 */
#include <rados/librados.h>
#include <rbd/librbd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
int main(int argc, char**argv){
  const char*conf=argv[1],*keyring=argv[2],*pool=argv[3],*img=argv[4];
  uint64_t sz=(uint64_t)atoll(argv[5])*1024*1024;
  rados_t cl; if(rados_create(&cl,"admin")){fprintf(stderr,"create\n");return 1;}
  rados_conf_read_file(cl,conf); rados_conf_set(cl,"keyring",keyring);
  if(rados_connect(cl)){fprintf(stderr,"connect FAIL\n");return 1;}
  rados_ioctx_t io; if(rados_ioctx_create(cl,pool,&io)){fprintf(stderr,"ioctx\n");return 1;}
  int order=22; rbd_remove(io,img);
  if(rbd_create(io,img,sz,&order)){fprintf(stderr,"rbd_create FAIL\n");return 1;}
  rbd_image_t image; if(rbd_open(io,img,&image,NULL)){fprintf(stderr,"rbd_open\n");return 1;}
  char*buf=calloc(1,sz);
  for(uint64_t off=0;off<sz;off+=512){char s[48];int n=snprintf(s,sizeof s,"RADOS-LBA-%08llu-",(unsigned long long)(off/512));for(int i=0;i<512;i++)buf[off+i]=s[i%n];}
  if(rbd_write(image,0,sz,buf)<0){fprintf(stderr,"rbd_write FAIL\n");return 1;}
  rbd_close(image); free(buf); rados_ioctx_destroy(io); rados_shutdown(cl);
  printf("OK: rbd %s/%s created+written %llu bytes\n",pool,img,(unsigned long long)sz);
  return 0;
}
