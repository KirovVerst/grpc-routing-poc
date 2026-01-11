package main

import (
	"context"
	"crypto/tls"
	"log"
	"os"
	"time"

	"github.com/google/uuid"
	pb "github.com/kirovverst/grpc-routing-poc/proto"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
)

func main() {
	version := os.Getenv("AGENT_VERSION")
	if version == "" {
		version = "v1"
	}

	agentID := os.Getenv("AGENT_ID")
	if agentID == "" {
		agentID = uuid.New().String()
	}

	serverAddress := os.Getenv("SERVER_ADDRESS")
	if serverAddress == "" {
		serverAddress = "localhost:50051"
	}

	useTLS := os.Getenv("USE_TLS")

	log.Printf("[AGENT_%s] Starting agent-id=%s target=%s", version, agentID, serverAddress)

	// Configure credentials
	var opts []grpc.DialOption
	if useTLS == "true" {
		// TLS with certificate verification skipped (for self-signed)
		tlsConfig := &tls.Config{
			InsecureSkipVerify: true,
			// Specify NextProtos for gRPC over HTTP/2
			NextProtos: []string{"h2"},
		}
		creds := credentials.NewTLS(tlsConfig)
		opts = append(opts, grpc.WithTransportCredentials(creds))
	} else {
		opts = append(opts, grpc.WithTransportCredentials(insecure.NewCredentials()))
	}

	// Establish a single long-lived connection
	for {
		conn, err := grpc.NewClient(serverAddress, opts...)
		if err != nil {
			log.Printf("[AGENT_%s] Failed to connect: %v. Retrying in 5s...", version, err)
			time.Sleep(5 * time.Second)
			continue
		}

		client := pb.NewPingServiceClient(conn)
		log.Printf("[AGENT_%s] Connected to %s", version, serverAddress)

		// Infinite loop of Ping calls
		for {
			// Create context with metadata
			ctx := metadata.NewOutgoingContext(context.Background(), metadata.Pairs(
				"agent-version", version,
				"agent-id", agentID,
			))

			// Add timeout for each RPC
			ctx, cancel := context.WithTimeout(ctx, 5*time.Second)

			resp, err := client.Ping(ctx, &pb.PingRequest{
				Message: "ping",
			})
			cancel()

			if err != nil {
				log.Printf("[AGENT_%s] Ping failed: %v. Reconnecting...", version, err)
				conn.Close()
				break // Exit inner loop to reconnect
			}

			log.Printf("[AGENT_%s] Ping successful: %s (server=%s)",
				version, resp.Message, resp.ServerVersion)

			time.Sleep(5 * time.Second)
		}

		time.Sleep(2 * time.Second) // Pause before reconnecting
	}
}
