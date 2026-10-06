//
//  GuestLibraries.swift
//  maciOS
//

import Foundation
import MachO

/// Patched copies of the non-system libraries guest programs link against,
/// such as the dependencies of a Homebrew formula. Like guest executables
/// they are built for macOS, so each is retargeted to this platform and the
/// references between them are pointed at the patched copies.
enum GuestLibraries {
    static var directory: URL { Execute.imageCacheDirectory.appendingPathComponent("lib") }

    private static let lock = NSRecursiveLock()
    private static var inProgress: Set<String> = []

    /// The path of a loadable copy of the library at `path`, patching it the
    /// first time. `executablePath` and `rpaths` are what `@executable_path`
    /// and `@rpath` mean for the image that loads it.
    static func patched(_ path: String, executablePath: String, rpaths: [String]) -> String? {
        lock.lock()
        defer { lock.unlock() }

        let original = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: original.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        // FNV-1a, so the name is stable across launches.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in original.path.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        let name = "\(original.deletingPathExtension().lastPathComponent)-\(String(hash, radix: 16))-\(size)-\(Int64(modified * 1000)).dylib"
        let output = directory.appendingPathComponent(name)

        if fileManager.fileExists(atPath: output.path) { return output.path }
        // A library that (indirectly) links back to one being patched: it
        // will be at `output` once the outer patch finishes.
        if inProgress.contains(original.path) { return output.path }
        inProgress.insert(original.path)
        defer { inProgress.remove(original.path) }

        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(UUID().uuidString + ".dylib")
        guard MachOPatcher(original, output: staging).patchLibrary(executablePath: executablePath, rpaths: rpaths) != nil else {
            try? fileManager.removeItem(at: staging)
            return nil
        }
        do {
            try fileManager.moveItem(at: staging, to: output)
        } catch {
            try? fileManager.removeItem(at: staging)
            guard fileManager.fileExists(atPath: output.path) else { return nil }
        }
        return output.path
    }

    /// Copies (clones, on APFS) the patched libraries the image at `image`
    /// needs, directly or not, into its directory, where it looks for them.
    static func cloneDependencies(of image: URL) throws {
        let fileManager = FileManager.default
        let target = image.deletingLastPathComponent()
        var pending = [image]
        var seen: Set<String> = []
        while let next = pending.popLast() {
            for name in loaderPathDependencies(of: next) where seen.insert(name).inserted {
                let destination = target.appendingPathComponent(name)
                if !fileManager.fileExists(atPath: destination.path) {
                    try fileManager.copyItem(at: directory.appendingPathComponent(name), to: destination)
                }
                pending.append(destination)
            }
        }
    }

