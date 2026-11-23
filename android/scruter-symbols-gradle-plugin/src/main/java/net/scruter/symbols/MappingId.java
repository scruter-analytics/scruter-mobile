package net.scruter.symbols;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.InputStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.DigestInputStream;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;

/** The debug id of a mapping file: R8's {@code pg_map_id}, else (ProGuard) the start of the file's SHA-256. */
final class MappingId {
    private MappingId() {}

    static String of(Path file) throws IOException {
        try (BufferedReader r = Files.newBufferedReader(file, StandardCharsets.UTF_8)) {
            String line;
            while ((line = r.readLine()) != null && line.startsWith("#")) {
                if (line.startsWith("# pg_map_id:")) {
                    String id = line.substring("# pg_map_id:".length()).trim();
                    if (!id.isEmpty()) return id;
                }
            }
        }
        return sha256(file).substring(0, 32);
    }

    static String sha256(Path file) throws IOException {
        try (InputStream in = new DigestInputStream(Files.newInputStream(file), digest())) {
            byte[] buf = new byte[1 << 16];
            while (in.read(buf) >= 0) {
                // the digest reads along
            }
            return hex(((DigestInputStream) in).getMessageDigest().digest());
        }
    }

    private static MessageDigest digest() {
        try {
            return MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException(e);
        }
    }

    static String hex(byte[] bytes) {
        StringBuilder b = new StringBuilder(bytes.length * 2);
        for (byte x : bytes) b.append(String.format("%02x", x & 0xff));
        return b.toString();
    }
}
