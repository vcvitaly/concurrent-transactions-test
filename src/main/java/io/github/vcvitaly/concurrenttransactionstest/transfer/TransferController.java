package io.github.vcvitaly.concurrenttransactionstest.transfer;

import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.List;

@RestController
@RequestMapping("/transfers")
@RequiredArgsConstructor
public class TransferController {

    private final TransferService transferService;

    /** 201 for a new transfer, 200 with the original transfer for a repeated idempotency key. */
    @PostMapping
    public ResponseEntity<Transfer> transfer(@RequestBody TransferRequest request) {
        TransferResult result = transferService.transfer(request);
        HttpStatus status = result.created() ? HttpStatus.CREATED : HttpStatus.OK;
        return ResponseEntity.status(status).body(result.transfer());
    }

    @GetMapping
    public List<Transfer> getAll() {
        return transferService.getAll();
    }

    @GetMapping("/{id}")
    public Transfer get(@PathVariable long id) {
        return transferService.get(id);
    }
}
