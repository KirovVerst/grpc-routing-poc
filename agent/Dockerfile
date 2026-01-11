# Build stage
FROM golang:1.23-alpine AS builder

# Install build dependencies
RUN apk add --no-cache git protobuf-dev

WORKDIR /workspace

# Copy proto files
COPY proto/ ./proto/

# Copy agent files
COPY agent/ ./agent/

# Install protoc-gen-go and protoc-gen-go-grpc (specific versions for Go 1.23)
RUN go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.34.2
RUN go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.5.1

# Generate proto files
WORKDIR /workspace/proto
RUN protoc --go_out=. --go_opt=paths=source_relative \
    --go-grpc_out=. --go-grpc_opt=paths=source_relative \
    ping.proto

# Initialize proto module dependencies
RUN go mod tidy

# Download agent dependencies and build
WORKDIR /workspace/agent
RUN go mod tidy
RUN go mod download

# Build the binary
RUN CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o agent .

# Final stage
FROM alpine:latest

RUN apk --no-cache add ca-certificates

WORKDIR /app

COPY --from=builder /workspace/agent/agent .

CMD ["./agent"]
