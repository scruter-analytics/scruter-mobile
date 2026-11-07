package net.scruter.symbols;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import java.io.ByteArrayOutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import org.junit.After;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

public class SymbolsTest {
    @Rule public TemporaryFolder tmp = new TemporaryFolder();
    private final FakeApi api;

    public SymbolsTest() throws Exception {
        api = new FakeApi();
    }

    @After
    public void stop() {
        api.close();
    }

    @Test
    public void mappingIds() throws Exception {
        Path r8 = tmp.newFile("r8.txt").toPath();
        Files.writeString(r8, "# compiler: R8\n# compiler_version: 8.7\n# pg_map_id: 3a1f9c2\n# common_typos_disable\nfoo.Bar -> a:\n");
        assertEquals("3a1f9c2", MappingId.of(r8));
        Path proguard = tmp.newFile("pg.txt").toPath();
        Files.writeString(proguard, "foo.Bar -> a:\n");
        assertEquals(32, MappingId.of(proguard).length());
    }

    /** A little-endian ELF64 with a build-id note, and .symtab when [symbols]. */
    static byte[] elf(byte[] id, boolean symbols, int machine) {
        byte[] names = (symbols ? "\0.shstrtab\0.note.gnu.build-id\0.symtab\0" : "\0.shstrtab\0.note.gnu.build-id\0\0\0\0\0\0\0\0\0").getBytes(StandardCharsets.ISO_8859_1);
        ByteBuffer note = ByteBuffer.allocate(16 + id.length).order(ByteOrder.LITTLE_ENDIAN);
        note.putInt(4).putInt(id.length).putInt(3).put("GNU\0".getBytes(StandardCharsets.ISO_8859_1)).put(id);
        int notesAt = 64;
        int namesAt = notesAt + note.capacity();
        int shoff = namesAt + names.length;
        int sections = symbols ? 4 : 3;
        ByteBuffer b = ByteBuffer.allocate(shoff + sections * 64).order(ByteOrder.LITTLE_ENDIAN);
        b.put(new byte[] {0x7f, 'E', 'L', 'F', 2, 1, 1, 0});
        b.position(16);
        b.putShort((short) 3).putShort((short) machine).putInt(1).putLong(0).putLong(0).putLong(shoff);
        b.putInt(0).putShort((short) 64).putShort((short) 56).putShort((short) 0).putShort((short) 64);
        b.putShort((short) sections).putShort((short) 1);
        b.position(notesAt);
        b.put(note.array());
        b.put(names);
        section(b, shoff, 0, 0, 0, 0);
        section(b, shoff + 64, 1, 3, namesAt, names.length);
        section(b, shoff + 128, 11, 7, notesAt, note.capacity());
        if (symbols) section(b, shoff + 192, 30, 2, 0, 0);
        return b.array();
    }

    private static void section(ByteBuffer b, int at, int name, int type, int offset, int size) {
        b.putInt(at, name);
        b.putInt(at + 4, type);
        b.putLong(at + 24, offset);
        b.putLong(at + 32, size);
    }

    @Test
    public void elfFacts() throws Exception {
        Path so = tmp.newFile("libmona.so").toPath();
        Files.write(so, elf(new byte[] {(byte) 0xaa, (byte) 0xbb, 0x0c, 0x1d}, true, 0xB7));
        Elf e = Elf.read(so);
        assertEquals("aabb0c1d", e.buildId);
        assertEquals("arm64-v8a", e.arch);
        assertTrue(e.hasSymbols);
        Path stripped = tmp.newFile("libs.so").toPath();
        Files.write(stripped, elf(new byte[] {1, 2}, false, 0x3E));
        assertFalse(Elf.read(stripped).hasSymbols);
        assertEquals("x86_64", Elf.read(stripped).arch);
        Path text = tmp.newFile("x.so").toPath();
        Files.writeString(text, "not an elf file, at all, not even a little bit, really not one, nope, no.");
        assertNull(Elf.read(text));
    }

    @Test
    public void uploadsWhatIsMissing() throws Exception {
        Path gz = tmp.newFile("mapping.txt.gz").toPath();
        Files.write(gz, new byte[] {1, 2, 3, 4});
        SymbolClient c = new SymbolClient("ATMONA02", api.url(), "scr_up_token", 2);
        assertTrue(c.missing("r8_mapping", "abc"));
        Map<String, Object> d = new LinkedHashMap<>();
        d.put("platform", "android");
        d.put("kind", "r8_mapping");
        d.put("debug_id", "abc");
        d.put("file_name", "mapping.txt.gz");
        c.upload(d, gz);
        assertEquals("[POST /m/v1/symbols/missing, POST /m/v1/symbols, PUT /object, POST /m/v1/symbols/s1/complete]", api.calls.toString());
        assertTrue(api.bodies.get(1).contains("\"sha256\":\"" + MappingId.sha256(gz) + "\""));
        assertTrue(api.bodies.get(1).contains("\"size\":4"));
        assertEquals("Bearer scr_up_token", api.auth.get(0));
        assertEquals("the presigned PUT carries no token", "", api.auth.get(2));
        assertEquals(4, api.put.length);
    }

    @Test
    public void alreadyThereAndErrors() throws Exception {
        api.missing = false;
        SymbolClient c = new SymbolClient("ATMONA02", api.url(), "scr_up_token", 1);
        assertFalse(c.missing("r8_mapping", "abc"));
        api.createStatus = 409;
        Path gz = tmp.newFile("a.gz").toPath();
        Files.write(gz, new byte[] {1});
        c.upload(new LinkedHashMap<>(), gz);
        assertEquals("a conflict stops quietly", 2, api.calls.size());
        api.createStatus = 401;
        try {
            c.upload(new LinkedHashMap<>(), gz);
            throw new AssertionError("should fail");
        } catch (SymbolClient.Failed e) {
            assertTrue(e.getMessage().contains("401"));
            assertFalse(e.getMessage().contains("scr_up_token"));
        }
    }

    @Test
    public void retriesAServerError() throws Exception {
        api.failFirst = 1;
        SymbolClient c = new SymbolClient("ATMONA02", api.url(), "scr_up_token", 3);
        assertTrue(c.missing("ndk_symbols", "abc"));
        assertEquals(2, api.calls.size());
    }

    static byte[] gunzip(byte[] b) throws Exception {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        try (java.util.zip.GZIPInputStream in = new java.util.zip.GZIPInputStream(new java.io.ByteArrayInputStream(b))) {
            in.transferTo(out);
        }
        return out.toByteArray();
    }
}
