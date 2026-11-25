import Foundation

/// Liest das Programm-Icon aus einer Windows-EXE (PE-Format) und baut daraus eine `.ico`-Datei,
/// die macOS direkt anzeigen kann.
///
/// Aufbau in Kürze: Die EXE enthält einen Ressourcen-Baum (Typ → Name → Sprache → Daten).
/// Typ 14 (`RT_GROUP_ICON`) listet die Größen eines Icons, Typ 3 (`RT_ICON`) enthält die Bilder.
/// Eine `.ico`-Datei ist fast dasselbe, nur mit Datei-Offsets statt Ressourcen-IDs.
public enum PEIcon {
    private static let groupIconType: UInt32 = 14
    private static let iconType: UInt32 = 3
    /// Größere Ressourcen-Bereiche (z. B. eingebettete Videos) lesen wir nicht ein.
    private static let maxResourceSize = 64 << 20

    public static func icoData(fromExecutableAt url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        func read(_ offset: UInt64, _ count: Int, exact: Bool = true) -> Data? {
            guard count > 0, (try? handle.seek(toOffset: offset)) != nil,
                  let data = try? handle.read(upToCount: count)
            else { return nil }
            return (!exact || data.count == count) ? Data(data) : nil
        }

        // DOS-Kopf ("MZ") → Offset des PE-Kopfs
        guard let dos = read(0, 64), dos.u16(0) == 0x5A4D else { return nil }
        let peOffset = UInt64(dos.u32(0x3C))
        guard let coff = read(peOffset, 24), coff.u32(0) == 0x0000_4550 else { return nil }
        let sectionCount = Int(coff.u16(6))
        let optionalSize = Int(coff.u16(20))
        guard (1...96).contains(sectionCount), optionalSize > 0, let optional = read(peOffset + 24, optionalSize) else { return nil }

        // Datenverzeichnis Nr. 2 = Ressourcen
        let directoryStart: Int
        switch optional.u16(0) {
        case 0x10B: directoryStart = 96   // PE32
        case 0x20B: directoryStart = 112  // PE32+
        default: return nil
        }
        guard optional.count >= directoryStart + 3 * 8 else { return nil }
        let resourceRVA = optional.u32(directoryStart + 16)
        let resourceSize = Int(optional.u32(directoryStart + 20))
        guard resourceRVA != 0, resourceSize >= 16, resourceSize <= maxResourceSize else { return nil }

        guard let table = read(peOffset + 24 + UInt64(optionalSize), sectionCount * 40) else { return nil }
        let sections: [(virtualAddress: UInt32, virtualSize: UInt32, rawPointer: UInt32, rawSize: UInt32)] =
            (0..<sectionCount).map { index in
                let base = index * 40
                return (table.u32(base + 12), table.u32(base + 8), table.u32(base + 20), table.u32(base + 16))
            }

        func fileOffset(rva: UInt32) -> UInt64? {
            for section in sections {
                let span = max(section.virtualSize, section.rawSize)
                if rva >= section.virtualAddress, UInt64(rva) < UInt64(section.virtualAddress) + UInt64(span) {
                    return UInt64(rva - section.virtualAddress) + UInt64(section.rawPointer)
                }
            }
            return nil
        }

        guard let resourceOffset = fileOffset(rva: resourceRVA),
              let resources = read(resourceOffset, resourceSize, exact: false),
              resources.count >= 16
        else { return nil }

        struct Entry {
            let id: UInt32?
            let offset: Int
            let isDirectory: Bool
        }

        func entries(at offset: Int) -> [Entry] {
            guard offset >= 0, offset + 16 <= resources.count else { return [] }
            let count = min(Int(resources.u16(offset + 12)) + Int(resources.u16(offset + 14)), 4096)
            var result: [Entry] = []
            for index in 0..<count {
                let position = offset + 16 + index * 8
                guard position + 8 <= resources.count else { break }
                let name = resources.u32(position)
                let target = resources.u32(position + 4)
                result.append(Entry(
                    id: name & 0x8000_0000 == 0 ? name : nil,
                    offset: Int(target & 0x7FFF_FFFF),
                    isDirectory: target & 0x8000_0000 != 0
                ))
            }
            return result
        }

        /// Steigt bis zum ersten Datenblock hinab (Name → Sprache → Daten).
        func data(under entry: Entry) -> Data? {
            var current = entry
            var depth = 0
            while current.isDirectory {
                guard depth < 4, let first = entries(at: current.offset).first else { return nil }
                current = first
                depth += 1
            }
            guard current.offset + 8 <= resources.count else { return nil }
            let rva = resources.u32(current.offset)
            let size = Int(resources.u32(current.offset + 4))
            guard size > 0, size <= maxResourceSize else { return nil }
            if rva >= resourceRVA {
                let start = Int(rva - resourceRVA)
                if start + size <= resources.count {
                    return resources.subdata(in: start..<(start + size))
                }
            }
            guard let offset = fileOffset(rva: rva) else { return nil }
            return read(offset, size)
        }

        let root = entries(at: 0)
        guard let groupDirectory = root.first(where: { $0.id == groupIconType && $0.isDirectory }),
              let iconDirectory = root.first(where: { $0.id == iconType && $0.isDirectory }),
              let firstGroup = entries(at: groupDirectory.offset).first,
              let group = data(under: firstGroup),
              group.count >= 6
        else { return nil }

        let iconCount = Int(group.u16(4))
        guard (1...255).contains(iconCount), group.count >= 6 + iconCount * 14 else { return nil }
        let icons = entries(at: iconDirectory.offset)

        var images: [(header: Data, image: Data)] = []
        for index in 0..<iconCount {
            let base = 6 + index * 14
            let iconID = UInt32(group.u16(base + 12))
            guard let entry = icons.first(where: { $0.id == iconID }), let image = data(under: entry) else { continue }
            // Breite, Höhe, Farben, reserviert, Ebenen (2), Bits pro Pixel (2)
            images.append((group.subdata(in: base..<(base + 8)), image))
        }
        guard !images.isEmpty else { return nil }

        var ico = Data()
        ico.appendLittleEndian(UInt16(0))
        ico.appendLittleEndian(UInt16(1))
        ico.appendLittleEndian(UInt16(images.count))
        var offset = 6 + 16 * images.count
        for (header, image) in images {
            ico.append(header)
            ico.appendLittleEndian(UInt32(image.count))
            ico.appendLittleEndian(UInt32(offset))
            offset += image.count
        }
        for (_, image) in images {
            ico.append(image)
        }
        return ico
    }
}

extension Data {
    /// Little-Endian lesen; außerhalb der Daten gibt es 0 statt eines Absturzes.
    func u16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let start = startIndex + offset
        return UInt16(self[start]) | UInt16(self[start + 1]) << 8
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let start = startIndex + offset
        return UInt32(self[start]) | UInt32(self[start + 1]) << 8 | UInt32(self[start + 2]) << 16 | UInt32(self[start + 3]) << 24
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
