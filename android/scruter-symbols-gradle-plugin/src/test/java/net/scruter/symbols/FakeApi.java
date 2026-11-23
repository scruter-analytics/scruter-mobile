package net.scruter.symbols;

import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** The symbol endpoints of docs/API.md §5.3 and an object store, on a local port. */
final class FakeApi implements AutoCloseable {
    final List<String> calls = Collections.synchronizedList(new ArrayList<>());
    final List<String> bodies = Collections.synchronizedList(new ArrayList<>());
    final List<String> auth = Collections.synchronizedList(new ArrayList<>());
    volatile byte[] put = new byte[0];
    volatile boolean missing = true;
    volatile int createStatus = 201;
    volatile int failFirst = 0;
    private final HttpServer server;

    FakeApi() throws IOException {
        server = HttpServer.create(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 0);
        server.createContext("/", this::handle);
        server.start();
    }

    String url() {
        return "http://127.0.0.1:" + server.getAddress().getPort();
    }

    private void respond(HttpExchange e, int code, String body) throws IOException {
        byte[] b = body.getBytes(StandardCharsets.UTF_8);
        e.sendResponseHeaders(code, b.length == 0 ? -1 : b.length);
        if (b.length > 0) e.getResponseBody().write(b);
        e.close();
    }

    private void handle(HttpExchange e) throws IOException {
        byte[] body = e.getRequestBody().readAllBytes();
        String path = e.getRequestURI().getPath();
        calls.add(e.getRequestMethod() + " " + path);
        bodies.add(new String(body, StandardCharsets.UTF_8));
        String a = e.getRequestHeaders().getFirst("Authorization");
        auth.add(a == null ? "" : a);
        if (failFirst > 0) {
            failFirst--;
            e.getResponseHeaders().add("Retry-After", "0");
            respond(e, 503, "{}");
        } else if (path.equals("/m/v1/symbols/missing")) {
            respond(e, 200, missing ? "{\"missing\":[{\"kind\":\"x\",\"debug_id\":\"y\"}]}" : "{\"missing\":[]}");
        } else if (path.equals("/m/v1/symbols")) {
            String created = "{\"id\":\"s1\",\"upload\":{\"method\":\"PUT\",\"url\":\"" + url() + "/object\",\"headers\":"
                    + "{\"Content-Type\":\"application/octet-stream\",\"Content-Length\":\"" + 1 + "\"},\"expires_at\":\"x\"}}";
            respond(e, createStatus, createStatus == 201 ? created : "{\"error\":{\"code\":\"x\",\"message\":\"x\"}}");
        } else if (path.equals("/object")) {
            put = body;
            respond(e, 200, "");
        } else if (path.endsWith("/complete")) {
            respond(e, 202, "{}");
        } else {
            respond(e, 404, "{}");
        }
    }

    @Override
    public void close() {
        server.stop(0);
    }
}
