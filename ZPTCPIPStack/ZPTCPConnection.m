//
//  ZPTCPConnection.m
//  ZPTCPIPStack
//
//  Created by ZapCannon87 on 11/08/2017.
//  Copyright © 2017 zapcannon87. All rights reserved.
//

#import "ZPTCPConnection.h"
#import "ZPTCPConnectionEx.h"
#import "ZPPacketTunnel.h"
#import "ZPPacketTunnelEx.h"

err_t zp_tcp_sent(void *arg, struct tcp_pcb *tpcb, u16_t len)
{
    return ERR_OK;
}

err_t zp_tcp_recv(void *arg, struct tcp_pcb *tpcb, struct pbuf *p, err_t err)
{
    return ERR_OK;
}

err_t zp_tcp_connected(void *arg, struct tcp_pcb *tpcb, err_t err)
{
    ZPTCPConnection *conn = (__bridge ZPTCPConnection *)(arg);
    [ZPPacketTunnel.shared tcpConnectionEstablished:conn];
    return ERR_OK;
}

err_t zp_tcp_poll(void *arg, struct tcp_pcb *tpcb)
{
    return ERR_OK;
}

void zp_tcp_err(void *arg, err_t err)
{
    
}


@implementation ZPTCPConnection
{
    void *IsOnTimerQueueKey;
}

+ (instancetype)newTCPConnectionWith:(ZPPacketTunnel *)tunnel
                           identifie:(NSString *)identifie
                              ipData:(struct ip_globals *)ipData
                             tcpInfo:(struct tcp_info *)tcpInfo
                                pbuf:(struct pbuf *)pbuf
{
    return [[self alloc] initWithTunnel:tunnel
                              identifie:identifie
                                 ipData:ipData
                                tcpInfo:tcpInfo
                                   pbuf:pbuf];
}

