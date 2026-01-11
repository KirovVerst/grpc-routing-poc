# gRPC Routing PoC

Proof of Concept for routing gRPC requests by client version with sticky routing at the TCP connection level.

## Table of Contents

- [Overview](#overview)
- [Key Features](#key-features)
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

This project demonstrates gRPC request routing based on client version using Envoy proxy. The system uses prefix matching to route clients with vX.Y versions to corresponding vX backend clusters.

## Key Features

- **Sticky Routing**: one agent always routes to the same backend cluster throughout the connection
- **vX.Y → vX Versioning**: agents use format v1.1, v1.2, v2.1, v2.2; servers use v1, v2
- **Prefix-based Routing**: Envoy uses prefix matching on `agent-version` header (v1.* → server-v1, v2.* → server-v2)
- **TLS Termination**: TLS terminates at Envoy, upstream connections without TLS
- **HTTP/2 End-to-End**: full HTTP/2 support for efficient gRPC operations

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
│  │  │  (1 replica) │──────│      Envoy Ingress       │        │  │
│  │  │              │ gRPC │      (1 replica)         │        │  │
│  │  │ metadata:    │ +TLS │                          │        │  │
│  │  │ version=v1.1 │──────│  • TLS termination       │        │  │
│  │  │ id=uuid-1    │      │  • Route by metadata     │        │  │
│  │  └──────────────┘      │  • HTTP/2 upstream       │        │  │
│  │                        │                          │        │  │
│  │  ┌──────────────┐      │                          │        │  │
│  │  │  Agent v2.1  │      │                          │        │  │
│  │  │  (1 replica) │──────│                          │        │  │
│  │  │              │ gRPC │                          │        │  │
│  │  │ metadata:    │ +TLS │                          │        │  │
│  │  │ version=v2.1 │──────│                          │        │  │
│  │  │ id=uuid-2    │      └────────┬─────────────────┘        │  │
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
- Single long-lived gRPC connection
- Request frequency: every 5 seconds
- Automatic reconnection on connection loss

**Metadata**:
- `agent-version`: agent version in vMAJOR.MINOR format (v1.1, v1.2, v2.1, v2.2)
- `agent-id`: unique agent identifier (UUID)

**Deployment Versions**:
- `agent-v1.1`: minor version 1.1 → routed to server-v1
- `agent-v1.2`: minor version 1.2 → routed to server-v1
- `agent-v2.1`: minor version 2.1 → routed to server-v2
- `agent-v2.2`: minor version 2.2 → routed to server-v2

**Behavior**:
```
1. Connect to envoy-ingress.grpc-routing-poc.svc.cluster.local:8443 (TLS)
2. For each request, add metadata:
   - agent-version: v1.1
   - agent-id: agent-v1.1-uuid
3. Call Ping() method every 5 seconds
4. Log result: success or error
5. Reconnect on error
```

#### 2. Server (gRPC Server)

**Purpose**: gRPC backend that processes requests.

**Characteristics**:
- Language: Go
- HTTP/2 without TLS (plain text connection)
- Logs incoming requests with metadata

**Deployment Versions**:
- `server-v1`: 2 replicas, accepts requests from agents v1.*
- `server-v2`: 2 replicas, accepts requests from agents v2.*

**Behavior**:
```
1. Listen on :50051 (HTTP/2, no TLS)
2. Accept Ping() requests
3. Extract metadata:
   - agent-version
   - agent-id
4. Log: [SERVER_v1] agent-id=... agent-version=... message=ping
5. Return: Pong from server-v1 (server=v1)
```

#### 3. Envoy Proxy (Ingress)

**Purpose**: Routes gRPC requests based on metadata with TLS termination.

**Characteristics**:
- TLS listener on port 8443
- Routes based on `agent-version` header
- HTTP/2 upstream connections (no TLS)
- Admin interface on port 9901

##### Routing Rules

1. **Route for v2.* agents**:
   - Match: header `agent-version` starts with `v2.`
   - Target: cluster `server-v2`
   
2. **Route for v1.* agents**:
   - Match: header `agent-version` starts with `v1.`
   - Target: cluster `server-v1`

3. **Default route**:
   - Match: any request without matching header
   - Target: cluster `server-v1`

##### Clusters
- **server-v1**:
  - Upstream: `server-v1.grpc-routing-poc.svc.cluster.local:50051`
  - Protocol: HTTP/2
  - LB: Round Robin

- **server-v2**:
  - Upstream: `server-v2.grpc-routing-poc.svc.cluster.local:50051`
  - Protocol: HTTP/2
  - LB: Round Robin

##### Admin Interface

Access at: `http://localhost:30901`

Useful endpoints:
- `/stats` - metrics
- `/config_dump` - current configuration
- `/clusters` - cluster status
- `/listeners` - listener status

### Sticky Routing Principle

**Key Idea**: One TCP connection → one backend server

```
┌─────────────┐                                 ┌─────────────┐
│  Agent v1.1 │────────────────────────────────▶│  Server v1  │
│             │  1 TCP connection               │  (replica 1)│
│  5s pings   │  All requests via this conn     │             │
└─────────────┘                                 └─────────────┘
     │
     │ connection breaks
     ▼
┌─────────────┐                                 ┌─────────────┐
│  Agent v1.1 │────────────────────────────────▶│  Server v1  │
│             │  new TCP connection             │  (replica 2)│
│  reconnect  │  (may route to different pod)   │             │
└─────────────┘                                 └─────────────┘
```

**How It Works**:

1. **Connection Level**:
   - Agent establishes 1 TCP connection with Envoy
   - Envoy reads metadata once (first request)
   - Routes connection to appropriate cluster (server-v1 or server-v2)
   - Envoy selects 1 backend pod (Round Robin)

2. **Sticky Behavior**:
   - All subsequent requests use the same TCP connection
   - Connection stays with the same backend pod
   - No re-routing happens during connection lifetime

3. **Reconnection**:
   - On connection failure, agent reconnects
   - New connection may route to a different pod
   - But all requests within new connection go to the same pod

**Example**:
```
Time | Agent v1.1 | Connection | Backend
-----|------------|------------|----------
0s   | connect    | TCP-1      | server-v1-pod-A
5s   | ping #1    | TCP-1      | server-v1-pod-A
10s  | ping #2    | TCP-1      | server-v1-pod-A
15s  | [ERROR]    | TCP-1      | connection lost
16s  | reconnect  | TCP-2      | server-v1-pod-B
20s  | ping #3    | TCP-2      | server-v1-pod-B
25s  | ping #4    | TCP-2      | server-v1-pod-B
```

### Network Topology

```
┌────────────────────────────────────────────────────────┐
│                    Kubernetes Cluster                  │
│  ┌──────────────────────────────────────────────────┐  │
│  │              Namespace: grpc-routing-poc         │  │
│  │                                                  │  │
│  │  Agents ────▶ Envoy Service ────▶ Server Services│  │
│  │   (TLS)         (ClusterIP)          (ClusterIP) │  │
│  │                      │                     │     │  │
│  │                      ▼                     ▼     │  │
│  │                 Envoy Pod          Server Pod    │  │
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
  └─> envoy-ingress.grpc-routing-poc.svc.cluster.local
       └─> Service envoy-ingress (ClusterIP)
            └─> Envoy pod

envoy pod
  ├─> server-v1.grpc-routing-poc.svc.cluster.local
  │    └─> Service server-v1 (ClusterIP)
  │         └─> server-v1 pods (2 replicas)
  │
  └─> server-v2.grpc-routing-poc.svc.cluster.local
       └─> Service server-v2 (ClusterIP)
            └─> server-v2 pods (2 replicas)
```

### Data Flows

#### Successful Request Flow

```
Agent v1.1                Envoy                 Server v1
    │                       │                       │
    │ ┌─ TLS Handshake ────▶│                       │
    │ │                     │                       │
    │ └◀─ TLS Established ──│                       │
    │                       │                       │
    │ ┌─ gRPC Ping ────────▶│                       │
    │ │  metadata:          │                       │
    │ │  - agent-version:v1.1                       │
    │ │  - agent-id:uuid    │                       │
    │ │                     │                       │
    │ │                     │ ┌─ Check metadata     │
    │ │                     │ │  v1.1 → server-v1   │
    │ │                     │ │                     │
    │ │                     │ └─ HTTP/2 Ping ──────▶│
    │ │                     │    (no TLS)           │
    │ │                     │                       │
    │ │                     │                       │ ┌─ Process
    │ │                     │                       │ │  Log request
    │ │                     │                       │ └─ Generate response
    │ │                     │                       │
    │ │                     │ ◀── Pong response ────┘
    │ │                     │     "Pong from        │
    │ │                     │      server-v1"       │
    │ │                     │                       │
    │ └◀─ Pong (via TLS) ───┘                       │
    │                       │                       │
    ▼                       ▼                       ▼
  Log success          Forward response         Log completion
```

#### Routing Decision

```
Request arrives at Envoy
      │
      ▼
Extract metadata header "agent-version"
      │
      ├─ v2.* ──────▶ Route to cluster server-v2
      │                     │
      ├─ v1.* ──────▶ Route to cluster server-v1
      │                     │
      └─ no match ──▶ Route to cluster server-v1 (default)
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
                      Forward request
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
make all

# 3. Check status
kubectl get pods -n grpc-routing-poc

# 4. View logs
make logs-agents-v1
make logs-agents-v2
```

**Expected output** in agent logs:
```
[AGENT_v1.1] Ping successful: Pong from server-v1 (server=v1)
[AGENT_v1.2] Ping successful: Pong from server-v1 (server=v1)
[AGENT_v2.1] Ping successful: Pong from server-v2 (server=v2)
[AGENT_v2.2] Ping successful: Pong from server-v2 (server=v2)
```

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
# envoy-ingress-xxx                1/1     Running   0          2m
# server-v1-xxx                    1/1     Running   0          2m
# server-v1-yyy                    1/1     Running   0          2m
# server-v2-xxx                    1/1     Running   0          2m
# server-v2-yyy                    1/1     Running   0          2m

# View services
kubectl get svc -n grpc-routing-poc

# Check Envoy admin interface
kubectl port-forward -n grpc-routing-poc svc/envoy-ingress 9901:9901
# Open http://localhost:9901
```

### Routing Verification

#### Manual Verification

```bash
# 1. Check v1 agents route to server-v1
make logs-agents-v1 | grep "server-v1"

# 2. Check v2 agents route to server-v2
make logs-agents-v2 | grep "server-v2"

# 3. Verify server-v1 receives only v1.* requests
make logs-server-v1 | grep "agent-version"

# 4. Verify server-v2 receives only v2.* requests
make logs-server-v2 | grep "agent-version"
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

2. **✅ Sticky Routing**
   - Single TCP connection per agent
   - All requests use the same connection
   - Connection stays with one backend pod

3. **✅ TLS Termination**
   - Agents connect via TLS (port 8443)
   - Envoy terminates TLS
   - Upstream connections use plain HTTP/2

4. **✅ HTTP/2 End-to-End**
   - Full HTTP/2 support for gRPC
   - Efficient connection multiplexing

5. **✅ Automatic Reconnection**
   - Agents reconnect on connection loss
   - New connection may route to different pod
   - Routing logic applies to new connection

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
│   ├── ping.proto         # Protocol Buffers definitions
│   ├── go.mod
│   ├── ping.pb.go         # Generated Go code
│   └── ping_grpc.pb.go    # Generated gRPC code
├── certs/
│   ├── generate-certs.sh  # TLS certificate generation script
│   ├── cert.pem           # Generated certificate
│   └── key.pem            # Generated private key
├── k8s/
│   ├── namespace.yaml
│   ├── server-v1.yaml     # Server v1 Deployment + Service
│   ├── server-v2.yaml     # Server v2 Deployment + Service
│   ├── agent-v1.yaml      # Agent v1 Deployment
│   ├── agent-v2.yaml      # Agent v2 Deployment
│   └── envoy.yaml         # Envoy Deployment + Service + ConfigMap
├── scripts/
│   ├── verify-routing.sh       # Automated routing verification
│   └── test-sticky-routing.sh  # Sticky routing test
├── Makefile               # Automation scripts
└── README.md
```

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
# Expected: "Ping successful: Pong from server-v1"
```

#### 3. View Agent v2.1 Logs
```bash
make logs-agent-v2-1
# Expected: "Ping successful: Pong from server-v2"
```

#### 4. View Server v1 Logs
```bash
make logs-server-v1
# Expected: agent-version=v1.1 or v1.2
```

#### 5. View Server v2 Logs
```bash
make logs-server-v2
# Expected: agent-version=v2.1 or v2.2
```

### Advanced Tests

#### 1. Sticky Routing Test

```bash
./scripts/test-sticky-routing.sh
```

What it checks:
- One agent maintains single connection
- All requests go through same backend pod
- Connection persists throughout test

Expected output:
```
Testing sticky routing for agent-v1-1...
✅ All 20 requests routed to same pod: server-v1-xxx
Sticky routing works correctly!
```

#### 2. Load Testing

```bash
# Scale agents
kubectl scale deployment agent-v1-1 --replicas=5 -n grpc-routing-poc
kubectl scale deployment agent-v2-1 --replicas=5 -n grpc-routing-poc

# Monitor Envoy metrics
kubectl port-forward -n grpc-routing-poc svc/envoy-ingress 9901:9901
curl http://localhost:9901/stats | grep grpc

# Scale servers
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
# - Connection error logged
# - Automatic reconnection
# - Requests resume with same routing
```

#### 4. TLS Testing

```bash
# Test with insecure connection (should fail)
kubectl run test-pod --rm -it --image=nicolaka/netshoot -n grpc-routing-poc -- /bin/bash
grpcurl -plaintext envoy-ingress:8443 list
# Should fail: TLS required

# Test with TLS (should work via NodePort)
grpcurl -insecure localhost:30443 list
```

#### 5. Metadata Testing

```bash
# Test without agent-version header
grpcurl -insecure \
  -d '{"message": "ping"}' \
  localhost:30443 \
  ping.PingService/Ping
# Should route to server-v1 (default route)

# Test with v3.0 (unknown version)
grpcurl -insecure \
  -H 'agent-version: v3.0' \
  -d '{"message": "ping"}' \
  localhost:30443 \
  ping.PingService/Ping
# Should route to server-v1 (default route)
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
make deploy         # Deploy to Kubernetes
make all            # Full setup: certs + build + load + deploy

# Log viewing
make logs-server-v1      # View server-v1 logs
make logs-server-v2      # View server-v2 logs
make logs-agent-v1-1     # View agent-v1.1 logs
make logs-agent-v1-2     # View agent-v1.2 logs
make logs-agent-v2-1     # View agent-v2.1 logs
make logs-agent-v2-2     # View agent-v2.2 logs
make logs-agents-v1      # View all v1.x agent logs
make logs-agents-v2      # View all v2.x agent logs
make logs-envoy          # View Envoy logs

# Cleanup
make clean          # Delete namespace and all resources
```

## Scalability

### Horizontal Scaling

#### Scaling Agents

```bash
# Scale up
kubectl scale deployment agent-v1-1 --replicas=10 -n grpc-routing-poc

# Scale down
kubectl scale deployment agent-v1-1 --replicas=1 -n grpc-routing-poc

# All agents will maintain their own sticky connections
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

#### Scaling Envoy

```bash
# Scale Envoy (multiple instances)
kubectl scale deployment envoy-ingress --replicas=3 -n grpc-routing-poc

# Considerations:
# - Service LoadBalancer distributes connections
# - Each Envoy instance handles its own connections
# - No shared state between Envoy instances
```

## Monitoring

### Envoy Metrics

Access admin interface:
```bash
kubectl port-forward -n grpc-routing-poc svc/envoy-ingress 9901:9901
```

Useful metrics:
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

2. **Connection Stability**:
   - Reconnection rate (should be low)
   - Connection duration (should be high)

3. **Performance**:
   - Request latency (p50, p95, p99)
   - Throughput (req/s)
   - Error rate (should be 0%)

4. **Resource Usage**:
   - CPU utilization
   - Memory usage
   - Network I/O

## License

This is a Proof of Concept project for educational purposes.
