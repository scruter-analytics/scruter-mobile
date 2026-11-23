package net.scruter.symbols;

import groovy.json.JsonOutput;
import groovy.json.JsonSlurper;
import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/** The symbol upload protocol (docs/MOBILE.md §4.3, docs/API.md §5.3). The token never reaches a log or an exception. */
final class SymbolClient {
    static final class Failed extends IOException {
        Failed(String message) {
            super(message);
        }
    }

    private final HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(20)).build();
    private final String app;
    private final String endpoint;
    private final String token;
    private final int maxTries;

    SymbolClient(String app, String endpoint, String token, int maxTries) {
        this.app = app;
        this.endpoint = endpoint.replaceAll("/+$", "");
        this.token = token;
        this.maxTries = maxTries;
    }

    private HttpResponse<String> json(String path, Map<String, Object> body) throws IOException, InterruptedException {
        HttpRequest.Builder b = HttpRequest.newBuilder(URI.create(endpoint + path))
                .timeout(Duration.ofSeconds(60))
                .header("Authorization", "Bearer " + token)
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(JsonOutput.toJson(body)));
        return withRetries(b.build(), HttpResponse.BodyHandlers.ofString());
    }

    /** 429 and 5xx wait for {@code Retry-After} (else 2ⁿ s) and try again. */
    private <T> HttpResponse<T> withRetries(HttpRequest request, HttpResponse.BodyHandler<T> handler)
            throws IOException, InterruptedException {
        for (int attempt = 0; ; attempt++) {
            HttpResponse<T> r;
            try {
                r = http.send(request, handler);
            } catch (IOException e) {
                if (attempt + 1 >= maxTries) throw new Failed("cannot reach " + request.uri().getHost() + ": " + e.getClass().getSimpleName());
                Thread.sleep(1000L << attempt);
                continue;
            }
            if ((r.statusCode() != 429 && r.statusCode() < 500) || attempt + 1 >= maxTries) return r;
            long wait = r.headers().firstValueAsLong("Retry-After").orElse(1L << attempt);
            Thread.sleep(Math.min(wait, 60) * 1000);
        }
    }

    /** Whether the server still needs this file. */
    boolean missing(String kind, String debugId) throws IOException, InterruptedException {
        Map<String, Object> file = new LinkedHashMap<>();
        file.put("kind", kind);
        file.put("debug_id", debugId);
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("app", app);
        body.put("files", List.of(file));
        HttpResponse<String> r = json("/m/v1/symbols/missing", body);
        check(r, "ask which symbols are missing");
        Object missing = ((Map<?, ?>) new JsonSlurper().parseText(r.body())).get("missing");
        return missing instanceof List<?> l && !l.isEmpty();
    }

    /** Declares, uploads and completes [file] (already compressed). */
    void upload(Map<String, Object> declaration, Path file) throws IOException, InterruptedException {
        Map<String, Object> body = new LinkedHashMap<>(declaration);
        body.put("app", app);
        body.put("size", Files.size(file));
        body.put("sha256", MappingId.sha256(file));
        HttpResponse<String> created = json("/m/v1/symbols", body);
        if (created.statusCode() == 409) return; // already uploaded: the CI moves on
        check(created, "declare the file");
        Map<?, ?> o = (Map<?, ?>) new JsonSlurper().parseText(created.body());
        Map<?, ?> upload = (Map<?, ?>) o.get("upload");
        HttpRequest.Builder put = HttpRequest.newBuilder(URI.create(String.valueOf(upload.get("url"))))
                .timeout(Duration.ofMinutes(30))
                .PUT(HttpRequest.BodyPublishers.ofFile(file));
        Object headers = upload.get("headers");
        if (headers instanceof Map<?, ?> m) {
            for (Map.Entry<?, ?> e : m.entrySet()) {
                // HttpClient sets Content-Length itself, from the file: exactly the declared size.
                if (!"content-length".equalsIgnoreCase(String.valueOf(e.getKey()))) {
                    put.header(String.valueOf(e.getKey()), String.valueOf(e.getValue()));
                }
            }
        }
        HttpResponse<Void> stored = withRetries(put.build(), HttpResponse.BodyHandlers.discarding());
        if (stored.statusCode() / 100 != 2) throw new Failed("the object store refused the file (" + stored.statusCode() + ")");
        HttpResponse<String> done = json("/m/v1/symbols/" + o.get("id") + "/complete", new LinkedHashMap<>());
        check(done, "complete the upload");
    }

    private static void check(HttpResponse<String> r, String what) throws Failed {
        if (r.statusCode() / 100 == 2) return;
        String hint = r.statusCode() == 401 ? " (upload token unknown or revoked: see App settings › SDK)"
                : r.statusCode() == 403 ? " (this token belongs to another app)" : "";
        throw new Failed("cannot " + what + ": HTTP " + r.statusCode() + hint);
    }
}
