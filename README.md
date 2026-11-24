# Concurrent Transactions Test

## How to run

Start the infrastructure:

```bash
./deploy.sh
```

Port-forward speedbump to `localhost:8081`, and keep this terminal open:

```bash
kubectl -n concurrent-transactions port-forward pod/speedbump 8081:8081
```

Run the load test through it:

```bash
k6 run --no-connection-reuse -e BASE_URL=http://localhost:8081 -e SUMMARY_FILE=run-(date +%s)-summary.json k6/concurrent-transfers.js
```

Stop the infrastructure:

```bash
./deploy.sh --teardown
```
