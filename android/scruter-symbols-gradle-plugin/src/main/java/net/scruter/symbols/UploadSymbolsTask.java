package net.scruter.symbols;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;
import java.util.stream.Stream;
import java.util.zip.GZIPOutputStream;
import org.gradle.api.DefaultTask;
import org.gradle.api.GradleException;
import org.gradle.api.file.ConfigurableFileCollection;
import org.gradle.api.file.RegularFileProperty;
import org.gradle.api.provider.Property;
import org.gradle.api.tasks.Internal;
import org.gradle.api.tasks.TaskAction;
import org.gradle.work.DisableCachingByDefault;

/**
 * Uploads the variant's symbols: R8 / ProGuard mapping ({@code r8_mapping}) and unstripped native libraries
 * ({@code ndk_symbols}), gzipped, skipping what the server already has. Without a token it does nothing and says so.
 */
@DisableCachingByDefault(because = "talks to a server")
public abstract class UploadSymbolsTask extends DefaultTask {
    private static final long MAX_SIZE = 2_147_483_648L;

    @Internal public abstract Property<String> getAppId();
    @Internal public abstract Property<String> getToken();
    @Internal public abstract Property<String> getApiEndpoint();
    @Internal public abstract Property<Boolean> getFailOnError();
    @Internal public abstract RegularFileProperty getMapping();
    @Internal public abstract Property<String> getVersionName();
    @Internal public abstract Property<String> getVersionCode();
    @Internal public abstract ConfigurableFileCollection getNativeDirs();

    public UploadSymbolsTask() {
        getOutputs().upToDateWhen(t -> false);
    }

    @TaskAction
    public void upload() throws InterruptedException {
        String token = getToken().getOrNull();
        if (token == null || token.isBlank()) {
            getLogger().warn("Scruter: no SCRUTER_UPLOAD_TOKEN: symbols not uploaded, crashes of this build stay unreadable.");
            return;
        }
        SymbolClient client = new SymbolClient(getAppId().get(), getApiEndpoint().get(), token.trim(), 4);
        try {
            if (getMapping().isPresent() && getMapping().get().getAsFile().isFile()) {
                uploadMapping(client, getMapping().get().getAsFile().toPath());
            }
            uploadNative(client);
        } catch (IOException e) {
            String message = "Scruter: symbols not uploaded: " + e.getMessage();
            if (getFailOnError().get()) throw new GradleException(message);
            getLogger().warn(message);
        }
    }

    private Map<String, Object> declaration(String kind, String debugId, String fileName) {
        Map<String, Object> d = new LinkedHashMap<>();
        d.put("platform", "android");
        d.put("kind", kind);
        d.put("debug_id", debugId);
        if (getVersionName().isPresent()) d.put("app_version", getVersionName().get());
        if (getVersionCode().isPresent()) d.put("build", getVersionCode().get());
        d.put("file_name", fileName);
        return d;
    }

    private void uploadMapping(SymbolClient client, Path mapping) throws IOException, InterruptedException {
        String id = MappingId.of(mapping);
        if (!client.missing("r8_mapping", id)) {
            getLogger().lifecycle("Scruter: mapping {} already uploaded", id);
            return;
        }
        Path gz = gzip(mapping, "mapping.txt.gz");
        client.upload(declaration("r8_mapping", id, "mapping.txt.gz"), gz);
        Files.deleteIfExists(gz);
        getLogger().lifecycle("Scruter: mapping {} uploaded", id);
    }

    private void uploadNative(SymbolClient client) throws IOException, InterruptedException {
        Set<String> seen = new HashSet<>();
        for (File dir : getNativeDirs().getFiles()) {
            if (!dir.isDirectory()) continue;
            List<Path> libs;
            try (Stream<Path> walk = Files.walk(dir.toPath())) {
                libs = walk.filter(p -> p.getFileName().toString().endsWith(".so")).sorted().collect(Collectors.toList());
            }
            for (Path lib : libs) {
                Elf elf = Elf.read(lib);
                if (elf == null || elf.buildId == null || !elf.hasSymbols || !seen.add(elf.buildId)) continue;
                if (!client.missing("ndk_symbols", elf.buildId)) continue;
                String name = lib.getFileName() + ".gz";
                Path gz = gzip(lib, elf.arch + "-" + name);
                Map<String, Object> d = declaration("ndk_symbols", elf.buildId, name);
                d.put("arch", elf.arch);
                client.upload(d, gz);
                Files.deleteIfExists(gz);
                getLogger().lifecycle("Scruter: {} ({}) uploaded", lib.getFileName(), elf.arch);
            }
        }
    }

    private Path gzip(Path source, String name) throws IOException {
        Path out = getTemporaryDir().toPath().resolve(name);
        try (InputStream in = Files.newInputStream(source);
                OutputStream gz = new GZIPOutputStream(Files.newOutputStream(out))) {
            in.transferTo(gz);
        }
        if (Files.size(out) > MAX_SIZE) throw new IOException(source.getFileName() + " is larger than 2 GiB");
        return out;
    }
}
