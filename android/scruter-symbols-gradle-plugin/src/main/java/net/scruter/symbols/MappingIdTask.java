package net.scruter.symbols;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import org.gradle.api.DefaultTask;
import org.gradle.api.GradleException;
import org.gradle.api.file.DirectoryProperty;
import org.gradle.api.file.RegularFileProperty;
import org.gradle.api.tasks.CacheableTask;
import org.gradle.api.tasks.InputFile;
import org.gradle.api.tasks.OutputDirectory;
import org.gradle.api.tasks.PathSensitive;
import org.gradle.api.tasks.PathSensitivity;
import org.gradle.api.tasks.TaskAction;

/** Writes {@code assets/net.scruter/mapping-id}: the SDK puts it in crash reports (`map`, docs/MOBILE.md §3.10). */
@CacheableTask
public abstract class MappingIdTask extends DefaultTask {
    @InputFile
    @PathSensitive(PathSensitivity.NONE)
    public abstract RegularFileProperty getMapping();

    @OutputDirectory
    public abstract DirectoryProperty getOutputDir();

    @TaskAction
    public void write() {
        try {
            String id = MappingId.of(getMapping().get().getAsFile().toPath());
            Path dir = getOutputDir().get().getAsFile().toPath().resolve("net.scruter");
            Files.createDirectories(dir);
            Files.write(dir.resolve("mapping-id"), id.getBytes(StandardCharsets.UTF_8));
        } catch (IOException e) {
            throw new GradleException("net.scruter.symbols: cannot read the mapping file", e);
        }
    }
}
