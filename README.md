# Concurrent Transactions Test

Deploy:

```bash
./deploy.sh
```

Tear down:

```bash
./deploy.sh --teardown
```

## Inject 50ms latency

[speedbump](https://github.com/kffl/speedbump) runs in front of `app-proxy` and adds about 50ms to each request. Deploy the app first.

Build speedbump for the cluster's architecture, because the published image is amd64-only:

```bash
docker build -t speedbump:v1.1.0 - <<'EOF'
FROM golang:1.17.11-alpine3.16 AS builder
ADD https://github.com/kffl/speedbump.git#v1.1.0 /src
WORKDIR /src
RUN CGO_ENABLED=0 go build -o /speedbump .

FROM scratch
COPY --from=builder /speedbump /speedbump
USER 65534:65534
ENTRYPOINT ["/speedbump"]
EOF
```

Expose `app-proxy` inside the cluster:

```bash
kubectl -n concurrent-transactions expose deployment app-concurrent-transactions-proxy --name app-proxy --port 8080
```

Start speedbump:

```bash
kubectl -n concurrent-transactions run speedbump --image=speedbump:v1.1.0 --image-pull-policy=IfNotPresent --port=8081 -- --port=8081 --latency=20ms app-proxy:8080
```

```bash
kubectl -n concurrent-transactions wait --for=condition=Ready pod/speedbump --timeout=60s
```

Port-forward it, and keep this terminal open:

```bash
kubectl -n concurrent-transactions port-forward pod/speedbump 8081:8081
```

Run the load test through it:

```bash
k6 run --no-connection-reuse -e BASE_URL=http://localhost:8081 k6/concurrent-transfers.js
```

Remove speedbump before running `./deploy.sh --teardown`:

```bash
kubectl -n concurrent-transactions delete pod/speedbump service/app-proxy
```