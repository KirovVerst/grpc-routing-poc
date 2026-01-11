package main

import (
	"context"
	"fmt"
	"log"
	"net"
	"os"
	"os/signal"
	"syscall"

	pb "github.com/kirovverst/grpc-routing-poc/proto"
	"google.golang.org/grpc"
	"google.golang.org/grpc/metadata"
)

type server struct {
	pb.UnimplementedPingServiceServer
	version string
}

func (s *server) Ping(ctx context.Context, req *pb.PingRequest) (*pb.PingResponse, error) {
	// Extract metadata from context
	md, ok := metadata.FromIncomingContext(ctx)

	agentVersion := "unknown"
	agentID := "unknown"

	if ok {
		if vals := md.Get("agent-version"); len(vals) > 0 {
			agentVersion = vals[0]
		}
		if vals := md.Get("agent-id"); len(vals) > 0 {
			agentID = vals[0]
		}
	}

	// Logging
	log.Printf("[SERVER_%s] agent-id=%s agent-version=%s message=%s",
		s.version, agentID, agentVersion, req.Message)

	return &pb.PingResponse{
		Message:       fmt.Sprintf("Pong from server-%s", s.version),
		ServerVersion: s.version,
	}, nil
}

func main() {
	version := os.Getenv("SERVER_VERSION")
	if version == "" {
		version = "unknown"
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = "50051"
	}

	lis, err := net.Listen("tcp", fmt.Sprintf(":%s", port))
	if err != nil {
		log.Fatalf("Failed to listen: %v", err)
	}

	grpcServer := grpc.NewServer()
	pb.RegisterPingServiceServer(grpcServer, &server{version: version})

	// Graceful shutdown
	go func() {
		sigChan := make(chan os.Signal, 1)
		signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
		<-sigChan

		log.Printf("[SERVER_%s] Shutting down gracefully...", version)
		grpcServer.GracefulStop()
	}()

	log.Printf("[SERVER_%s] Starting gRPC server on port %s", version, port)
	if err := grpcServer.Serve(lis); err != nil {
		log.Fatalf("Failed to serve: %v", err)
	}
}
