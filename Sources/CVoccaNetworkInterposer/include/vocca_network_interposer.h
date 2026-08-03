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

#ifndef VOCCA_NETWORK_INTERPOSER_H
#define VOCCA_NETWORK_INTERPOSER_H

// This library is never linked against or imported. It is a `dyld` interposition shim, loaded
// into a probe process with `DYLD_INSERT_LIBRARIES`, and it communicates entirely through a
// file. This header exists to document that contract.
//
// Environment variable read at load time:
//
//   VOCCA_NETWORK_INTERPOSER_LOG
//       Absolute path of the file the shim appends its observations to. The file is opened
//       once, in the library's constructor, with O_CREAT|O_WRONLY|O_APPEND. If the variable is
//       unset or the file cannot be opened, the shim records nothing at all — including the
//       `LOADED` line, whose absence is how the test harness distinguishes "observed no
//       connections" from "observed nothing because it was never watching".
//
// Wire format, one record per line, tab-separated:
//
//   LOADED <TAB> <pid>
//   EVENT  <TAB> <class> <TAB> <call> <TAB> <detail>
//
// where <class> is one of:
//
//   NETWORK      An outbound AF_INET / AF_INET6 connection or datagram. This is the class the
//                zero-network invariant asserts to be empty.
//   RESOLUTION   A hostname lookup. Counted separately because a DNS query leaves the machine
//                even when the connection that would have followed it never opens.
//   OTHER        Recorded for forensics, never asserted on: AF_UNIX and other non-IP address
//                families, and AF_INET socket creation that was never connected.

#endif /* VOCCA_NETWORK_INTERPOSER_H */
