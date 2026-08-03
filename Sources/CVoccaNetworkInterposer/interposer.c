// Copyright 2026 The Vocca Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// A `dyld` interposition shim that records every outbound network call made by the process it
// is inserted into. See include/vocca_network_interposer.h for the file/environment contract.
//
// Why interposition and not something lighter: this sits below every networking abstraction on
// the system. URLSession, Network.framework, a raw BSD socket and any C library all funnel into
// the same handful of libSystem entry points, so hooking those entry points catches all of them
// without having to know which one the code under test chose. A URLProtocol subclass would only
// see URLSession, and a linkage check would only see what a binary declares — neither would
// notice a raw socket() / connect() pair.
//
// Note that `connect` alone is NOT sufficient. On current macOS, URLSession and
// Network.framework both reach the kernel through `connectx`, not `connect`; a shim that
// interposed only `connect` would pass a URLSession request straight through unseen. That is
// the single easiest way to build a convincing-looking version of this file that does not work.

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

// MARK: - Recording

// Opened once by the constructor below and never closed: the process being observed is
// short-lived, and keeping it open means an observation can never be lost to a failed reopen.
static _Atomic int vocca_log_fd = -1;

// Appends one record. Built in a stack buffer and emitted with a single write() so that records
// from concurrent threads interleave line-by-line rather than character-by-character.
static void vocca_record(const char *event_class, const char *call, const char *detail) {
    int fd = vocca_log_fd;
    if (fd < 0) {
        return;
    }
    char line[1024];
    int n = snprintf(line, sizeof(line), "EVENT\t%s\t%s\t%s\n", event_class, call,
                     detail ? detail : "(none)");
    if (n <= 0) {
        return;
    }
    if ((size_t)n >= sizeof(line)) {
        n = (int)sizeof(line) - 1;
    }
    ssize_t written = write(fd, line, (size_t)n);
    (void)written;
}

// Renders `sa` for the log and reports whether it is an off-box-capable IP address.
// Returns 1 for AF_INET / AF_INET6, 0 for every other family.
//
// Loopback counts as NETWORK on purpose. Vocca's default configuration contacts nothing at all,
// including localhost: the opt-in local LLM lives on loopback, and the invariant is meant to
// catch it becoming reachable by default. It is also what lets the positive-control test open a
// real, observable connection without depending on the internet.
static int vocca_describe(const struct sockaddr *sa, char *out, size_t out_size) {
    if (sa == NULL) {
        snprintf(out, out_size, "(null sockaddr)");
        return 0;
    }
    switch (sa->sa_family) {
        case AF_INET: {
            const struct sockaddr_in *in4 = (const struct sockaddr_in *)sa;
            char host[INET_ADDRSTRLEN] = {0};
            inet_ntop(AF_INET, &in4->sin_addr, host, sizeof(host));
            snprintf(out, out_size, "%s:%u", host, (unsigned)ntohs(in4->sin_port));
            return 1;
        }
        case AF_INET6: {
            const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)sa;
            char host[INET6_ADDRSTRLEN] = {0};
            inet_ntop(AF_INET6, &in6->sin6_addr, host, sizeof(host));
            snprintf(out, out_size, "[%s]:%u", host, (unsigned)ntohs(in6->sin6_port));
            return 1;
        }
        case AF_UNIX: {
            const struct sockaddr_un *un = (const struct sockaddr_un *)sa;
            snprintf(out, out_size, "unix:%.*s", (int)sizeof(un->sun_path), un->sun_path);
            return 0;
        }
        default:
            snprintf(out, out_size, "address-family=%d", (int)sa->sa_family);
            return 0;
    }
}

static void vocca_record_sockaddr(const char *call, const struct sockaddr *sa) {
    char detail[512];
    int is_ip = vocca_describe(sa, detail, sizeof(detail));
    vocca_record(is_ip ? "NETWORK" : "OTHER", call, detail);
}

// MARK: - Interposed entry points

static int vocca_connect(int s, const struct sockaddr *name, socklen_t namelen) {
    vocca_record_sockaddr("connect", name);
    return connect(s, name, namelen);
}

// The path URLSession and Network.framework actually take.
static int vocca_connectx(int s, const sa_endpoints_t *endpoints, sae_associd_t associd,
                          unsigned int flags, const struct iovec *iov, unsigned int iovcnt,
                          size_t *len, sae_connid_t *connid) {
    vocca_record_sockaddr("connectx", endpoints ? endpoints->sae_dstaddr : NULL);
    return connectx(s, endpoints, associd, flags, iov, iovcnt, len, connid);
}

