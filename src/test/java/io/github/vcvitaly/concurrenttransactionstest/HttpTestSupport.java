package io.github.vcvitaly.concurrenttransactionstest;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;

/** Plain HTTP calls against a running test server, so tests hit the real listeners on both ports. */
public final class HttpTestSupport {

    private static final HttpClient CLIENT = HttpClient.newBuilder()
            .connectTimeout(Duration.ofSeconds(5))
            .build();

    private HttpTestSupport() {
    }

    public static HttpResponse<String> get(int port, String path) {
        return send(HttpRequest.newBuilder(uri(port, path)).GET());
    }

    public static HttpResponse<String> postJson(int port, String path, String body) {
        return send(HttpRequest.newBuilder(uri(port, path))
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(body)));
    }

    private static URI uri(int port, String path) {
        return URI.create("http://localhost:" + port + path);
    }

    private static HttpResponse<String> send(HttpRequest.Builder builder) {
        try {
            return CLIENT.send(builder.timeout(Duration.ofSeconds(30)).build(), HttpResponse.BodyHandlers.ofString());
        } catch (IOException e) {
            throw new IllegalStateException(e);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException(e);
        }
    }
}
