package net.scruter.symbols;

import com.android.build.api.artifact.SingleArtifact;
import com.android.build.api.variant.ApplicationAndroidComponentsExtension;
import com.android.build.api.variant.ApplicationVariant;
import com.android.build.api.variant.VariantOutput;
import java.util.Locale;
import java.util.regex.Pattern;
import org.gradle.api.Action;
import org.gradle.api.GradleException;
import org.gradle.api.Plugin;
import org.gradle.api.Project;
import org.gradle.api.tasks.TaskProvider;

/** {@code id("net.scruter.symbols")}: see the extension {@link ScruterExtension} and docs/MOBILE.md §4.3. */
public class ScruterSymbolsPlugin implements Plugin<Project> {
    private static final Pattern APP_ID = Pattern.compile("^[A-Z0-9_-]{1,32}$");

    @Override
    public void apply(Project project) {
        ScruterExtension ext = project.getExtensions().create("scruter", ScruterExtension.class);
        ext.getApiEndpoint().convention("https://api.scruter.net");
        ext.getAutoUpload().convention(true);
        ext.getFailOnError().convention(false);
        ext.getUploadToken().convention(project.getProviders().environmentVariable("SCRUTER_UPLOAD_TOKEN"));
        project.getPluginManager().withPlugin("com.android.application", p -> configure(project, ext));
    }

    private static String capitalized(String s) {
        return s.substring(0, 1).toUpperCase(Locale.ROOT) + s.substring(1);
    }

    private void configure(Project project, ScruterExtension ext) {
        ApplicationAndroidComponentsExtension components =
                project.getExtensions().getByType(ApplicationAndroidComponentsExtension.class);
        Action<ApplicationVariant> action = variant -> configureVariant(project, ext, variant);
        components.onVariants(components.selector().all(), action);
    }

    private void configureVariant(Project project, ScruterExtension ext, ApplicationVariant variant) {
        String appId = ext.getAppId().getOrNull();
        if (appId == null || !APP_ID.matcher(appId).matches()) {
            throw new GradleException("net.scruter.symbols: set your app id: scruter { appId = \"ATMONA02\" } (found: " + appId + ")");
        }
        variant.getManifestPlaceholders().put("scruterAppId", appId.toLowerCase(Locale.ROOT));

        String name = capitalized(variant.getName());
        boolean minified = variant.isMinifyEnabled();
        if (minified) {
            TaskProvider<MappingIdTask> mappingId = project.getTasks()
                    .register("scruterMappingId" + name, MappingIdTask.class, t -> {
                        t.setGroup("scruter");
                        t.setDescription("Writes R8's mapping id into the app's assets.");
                        t.getMapping().set(variant.getArtifacts().get(SingleArtifact.OBFUSCATION_MAPPING_FILE.INSTANCE));
                    });
            variant.getSources().getAssets().addGeneratedSourceDirectory(mappingId, MappingIdTask::getOutputDir);
        }
        if (variant.getDebuggable()) return;

        TaskProvider<UploadSymbolsTask> upload = project.getTasks()
                .register("scruterUploadSymbols" + name, UploadSymbolsTask.class, t -> {
                    t.setGroup("scruter");
                    t.setDescription("Uploads the R8 mapping and the NDK symbols of " + variant.getName() + " to Scruter.");
                    t.getAppId().set(ext.getAppId());
                    t.getToken().set(ext.getUploadToken());
                    t.getApiEndpoint().set(ext.getApiEndpoint());
                    t.getFailOnError().set(ext.getFailOnError());
                    if (minified) t.getMapping().set(variant.getArtifacts().get(SingleArtifact.OBFUSCATION_MAPPING_FILE.INSTANCE));
                    VariantOutput output = variant.getOutputs().get(0);
                    t.getVersionName().set(output.getVersionName());
                    t.getVersionCode().set(output.getVersionCode().map(String::valueOf));
                    // AGP has no public artifact for native libraries: its stable intermediate directories.
                    t.getNativeDirs().from(project.getLayout().getBuildDirectory().dir("intermediates/merged_native_libs/" + variant.getName()));
                    t.getNativeDirs().from(project.getLayout().getBuildDirectory().dir("intermediates/cxx/" + name));
                    t.getNativeDirs().from(ext.getNativeSymbolDirs());
                });
        project.getTasks().configureEach(t -> {
            if ((t.getName().equals("assemble" + name) || t.getName().equals("bundle" + name)) && ext.getAutoUpload().get()) {
                t.finalizedBy(upload);
            }
        });
    }
}