// Datagram egress on an unconnected socket never passes through connect()/connectx().
static ssize_t vocca_sendto(int s, const void *buffer, size_t length, int flags,
                            const struct sockaddr *dest_addr, socklen_t dest_len) {
    if (dest_addr != NULL) {
        vocca_record_sockaddr("sendto", dest_addr);
    }
    // A NULL dest_addr means the socket is already connected, so the destination was recorded
    // when the connection was established. Recording it again would double-count.
    return sendto(s, buffer, length, flags, dest_addr, dest_len);
}

static ssize_t vocca_sendmsg(int s, const struct msghdr *message, int flags) {
    if (message != NULL && message->msg_name != NULL) {
        vocca_record_sockaddr("sendmsg", (const struct sockaddr *)message->msg_name);
    }
    return sendmsg(s, message, flags);
}

// Name resolution is recorded even though it is not itself a connection: a DNS query leaves the
// machine, and it reveals intent to connect even if the connection is never made.
static int vocca_getaddrinfo(const char *hostname, const char *servname,
                             const struct addrinfo *hints, struct addrinfo **res) {
    char detail[512];
    snprintf(detail, sizeof(detail), "%s:%s", hostname ? hostname : "(null)",
             servname ? servname : "(null)");
    vocca_record("RESOLUTION", "getaddrinfo", detail);
    return getaddrinfo(hostname, servname, hints, res);
}

static int vocca_getnameinfo(const struct sockaddr *sa, socklen_t salen, char *host,
                             socklen_t hostlen, char *serv, socklen_t servlen, int flags) {
    char detail[512];
    vocca_describe(sa, detail, sizeof(detail));
    vocca_record("RESOLUTION", "getnameinfo", detail);
    return getnameinfo(sa, salen, host, hostlen, serv, servlen, flags);
}

static struct hostent *vocca_gethostbyname(const char *name) {
    vocca_record("RESOLUTION", "gethostbyname", name);
    return gethostbyname(name);
}

// Not a violation by itself — a socket that is never connected sends nothing — but it is
// recorded so that a failure report can show intent, and so that egress smuggled past the calls
// above (via raw syscall(), say) still leaves a trace in the log.
static int vocca_socket(int domain, int type, int protocol) {
    if (domain == AF_INET || domain == AF_INET6) {
        char detail[128];
        snprintf(detail, sizeof(detail), "domain=%d type=%d protocol=%d", domain, type, protocol);
        vocca_record("OTHER", "socket", detail);
    }
    return socket(domain, type, protocol);
}

// MARK: - Interposition table

#define VOCCA_INTERPOSE(replacement, replacee)                                   \
    __attribute__((used)) static const struct {                                  \
        const void *replacement;                                                 \
        const void *replacee;                                                    \
    } vocca_interpose_##replacee __attribute__((section("__DATA,__interpose"))) = \
        {(const void *)&replacement, (const void *)&replacee};

VOCCA_INTERPOSE(vocca_connect, connect)
VOCCA_INTERPOSE(vocca_connectx, connectx)
VOCCA_INTERPOSE(vocca_sendto, sendto)
VOCCA_INTERPOSE(vocca_sendmsg, sendmsg)
VOCCA_INTERPOSE(vocca_getaddrinfo, getaddrinfo)
VOCCA_INTERPOSE(vocca_getnameinfo, getnameinfo)
VOCCA_INTERPOSE(vocca_gethostbyname, gethostbyname)
VOCCA_INTERPOSE(vocca_socket, socket)

// MARK: - Load

// Runs before the host process's main(). The `LOADED` line it writes is load-bearing: the test
// harness treats its absence as a failure, so a run where `DYLD_INSERT_LIBRARIES` was ignored
// can never be mistaken for a run where nothing connected.
__attribute__((constructor)) static void vocca_network_interposer_init(void) {
    const char *path = getenv("VOCCA_NETWORK_INTERPOSER_LOG");
    if (path == NULL || path[0] == '\0') {
        return;
    }
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd < 0) {
        return;
    }
    vocca_log_fd = fd;

    char line[128];
    int n = snprintf(line, sizeof(line), "LOADED\t%d\n", (int)getpid());
    if (n > 0) {
        ssize_t written = write(fd, line, (size_t)n);
        (void)written;
    }
}
