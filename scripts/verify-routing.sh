#!/bin/bash

set -e

NAMESPACE="grpc-routing-poc"

echo "==================================================================="
echo "gRPC Routing PoC - Verification Script"
echo "==================================================================="
echo ""

# Check if namespace exists
if ! kubectl get namespace $NAMESPACE &> /dev/null; then
    echo "❌ Namespace $NAMESPACE does not exist. Please run 'make all-envoy' or 'make all-traefik' first."
    exit 1
fi

echo "✅ Namespace $NAMESPACE exists"
echo ""

# Check pod status
echo "📦 Pod Status:"
echo "-------------------------------------------------------------------"
kubectl get pods -n $NAMESPACE
echo ""

# Wait for all pods to be ready
echo "⏳ Waiting for all pods to be ready..."
kubectl wait --for=condition=ready --timeout=120s pod --all -n $NAMESPACE
echo "✅ All pods are ready"
echo ""

# Check services
echo "🌐 Services:"
echo "-------------------------------------------------------------------"
kubectl get svc -n $NAMESPACE
echo ""

# Verify routing by checking logs
echo "🔍 Verifying Routing..."
echo "-------------------------------------------------------------------"
echo ""

echo "📝 Server v1 Logs (last 20 lines):"
echo "Should show requests from agent-v1.1 and agent-v1.2"
echo "-------------------------------------------------------------------"
kubectl logs -n $NAMESPACE -l app=server,version=v1 --tail=20 --all-containers=true | grep -E "agent-version" || echo "No logs yet, wait a moment..."
echo ""

echo "📝 Server v2 Logs (last 20 lines):"
echo "Should show requests from agent-v2.1 and agent-v2.2"
echo "-------------------------------------------------------------------"
kubectl logs -n $NAMESPACE -l app=server,version=v2 --tail=20 --all-containers=true | grep -E "agent-version" || echo "No logs yet, wait a moment..."
echo ""

echo "📝 Agent v1.1 Logs (last 5 lines):"
echo "Should show successful pings to server-v1"
echo "-------------------------------------------------------------------"
kubectl logs -n $NAMESPACE -l version=v1.1 --tail=5 | grep -E "AGENT|Ping" || echo "No logs yet, wait a moment..."
echo ""

echo "📝 Agent v1.2 Logs (last 5 lines):"
echo "Should show successful pings to server-v1"
echo "-------------------------------------------------------------------"
kubectl logs -n $NAMESPACE -l version=v1.2 --tail=5 | grep -E "AGENT|Ping" || echo "No logs yet, wait a moment..."
echo ""

echo "📝 Agent v2.1 Logs (last 5 lines):"
echo "Should show successful pings to server-v2"
echo "-------------------------------------------------------------------"
kubectl logs -n $NAMESPACE -l version=v2.1 --tail=5 | grep -E "AGENT|Ping" || echo "No logs yet, wait a moment..."
echo ""

echo "📝 Agent v2.2 Logs (last 5 lines):"
echo "Should show successful pings to server-v2"
echo "-------------------------------------------------------------------"
kubectl logs -n $NAMESPACE -l version=v2.2 --tail=5 | grep -E "AGENT|Ping" || echo "No logs yet, wait a moment..."
echo ""

# Check Proxy admin
echo "🔧 Proxy Admin Interface:"
echo "-------------------------------------------------------------------"
echo "To access proxy admin interface, run:"
echo "  kubectl port-forward -n $NAMESPACE svc/proxy-ingress 9901:9901"
echo "  Then open: http://localhost:9901"
echo ""

# Verification summary
echo "==================================================================="
echo "Verification Summary"
echo "==================================================================="
echo ""
echo "✅ All components are deployed and running"
echo ""
echo "Expected behavior:"
echo "  • agent-v1.1 and v1.2 should only appear in server-v1 logs"
echo "  • agent-v2.1 and v2.2 should only appear in server-v2 logs"
echo "  • Prefix matching: v1.* → server-v1, v2.* → server-v2"
echo "  • Each agent maintains a single persistent connection"
echo "  • Routing is sticky - no switching between versions"
echo ""
echo "To monitor logs in real-time:"
echo "  make logs-server-v1"
echo "  make logs-server-v2"
echo "  make logs-agent-v1"
echo "  make logs-agent-v2"
echo ""
echo "==================================================================="
