# Wire Protocol

GitZ implements the Git Smart HTTP protocol natively in Zig, without depending on the git binary.

## Protocol Overview

The Smart HTTP protocol uses three requests for clone/fetch:

```
1. GET  /info/refs?service=git-upload-pack    → Discover refs
2. POST /git-upload-pack                       → Download objects
3. (optional) POST for additional data
```

For push:

```
1. GET  /info/refs?service=git-receive-pack   → Discover refs
2. POST /git-receive-pack                      → Upload objects
3. Report status response
```

## Pkt-Line Format

All protocol messages use the pkt-line format:

```
<4-hex-digit-length><payload>\n
```

- Length includes the 4-byte header + payload + newline
- `0000` is a flush packet (end of section)
- `0001` is a special delimiter

## Clone/Fetch Sequence

### 1. Ref Discovery

```
GET /info/refs?service=git-upload-pack

Response:
001e# service=git-upload-pack\n
0000
00XX<ref-name> <sha>[ capabilities]\n
00XX<ref-name> <sha>\n
...
0000
```

### 2. Want/Have Negotiation

```
POST /git-upload-pack

Client sends:
00XXwant <sha> <capabilities>\n    ← First want with capabilities
00XXwant <sha>\n                   ← Additional wants
...
00XXhave <sha>\n                   ← What we already have
...
0000                               ← End negotiation

Server responds with:
- ACK/NAK for each round
- Pack data when negotiation complete
```

**Capabilities:**
- `multi_ack` — Multiple ACK support
- `thin-pack` — Allow thin packs
- `side-band-64k` — Multiplexed pack + progress output
- `ofs-delta` — Offset delta support
- `agent=git/2.45.0` — User agent impersonation

### 3. Pack Download

The pack data is sent in side-band format when `side-band-64k` is negotiated:

```
Band 1: Pack data
Band 2: Progress messages (ignored)
Band 3: Error messages (logged)
```

## Push Sequence

### 1. Ref Discovery

Same as clone, but with `git-receive-pack`.

### 2. Push Command

```
POST /git-receive-pack

Client sends:
00XX<old-sha> <new-sha> <ref-name>\0<capabilities>\n
0000
<pack data>
```

### 3. Server Response

```
unpack ok\n              ← Unpack successful
ok <ref-name>\n          ← Ref updated
ng <ref-name> <reason>\n ← Ref update failed
```

## Authentication

GitZ supports three authentication methods:

### URL Credentials

```bash
gitz clone https://user:token@github.com/user/repo.git
```

### Environment Variables

```bash
export GITZ_HTTP_USERNAME=user
export GITZ_HTTP_PASSWORD=token
gitz clone https://github.com/user/repo.git
```

### Token Auto-Detection

```bash
export GITHUB_TOKEN=ghp_xxxx
gitz clone https://github.com/user/repo.git
# Automatically uses x-access-token:ghp_xxxx
```

The `Authorization` header is sent on all 3 requests (info/refs, upload-pack, receive-pack).

## SSH Transport

GitZ SSH transport works via child process pipes:

```bash
gitz clone git@github.com:user/repo.git
# Spawns: ssh -T git@github.com
# Communicates via stdin/stdout pipes
```

## User-Agent

All HTTP requests include:

```
User-Agent: git/2.45.0
```

This makes GitZ indistinguishable from a real git client to servers.

## Reference Format

All refs in the wire protocol are fully-qualified:

```
refs/heads/main
refs/tags/v1.0
refs/remotes/origin/main
```
