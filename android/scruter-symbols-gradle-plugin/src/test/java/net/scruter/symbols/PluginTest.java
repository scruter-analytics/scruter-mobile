package net.scruter.symbols;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.HashMap;
import java.util.Map;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import org.gradle.testkit.runner.BuildResult;
import org.gradle.testkit.runner.GradleRunner;
import org.gradle.testkit.runner.TaskOutcome;
import org.junit.After;
import org.junit.Before;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

/** A real Android release build with R8 (Gradle TestKit): the manifest scheme, the mapping id, the uploads. */
public class PluginTest {
    @Rule public TemporaryFolder tmp = new TemporaryFolder();
    private FakeApi api;
    private File project;

    private static final String MANIFEST = """
            <manifest xmlns:android="http://schemas.android.com/apk/res/android">
                <application>
                    <activity android:name=".Main" android:exported="true">
                        <intent-filter>
                            <action android:name="android.intent.action.MAIN" />
                            <category android:name="android.intent.category.LAUNCHER" />
                        </intent-filter>
                        <intent-filter>
                            <action android:name="android.intent.action.VIEW" />
                            <category android:name="android.intent.category.DEFAULT" />
                            <data android:scheme="scruter-${scruterAppId}" android:host="team" />
                        </intent-filter>
                    </activity>
                </application>
            </manifest>
            """;

    private static final String ACTIVITY = """
            package fr.test.app;
            public class Main extends android.app.Activity {
                @Override protected void onCreate(android.os.Bundle b) { super.onCreate(b); helper(); }
                private void helper() { android.util.Log.d("x", "y"); }
            }
            """;

    @Before
    public void setUp() throws Exception {
        api = new FakeApi();
        project = tmp.newFolder("app");
        Path root = project.toPath();
        Files.writeString(root.resolve("settings.gradle.kts"), """
                dependencyResolutionManagement {
                    repositories { google(); mavenCentral() }
                }
                rootProject.name = "fixture"
                """);
        Files.writeString(root.resolve("gradle.properties"), "android.useAndroidX=true\norg.gradle.jvmargs=-Xmx1536m\n");
        Files.writeString(root.resolve("build.gradle.kts"), """
                plugins {
                    id("com.android.application")
                    id("net.scruter.symbols")
                }
                android {
                    namespace = "fr.test.app"
                    compileSdk = 35
                    buildToolsVersion = "35.0.0"
                    defaultConfig {
                        applicationId = "fr.test.app"
                        minSdk = 24
                        targetSdk = 35
                        versionCode = 230
                        versionName = "2.3.0"
                    }
                    buildTypes {
                        release { isMinifyEnabled = true }
                    }
                }
                scruter {
                    appId = "ATMONA02"
                    apiEndpoint = "%s"
                    failOnError = true
                }
                """.formatted(api.url()));
        Path main = root.resolve("src/main");
        Files.createDirectories(main.resolve("java/fr/test/app"));
        Files.writeString(main.resolve("AndroidManifest.xml"), MANIFEST);
        Files.writeString(main.resolve("java/fr/test/app/Main.java"), ACTIVITY);
        // An unstripped native library, where AGP merges them.
        Path jni = main.resolve("jniLibs/arm64-v8a");
        Files.createDirectories(jni);
        Files.write(jni.resolve("libmona.so"), SymbolsTest.elf(new byte[] {(byte) 0xca, (byte) 0xfe, 1, 2}, true, 0xB7));
    }

    @After
    public void tearDown() {
        api.close();
    }

    private GradleRunner runner(Map<String, String> env, String... args) {
        Map<String, String> e = new HashMap<>(System.getenv());
        e.putAll(env);
        return GradleRunner.create().withProjectDir(project).withPluginClasspath().withEnvironment(e).withArguments(args);
    }

    @Test
    public void aReleaseBuild() throws Exception {
        BuildResult r = runner(Map.of("SCRUTER_UPLOAD_TOKEN", "scr_up_test"), "assembleRelease", "--stacktrace", "--max-workers=2").build();
        assertEquals(TaskOutcome.SUCCESS, r.task(":scruterUploadSymbolsRelease").getOutcome());
        assertFalse("the token never reaches the output", r.getOutput().contains("scr_up_test"));

        File mapping = new File(project, "build/outputs/mapping/release/mapping.txt");
        String id = MappingId.of(mapping.toPath());

        File apk = new File(project, "build/outputs/apk/release/fixture-release-unsigned.apk");
        assertTrue(apk.getPath(), apk.exists());
        try (ZipFile zip = new ZipFile(apk)) {
            ZipEntry e = zip.getEntry("assets/net.scruter/mapping-id");
            assertNotNull("the id is in the app", e);
            assertEquals(id, new String(zip.getInputStream(e).readAllBytes(), StandardCharsets.UTF_8));
        }
        String manifest = Files.readString(new File(project, "build/intermediates/merged_manifests/release/processReleaseManifest/AndroidManifest.xml").toPath());
        assertTrue(manifest, manifest.contains("scruter-atmona02"));

        String calls = api.calls.toString();
        assertTrue(calls, calls.contains("POST /m/v1/symbols/missing"));
        assertTrue(calls, calls.contains("PUT /object"));
        int mappingAt = -1;
        int ndkAt = -1;
        for (int i = 0; i < api.bodies.size(); i++) {
            String b = api.bodies.get(i);
            if (api.calls.get(i).equals("POST /m/v1/symbols") && b.contains("r8_mapping")) mappingAt = i;
            if (api.calls.get(i).equals("POST /m/v1/symbols") && b.contains("ndk_symbols")) ndkAt = i;
        }
        assertTrue(calls, mappingAt >= 0);
        String decl = api.bodies.get(mappingAt);
        assertTrue(decl, decl.contains("\"debug_id\":\"" + id + "\""));
        assertTrue(decl, decl.contains("\"app\":\"ATMONA02\""));
        assertTrue(decl, decl.contains("\"platform\":\"android\""));
        assertTrue(decl, decl.contains("\"app_version\":\"2.3.0\""));
        assertTrue(decl, decl.contains("\"build\":\"230\""));
        assertTrue(calls, ndkAt >= 0);
        String ndk = api.bodies.get(ndkAt);
        assertTrue(ndk, ndk.contains("\"debug_id\":\"cafe0102\""));
        assertTrue(ndk, ndk.contains("\"arch\":\"arm64-v8a\""));
    }

    @Test
    public void withoutTokenTheBuildPassesAndSaysSo() {
        Map<String, String> env = new HashMap<>();
        env.put("SCRUTER_UPLOAD_TOKEN", "");
        BuildResult r = runner(env, "assembleRelease", "--max-workers=2").build();
        assertTrue(r.getOutput(), r.getOutput().contains("symbols not uploaded"));
        assertTrue(api.calls.isEmpty());
    }

    @Test
    public void aMissingAppIdIsAClearError() throws Exception {
        Path build = project.toPath().resolve("build.gradle.kts");
        Files.writeString(build, Files.readString(build).replace("appId = \"ATMONA02\"", ""));
        BuildResult r = runner(Map.of(), "tasks").buildAndFail();
        assertTrue(r.getOutput(), r.getOutput().contains("scruter { appId"));
    }
}
