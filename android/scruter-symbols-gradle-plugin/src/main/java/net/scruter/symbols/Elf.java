package net.scruter.symbols;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.FileChannel;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.util.ArrayList;
import java.util.List;

/**
 * What the upload needs from a shared library: the GNU build id (the crash reports' image id, docs/MOBILE.md §4.3), the
 * architecture, and whether it still has symbols (a stripped library is useless).
 */
final class Elf {
    final String buildId;
    final String arch;
    final boolean hasSymbols;

    private Elf(String buildId, String arch, boolean hasSymbols) {
        this.buildId = buildId;
        this.arch = arch;
        this.hasSymbols = hasSymbols;
    }

    private static final class Section {
        long nameOffset;
        int type;
        long offset;
        long size;
    }

    /** {@code null} when the file is not an ELF shared object this reader understands. */
    static Elf read(Path file) throws IOException {
        try (FileChannel ch = FileChannel.open(file, StandardOpenOption.READ)) {
            ByteBuffer h = ByteBuffer.allocate(64);
            if (ch.read(h, 0) < 52) return null;
            h.flip();
            if (h.get(0) != 0x7f || h.get(1) != 'E' || h.get(2) != 'L' || h.get(3) != 'F') return null;
            boolean is64 = h.get(4) == 2;
            h.order(h.get(5) == 1 ? ByteOrder.LITTLE_ENDIAN : ByteOrder.BIG_ENDIAN);
            int machine = h.getShort(18) & 0xffff;
            long shoff = is64 ? h.getLong(40) : h.getInt(32) & 0xffffffffL;
            int shentsize = h.getShort(is64 ? 58 : 46) & 0xffff;
            int shnum = h.getShort(is64 ? 60 : 48) & 0xffff;
            int shstrndx = h.getShort(is64 ? 62 : 50) & 0xffff;
            if (shoff <= 0 || shnum == 0 || shentsize < (is64 ? 64 : 40) || shstrndx >= shnum) return null;
            ByteBuffer table = ByteBuffer.allocate(shentsize * shnum).order(h.order());
            if (ch.read(table, shoff) < table.capacity()) return null;
            List<Section> sections = new ArrayList<>();
            for (int i = 0; i < shnum; i++) {
                int at = i * shentsize;
                Section s = new Section();
                s.nameOffset = table.getInt(at) & 0xffffffffL;
                s.type = table.getInt(at + 4);
                s.offset = is64 ? table.getLong(at + 24) : table.getInt(at + 16) & 0xffffffffL;
                s.size = is64 ? table.getLong(at + 32) : table.getInt(at + 20) & 0xffffffffL;
                sections.add(s);
            }
            Section strs = sections.get(shstrndx);
            ByteBuffer names = ByteBuffer.allocate((int) Math.min(strs.size, 1 << 20));
            ch.read(names, strs.offset);
            String buildId = null;
            boolean symbols = false;
            for (Section s : sections) {
                String name = cString(names, (int) s.nameOffset);
                if (name.equals(".symtab") || name.equals(".debug_info")) symbols = true;
                if (s.type == 7 && buildId == null && s.size <= 1 << 16) {
                    ByteBuffer note = ByteBuffer.allocate((int) s.size).order(h.order());
                    ch.read(note, s.offset);
                    buildId = buildId(note);
                }
            }
            return new Elf(buildId, arch(machine), symbols);
        }
    }

    private static String cString(ByteBuffer b, int at) {
        StringBuilder s = new StringBuilder();
        for (int i = at; i >= 0 && i < b.capacity() && b.get(i) != 0; i++) s.append((char) b.get(i));
        return s.toString();
    }

    private static String buildId(ByteBuffer n) {
        int at = 0;
        while (at + 12 <= n.capacity()) {
            int namesz = n.getInt(at);
            int descsz = n.getInt(at + 4);
            int type = n.getInt(at + 8);
            int name = at + 12;
            int desc = name + ((namesz + 3) & ~3);
            if (namesz < 0 || descsz < 0 || desc + descsz > n.capacity()) return null;
            if (type == 3 && namesz == 4 && n.get(name) == 'G' && n.get(name + 1) == 'N' && n.get(name + 2) == 'U') {
                byte[] id = new byte[descsz];
                for (int i = 0; i < descsz; i++) id[i] = n.get(desc + i);
                return MappingId.hex(id);
            }
            at = desc + ((descsz + 3) & ~3);
        }
        return null;
    }

    private static String arch(int machine) {
        return switch (machine) {
            case 0xB7 -> "arm64-v8a";
            case 0x28 -> "armeabi-v7a";
            case 0x3E -> "x86_64";
            case 0x03 -> "x86";
            case 0xF3 -> "riscv64";
            default -> "unknown";
        };
    }
}