    /// The names of the libraries the image refers to as @loader_path/name.
    private static func loaderPathDependencies(of image: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: image),
              let head = try? handle.read(upToCount: 64 * 1024) else { return [] }
        try? handle.close()
        let headerSize = MemoryLayout<mach_header_64>.size
        guard head.count >= headerSize else { return [] }
        return head.withUnsafeBytes { raw -> [String] in
            let header = raw.loadUnaligned(as: mach_header_64.self)
            guard header.magic == MH_MAGIC_64, headerSize + Int(header.sizeofcmds) <= raw.count else { return [] }
            let dylibCommands: Set<UInt32> = [UInt32(LC_LOAD_DYLIB), LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, UInt32(LC_LAZY_LOAD_DYLIB), LC_LOAD_UPWARD_DYLIB]
            var names: [String] = []
            var cursor = headerSize
            for _ in 0..<header.ncmds {
                let cmd = raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self)
                let size = Int(raw.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self))
                guard size >= 8, cursor + size <= raw.count else { break }
                if dylibCommands.contains(cmd) {
                    let offset = Int(raw.loadUnaligned(fromByteOffset: cursor + 8, as: UInt32.self))
                    let bytes = raw[(cursor + offset)..<(cursor + size)].prefix { $0 != 0 }
                    let name = String(decoding: bytes, as: UTF8.self)
                    if name.hasPrefix("@loader_path/") {
                        names.append(String(name.dropFirst("@loader_path/".count)))
                    }
                }
                cursor += size
            }
            return names
        }
    }

    /// A library the program at `executablePath` opens itself, placed beside
    /// `programImage`, the program's loaded copy. Its imports looked up in the
    /// main executable or the flat namespace, like a Ruby extension's calls
    /// into the interpreter, are bound to that copy: here the main executable
    /// is the app, and each running copy of the program has its own globals.
    static func loadable(_ path: String, programImage: String, executablePath: String) -> String? {
        // System libraries, and images that are already patched copies.
        let loadablePrefixes = ["/usr/lib/", "/System/", Bundle.main.bundlePath + "/",
                                Execute.imageCacheDirectory.path + "/", Execute.instanceDirectory.path + "/"]
        guard !loadablePrefixes.contains(where: path.hasPrefix),
              FileManager.default.fileExists(atPath: path),
              let patched = patched(path, executablePath: executablePath, rpaths: []),
              var data = try? Data(contentsOf: URL(fileURLWithPath: patched)) else { return nil }

        lock.lock()
        defer { lock.unlock() }
        let fileManager = FileManager.default
        // Beside the program's copy, with clones of what it needs.
        let directory = URL(fileURLWithPath: programImage).deletingLastPathComponent()
        let target = directory.appendingPathComponent((patched as NSString).lastPathComponent)
        if fileManager.fileExists(atPath: target.path) { return target.path }
        let staging = directory.appendingPathComponent(UUID().uuidString + ".dylib")
        do {
            switch MachOPatcher.bindProgramLookups(in: &data, to: programImage) {
            case true?:
                try data.write(to: staging)
                MachOPatcher(staging, output: staging).finishPatching()
            case false?:
                try fileManager.copyItem(at: URL(fileURLWithPath: patched), to: staging)
            case nil:
                NSLog("Cannot bind %@ to %@", path, programImage)
                try fileManager.copyItem(at: URL(fileURLWithPath: patched), to: staging)
            }
            try fileManager.moveItem(at: staging, to: target)
            try cloneDependencies(of: target)
            return target.path
        } catch {
            try? fileManager.removeItem(at: staging)
            NSLog("Error preparing %@ for %@: %@", path, programImage, error.localizedDescription)
            return nil
        }
    }
}

