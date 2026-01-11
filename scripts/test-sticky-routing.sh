#!/bin/bash

set -e

NAMESPACE="grpc-routing-poc"

echo "==================================================================="
echo "Sticky Routing Test"
echo "==================================================================="
echo ""

echo "This script will:"
echo "1. Monitor server logs to see which agents connect to which servers"
echo "2. Delete a server pod to test reconnection"
echo "3. Verify that agents reconnect to the same version"
echo ""

read -p "Press Enter to continue..."
echo ""

# Get initial pod distribution
echo "📊 Initial Pod Distribution:"
echo "-------------------------------------------------------------------"
kubectl get pods -n $NAMESPACE -o wide
echo ""

echo "📝 Checking current routing (5 seconds of logs)..."
echo ""

# Monitor for 5 seconds
echo "Server v1 connections:"
kubectl logs -n $NAMESPACE -l app=server,version=v1 --tail=20 --all-containers=true | grep "agent-id" | tail -5
echo ""

echo "Server v2 connections:"
kubectl logs -n $NAMESPACE -l app=server,version=v2 --tail=20 --all-containers=true | grep "agent-id" | tail -5
echo ""

# Delete one server-v1 pod
echo "🔄 Deleting one server-v1 pod to test reconnection..."
POD_TO_DELETE=$(kubectl get pods -n $NAMESPACE -l app=server,version=v1 -o jsonpath='{.items[0].metadata.name}')
echo "Deleting pod: $POD_TO_DELETE"
kubectl delete pod -n $NAMESPACE $POD_TO_DELETE
echo ""

echo "⏳ Waiting for pod to restart..."
sleep 5
kubectl wait --for=condition=ready --timeout=60s pod -l app=server,version=v1 -n $NAMESPACE
echo "✅ Pod restarted"
echo ""

echo "📊 New Pod Distribution:"
echo "-------------------------------------------------------------------"
kubectl get pods -n $NAMESPACE -o wide
echo ""

echo "⏳ Waiting 10 seconds for agents to reconnect..."
sleep 10
echo ""

echo "📝 Checking routing after reconnection..."
echo ""

echo "Server v1 connections (should still have agent-v1.1 and v1.2):"
kubectl logs -n $NAMESPACE -l app=server,version=v1 --tail=20 --all-containers=true | grep "agent-version" | tail -10
echo ""

echo "Server v2 connections (should still have agent-v2.1 and v2.2):"
kubectl logs -n $NAMESPACE -l app=server,version=v2 --tail=20 --all-containers=true | grep "agent-version" | tail -10
echo ""

echo "Agent v1.1 logs (should show reconnection):"
kubectl logs -n $NAMESPACE -l version=v1.1 --tail=10
echo ""

echo "==================================================================="
echo "✅ Test Complete"
echo "==================================================================="
echo ""
echo "Expected results:"
echo "  • agent-v1.1 and v1.2 reconnected and still go to server-v1"
echo "  • agent-v2.1 and v2.2 were not affected and still go to server-v2"
echo "  • Prefix matching (v1.*, v2.*) remained correct"
echo "  • Routing remained sticky to the correct version"
echo ""
