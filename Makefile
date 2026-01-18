.PHONY: help proto build load deploy-envoy deploy-traefik clean logs-server-v1 logs-server-v2 logs-agent-v1-1 logs-agent-v1-2 logs-agent-v2-1 logs-agent-v2-2 logs-agents-v1 logs-agents-v2 logs-envoy logs-traefik logs-proxy certs apply-certs all-envoy all-traefik

# Default target
help:
	@echo "Available targets:"
	@echo "  proto           - Generate Go code from proto files"
	@echo "  certs           - Generate TLS certificates for proxy"
	@echo "  build           - Build Docker images for server and agent"
	@echo "  load            - Load Docker images into kind cluster"
	@echo "  apply-certs     - Apply TLS certificates to Kubernetes secret"
	@echo "  deploy-envoy    - Deploy all components with Envoy proxy"
	@echo "  deploy-traefik  - Deploy all components with Traefik proxy"
	@echo "  all-envoy       - Full setup with Envoy: certs + build + load + deploy"
	@echo "  all-traefik     - Full setup with Traefik: certs + build + load + deploy"
	@echo "  logs-server-v1  - Show logs from server-v1 pods"
	@echo "  logs-server-v2  - Show logs from server-v2 pods"
	@echo "  logs-agent-v1-1 - Show logs from agent-v1.1 pod"
	@echo "  logs-agent-v1-2 - Show logs from agent-v1.2 pod"
	@echo "  logs-agent-v2-1 - Show logs from agent-v2.1 pod"
	@echo "  logs-agent-v2-2 - Show logs from agent-v2.2 pod"
	@echo "  logs-agents-v1  - Show logs from all v1.x agents"
	@echo "  logs-agents-v2  - Show logs from all v2.x agents"
	@echo "  logs-envoy      - Show logs from Envoy proxy pod"
	@echo "  logs-traefik    - Show logs from Traefik proxy pod"
	@echo "  logs-proxy      - Show logs from active proxy pod"
	@echo "  clean           - Delete the grpc-routing-poc namespace and all resources"

# Generate proto files
proto:
	@echo "Generating proto files..."
	cd proto && protoc --go_out=. --go_opt=paths=source_relative \
		--go-grpc_out=. --go-grpc_opt=paths=source_relative \
		ping.proto
	@echo "Proto files generated successfully"

# Generate TLS certificates
certs:
	@echo "Generating TLS certificates..."
	cd certs && chmod +x generate-certs.sh && ./generate-certs.sh
	@echo "Certificates generated successfully"

# Build Docker images
build:
	@echo "Building server image..."
	docker build -t grpc-routing-poc/server:latest -f server/Dockerfile .
	@echo "Building agent image..."
	docker build -t grpc-routing-poc/agent:latest -f agent/Dockerfile .
	@echo "Docker images built successfully"

# Load images into kind cluster
load:
	@echo "Loading images into kind cluster..."
	kind load docker-image grpc-routing-poc/server:latest --name grpc-routing-poc
	kind load docker-image grpc-routing-poc/agent:latest --name grpc-routing-poc
	@echo "Images loaded into kind cluster"

# Apply TLS certificates to Kubernetes
apply-certs:
	@echo "Creating TLS secret in Kubernetes..."
	@if [ ! -f certs/cert.pem ] || [ ! -f certs/key.pem ]; then \
		echo "Error: Certificates not found. Run 'make certs' first."; \
		exit 1; \
	fi
	@kubectl create namespace grpc-routing-poc --dry-run=client -o yaml | kubectl apply -f -
	@kubectl delete secret proxy-certs -n grpc-routing-poc --ignore-not-found=true
	@kubectl create secret generic proxy-certs -n grpc-routing-poc \
		--from-file=cert.pem=certs/cert.pem \
		--from-file=key.pem=certs/key.pem
	@echo "TLS secret created successfully"
	@echo "Verifying secret..."
	@kubectl get secret proxy-certs -n grpc-routing-poc -o jsonpath='{.data}' | grep -q cert.pem && echo "✓ Secret contains cert.pem" || echo "✗ Secret missing cert.pem"
	@kubectl get secret proxy-certs -n grpc-routing-poc -o jsonpath='{.data}' | grep -q key.pem && echo "✓ Secret contains key.pem" || echo "✗ Secret missing key.pem"

# Deploy with Envoy proxy
deploy-envoy: apply-certs
	@echo "Deploying to Kubernetes with Envoy proxy..."
	kubectl apply -f k8s/namespace.yaml
	kubectl apply -f k8s/envoy.yaml
	kubectl apply -f k8s/server-v1.yaml
	kubectl apply -f k8s/server-v2.yaml
	@echo "Waiting for server services to be ready..."
	kubectl wait --for=condition=available --timeout=60s deployment/server-v1 -n grpc-routing-poc
	kubectl wait --for=condition=available --timeout=60s deployment/server-v2 -n grpc-routing-poc
	kubectl wait --for=condition=available --timeout=60s deployment/proxy-ingress -n grpc-routing-poc
	@echo "Deploying agents..."
	kubectl apply -f k8s/agent-v1.1.yaml
	kubectl apply -f k8s/agent-v1.2.yaml
	kubectl apply -f k8s/agent-v2.1.yaml
	kubectl apply -f k8s/agent-v2.2.yaml
	@echo "Deployment complete with Envoy proxy!"
	@echo ""
	@echo "Check status with:"
	@echo "  kubectl get pods -n grpc-routing-poc"
	@echo ""
	@echo "View logs with:"
	@echo "  make logs-server-v1"
	@echo "  make logs-server-v2"
	@echo "  make logs-proxy"
	@echo "  make logs-agent-v1-1"

