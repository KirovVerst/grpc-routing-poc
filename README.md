# gRPC Routing PoC

Proof of Concept for routing gRPC requests by client version with sticky routing at the TCP connection level.

## Table of Contents

- [Overview](#overview)
- [Key Features](#key-features)
- [Proxy Options](#proxy-options)
  - [Envoy](#envoy)
  - [Traefik](#traefik)
- [Architecture](#architecture)
  - [System Overview](#system-overview)
  - [Components](#components)
  - [Sticky Routing Principle](#sticky-routing-principle)
  - [Network Topology](#network-topology)
  - [Data Flows](#data-flows)
- [Quick Start](#quick-start)
  - [Requirements](#requirements)
  - [5-Minute Setup](#5-minute-setup)
  - [Status Check](#status-check)
  - [Routing Verification](#routing-verification)
  - [What This PoC Tests](#what-this-poc-tests)
- [Project Structure](#project-structure)
- [Testing](#testing)
  - [Basic Tests](#basic-tests)
  - [Advanced Tests](#advanced-tests)
- [Makefile Commands](#makefile-commands)
- [Scalability](#scalability)
- [Monitoring](#monitoring)

## Overview

This project demonstrates gRPC request routing based on client version using either Envoy or Traefik proxy with bidirectional streaming. The system uses header matching to route clients with vX.Y versions to corresponding vX backend clusters, maintaining long-lived streaming connections for continuous ping-pong communication.

## Key Features

- **Bidirectional Streaming**: agents and servers maintain long-lived bidirectional streams for continuous ping-pong communication
- **Sticky Routing**: one agent always routes to the same backend cluster and pod throughout the stream connection
- **vX.Y → vX Versioning**: agents use format v1.1, v1.2, v2.1, v2.2; servers use v1, v2
- **Header-based Routing**: proxy uses header matching on `agent-version` header (v1.* → server-v1, v2.* → server-v2)
- **Multiple Proxy Options**: choose between Envoy or Traefik proxy
- **TLS Termination**: TLS terminates at proxy, upstream connections without TLS
- **HTTP/2 End-to-End**: full HTTP/2 support for efficient gRPC streaming operations

## Proxy Options

This PoC supports two proxy implementations with identical routing behavior:

### Envoy

**Image**: `envoyproxy/envoy:v1.28-latest`

**Configuration**: YAML-based static and dynamic configuration
- Uses `http_connection_manager` filter
- Header prefix matching with route priorities
- Native HTTP/2 and gRPC support

**Deploy with**: `make deploy-envoy`

**Advantages**:
- Purpose-built for service mesh and API gateway
- Extensive gRPC and HTTP/2 optimizations
- Rich observability and metrics

### Traefik

**Image**: `traefik:v3.2`

**Configuration**: Static and dynamic YAML configuration
- Uses HeadersRegexp matchers for routing
- Native HTTP/2 and gRPC support
- Web dashboard on port 9901

**Deploy with**: `make deploy-traefik`

**Advantages**:
- Simpler configuration syntax
- Built-in web UI for monitoring
- Auto-discovery capabilities (not used in this PoC)

Both proxies use the same service name (`proxy-ingress`) and ports (8443 for gRPC, 9901 for admin).

## Architecture

### System Overview

```
┌──────────────────────────────────────────────────────────────────┐
│                        Kubernetes Cluster                        │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │                    Namespace: grpc-routing-poc             │  │
│  │                                                            │  │
│  │  ┌──────────────┐      ┌──────────────────────────┐        │  │
│  │  │  Agent v1.1  │      │                          │        │  │
│  │  │  (N replicas)│──────│    Proxy Ingress         │        │  │
│  │  │              │ gRPC │    (Envoy or Traefik)    │        │  │
│  │  │ metadata:    │ +TLS │    (1 replica)           │        │  │
│  │  │ version=v1.1 │──────│                          │        │  │
│  │  │ id=pod-name  │      │  • TLS termination       │        │  │
│  │  └──────────────┘      │  • Route by metadata     │        │  │
│  │                        │  • HTTP/2 upstream       │        │  │
│  │  ┌──────────────┐      │                          │        │  │
│  │  │  Agent v2.1  │      │                          │        │  │
│  │  │  (N replicas)│──────│                          │        │  │
│  │  │              │ gRPC │                          │        │  │
│  │  │ metadata:    │ +TLS │                          │        │  │
│  │  │ version=v2.1 │──────│                          │        │  │
│  │  │ id=pod-name  │      └────────┬─────────────────┘        │  │
│  │  └──────────────┘               │                          │  │
│  │                                 │                          │  │
│  │                      ┌──────────┴────────────┐             │  │
│  │                      │                       │             │  │
│  │                      v                       v             │  │
│  │           ┌──────────────────┐    ┌──────────────────┐     │  │
│  │           │   Server v1      │    │   Server v2      │     │  │
│  │           │   (2 replicas)   │    │   (2 replicas)   │     │  │
│  │           │                  │    │                  │     │  │
│  │           │   Service:       │    │   Service:       │     │  │
│  │           │   server-v1      │    │   server-v2      │     │  │
│  │           │   :50051         │    │   :50051         │     │  │
│  │           └──────────────────┘    └──────────────────┘     │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

### Components

#### 1. Agent (gRPC Client)

**Purpose**: Emulates a client application of a specific version.

**Characteristics**:
- Single long-lived gRPC bidirectional streaming connection
- Sends ping messages every 5 seconds
- Receives pong responses continuously
- Automatic reconnection on connection loss

**Metadata**:
- `agent-version`: agent version in vMAJOR.MINOR format (v1.1, v1.2, v2.1, v2.2)
- `agent-id`: unique agent identifier (Kubernetes pod name via Downward API)

**Deployment Versions**:
- `agent-v1.1`: minor version 1.1 → routed to server-v1
- `agent-v1.2`: minor version 1.2 → routed to server-v1
- `agent-v2.1`: minor version 2.1 → routed to server-v2
- `agent-v2.2`: minor version 2.2 → routed to server-v2

**Behavior**:
```
1. Connect to proxy-ingress.grpc-routing-poc.svc.cluster.local:8443 (TLS)
2. Open bidirectional stream with metadata:
   - agent-version: v1.1
   - agent-id: agent-v1-1-<pod-hash> (from Kubernetes pod name)
3. Start receive goroutine to listen for pong responses
4. Send ping messages every 5 seconds on the stream
5. Log each ping sent and pong received with server pod details
6. Reconnect and reopen stream on error
```

#### 2. Server (gRPC Server)

**Purpose**: gRPC backend that processes streaming requests.

**Characteristics**:
- Language: Go
- HTTP/2 without TLS (plain text connection)
- Handles bidirectional streaming connections
- Logs incoming requests with agent metadata and pod information

**Deployment Versions**:
- `server-v1`: 2 replicas, accepts streams from agents v1.*
- `server-v2`: 2 replicas, accepts streams from agents v2.*

**Behavior**:
```
1. Listen on :50051 (HTTP/2, no TLS)
2. Accept PingPong() bidirectional streaming requests
3. Extract metadata once at stream start:
   - agent-version
   - agent-id
4. Log stream opening with agent details
5. Receive ping messages continuously:
   - Log: [SERVER_v1/pod-name] Received ping from agent-id=... agent-version=...
6. Send pong responses immediately:
   - Include server version and pod ID (HOSTNAME)
   - Log: [SERVER_v1/pod-name] Sent pong to agent-id=...
7. Handle stream closure gracefully
```

#### 3. Proxy (Ingress)

**Purpose**: Routes gRPC bidirectional streams based on metadata with TLS termination.

**Options**: Envoy or Traefik (deployed via `make deploy-envoy` or `make deploy-traefik`)

**Common Characteristics**:
- TLS listener on port 8443
- Routes streams based on `agent-version` header
- HTTP/2 upstream connections (no TLS)
- Maintains stream routing throughout connection lifetime
- Admin/dashboard interface on port 9901

##### Routing Rules

Both proxies implement the same routing logic:

1. **Route for v2.* agents**:
   - Match: header `agent-version` matches regex `^v2\..*`
   - Target: `server-v2.grpc-routing-poc.svc.cluster.local:50051`
   
2. **Route for v1.* agents**:
   - Match: header `agent-version` matches regex `^v1\..*`
   - Target: `server-v1.grpc-routing-poc.svc.cluster.local:50051`

3. **Default route**:
   - Match: any request without matching header
   - Target: `server-v1.grpc-routing-poc.svc.cluster.local:50051`

##### Load Balancing
- **Algorithm**: Round Robin
- **Protocol**: HTTP/2 (h2c - cleartext HTTP/2)
- **Health Checks**: Periodic checks to backend servers

##### Admin Interface

Access at: `http://localhost:30901`

**Envoy endpoints**:
- `/stats` - metrics
- `/config_dump` - current configuration
- `/clusters` - cluster status
- `/listeners` - listener status

**Traefik endpoints**:
- `/dashboard` - web UI
- `/api/rawdata` - configuration and runtime data

##### HTTP/2 Stream Isolation

**Connection Pooling vs Stream Isolation**:

Envoy maintains a connection pool to upstream servers for efficiency. However, **metadata and messages are isolated per HTTP/2 stream**, not per TCP connection:

```
Agent Pod A ──[Stream 1: agent-id=agent-v1-1-abc-123]──┐
                                                        ├──> Proxy ──[1 TCP]──> Server Pod
Agent Pod B ──[Stream 3: agent-id=agent-v1-1-def-456]──┘            ├─> Stream 1: agent-id=agent-v1-1-abc-123
                                                                     └─> Stream 3: agent-id=agent-v1-1-def-456
```

**Key Points**:

- **One TCP connection** can multiplex **multiple gRPC streams**
- Each stream carries its own **gRPC metadata** (agent-id, agent-version)
- Server receives each stream as a **separate `PingPong()` call** with correct metadata
- Streams are **fully isolated** - metadata from one stream never leaks to another
- This enables **one server pod to handle multiple agents simultaneously** with distinct identities

**Practical Impact**:

✅ Server can distinguish between agents even when they share the same upstream TCP connection

✅ Each agent gets its own isolated bidirectional stream with proper metadata

✅ Perfect for scenarios requiring per-agent resources (e.g., RabbitMQ queues, sessions)

✅ Connection pooling provides efficiency without breaking isolation

### Sticky Routing Principle

**Key Idea**: One bidirectional stream → one backend server pod

```
┌─────────────┐                                 ┌─────────────┐
│  Agent v1.1 │◀───────────────────────────────▶│  Server v1  │
│             │  1 bidirectional stream         │  (replica 1)│
│  5s pings   │  All messages via this stream   │             │
└─────────────┘                                 └─────────────┘
     │
     │ stream closes
     ▼
┌─────────────┐                                 ┌─────────────┐
│  Agent v1.1 │◀───────────────────────────────▶│  Server v1  │
│             │  new stream                     │  (replica 2)│
│  reconnect  │  (may route to different pod)   │             │
└─────────────┘                                 └─────────────┘
```

**How It Works**:

1. **Stream Level**:
   - Agent establishes 1 TCP connection with Envoy
   - Opens bidirectional gRPC stream with metadata
   - Envoy reads metadata at stream start
   - Routes stream to appropriate cluster (server-v1 or server-v2)
   - Envoy selects 1 backend pod (Round Robin)

2. **Sticky Behavior**:
   - All ping/pong messages use the same bidirectional stream
   - Stream stays with the same backend pod throughout its lifetime
   - No re-routing happens during stream lifetime
   - Continuous communication without per-request overhead

3. **Reconnection**:
   - On stream or connection failure, agent reconnects
   - Opens new stream with metadata
   - New stream may route to a different pod
   - But all messages within new stream go to the same pod

**Example**:
```
Time | Agent v1.1 | Stream     | Backend
-----|------------|------------|----------
0s   | open stream| STREAM-1   | server-v1-pod-A
5s   | ping #1    | STREAM-1   | server-v1-pod-A
5s   | pong #1    | STREAM-1   | server-v1-pod-A
10s  | ping #2    | STREAM-1   | server-v1-pod-A
10s  | pong #2    | STREAM-1   | server-v1-pod-A
15s  | [ERROR]    | STREAM-1   | stream closed
16s  | open stream| STREAM-2   | server-v1-pod-B
20s  | ping #3    | STREAM-2   | server-v1-pod-B
20s  | pong #3    | STREAM-2   | server-v1-pod-B
```

### Network Topology

```
┌────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                  │
│  ┌──────────────────────────────────────────────────┐  │
│  │              Namespace: grpc-routing-poc         │  │
│  │                                                  │  │
│  │  Agents ────▶ Proxy Service ────▶ Server Services│  │
│  │   (TLS)         (ClusterIP)          (ClusterIP) │  │
│  │                      │                     │     │  │
│  │                      ▼                     ▼     │  │
│  │                 Proxy Pod          Server Pod    │  │
│  │              (NodePort 30443)    (2x v1, 2x v2)  │  │
│  └──────────────────────────────────────────────────┘  │
│                      │                                 │
│                      ▼ (NodePort)                      │
│              External Access Available                 │
└────────────────────────────────────────────────────────┘
```

#### DNS Resolution

```
agent-v1-1 pod
  └─> proxy-ingress.grpc-routing-poc.svc.cluster.local
       └─> Service proxy-ingress (ClusterIP)
            └─> Proxy pod (Envoy or Traefik)

proxy pod
  ├─> server-v1.grpc-routing-poc.svc.cluster.local
  │    └─> Service server-v1 (ClusterIP)
  │         └─> server-v1 pods (2 replicas)
  │
  └─> server-v2.grpc-routing-poc.svc.cluster.local
       └─> Service server-v2 (ClusterIP)
            └─> server-v2 pods (2 replicas)
```

### Data Flows

#### Bidirectional Streaming Flow

```
Agent v1.1                Proxy                 Server v1
    │                       │                       │
    │ ┌─ TLS Handshake ────▶│                       │
    │ │                     │                       │
    │ └◀─ TLS Established ──│                       │
    │                       │                       │
    │ ┌─ Open Stream ──────▶│                       │
    │ │  metadata:          │                       │
    │ │  - agent-version:v1.1                       │
    │ │  - agent-id:uuid    │                       │
    │ │                     │                       │
    │ │                     │ ┌─ Check metadata     │
    │ │                     │ │  v1.1 → server-v1   │
    │ │                     │ │                     │
    │ │                     │ └─ HTTP/2 Stream ────▶│
    │ │                     │    (no TLS)           │
    │ └◀─ Stream Ready ─────┴───────────────────────┘
    │                       │                       │
    │                       │                       │ ┌─ Log stream opened
    │                       │                       │ │  with agent details
    │                       │                       │ └─
    │                       │                       │
    │ ── Ping ─────────────▶│──────────────────────▶│
    │                       │                       │ ┌─ Log ping received
    │                       │                       │ └─
    │                       │                       │
    │ ◀─ Pong ──────────────│◀──────────────────────│
    │                       │                       │ ┌─ Log pong sent
    │                       │                       │ └─
    │                       │                       │
    │ ── Ping ─────────────▶│──────────────────────▶│
    │ ◀─ Pong ──────────────│◀──────────────────────│
    │                       │                       │
    │    (continuous ping-pong every 5s)            │
    │◀─────────────────────────────────────────────▶│
    │                       │                       │
    ▼                       ▼                       ▼
  Log each message    Forward messages        Log each message
```

#### Routing Decision

```
Stream opens at Proxy
      │
      ▼
Extract metadata header "agent-version"
      │
      ├─ v2.* ──────▶ Route to server-v2
      │                     │
      ├─ v1.* ──────▶ Route to server-v1
      │                     │
      └─ no match ──▶ Route to server-v1 (default)
                            │
                            ▼
                      Select backend pod
                      (Round Robin LB)
                            │
                            ▼
                      Establish HTTP/2 connection
                      (if not exists)
                            │
                            ▼
                      Open bidirectional stream
                            │
                            ▼
                      Forward all messages on stream
                      (sticky to same pod)
```

## Quick Start

### Requirements

- [kind](https://kind.sigs.k8s.io/) (Kubernetes in Docker)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Docker](https://www.docker.com/)
- [Go](https://golang.org/) 1.23+ (for local development)
- [protoc](https://grpc.io/docs/protoc-installation/) (for generating proto files)

### 5-Minute Setup

```bash
# 1. Create kind cluster
kind create cluster --name grpc-routing-poc

# 2. Build and deploy everything
make all-envoy     # Deploy with Envoy
# OR
make all-traefik   # Deploy with Traefik

# 3. Check status
kubectl get pods -n grpc-routing-poc

# 4. View logs
make logs-agents-v1
make logs-agents-v2
make logs-proxy
```

**Expected output** in agent logs:
```
[AGENT_v1.1/agent-v1-1-7df8b5c9d-xyzab] Stream opened to proxy-ingress:8443
[AGENT_v1.1/agent-v1-1-7df8b5c9d-xyzab] Sent ping
[AGENT_v1.1/agent-v1-1-7df8b5c9d-xyzab] Received pong from server=v1/server-v1-abc123-def message=pong
[AGENT_v1.2/agent-v1-2-9gh8k3l2m-pqrst] Stream opened to proxy-ingress:8443
[AGENT_v1.2/agent-v1-2-9gh8k3l2m-pqrst] Sent ping
[AGENT_v1.2/agent-v1-2-9gh8k3l2m-pqrst] Received pong from server=v1/server-v1-abc123-ghi message=pong
```

Note: Agent ID is the Kubernetes pod name (e.g., `agent-v1-1-<hash>`), allowing easy traceability between logs and pods.

### Status Check

```bash
# View all pods
kubectl get pods -n grpc-routing-poc

# Expected output:
# NAME                             READY   STATUS    RESTARTS   AGE
# agent-v1-1-xxx                   1/1     Running   0          2m
# agent-v1-2-xxx                   1/1     Running   0          2m
# agent-v2-1-xxx                   1/1     Running   0          2m
# agent-v2-2-xxx                   1/1     Running   0          2m
# proxy-ingress-xxx                1/1     Running   0          2m
# server-v1-xxx                    1/1     Running   0          2m
# server-v1-yyy                    1/1     Running   0          2m
# server-v2-xxx                    1/1     Running   0          2m
# server-v2-yyy                    1/1     Running   0          2m

# View services
kubectl get svc -n grpc-routing-poc

# Check proxy admin interface
kubectl port-forward -n grpc-routing-poc svc/proxy-ingress 9901:9901
# Open http://localhost:9901 (Envoy) or http://localhost:9901/dashboard (Traefik)
```

### Routing Verification

#### Manual Verification

```bash
# 1. Check v1 agents route to server-v1 and receive pongs
make logs-agents-v1 | grep "Received pong from server=v1"

# 2. Check v2 agents route to server-v2 and receive pongs
make logs-agents-v2 | grep "Received pong from server=v2"

# 3. Verify server-v1 receives only v1.* streams
make logs-server-v1 | grep "Stream opened from"

# 4. Verify server-v2 receives only v2.* streams
make logs-server-v2 | grep "Stream opened from"

# 5. Check continuous ping-pong communication
make logs-agents-v1 | grep -E "(Sent ping|Received pong)"
```

#### Automated Verification

```bash
./scripts/verify-routing.sh
```

Expected output:
```
✅ Agent v1.1 → Server v1: OK
✅ Agent v1.2 → Server v1: OK
✅ Agent v2.1 → Server v2: OK
✅ Agent v2.2 → Server v2: OK
🎉 Routing verification passed!
```

### What This PoC Tests

1. **✅ Version-based Routing**
   - v1.* agents route to server-v1
   - v2.* agents route to server-v2

2. **✅ Bidirectional Streaming**
   - Long-lived bidirectional gRPC streams
   - Continuous ping-pong communication
   - Reduced per-message overhead

3. **✅ Sticky Routing**
   - Single bidirectional stream per agent
   - All messages use the same stream
   - Stream stays with one backend pod throughout its lifetime

4. **✅ TLS Termination**
   - Agents connect via TLS (port 8443)
   - Envoy terminates TLS
   - Upstream connections use plain HTTP/2

5. **✅ HTTP/2 End-to-End**
   - Full HTTP/2 support for gRPC streaming
   - Efficient connection multiplexing

6. **✅ Automatic Reconnection**
   - Agents reconnect and reopen stream on failure
   - New stream may route to different pod
   - Routing logic applies to new stream

7. **✅ Horizontal Scalability with Unique Identity**
   - Each agent replica gets unique ID from Kubernetes pod name
   - Scale deployments to simulate multiple agents of same version
   - Perfect for testing scenarios with many agents per version
   - Server can distinguish each agent instance for per-agent resources

## Project Structure

```
.
├── agent/
│   ├── main.go            # gRPC client implementation
│   ├── go.mod
│   └── Dockerfile
├── server/
│   ├── main.go            # gRPC server implementation
│   ├── go.mod
│   └── Dockerfile
├── proto/
│   ├── ping.proto         # Protocol Buffers definitions (bidirectional streaming)
│   ├── go.mod
│   ├── ping.pb.go         # Generated Go code
│   └── ping_grpc.pb.go    # Generated gRPC streaming code
├── certs/
│   ├── generate-certs.sh  # TLS certificate generation script
│   ├── cert.pem           # Generated certificate
│   └── key.pem            # Generated private key
├── k8s/
│   ├── namespace.yaml
│   ├── server-v1.yaml     # Server v1 Deployment + Service
│   ├── server-v2.yaml     # Server v2 Deployment + Service
│   ├── agent-v1.1.yaml    # Agent v1.1 Deployment
│   ├── agent-v1.2.yaml    # Agent v1.2 Deployment
│   ├── agent-v2.1.yaml    # Agent v2.1 Deployment
│   ├── agent-v2.2.yaml    # Agent v2.2 Deployment
│   ├── envoy.yaml         # Envoy Deployment + Service + ConfigMap
│   └── traefik.yaml       # Traefik Deployment + Service + ConfigMap
├── scripts/
│   ├── verify-routing.sh       # Automated routing verification
│   └── test-sticky-routing.sh  # Sticky routing test
├── Makefile               # Automation scripts
└── README.md
```

### Protocol Definition

The bidirectional streaming RPC is defined in `proto/ping.proto`:

**Key Points**:
- `stream PingRequest` - client can send multiple messages
- `stream PingResponse` - server can send multiple responses
- Agent metadata (version, ID) sent via gRPC headers, not in message body
- Server includes pod ID in responses for observability

## Testing

### Basic Tests

#### 1. Check All Pods Running
```bash
kubectl get pods -n grpc-routing-poc
# All pods should be Running with READY 1/1
```

#### 2. View Agent v1.1 Logs
```bash
make logs-agent-v1-1
# Expected: "Stream opened", "Sent ping", "Received pong from server=v1/..."
```

#### 3. View Agent v2.1 Logs
```bash
make logs-agent-v2-1
# Expected: "Stream opened", "Sent ping", "Received pong from server=v2/..."
```

#### 4. View Server v1 Logs
```bash
make logs-server-v1
# Expected output:
# [SERVER_v1/server-v1-abc123-def] Stream opened from agent-id=agent-v1-1-7df8b5c9d-xyzab agent-version=v1.1
# [SERVER_v1/server-v1-abc123-def] Received ping from agent-id=agent-v1-1-7df8b5c9d-xyzab agent-version=v1.1 message=ping
# [SERVER_v1/server-v1-abc123-def] Sent pong to agent-id=agent-v1-1-7df8b5c9d-xyzab
```

#### 5. View Server v2 Logs
```bash
make logs-server-v2
# Expected output:
# [SERVER_v2/server-v2-xyz789-ghi] Stream opened from agent-id=agent-v2-1-9gh8k3l2m-pqrst agent-version=v2.1
# [SERVER_v2/server-v2-xyz789-ghi] Received ping from agent-id=agent-v2-1-9gh8k3l2m-pqrst agent-version=v2.1 message=ping
# [SERVER_v2/server-v2-xyz789-ghi] Sent pong to agent-id=agent-v2-1-9gh8k3l2m-pqrst
```

### Advanced Tests

#### 1. Sticky Routing Test

```bash
./scripts/test-sticky-routing.sh
```

What it checks:
- One agent maintains single bidirectional stream
- All ping/pong messages go through same backend pod
- Stream persists throughout test

Expected output:
```
Testing sticky routing for agent-v1-1...
✅ All 20 messages routed to same pod: server-v1-xxx
Sticky routing works correctly!
```

#### 2. Multi-Agent and Load Testing

```bash
# Scale agents to simulate multiple agents of the same version
kubectl scale deployment agent-v1-1 --replicas=5 -n grpc-routing-poc
kubectl scale deployment agent-v2-1 --replicas=5 -n grpc-routing-poc

# Verify each agent has unique ID (pod name)
kubectl get pods -n grpc-routing-poc -l version=v1.1 -o custom-columns=NAME:.metadata.name
# Output:
# agent-v1-1-7df8b5c9d-xyzab
# agent-v1-1-7df8b5c9d-pqrst
# agent-v1-1-7df8b5c9d-lmnop
# agent-v1-1-7df8b5c9d-uvwxy
# agent-v1-1-7df8b5c9d-zabcd

# Check server logs - should see multiple distinct agent-id connections
kubectl logs -n grpc-routing-poc -l app=server,version=v1 --tail=20 | grep "Stream opened"
# Expected: Multiple "Stream opened from agent-id=agent-v1-1-<different-hashes>"

# Scale servers to handle load
kubectl scale deployment server-v1 --replicas=4 -n grpc-routing-poc
kubectl scale deployment server-v2 --replicas=4 -n grpc-routing-poc
```

#### 3. Failover Testing

```bash
# Delete one server-v1 pod
kubectl delete pod -n grpc-routing-poc -l app=server,version=v1 --field-selector=status.phase=Running | head -1

# Watch agent logs - should see reconnection
make logs-agent-v1-1 -f

# Expected behavior:
# - Stream/connection error logged
# - Automatic reconnection and stream reopening
# - Ping/pong messages resume with same routing
```

## Makefile Commands

```bash
# Proto generation
make proto          # Generate Go code from .proto files

# Certificate management
make certs          # Generate TLS certificates
make apply-certs    # Apply certificates to Kubernetes

# Build and deploy
make build          # Build Docker images
make load           # Load images into kind cluster
make deploy-envoy   # Deploy with Envoy proxy
make deploy-traefik # Deploy with Traefik proxy
make all-envoy      # Full setup with Envoy: certs + build + load + deploy
make all-traefik    # Full setup with Traefik: certs + build + load + deploy

# Log viewing
make logs-server-v1      # View server-v1 logs
make logs-server-v2      # View server-v2 logs
make logs-agent-v1-1     # View agent-v1.1 logs
make logs-agent-v1-2     # View agent-v1.2 logs
make logs-agent-v2-1     # View agent-v2.1 logs
make logs-agent-v2-2     # View agent-v2.2 logs
make logs-agents-v1      # View all v1.x agent logs
make logs-agents-v2      # View all v2.x agent logs
make logs-envoy          # View Envoy proxy logs
make logs-traefik        # View Traefik proxy logs
make logs-proxy          # View active proxy logs

# Cleanup
make clean          # Delete namespace and all resources
```

## Scalability

### Horizontal Scaling

#### Scaling Agents

```bash
# Scale up to simulate multiple agents of the same version
kubectl scale deployment agent-v1-1 --replicas=10 -n grpc-routing-poc

# Each replica gets a unique pod name and agent-id
# Example pods:
#   agent-v1-1-7df8b5c9d-xyzab → agent-id: agent-v1-1-7df8b5c9d-xyzab
#   agent-v1-1-7df8b5c9d-pqrst → agent-id: agent-v1-1-7df8b5c9d-pqrst
#   agent-v1-1-7df8b5c9d-lmnop → agent-id: agent-v1-1-7df8b5c9d-lmnop

# Scale down
kubectl scale deployment agent-v1-1 --replicas=1 -n grpc-routing-poc

# View all agent instances with their unique IDs
kubectl get pods -n grpc-routing-poc -l version=v1.1 -o custom-columns=NAME:.metadata.name
```

#### Scaling Servers

```bash
# Scale server-v1
kubectl scale deployment server-v1 --replicas=5 -n grpc-routing-poc

# Scale server-v2
kubectl scale deployment server-v2 --replicas=5 -n grpc-routing-poc

# Load distribution:
# - New connections distributed via Round Robin
# - Existing connections remain sticky
```

#### Scaling Proxy

```bash
# Scale proxy (multiple instances)
kubectl scale deployment proxy-ingress --replicas=3 -n grpc-routing-poc

# Considerations:
# - Service LoadBalancer distributes connections
# - Each proxy instance handles its own connections
# - No shared state between proxy instances
```

## Monitoring

### Proxy Metrics

Access admin interface:
```bash
kubectl port-forward -n grpc-routing-poc svc/proxy-ingress 9901:9901
```

#### Envoy Metrics

```bash
# Connection stats
curl http://localhost:9901/stats | grep cx_active
curl http://localhost:9901/stats | grep cx_total

# Request stats
curl http://localhost:9901/stats | grep rq_total
curl http://localhost:9901/stats | grep rq_success

# Cluster health
curl http://localhost:9901/clusters

# Upstream connections
curl http://localhost:9901/stats | grep upstream_cx
```

#### Traefik Metrics

```bash
# Web dashboard
open http://localhost:9901/dashboard

# API endpoints
curl http://localhost:9901/api/http/routers
curl http://localhost:9901/api/http/services
curl http://localhost:9901/api/rawdata
```

### Application Logs

```bash
# Real-time agent logs
kubectl logs -f -n grpc-routing-poc -l version=v1.1

# Server logs with timestamps
kubectl logs --timestamps -n grpc-routing-poc -l app=server,version=v1

```

### Metrics to Monitor

1. **Routing Accuracy**:
   - v1.* agents → server-v1 (should be 100%)
   - v2.* agents → server-v2 (should be 100%)

2. **Stream Stability**:
   - Stream reconnection rate (should be low)
   - Stream duration (should be high - hours/days)
   - Active streams per server

3. **Performance**:
   - Message latency (p50, p95, p99)
   - Throughput (messages/s)
   - Error rate (should be 0%)

4. **Resource Usage**:
   - CPU utilization
   - Memory usage per stream
   - Network I/O

## License

This is a Proof of Concept project for educational purposes.
