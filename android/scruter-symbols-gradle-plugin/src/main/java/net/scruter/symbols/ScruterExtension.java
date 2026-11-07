package net.scruter.symbols;

import org.gradle.api.file.ConfigurableFileCollection;
import org.gradle.api.provider.Property;

/**
 * The {@code scruter { }} block of an app module:
 *
 * <pre>
 * scruter {
 *     appId = "ATMONA02"
 * }
 * </pre>
 */
public abstract class ScruterExtension {
    /** The "App identifier": sets the team-link scheme and names the app in uploads. Required. */
    public abstract Property<String> getAppId();

    /** The upload token ({@code scr_up_…}); default: the environment variable SCRUTER_UPLOAD_TOKEN. Never in the code. */
    public abstract Property<String> getUploadToken();

    /** Default https://api.scruter.net. */
    public abstract Property<String> getApiEndpoint();

    /** Uploads after {@code assemble} and {@code bundle} of non-debuggable variants. Default true. */
    public abstract Property<Boolean> getAutoUpload();

    /** Fails the build when an upload fails. Default false: Scruter being unreachable never stops a release. */
    public abstract Property<Boolean> getFailOnError();

    /** More directories holding unstripped {@code .so} files. */
    public abstract ConfigurableFileCollection getNativeSymbolDirs();
}