extension MachOPatcher {
    /// Points imports looked up in the main executable or the flat namespace
    /// at a dependency on `image`, which it adds. Returns whether there were
    /// any, or nil if the image cannot be changed that way.
    static func bindProgramLookups(in data: inout Data, to image: String) -> Bool? {
        let headerSize = MemoryLayout<mach_header_64>.size
        guard data.count >= headerSize else { return nil }
        let (magic, ncmds, sizeofcmds) = data.withUnsafeBytes { raw -> (UInt32, UInt32, UInt32) in
            let header = raw.loadUnaligned(as: mach_header_64.self)
            return (header.magic, header.ncmds, header.sizeofcmds)
        }
        guard magic == MH_MAGIC_64, headerSize + Int(sizeofcmds) <= data.count else { return nil }

        let LC_DYLD_CHAINED_FIXUPS: UInt32 = 0x80000034
        let dylibCommands: Set<UInt32> = [UInt32(LC_LOAD_DYLIB), LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, UInt32(LC_LAZY_LOAD_DYLIB), LC_LOAD_UPWARD_DYLIB]
        var dylibCount = 0
        var fixups: Int?
        var bindStreams: [(Int, Int)] = []
        var cursor = headerSize
        for _ in 0..<ncmds {
            let words = data.withUnsafeBytes { raw in
                (0..<10).map { Int(raw.loadUnaligned(fromByteOffset: cursor + $0 * 4, as: UInt32.self)) }
            }
            let cmd = UInt32(words[0])
            if dylibCommands.contains(cmd) { dylibCount += 1 }
            if cmd == LC_DYLD_CHAINED_FIXUPS { fixups = words[2] }
            if cmd == UInt32(LC_DYLD_INFO) || cmd == UInt32(LC_DYLD_INFO_ONLY) {
                bindStreams = [(words[4], words[5]), (words[8], words[9])]
            }
            cursor += words[1]
        }
        let ordinal = dylibCount + 1

        var found = false
        let changed = data.withUnsafeMutableBytes { raw -> Bool in
            if let header = fixups {
                let importsOffset = Int(raw.loadUnaligned(fromByteOffset: header + 8, as: UInt32.self))
                let importsCount = Int(raw.loadUnaligned(fromByteOffset: header + 16, as: UInt32.self))
                let format = raw.loadUnaligned(fromByteOffset: header + 20, as: UInt32.self)
                let base = header + importsOffset
                for i in 0..<importsCount {
                    switch format {
                    case 1, 2: // lib_ordinal:8, where 0xff is the main executable and 0xfe the flat namespace
                        let offset = base + i * (format == 1 ? 4 : 8)
                        let value = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                        guard value & 0xff == 0xff || value & 0xff == 0xfe else { continue }
                        guard ordinal < 0xf0 else { return false }
                        raw.storeBytes(of: value & ~0xff | UInt32(ordinal), toByteOffset: offset, as: UInt32.self)
                        found = true
                    case 3: // lib_ordinal:16
                        let offset = base + i * 16
                        let value = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                        guard value & 0xffff == 0xffff || value & 0xffff == 0xfffe else { continue }
                        raw.storeBytes(of: value & ~0xffff | UInt64(ordinal), toByteOffset: offset, as: UInt64.self)
                        found = true
                    default:
                        return false
                    }
                }
            }
            for (offset, size) in bindStreams where size > 0 {
                var i = offset
                let end = offset + size
                func skipLEB() {
                    while i < end, raw[i] & 0x80 != 0 { i += 1 }
                    i += 1
                }
                while i < end {
                    let byte = raw[i]
                    let opcode = byte & 0xf0
                    i += 1
                    switch opcode {
                    case 0x30: // BIND_OPCODE_SET_DYLIB_SPECIAL_IMM: 0xf main executable, 0xe flat lookup
                        guard byte & 0x0f == 0x0f || byte & 0x0f == 0x0e else { continue }
                        // BIND_OPCODE_SET_DYLIB_ORDINAL_IMM holds ordinals up to 15.
                        guard ordinal <= 0x0f else { return false }
                        raw[i - 1] = 0x10 | UInt8(ordinal)
                        found = true
                    case 0x20, 0x60, 0x70, 0x80, 0xa0:
                        skipLEB()
                    case 0xc0:
                        skipLEB()
                        skipLEB()
                    case 0xd0:
                        if byte & 0x0f == 0 { skipLEB() }
                    case 0x40:
                        while i < end, raw[i] != 0 { i += 1 }
                        i += 1
                    default:
                        break
                    }
                }
            }
            return true
        }
        guard changed else { return nil }
        guard found else { return false }

        // The dependency, appended to the load commands.
        let nameOffset = MemoryLayout<dylib_command>.size
        var command = Data(count: nameOffset)
        command.append(contentsOf: Array(image.utf8) + [0])
        while command.count % 8 != 0 { command.append(0) }
        command.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(LC_LOAD_DYLIB), toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: UInt32(raw.count), toByteOffset: 4, as: UInt32.self)
            raw.storeBytes(of: UInt32(nameOffset), toByteOffset: 8, as: UInt32.self)
        }
        let space = data.withUnsafeMutableBytes { raw in
            freeHeaderSpace(raw.baseAddress!.assumingMemoryBound(to: mach_header_64.self))
        }
        guard command.count <= space else { return nil }
        let end = headerSize + Int(sizeofcmds)
        data.replaceSubrange(end..<end + command.count, with: command)
        data.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: ncmds + 1, toByteOffset: 16, as: UInt32.self)
            raw.storeBytes(of: sizeofcmds + UInt32(command.count), toByteOffset: 20, as: UInt32.self)
        }
        return true
    }

    /// Marks every imported symbol as a weak import: one this platform's
    /// libraries lack binds to NULL instead of keeping the image from loading,
    /// and only fails if the program actually uses it.
    static func weakenImports(in data: inout Data, commands: [Data]) {
        let LC_DYLD_CHAINED_FIXUPS: UInt32 = 0x80000034
        func command(_ cmd: UInt32) -> Data? {
            commands.first { $0.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } == cmd }
        }
        func word(_ command: Data, _ offset: Int) -> Int {
            Int(command.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) })
        }
        data.withUnsafeMutableBytes { raw in
            if let fixups = command(LC_DYLD_CHAINED_FIXUPS) {
                let header = word(fixups, 8)
                let importsOffset = Int(raw.loadUnaligned(fromByteOffset: header + 8, as: UInt32.self))
                let importsCount = Int(raw.loadUnaligned(fromByteOffset: header + 16, as: UInt32.self))
                let format = raw.loadUnaligned(fromByteOffset: header + 20, as: UInt32.self)
                let base = header + importsOffset
                for i in 0..<importsCount {
                    switch format {
                    case 1, 2: // DYLD_CHAINED_IMPORT(_ADDEND): lib_ordinal:8 weak_import:1 name_offset:23
                        let offset = base + i * (format == 1 ? 4 : 8)
                        let value = raw.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
                        raw.storeBytes(of: value | 1 << 8, toByteOffset: offset, as: UInt32.self)
                    case 3: // DYLD_CHAINED_IMPORT_ADDEND64: lib_ordinal:16 weak_import:1
                        let offset = base + i * 16
                        let value = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                        raw.storeBytes(of: value | 1 << 16, toByteOffset: offset, as: UInt64.self)
                    default:
                        return
                    }
                }
            }
            guard let info = command(UInt32(LC_DYLD_INFO_ONLY)) ?? command(UInt32(LC_DYLD_INFO)) else { return }
            // The bind and lazy bind opcode streams.
            for (offset, size) in [(word(info, 16), word(info, 20)), (word(info, 32), word(info, 36))] where size > 0 {
                var i = offset
                let end = offset + size
                func skipLEB() {
                    while i < end, raw[i] & 0x80 != 0 { i += 1 }
                    i += 1
                }
                while i < end {
                    let byte = raw[i]
                    let opcode = byte & 0xf0
                    i += 1
                    switch opcode {
                    case 0x20, 0x60, 0x70, 0x80, 0xa0: // ordinal, addend, segment, add address, bind+add
                        skipLEB()
                    case 0xc0: // bind ULEB times skipping ULEB
                        skipLEB()
                        skipLEB()
                    case 0xd0: // threaded: set the ordinal table size, or apply
                        if byte & 0x0f == 0 { skipLEB() }
                    case 0x40: // set symbol: flags in the immediate, then the name
                        raw[i - 1] = byte | 0x01 // BIND_SYMBOL_FLAGS_WEAK_IMPORT
                        while i < end, raw[i] != 0 { i += 1 }
                        i += 1
                    default:
                        break
                    }
                }
            }
        }
    }

    /// Patches a macOS dylib or bundle so a guest can load it.
    func patchLibrary(executablePath: String, rpaths: [String] = []) -> URL? {
        guard copyOriginalSlice() else { return nil }
        #if targetEnvironment(simulator)
        guard patchPlatform(targetPlatform: PLATFORM_IOSSIMULATOR) != nil else { return nil }
        #else
        guard patchPlatform(targetPlatform: PLATFORM_IOS) != nil else { return nil }
        #endif
        patchKnownFrameworks()
        guard relinkLibraries(executablePath: executablePath, inheritedRpaths: rpaths) else { return nil }
        finishPatching()
        return patchedURL
    }

    /// Copies the file to `patchedURL`, keeping only the arm64 slice of a
    /// universal binary.
    func copyOriginalSlice() -> Bool {
        do {
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: patchedURL.path) {
                try fileManager.removeItem(at: patchedURL)
            }
            var data = try Data(contentsOf: fileURL)
            if let slice = Self.arm64Slice(of: data) {
                data = slice
            }
            try data.write(to: patchedURL)
            return true
        } catch {
            NSLog("Error copying file: \(error)")
            return false
        }
    }

    private static func arm64Slice(of data: Data) -> Data? {
        guard data.count >= MemoryLayout<fat_header>.size else { return nil }
        func word(_ offset: Int) -> UInt32 {
            data.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) }
        }
        guard word(0) == FAT_MAGIC else { return nil }
        let count = Int(word(4))
        var best: Range<Int>?
        for i in 0..<count {
            let base = MemoryLayout<fat_header>.size + i * MemoryLayout<fat_arch>.size
            guard base + MemoryLayout<fat_arch>.size <= data.count else { break }
            let cputype = Int32(bitPattern: word(base))
            let subtype = word(base + 4) & ~UInt32(CPU_SUBTYPE_MASK)
            let offset = Int(word(base + 8))
            let size = Int(word(base + 12))
            guard cputype == CPU_TYPE_ARM64, offset + size <= data.count else { continue }
            // arm64e code cannot be loaded into this process; prefer plain arm64.
            if subtype != UInt32(CPU_SUBTYPE_ARM64E) || best == nil {
                best = offset..<(offset + size)
            }
        }
        return best.map { data.subdata(in: $0) }
    }

    /// Makes the patched file's signature match its contents again.
    func finishPatching() {
        #if targetEnvironment(simulator)
        // The simulator has no JIT-based signature bypass, so make the existing
        // ad-hoc signature match the patched contents instead.
        if !macho_rehash_code_signature(patchedURL.path) {
            NSLog("Failed to rehash code signature of %@", patchedURL.path)
        }
        // Rewrite into a fresh inode so no state the kernel attached to the
        // file while it was being patched is reused when it is mapped.
        if let data = try? Data(contentsOf: patchedURL) {
            try? data.write(to: patchedURL, options: .atomic)
        }
        #endif
    }

    /// Points the image's references to non-system libraries at patched
    /// copies of them, and weakly links system libraries this platform lacks.
    func relinkLibraries(executablePath: String, inheritedRpaths: [String] = []) -> Bool {
        guard var data = try? Data(contentsOf: patchedURL) else { return false }
        let headerSize = MemoryLayout<mach_header_64>.size
        guard data.count >= headerSize else { return false }

        let loaderDirectory = fileURL.resolvingSymlinksInPath().deletingLastPathComponent().path
        let executableDirectory = URL(fileURLWithPath: executablePath).resolvingSymlinksInPath().deletingLastPathComponent().path
        func expand(_ path: String) -> String {
            path.replacingOccurrences(of: "@loader_path", with: loaderDirectory)
                .replacingOccurrences(of: "@executable_path", with: executableDirectory)
        }

        struct Command {
            var bytes: Data
            var cmd: UInt32
        }
        var commands: [Command] = []
        var rpaths: [String] = []
        let (magic, ncmds, sizeofcmds) = data.withUnsafeBytes { raw -> (UInt32, UInt32, UInt32) in
            let header = raw.loadUnaligned(as: mach_header_64.self)
            return (header.magic, header.ncmds, header.sizeofcmds)
        }
        guard magic == MH_MAGIC_64, headerSize + Int(sizeofcmds) <= data.count else { return false }

        func string(in command: Data, at offset: Int) -> String {
            guard offset < command.count else { return "" }
            let bytes = command[command.startIndex + offset..<command.endIndex].prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }

        var cursor = headerSize
        for _ in 0..<ncmds {
            let (cmd, cmdsize) = data.withUnsafeBytes { raw in
                (raw.loadUnaligned(fromByteOffset: cursor, as: UInt32.self),
                 raw.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self))
            }
            guard cmdsize >= 8, cursor + Int(cmdsize) <= headerSize + Int(sizeofcmds) else { return false }
            let bytes = data.subdata(in: cursor..<cursor + Int(cmdsize))
            if cmd == LC_RPATH {
                let offset = bytes.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) }
                rpaths.append(expand(string(in: bytes, at: offset)))
            }
            commands.append(Command(bytes: bytes, cmd: cmd))
            cursor += Int(cmdsize)
        }
        let searchPaths = rpaths + inheritedRpaths

        let dylibCommands: Set<UInt32> = [UInt32(LC_LOAD_DYLIB), LC_LOAD_WEAK_DYLIB, LC_REEXPORT_DYLIB, UInt32(LC_LAZY_LOAD_DYLIB), LC_LOAD_UPWARD_DYLIB]
        let appFrameworks = Bundle.main.privateFrameworksPath ?? ""

        for index in commands.indices where dylibCommands.contains(commands[index].cmd) {
            let bytes = commands[index].bytes
            let nameOffset = bytes.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 8, as: UInt32.self)) }
            let name = string(in: bytes, at: nameOffset)

            let candidates: [String]
            if name.hasPrefix("/usr/lib/") || name.hasPrefix("/System/") {
                if dlopen_preflight(name) { continue }
                // A library this platform lacks comes from the guest root
                // when it has a stand-in; otherwise it is weakly linked and
                // its symbols resolve to NULL.
                let substitute = Execute.rootDirectory.path + name
                if !FileManager.default.fileExists(atPath: substitute) {
                    if commands[index].cmd == UInt32(LC_LOAD_DYLIB) {
                        NSLog("%@ is not available; linking it weakly", name)
                        commands[index].cmd = LC_LOAD_WEAK_DYLIB
                        commands[index].bytes.withUnsafeMutableBytes { $0.storeBytes(of: LC_LOAD_WEAK_DYLIB, as: UInt32.self) }
                    }
                    continue
                }
                candidates = [substitute]
            } else if name.hasPrefix("@executable_path/Frameworks/") {
                continue
            } else if name.hasPrefix("@rpath/"), FileManager.default.fileExists(atPath: appFrameworks + "/" + name.dropFirst("@rpath/".count)) {
                continue
            } else if name.hasPrefix("@rpath/") {
                let rest = String(name.dropFirst("@rpath/".count))
                candidates = searchPaths.map { $0 + "/" + rest }
            } else {
                candidates = [expand(name)]
            }
            var resolved: String?
            for candidate in candidates {
                let mapped = candidate.withCString { path -> String in
                    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
                    return String(cString: guest_root_map(path, &buffer))
                }
                if FileManager.default.fileExists(atPath: mapped) {
                    resolved = mapped
                    break
                }
            }
            guard let resolved,
                  let patched = GuestLibraries.patched(resolved, executablePath: executablePath, rpaths: searchPaths) else {
                NSLog("Could not find library %@ for %@", name, fileURL.path)
                continue
            }

            // By name next to the image: each program gets clones of its
            // libraries beside its own copy (Execute.instantiate), so their
            // globals are its own, as in a process of its own.
            let header = bytes.prefix(MemoryLayout<dylib_command>.size)
            var replacement = Data(header)
            replacement.append(contentsOf: Array(("@loader_path/" + (patched as NSString).lastPathComponent).utf8) + [0])
            while replacement.count % 8 != 0 { replacement.append(0) }
            replacement.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: UInt32(raw.count), toByteOffset: 4, as: UInt32.self)
                raw.storeBytes(of: UInt32(MemoryLayout<dylib_command>.size), toByteOffset: 8, as: UInt32.self)
            }
            commands[index].bytes = replacement
        }

        let newCommands = commands.reduce(into: Data()) { $0.append($1.bytes) }
        let available = data.withUnsafeMutableBytes { raw in
            Self.freeHeaderSpace(raw.baseAddress!.assumingMemoryBound(to: mach_header_64.self))
        } + Int(sizeofcmds)
        guard newCommands.count <= available else {
            NSLog("Not enough header space in %@ to relink its libraries", fileURL.path)
            return false
        }
        let oldEnd = headerSize + Int(sizeofcmds)
        data.replaceSubrange(headerSize..<headerSize + newCommands.count, with: newCommands)
        if newCommands.count < Int(sizeofcmds) {
            data.resetBytes(in: headerSize + newCommands.count..<oldEnd)
        }
        data.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(newCommands.count), toByteOffset: 20, as: UInt32.self)
        }
        Self.weakenImports(in: &data, commands: commands.map(\.bytes))
        do {
            try data.write(to: patchedURL)
            return true
        } catch {
            NSLog("Error writing %@: %@", patchedURL.path, error.localizedDescription)
            return false
        }
    }
}
