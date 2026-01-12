package main

import (
	"context"
	"crypto/tls"
	"io"
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
		log.Printf("[AGENT_%s/%s] Connected to %s", version, agentID, serverAddress)

		// Create context with metadata for the stream
		ctx := metadata.NewOutgoingContext(context.Background(), metadata.Pairs(
			"agent-version", version,
			"agent-id", agentID,
		))

		// Open bidirectional stream
		stream, err := client.PingPong(ctx)
		if err != nil {
			log.Printf("[AGENT_%s/%s] Failed to open stream: %v. Reconnecting...", version, agentID, err)
			conn.Close()
			time.Sleep(2 * time.Second)
			continue
		}

		log.Printf("[AGENT_%s/%s] Stream opened to %s", version, agentID, serverAddress)

		// Channel to signal when receive goroutine exits
		done := make(chan bool)

		// Goroutine to receive pongs
		go func() {
			for {
				resp, err := stream.Recv()
				if err == io.EOF {
					log.Printf("[AGENT_%s/%s] Stream closed by server", version, agentID)
					done <- true
					return
				}
				if err != nil {
					log.Printf("[AGENT_%s/%s] Receive error: %v", version, agentID, err)
					done <- true
					return
				}

				log.Printf("[AGENT_%s/%s] Received pong from server=%s/%s message=%s",
					version, agentID, resp.ServerVersion, resp.ServerId, resp.Message)
			}
		}()

		// Main loop to send pings
	pingLoop:
		for {
			req := &pb.PingRequest{
				Message: "ping",
			}

			if err := stream.Send(req); err != nil {
				log.Printf("[AGENT_%s/%s] Send error: %v. Reconnecting...", version, agentID, err)
				break pingLoop
			}

			log.Printf("[AGENT_%s/%s] Sent ping", version, agentID)

			// Wait for 5 seconds or done signal
			select {
			case <-done:
				log.Printf("[AGENT_%s/%s] Receive goroutine exited, reconnecting...", version, agentID)
				break pingLoop
			case <-time.After(5 * time.Second):
				// Continue to next ping
			}
		}

		// Clean up
		stream.CloseSend()
		conn.Close()

		time.Sleep(2 * time.Second) // Pause before reconnecting
	}
}