- (instancetype)initWithTunnel:(ZPPacketTunnel *)tunnel
                     identifie:(NSString *)identifie
                        ipData:(struct ip_globals *)ipData
                       tcpInfo:(struct tcp_info *)tcpInfo
                          pbuf:(struct pbuf *)pbuf
{
    self = [super init];
    if (self) {
        _tunnel = tunnel;
        _identifie = identifie;
        _tcpBlock.ip_data = *ipData;
        _tcpBlock.tcpInfo = *tcpInfo;
        _tcpBlock.tcp_ticks = 0;
        _tcpBlock.tcp_timer = 0;
        
        if (_tcpBlock.tcpInfo.flags & TCP_RST) {
            /* An incoming RST should be ignored. Return. */
            return NULL;
        }
        
        /* In the LISTEN state, we check for incoming SYN segments,
         creates a new PCB, and responds with a SYN|ACK. */
        if (_tcpBlock.tcpInfo.flags & TCP_ACK) {
            /* For incoming segments with the ACK flag set, respond with a
             RST. */
            LWIP_DEBUGF(TCP_RST_DEBUG, ("tcp_listen_input: ACK in LISTEN, sending reset\n"));
            tcp_rst(_tcpBlock.tcpInfo.ackno, _tcpBlock.tcpInfo.seqno + _tcpBlock.tcpInfo.tcplen,
                    (&_tcpBlock.ip_data.current_iphdr_dest), (&_tcpBlock.ip_data.current_iphdr_src),
                    _tcpBlock.tcpInfo.tcphdr->dest, _tcpBlock.tcpInfo.tcphdr->src,
                    &_tcpBlock);
        } else if (_tcpBlock.tcpInfo.flags & TCP_SYN) {
            LWIP_DEBUGF(TCP_DEBUG, ("TCP connection request %"U16_F" -> %"U16_F".\n", tcphdr->src, tcphdr->dest));
            struct tcp_pcb *npcb = tcp_alloc(TCP_PRIO_NORMAL);
            /* If a new PCB could not be created (probably due to lack of memory),
             we don't do anything, but rely on the sender will retransmit the
             SYN at a time when we have more memory available. */
            if (npcb == NULL) {
                LWIP_DEBUGF(TCP_DEBUG, ("tcp_listen_input: could not allocate PCB\n"));
                TCP_STATS_INC(tcp.memerr);
                return NULL;
            }
            _tcpBlock.pcb = npcb;
            /* Set up the new PCB. */
            ip_addr_copy(npcb->local_ip, _tcpBlock.ip_data.current_iphdr_dest);
            ip_addr_copy(npcb->remote_ip, _tcpBlock.ip_data.current_iphdr_src);
            npcb->local_port = _tcpBlock.tcpInfo.tcphdr->dest;
            npcb->remote_port = _tcpBlock.tcpInfo.tcphdr->src;
            npcb->state = SYN_RCVD;
            npcb->rcv_nxt = _tcpBlock.tcpInfo.seqno + 1;
            npcb->rcv_ann_right_edge = npcb->rcv_nxt;
            u32_t iss = tcp_next_iss(npcb, &_tcpBlock);
            npcb->snd_wl2 = iss;
            npcb->snd_nxt = iss;
            npcb->lastack = iss;
            npcb->snd_lbb = iss;
            npcb->snd_wl1 = _tcpBlock.tcpInfo.seqno - 1;/* initialise to seqno-1 to force window update */
            npcb->callback_arg = (__bridge void *)(self);
#if LWIP_CALLBACK_API || TCP_LISTEN_BACKLOG
            npcb->listener = NULL;
#endif /* LWIP_CALLBACK_API || TCP_LISTEN_BACKLOG */
            /* inherit socket options */
            npcb->so_options = SOF_KEEPALIVE;
            
            /* lwIP's `NETCONN_TCP_POLL_INTERVAL` is set to 2,
             so we stay the same, let pcb poll once per second */
            npcb->polltmr = 0;
            npcb->pollinterval = 2;
            
            /* set callback func */
            npcb->sent      = zp_tcp_sent;
            npcb->recv      = zp_tcp_recv;
            npcb->connected = zp_tcp_connected;
            npcb->poll      = zp_tcp_poll;
            npcb->errf      = zp_tcp_err;
            
            /* Parse any options in the SYN. */
            tcp_parseopt(npcb, &_tcpBlock);
            npcb->snd_wnd = _tcpBlock.tcpInfo.tcphdr->wnd;
            npcb->snd_wnd_max = npcb->snd_wnd;
            
#if TCP_CALCULATE_EFF_SEND_MSS
            npcb->mss = tcp_eff_send_mss(npcb->mss, &npcb->local_ip, &npcb->remote_ip, &_tcpBlock);
#endif /* TCP_CALCULATE_EFF_SEND_MSS */
            
            MIB2_STATS_INC(mib2.tcppassiveopens);
            
            /* Send a SYN|ACK together with the MSS option. */
            err_t rc = tcp_enqueue_flags(npcb, TCP_SYN | TCP_ACK);
            if (rc != ERR_OK) {
                tcp_abandon(npcb, 0, &_tcpBlock);
                return NULL;
            }
            tcp_output(npcb, &_tcpBlock);
            
            /* set timer queue */
            _timerQueue = dispatch_queue_create("ZPTCPConnection.timerQueue", NULL);
            IsOnTimerQueueKey = &IsOnTimerQueueKey;
            void *nonNullUnusedPointer = (__bridge void *)(self);
            dispatch_queue_set_specific(_timerQueue, IsOnTimerQueueKey, nonNullUnusedPointer, NULL);
            
            /* setup timer */
            _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _timerQueue);
            /* lwIP's doc suggest run the timer checkout 4 times per second */
            int64_t interval = NSEC_PER_SEC * 0.25;
            dispatch_time_t start = dispatch_time(DISPATCH_TIME_NOW, interval);
            dispatch_source_set_timer(_timer, start, interval, interval);
            dispatch_source_set_event_handler(_timer, ^{
                tcp_tmr(&_tcpBlock);
            });
            dispatch_resume(_timer);
        } else {
            return NULL;
        }
    }
    return self;
}

- (void)configSrcAddr:(NSString *)srcAddr
              srcPort:(UInt16)srcPort
             destAddr:(NSString *)destAddr
             destPort:(UInt16)destPort
{
    _srcAddr = srcAddr;
    _srcPort = srcPort;
    _destAddr = destAddr;
    _destPort = destPort;
}

- (void)tcpInputWith:(struct ip_globals)ipdata
             tcpInfo:(struct tcp_info)info
                pbuf:(struct pbuf *)pbuf
{
    dispatch_async(_timerQueue, ^{
        _tcpBlock.ip_data = ipdata;
        _tcpBlock.tcpInfo = info;
        tcp_input(pbuf, &_tcpBlock);
    });
}

// MARK: - API

- (void)write:(NSData *)data
{
    dispatch_async(_timerQueue, ^{
        struct tcp_pcb *pcb = _tcpBlock.pcb;
        NSAssert(pcb != NULL && data.length <= TCP_SND_BUF, @"error in write data");
        err_t err = tcp_write(pcb, data.bytes, data.length, 0);
        if (err != ERR_OK) {
            tcp_abort(pcb, &_tcpBlock);
            return;
        }
        tcp_output(pcb, &_tcpBlock);
    });
}

@end
