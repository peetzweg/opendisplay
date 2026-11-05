#include "raop_rtp_mirror.h"
#include "raop_ntp.h"
#include <arpa/inet.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
static void log_message(void *p, int level, const char *message) { (void)p;(void)level;fprintf(stderr,"%s\n",message); }
static atomic_int sizes, codecs, pauses, resumes;
static void reset_video(void *p, reset_type_t type) { (void)p;(void)type; }
static void pause_video(void *p) { (void)p; pauses++; }
static void resume_video(void *p) { (void)p; resumes++; }
static void size_video(void *p, float *a, float *b, float *w, float *h) { (void)p;(void)a;(void)b; if (*w==640 && *h==320) sizes++; }
static int codec_video(void *p, video_codec_t codec) { (void)p; codecs++; return codec == VIDEO_CODEC_H264 ? 0 : -1; }
static int send_packet(int fd, unsigned char flags, const unsigned char *data, int length) {
    unsigned char packet[256] = {0};
    packet[0]=length; packet[4]=1; packet[6]=flags;
    float w=640,h=320;
    for (int offset=16;offset<=56;offset+=24) {memcpy(packet+offset,&w,4);memcpy(packet+offset+4,&h,4);}
    memcpy(packet+56,&w,4);memcpy(packet+60,&h,4);
    if(length)memcpy(packet+128,data,length);
    return send(fd,packet,128+length,0)==128+length;
}
#define CHECK(x) do {if(!(x)){fprintf(stderr,"Failed: %s\n",#x);return 1;}}while(0)
int main(void) {
    logger_t *logger=logger_init(); logger_set_level(logger,LOGGER_INFO); logger_set_callback(logger,log_message,NULL);
    raop_callbacks_t callbacks={0}; callbacks.video_reset=reset_video; callbacks.video_pause=pause_video; callbacks.video_resume=resume_video; callbacks.video_set_codec=codec_video; callbacks.video_report_size=size_video;
    timing_protocol_t timing=TP_NONE;
    raop_ntp_t *ntp=raop_ntp_init(logger,&callbacks,"127.0.0.1",4,0,&timing);CHECK(ntp);
    unsigned char key[16]={0};
    raop_rtp_mirror_t *mirror=raop_rtp_mirror_init(logger,&callbacks,ntp,"127.0.0.1",4,key);CHECK(mirror);
    unsigned short port=0; raop_rtp_mirror_start(mirror,&port,0); CHECK(port);
    int fd=socket(AF_INET,SOCK_STREAM,0); struct sockaddr_in addr={.sin_family=AF_INET,.sin_port=htons(port)};inet_pton(AF_INET,"127.0.0.1",&addr.sin_addr);
    CHECK(connect(fd,(struct sockaddr*)&addr,sizeof(addr))==0);
    CHECK(send_packet(fd,0x56,NULL,0)); CHECK(send_packet(fd,0x16,NULL,0));
    // Minimal avcC-style SPS/PPS configuration accepted by the native parser.
    const unsigned char avc[]={1,0x64,0,0x1f,0xff,0xe1,0,2,0x67,0x88,1,0,2,0x68,0x88};
    CHECK(send_packet(fd,0x16,avc,sizeof(avc)));
    for(int i=0;i<100 && codecs==0;i++)usleep(10000);
    CHECK(codecs==1); CHECK(sizes==1); CHECK(pauses==1);CHECK(resumes==1);
    // A later empty marker must leave the configured stream usable.
    CHECK(send_packet(fd,0x16,NULL,0));CHECK(send_packet(fd,0x16,avc,sizeof(avc)));
    for(int i=0;i<100 && sizes<2;i++)usleep(10000);
    CHECK(sizes==2);CHECK(codecs==1);
    close(fd);raop_rtp_mirror_destroy(mirror);raop_ntp_destroy(ntp);logger_destroy(logger);
    puts("Empty codec marker regression passed");return 0;
}
