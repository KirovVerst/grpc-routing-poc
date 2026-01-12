package main

import (
	"fmt"
	"io"
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

func (s *server) PingPong(stream pb.PingService_PingPongServer) error {
	serverID := os.Getenv("HOSTNAME")
	if serverID == "" {
		serverID = "unknown"
	}

	// Extract metadata once at stream start
	md, ok := metadata.FromIncomingContext(stream.Context())

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

	log.Printf("[SERVER_%s/%s] Stream opened from agent-id=%s agent-version=%s",
		s.version, serverID, agentID, agentVersion)

	for {
		req, err := stream.Recv()
		if err == io.EOF {
			log.Printf("[SERVER_%s/%s] Stream closed by agent-id=%s", s.version, serverID, agentID)
			return nil
		}
		if err != nil {
			log.Printf("[SERVER_%s/%s] Stream error from agent-id=%s: %v", s.version, serverID, agentID, err)
			return err
		}

		// Log received ping with source info
		log.Printf("[SERVER_%s/%s] Received ping from agent-id=%s agent-version=%s message=%s",
			s.version, serverID, agentID, agentVersion, req.Message)

		// Send pong response
		resp := &pb.PingResponse{
			Message:       "pong",
			ServerVersion: s.version,
			ServerId:      serverID,
		}

		if err := stream.Send(resp); err != nil {
			log.Printf("[SERVER_%s/%s] Failed to send pong to agent-id=%s: %v", s.version, serverID, agentID, err)
			return err
		}

		log.Printf("[SERVER_%s/%s] Sent pong to agent-id=%s",
			s.version, serverID, agentID)
	}
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