# Deploy with Traefik proxy
deploy-traefik: apply-certs
	@echo "Deploying to Kubernetes with Traefik proxy..."
	kubectl apply -f k8s/namespace.yaml
	kubectl apply -f k8s/traefik.yaml
	kubectl apply -f k8s/server-v1.yaml
	kubectl apply -f k8s/server-v2.yaml
	@echo "Waiting for server services to be ready..."
	kubectl wait --for=condition=available --timeout=60s deployment/server-v1 -n grpc-routing-poc
	kubectl wait --for=condition=available --timeout=60s deployment/server-v2 -n grpc-routing-poc
	kubectl wait --for=condition=available --timeout=60s deployment/proxy-ingress -n grpc-routing-poc
	@echo "Deploying agents..."
	kubectl apply -f k8s/agent-v1.1.yaml
	kubectl apply -f k8s/agent-v1.2.yaml
	kubectl apply -f k8s/agent-v2.1.yaml
	kubectl apply -f k8s/agent-v2.2.yaml
	@echo "Deployment complete with Traefik proxy!"
	@echo ""
	@echo "Check status with:"
	@echo "  kubectl get pods -n grpc-routing-poc"
	@echo ""
	@echo "View logs with:"
	@echo "  make logs-server-v1"
	@echo "  make logs-server-v2"
	@echo "  make logs-proxy"
	@echo "  make logs-agent-v1-1"

# Show logs from server-v1
logs-server-v1:
	@echo "Logs from server-v1 (should show agent-v1 requests):"
	@echo "=================================================="
	kubectl logs -n grpc-routing-poc -l app=server,version=v1 --tail=50 --all-containers=true

# Show logs from server-v2
logs-server-v2:
	@echo "Logs from server-v2 (should show agent-v2 requests):"
	@echo "=================================================="
	kubectl logs -n grpc-routing-poc -l app=server,version=v2 --tail=50 --all-containers=true

# Show logs from agent-v1.1
logs-agent-v1-1:
	@echo "Logs from agent-v1.1:"
	@echo "====================="
	kubectl logs -n grpc-routing-poc -l version=v1.1 --tail=50

# Show logs from agent-v1.2
logs-agent-v1-2:
	@echo "Logs from agent-v1.2:"
	@echo "====================="
	kubectl logs -n grpc-routing-poc -l version=v1.2 --tail=50

# Show logs from agent-v2.1
logs-agent-v2-1:
	@echo "Logs from agent-v2.1:"
	@echo "====================="
	kubectl logs -n grpc-routing-poc -l version=v2.1 --tail=50

# Show logs from agent-v2.2
logs-agent-v2-2:
	@echo "Logs from agent-v2.2:"
	@echo "====================="
	kubectl logs -n grpc-routing-poc -l version=v2.2 --tail=50

# Show logs from all v1.x agents
logs-agents-v1:
	@echo "Logs from all v1.x agents:"
	@echo "=========================="
	kubectl logs -n grpc-routing-poc -l major-version=v1 --tail=50 --prefix=true

# Show logs from all v2.x agents
logs-agents-v2:
	@echo "Logs from all v2.x agents:"
	@echo "=========================="
	kubectl logs -n grpc-routing-poc -l major-version=v2 --tail=50 --prefix=true

# Show logs from Envoy proxy
logs-envoy:
	@echo "Logs from Envoy proxy:"
	@echo "======================"
	kubectl logs -n grpc-routing-poc -l app=proxy-ingress,proxy=envoy --tail=100

# Show logs from Traefik proxy
logs-traefik:
	@echo "Logs from Traefik proxy:"
	@echo "========================"
	kubectl logs -n grpc-routing-poc -l app=proxy-ingress,proxy=traefik --tail=100

# Show logs from active proxy (whichever is running)
logs-proxy:
	@echo "Logs from active proxy:"
	@echo "======================="
	kubectl logs -n grpc-routing-poc -l app=proxy-ingress --tail=100

# Clean up all resources
clean:
	@echo "Deleting grpc-routing-poc namespace and all resources..."
	kubectl delete namespace grpc-routing-poc --ignore-not-found=true
	@echo "Cleanup complete"

# Full setup from scratch with Envoy
all-envoy: certs build load deploy-envoy
	@echo "Full setup complete with Envoy!"

# Full setup from scratch with Traefik
all-traefik: certs build load deploy-traefik
	@echo "Full setup complete with Traefik!"
