package main

import (
	"context"
	"flag"
	"fmt"
	"math/rand"
	"os"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"SampleGrpcProject/pb"
)

var names = []string{"Alice", "Bob", "Charlie", "Dave", "Eve", "Frank", "Grace", "Heidi"}

func main() {
	addr := flag.String("addr", "192.168.1.110:30051", "gRPC server address")
	concurrency := flag.Int("concurrency", 20, "number of concurrent workers")
	duration := flag.Duration("duration", 30*time.Second, "test duration")
	flag.Parse()

	conn, err := grpc.NewClient(*addr, grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to connect: %v\n", err)
		os.Exit(1)
	}
	defer conn.Close()

	client := pb.NewGreeterClient(conn)

	var (
		totalReqs atomic.Int64
		errCount  atomic.Int64
		latencies []int64
		latMu     sync.Mutex
	)

	fmt.Printf("Load test: addr=%s  concurrency=%d  duration=%s\n\n", *addr, *concurrency, *duration)
	fmt.Println("Running...")

	ctx, cancel := context.WithTimeout(context.Background(), *duration)
	defer cancel()

	start := time.Now()
	var wg sync.WaitGroup

	for i := 0; i < *concurrency; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			local := make([]int64, 0, 2048)
			for {
				select {
				case <-ctx.Done():
					latMu.Lock()
					latencies = append(latencies, local...)
					latMu.Unlock()
					return
				default:
				}

				name := names[rand.Intn(len(names))]
				reqStart := time.Now()

				var reqErr error
				if rand.Intn(2) == 0 {
					_, reqErr = client.SayHello(ctx, &pb.HelloRequest{Name: name})
				} else {
					_, reqErr = client.SayGoodbye(ctx, &pb.GoodbyeRequest{Name: name})
				}

				ns := time.Since(reqStart).Nanoseconds()
				totalReqs.Add(1)
				if reqErr != nil {
					errCount.Add(1)
				} else {
					local = append(local, ns)
				}
			}
		}()
	}

	wg.Wait()
	elapsed := time.Since(start)

	total := totalReqs.Load()
	errors := errCount.Load()
	successful := total - errors
	rps := float64(total) / elapsed.Seconds()

	fmt.Printf("\nResults:\n")
	fmt.Printf("  Duration:         %s\n", elapsed.Round(time.Millisecond))
	fmt.Printf("  Total requests:   %d\n", total)
	fmt.Printf("  Successful:       %d\n", successful)
	fmt.Printf("  Errors:           %d (%.2f%%)\n", errors, pct(errors, total))
	fmt.Printf("  RPS:              %.1f\n", rps)

	if len(latencies) > 0 {
		sort.Slice(latencies, func(i, j int) bool { return latencies[i] < latencies[j] })
		n := len(latencies)
		fmt.Printf("  Latency (success):\n")
		fmt.Printf("    p50:  %s\n", time.Duration(latencies[n*50/100]))
		fmt.Printf("    p90:  %s\n", time.Duration(latencies[n*90/100]))
		fmt.Printf("    p95:  %s\n", time.Duration(latencies[n*95/100]))
		fmt.Printf("    p99:  %s\n", time.Duration(latencies[n*99/100]))
		fmt.Printf("    max:  %s\n", time.Duration(latencies[n-1]))
	}
}

func pct(n, total int64) float64 {
	if total == 0 {
		return 0
	}
	return float64(n) / float64(total) * 100
}
