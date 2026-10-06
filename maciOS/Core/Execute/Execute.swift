//
//  Execute.swift
//  maciOS
//
//  Created by Stossy11 on 23/08/2025.
//

import AppleArchive
import Foundation
import System
import UIKit

struct LCMain {
    let entryOffset: UInt64
    let stackSize: UInt64
}

class Execute: NSObject {

    private static let setUp: Void = {
        install_exit_hook()
        // Guests share the process; a write to a closed pipe gives EPIPE (see hook_sigaction).
        signal(SIGPIPE, SIG_IGN)
        guest_set_launcher { path, argv, envp, pid in
            Execute.spawn(path: String(cString: path), argv: argv, envp: envp, pid: pid)
        }
        guest_set_library_loader { path, programImage, executablePath, loadable in
            guard let result = GuestLibraries.loadable(String(cString: path), programImage: String(cString: programImage), executablePath: String(cString: executablePath)) else { return false }
            strlcpy(loadable, result, Int(PATH_MAX))
            return true
        }
        guest_set_toplevel_exit_observer { pid, status in
            DispatchQueue.main.async { Execute.toplevelExited(pid: pid, status: status) }
        }
        try? FileManager.default.removeItem(at: instanceDirectory)
        installBundledRoot()
        guest_root_set(rootDirectory.path)
        // Patched images refer to each other by absolute path, which changes
        // when the app's container moves.
        // Also when the patched images' format changes (imageCacheFormat).
        let location = imageCacheDirectory.appendingPathComponent(".location")
        let stamp = "\(imageCacheDirectory.path)\n\(imageCacheFormat)"
        if (try? String(contentsOf: location, encoding: .utf8)) != stamp {
            try? FileManager.default.removeItem(at: imageCacheDirectory)
            try? FileManager.default.createDirectory(at: imageCacheDirectory, withIntermediateDirectories: true)
            try? stamp.write(to: location, atomically: true, encoding: .utf8)
        }
    }()

    /// Stands in for /bin, /usr and /etc; see GuestRoot.h.
    static let rootDirectory = URL.documentsDirectory.appendingPathComponent("root")

    /// Installs the guest root built into the app (GuestRoot.aar, see
    /// scripts/embed-guest-root.sh) over Documents/root when it is a different
    /// build. Files the root does not have are left alone.
    private static func installBundledRoot() {
        let fileManager = FileManager.default
        guard let archive = Bundle.main.url(forResource: "GuestRoot", withExtension: "aar"),
              let versionURL = Bundle.main.url(forResource: "GuestRoot", withExtension: "version"),
              let version = try? String(contentsOf: versionURL, encoding: .utf8) else {
            fputs("maciOS: the app has no guest root (GuestRoot.aar) in \(Bundle.main.bundlePath)\n", stderr)
            return
        }
        let installedVersionURL = rootDirectory.appendingPathComponent(".maciOS-root-version")
        guard version != (try? String(contentsOf: installedVersionURL, encoding: .utf8)) else { return }

        let staging = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("GuestRoot")
        try? fileManager.removeItem(at: staging)
        defer { try? fileManager.removeItem(at: staging) }
        do {
            try extractArchive(archive, to: staging)
        } catch {
            NSLog("Could not extract the guest root: %@", error.localizedDescription)
            fputs("maciOS: could not extract the guest root: \(error)\n", stderr)
            return
        }

        guard let entries = fileManager.enumerator(at: staging, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        let base = staging.standardizedFileURL.path
        for case let entry as URL in entries {
            let relative = String(entry.standardizedFileURL.path.dropFirst(base.count + 1))
            // Written last, so an interrupted install is redone.
            if relative == installedVersionURL.lastPathComponent { continue }
            let target = rootDirectory.appendingPathComponent(relative)
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            do {
                if values?.isDirectory == true && values?.isSymbolicLink != true {
                    try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
                } else {
                    if (try? fileManager.attributesOfItem(atPath: target.path)) != nil {
                        try fileManager.removeItem(at: target)
                    }
                    try fileManager.moveItem(at: entry, to: target)
                }
            } catch {
                NSLog("Could not install %@ into the guest root: %@", relative, error.localizedDescription)
                fputs("maciOS: could not install \(relative) into the guest root: \(error)\n", stderr)
                return
            }
        }
        try? version.write(to: installedVersionURL, atomically: true, encoding: .utf8)
    }

    private static func extractArchive(_ archive: URL, to directory: URL) throws {
        struct ArchiveError: LocalizedError {
            var errorDescription: String? { "could not open the archive" }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let file = ArchiveByteStream.fileStream(path: FilePath(archive.path), mode: .readOnly, options: [], permissions: FilePermissions(rawValue: 0o644)) else { throw ArchiveError() }
        defer { try? file.close() }
        guard let decompressed = ArchiveByteStream.decompressionStream(readingFrom: file) else { throw ArchiveError() }
        defer { try? decompressed.close() }
        guard let decoder = ArchiveStream.decodeStream(readingFrom: decompressed) else { throw ArchiveError() }
        defer { try? decoder.close() }
        // The app cannot set some attributes on a device (owners, for one); the files matter, not those.
        guard let extractor = ArchiveStream.extractStream(extractingTo: FilePath(directory.path), flags: [.ignoreOperationNotPermitted]) else { throw ArchiveError() }
        defer { try? extractor.close() }
        _ = try ArchiveStream.process(readingFrom: decoder, writingTo: extractor, flags: [.ignoreOperationNotPermitted])
    }

    /// Changed when patched images are made differently, to drop older ones.
    /// 2: libraries are referred to as @loader_path/name.
    private static let imageCacheFormat = 2

    /// Patched copies of executables that guests start, keyed by the original's path, size and mtime.
    static let imageCacheDirectory = URL.cachesDirectory.appendingPathComponent("GuestImages")
    /// One copy of a patched image per running program, so each gets its own globals.
    static let instanceDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("GuestInstances")

    /// Sets up the environment guests run in, installing the guest root.
    static func prepare() {
        _ = setUp
    }

    /// Patches a macOS executable into a loadable dylib and runs it on its own
    /// thread. `onExit` is called on the main queue with its wait status.
    @discardableResult
    static func launch(executable url: URL, arguments: [String] = [], onExit: ((Int32) -> Void)? = nil) -> MachOPatcher {
        let patcher = MachOPatcher(url)
        _ = setUp
        if let instance = instantiate(url) {
            if !run(dylibPath: instance.path, programName: url.lastPathComponent, arguments: arguments, executablePath: url.path, onExit: onExit) {
                try? FileManager.default.removeItem(at: instance.deletingLastPathComponent())
            }
        }
        return patcher
    }

    /// What to do when programs started from the terminal exit, by pid. Main queue only.
    private static var exitHandlers: [pid_t: (Int32) -> Void] = [:]

    private static func toplevelExited(pid: pid_t, status: Int32) {
        exitHandlers.removeValue(forKey: pid)?(status)
    }

    /// Starts a program that a guest exec'd. Returns 0 once it is running, or an errno value.
    private static func spawn(path: String, argv: UnsafePointer<UnsafeMutablePointer<CChar>?>, envp: UnsafePointer<UnsafeMutablePointer<CChar>?>, pid: pid_t) -> Int32 {
        func strings(_ vector: UnsafePointer<UnsafeMutablePointer<CChar>?>) -> [String] {
            var result: [String] = []
            var cursor = vector
            while let entry = cursor.pointee {
                result.append(String(cString: entry))
                cursor += 1
            }
            return result
        }
        let url = URL(fileURLWithPath: path)
        let arguments = strings(argv)
        guard let instance = instantiate(url) else { return ENOEXEC }
        let started = run(dylibPath: instance.path, programName: arguments.first ?? url.lastPathComponent, arguments: Array(arguments.dropFirst()), executablePath: path, environment: strings(envp), pid: pid)
        if !started {
            try? FileManager.default.removeItem(at: instance.deletingLastPathComponent())
        }
        return started ? 0 : ENOEXEC
    }

    private static let instanceCounter = NSLock()
    private static var instanceCount = 0

    /// A loadable copy of the program at `url` for one run, in a directory of
    /// its own together with clones of the libraries it uses: a separate image
    /// for dyld, so the run gets its own globals, as a process would.
    private static func instantiate(_ url: URL) -> URL? {
        let fileManager = FileManager.default
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        // FNV-1a, so the key is stable across launches.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.path.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        let key = "\(url.lastPathComponent)-\(String(hash, radix: 16))-\(size)-\(Int64(modified * 1000))"
        let cached = imageCacheDirectory.appendingPathComponent(key + ".dylib")

        try? fileManager.createDirectory(at: imageCacheDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: instanceDirectory, withIntermediateDirectories: true)

        if !fileManager.fileExists(atPath: cached.path) {
            let staging = imageCacheDirectory.appendingPathComponent(UUID().uuidString + ".dylib")
            guard MachOPatcher(url, output: staging).patchExecutable() != nil else {
                try? fileManager.removeItem(at: staging)
                return nil
            }
            do {
                try fileManager.moveItem(at: staging, to: cached)
            } catch {
                try? fileManager.removeItem(at: staging)
                guard fileManager.fileExists(atPath: cached.path) else { return nil }
            }
        }

        // Copies have their own paths and inodes, so dyld loads them as new
        // images instead of handing back ones already running. On APFS they are clones.
        instanceCounter.lock()
        instanceCount += 1
        let number = instanceCount
        instanceCounter.unlock()
        let directory = instanceDirectory.appendingPathComponent("\(url.lastPathComponent)-\(number)")
        let instance = directory.appendingPathComponent(url.lastPathComponent + ".dylib")
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try fileManager.copyItem(at: cached, to: instance)
            try GuestLibraries.cloneDependencies(of: instance)
        } catch {
            NSLog("Failed to prepare %@: %@", url.path, error.localizedDescription)
            try? fileManager.removeItem(at: directory)
            return nil
        }
        return instance
    }

    /// Loads a patched image and starts its entry point on a new thread.
    /// `pid` is set for programs started by another guest, which run with
    /// `environment` instead of the app's.
    @discardableResult
    static func run(dylibPath: String, programName: String? = nil, arguments: [String] = [], executablePath: String? = nil, environment: [String]? = nil, pid spawnedPid: pid_t? = nil, onExit: ((Int32) -> Void)? = nil) -> Bool {
        NSLog("Attempting to run dylib at path: %@", dylibPath)

        guard FileManager.default.fileExists(atPath: dylibPath) else {
            NSLog("File does not exist at path: %@", dylibPath)
            return false
        }

        guard let handle = dlopen(dylibPath, RTLD_NOW | RTLD_GLOBAL) else {
            if let error = dlerror() {
                let message = String(cString: error)
                NSLog("Failed to load dylib: %@", message)
                fputs("maciOS: could not load \(programName ?? dylibPath): \(message)\n", stderr)
            }
            return false
        }
        NSLog("Dylib loaded successfully.")
        
        let entrySymbols = ["_main", "start", "_start", "main"]
        var entryPoint: UnsafeMutableRawPointer? = nil
        var lcmain: LCMain? = nil
        
        for symbol in entrySymbols {
            dlerror()
            if let sym = dlsym(handle, symbol), dlerror() == nil {
                entryPoint = sym
                NSLog("Found entry symbol: %@", symbol)
                break
            }
        }
        
        if entryPoint == nil {
            lcmain = getARM64EntryPoint(from: dylibPath)
            
            guard lcmain != nil else {
                NSLog("No entry symbol found.")
                return false
            }
        }

        let pid: pid_t
        let guestEnvironment: [String]
        if let spawnedPid, let environment {
            pid = spawnedPid
            guestEnvironment = environment
        } else {
            // Before registering, which records the working directory it sets.
            Execute().setEnvironmentVariables()
            pid = guest_register_toplevel()
            NSLog("Environment variables set.")
            var current: [String] = []
            var entry = environ
            while let value = entry.pointee {
                current.append(String(cString: value))
                entry += 1
            }
            guestEnvironment = current
        }
        let toplevel = spawnedPid == nil
        if !guest_attach_image(pid, dylibPath, handle, dylibPath) {
            NSLog("Failed to attach process hooks for %@", dylibPath)
        }

        let progName = programName ?? (dylibPath as NSString).lastPathComponent
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(progName)]
        argv.append(contentsOf: arguments.map { strdup($0) })
        
        argv.append(nil)
        
        // Programs that read their arguments via _NSGetArgv (e.g. Rust's std::env::args)
        // would otherwise see the app's own arguments.
        // Lay argv out the way the kernel does (argv, NULL, envp, NULL, apple, NULL):
        // some runtimes, such as Go's, find the environment by walking past argv.
        let argc = Int32(argv.count - 1)
        var vector = argv
        vector.append(contentsOf: guestEnvironment.map { strdup($0) })
        vector.append(nil)
        vector.append(strdup("executable_path=\(executablePath ?? dylibPath)"))
        vector.append(nil)
        let guestArgv = UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>.allocate(capacity: vector.count)
        guestArgv.initialize(from: vector, count: vector.count)
        // main(argc, argv, envp, apple)
        let guestEnvp = guestArgv + Int(argc) + 1
        let guestApple = guestEnvp + guestEnvironment.count + 1
        guest_set_process_info(pid, argc, guestArgv, guestEnvp, executablePath ?? dylibPath)
        
        
        
        let thread = Thread {
            guest_adopt_current_thread(pid)
            NSLog("Executing dylib entry point...")
            let status: Int32
            if let _ = lcmain {
                status = executeEntryPoint(for: dylibPath, argc, guestArgv, guestEnvp, guestApple)
            } else {
                typealias EntryFunc = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32
                let entry = unsafeBitCast(entryPoint, to: EntryFunc.self)
                status = entry(argc, guestArgv, guestEnvp, guestApple)
            }

            guest_entry_returned(pid, status)
            if toplevel {
                guest_restore_signal_handlers()
            }
            NSLog("Dylib execution finished.")
        }

        thread.name = "executable-thread-\(UUID().uuidString)"
        thread.qualityOfService = .userInteractive
        // Match the 8 MB main thread stack programs get on macOS.
        thread.stackSize = max(8 * 1024 * 1024, Int(lcmain?.stackSize ?? 0))

        if toplevel {
            guest_save_signal_handlers()
            if let onExit {
                DispatchQueue.main.async { exitHandlers[pid] = onExit }
            }
        }
        thread.start()
        return true
    }
    
    // NEW: Get TEXT segment base virtual address

    
    func setEnvironmentVariables() {
        let userName = NSUserName()
        let documentsDir = URL.documentsDirectory.path
        let shell = "/bin/bash"
        let hostname = UIDevice.current.hostname ?? "localhost"
        let tmpDir = NSTemporaryDirectory()
        let pathEnv = "\(documentsDir)/homebrew/bin:\(documentsDir)/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\(documentsDir)/bin"
        let launchInstanceID = UUID().uuidString
        let osLogRateLimit = "64"
        let securitySessionID = "18831"
        let termProgram = "maciOS"
        let termProgramVersion = "461"
        let termSessionID = UUID().uuidString
        let xpcFlags = "0x0"
        let xpcServiceName = "0"
        let cfBundleIdentifier = Bundle.main.bundleIdentifier ?? "com.stossy11.maciOS"

        let env: [String: String] = [
            "USER": userName,
            "LOGNAME": userName,
            "HOME": documentsDir,
            "PWD": documentsDir,
            "SHELL": shell,
            "HOSTNAME": hostname,
            "TMPDIR": tmpDir,
            "PATH": pathEnv,
            "LANG": "en_US.UTF-8",
            "LC_CTYPE": "UTF-8",
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "LaunchInstanceID": launchInstanceID,
            "OSLogRateLimit": osLogRateLimit,
            "SECURITYSESSIONID": securitySessionID,
            "TERM_PROGRAM": termProgram,
            "TERM_PROGRAM_VERSION": termProgramVersion,
            "TERM_SESSION_ID": termSessionID,
            "XPC_FLAGS": xpcFlags,
            "XPC_SERVICE_NAME": xpcServiceName,
            "__CFBundleIdentifier": cfBundleIdentifier,
            // The terminal's shell is bash.
            "PS1": "\\u@\\h:\\w\\$ "
        ]

        for (key, value) in env {
            setenv(key, value, 1) // overwrite existing
        }
        
        // Relative paths given to the program should resolve against $HOME, like a shell started there.
        FileManager.default.changeCurrentDirectoryPath(documentsDir)
        
        NSLog("Environment variables set including PS1")
    }
    
    static func getTextSegmentVMAddr(from path: String) -> UInt64? {
        guard let file = fopen(path, "rb") else { return nil }
        defer { fclose(file) }
        
        // Handle universal binaries
        var magic: UInt32 = 0
        fread(&magic, MemoryLayout<UInt32>.size, 1, file)
        fseek(file, 0, SEEK_SET)
        
        var sliceOffset: UInt32 = 0
        
        if magic == 0xcafebabe || magic == 0xbebafeca {
            let needsSwap = magic == 0xbebafeca
            
            struct fat_header {
                var magic: UInt32
                var nfat_arch: UInt32
            }
            struct fat_arch {
                var cputype: Int32
                var cpusubtype: Int32
                var offset: UInt32
                var size: UInt32
                var align: UInt32
            }
            
            var fatHeader = fat_header(magic: 0, nfat_arch: 0)
            fread(&fatHeader, MemoryLayout<fat_header>.size, 1, file)
            
            if needsSwap {
                fatHeader.nfat_arch = fatHeader.nfat_arch.byteSwapped
            }
            
            for _ in 0..<fatHeader.nfat_arch {
                var arch = fat_arch(cputype: 0, cpusubtype: 0, offset: 0, size: 0, align: 0)
                fread(&arch, MemoryLayout<fat_arch>.size, 1, file)
                
                if needsSwap {
                    arch.cputype = arch.cputype.byteSwapped
                    arch.offset = arch.offset.byteSwapped
                }
                
                if arch.cputype == 0x0100000C { // CPU_ARM64
                    sliceOffset = arch.offset
                    break
                }
            }
        }
        
        fseek(file, Int(sliceOffset), SEEK_SET)
        
        // Read Mach-O header
        struct mach_header_64 {
            var magic: UInt32
            var cputype: Int32
            var cpusubtype: Int32
            var filetype: UInt32
            var ncmds: UInt32
            var sizeofcmds: UInt32
            var flags: UInt32
            var reserved: UInt32
        }
        
        var header = mach_header_64(magic: 0, cputype: 0, cpusubtype: 0, filetype: 0, ncmds: 0, sizeofcmds: 0, flags: 0, reserved: 0)
        fread(&header, MemoryLayout<mach_header_64>.size, 1, file)
        
        guard header.magic == 0xfeedfacf else { return nil }
        
        // Iterate load commands to find TEXT segment
        var currentOffset = Int(sliceOffset) + MemoryLayout<mach_header_64>.size
        
        for _ in 0..<header.ncmds {
            fseek(file, currentOffset, SEEK_SET)
            
            struct load_command {
                var cmd: UInt32
                var cmdsize: UInt32
            }
            
            var cmd = load_command(cmd: 0, cmdsize: 0)
            fread(&cmd, MemoryLayout<load_command>.size, 1, file)
            
            if cmd.cmd == 0x19 { // LC_SEGMENT_64
                fseek(file, currentOffset, SEEK_SET)
                
                struct segment_command_64 {
                    var cmd: UInt32
                    var cmdsize: UInt32
                    var segname: (Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8, Int8)
                    var vmaddr: UInt64
                    var vmsize: UInt64
                    var fileoff: UInt64
                    var filesize: UInt64
                    var maxprot: Int32
                    var initprot: Int32
                    var nsects: UInt32
                    var flags: UInt32
                }
                
                var segment = segment_command_64(cmd: 0, cmdsize: 0, segname: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0), vmaddr: 0, vmsize: 0, fileoff: 0, filesize: 0, maxprot: 0, initprot: 0, nsects: 0, flags: 0)
                fread(&segment, MemoryLayout<segment_command_64>.size, 1, file)
                
                // Check if this is the __TEXT segment
                let segmentName = withUnsafePointer(to: &segment.segname) {
                    $0.withMemoryRebound(to: CChar.self, capacity: 16) {
                        String(cString: $0)
                    }
                }
                
                if segmentName == "__TEXT" {
                    return segment.vmaddr
                }
            }
            
            currentOffset += Int(cmd.cmdsize)
        }
        
        return nil
    }

    static func executeEntryPoint(for dylibPath: String, _ argc: Int32, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>, _ apple: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) -> Int32 {
        guard let lcMain = getARM64EntryPoint(from: dylibPath) else {
            NSLog("%@", "LC_MAIN not found.")
            return -1
        }
        
        guard let textVMAddr = getTextSegmentVMAddr(from: dylibPath) else {
            NSLog("%@", "Failed to get TEXT segment vmaddr.")
            return -1
        }
        
        guard let base = getMemoryBase(for: dylibPath) else {
            NSLog("%@", "Failed to retrieve in-memory base address.")
            return -1
        }
        
        // Calculate slide: difference between loaded address and expected vmaddr
        let baseAddr = UInt64(bitPattern: Int64(bitPattern: UInt64(UInt(bitPattern: base))))
        let slide = Int64(bitPattern: baseAddr) - Int64(bitPattern: textVMAddr)
        
        // Calculate actual entry point: TEXT vmaddr + entry offset + slide
        let actualEntryAddr = Int64(bitPattern: textVMAddr) + Int64(lcMain.entryOffset) + slide
        let entryPtr = UnsafeMutableRawPointer(bitPattern: Int(actualEntryAddr))
        
        guard let safeEntryPtr = entryPtr else {
            NSLog("%@", "Invalid entry point address calculated.")
            return -1
        }
        
        NSLog("%@", "TEXT vmaddr: 0x\(String(textVMAddr, radix: 16))")
        NSLog("%@", "Entry offset: 0x\(String(lcMain.entryOffset, radix: 16))")
        NSLog("%@", "Base address: 0x\(String(baseAddr, radix: 16))")
        NSLog("%@", "Slide: 0x\(String(UInt64(bitPattern: slide), radix: 16))")
        NSLog("%@", "Final entry point: 0x\(String(UInt64(bitPattern: actualEntryAddr), radix: 16))")
        typealias EntryFunc = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Int32
        let entryFunc = unsafeBitCast(safeEntryPtr, to: EntryFunc.self)
        return entryFunc(argc, argv, envp, apple)
    }

    // Keep your existing functions unchanged
    static func getSliceOffset(for path: String, desiredCpu: cpu_type_t) -> UInt32? {
        guard let file = fopen(path, "rb") else { return nil }
        defer { fclose(file) }
        
        var magic: UInt32 = 0
        fread(&magic, MemoryLayout<UInt32>.size, 1, file)
        fseek(file, 0, SEEK_SET)
        
        if magic == FAT_MAGIC || magic == FAT_CIGAM {
            var fatHeader = fat_header()
            fread(&fatHeader, MemoryLayout<fat_header>.size, 1, file)
            
            for _ in 0..<fatHeader.nfat_arch {
                var arch = fat_arch()
                fread(&arch, MemoryLayout<fat_arch>.size, 1, file)
                
                if arch.cputype == desiredCpu {
                    return arch.offset
                }
            }
            return nil
        } else {
            // Not a universal binary
            return 0
        }
    }

    static func getARM64EntryPoint(from path: String) -> LCMain? {
        let CPU_ARM64: Int32 = 0x0100000C
        let LC_MAIN: UInt32 = 0x80000028
        let LC_UNIXTHREAD: UInt32 = 0x5
        
        NSLog("%@", "Opening file: \(path)")
        guard let file = fopen(path, "rb") else {
            NSLog("%@", "Failed to open file")
            return nil
        }
        defer { fclose(file) }
        
        // Read first 4 bytes to detect universal binary
        var magic: UInt32 = 0
        fread(&magic, MemoryLayout<UInt32>.size, 1, file)
        fseek(file, 0, SEEK_SET)
        
        var sliceOffset: UInt32 = 0
        
        if magic == 0xcafebabe || magic == 0xbebafeca { // FAT_MAGIC / FAT_CIGAM
            NSLog("%@", "Universal binary detected")
            let needsSwap = magic == 0xbebafeca
            
            struct fat_header {
                var magic: UInt32
                var nfat_arch: UInt32
            }
            struct fat_arch {
                var cputype: Int32
                var cpusubtype: Int32
                var offset: UInt32
                var size: UInt32
                var align: UInt32
            }
            
            var fatHeader = fat_header(magic: 0, nfat_arch: 0)
            fread(&fatHeader, MemoryLayout<fat_header>.size, 1, file)
            
            if needsSwap {
                fatHeader.nfat_arch = fatHeader.nfat_arch.byteSwapped
            }
            
            NSLog("%@", "Number of architectures: \(fatHeader.nfat_arch)")
            var found = false
            for i in 0..<fatHeader.nfat_arch {
                var arch = fat_arch(cputype: 0, cpusubtype: 0, offset: 0, size: 0, align: 0)
                fread(&arch, MemoryLayout<fat_arch>.size, 1, file)
                
                if needsSwap {
                    arch.cputype = arch.cputype.byteSwapped
                    arch.offset = arch.offset.byteSwapped
                }
                
                NSLog("%@", "Arch \(i): cputype=0x\(String(arch.cputype, radix: 16)), offset=\(arch.offset)")
                if arch.cputype == CPU_ARM64 {
                    sliceOffset = arch.offset
                    found = true
                    NSLog("%@", "Selected ARM64 slice at offset \(sliceOffset)")
                    break
                }
            }
            if !found {
                NSLog("%@", "ARM64 slice not found in universal binary")
                return nil
            }
        } else {
            NSLog("%@", "Single-arch binary detected")
        }
        
        // Seek to the Mach-O slice
        fseek(file, Int(sliceOffset), SEEK_SET)
        
        // Read Mach-O header
        struct mach_header_64 {
            var magic: UInt32
            var cputype: Int32
            var cpusubtype: Int32
            var filetype: UInt32
            var ncmds: UInt32
            var sizeofcmds: UInt32
            var flags: UInt32
            var reserved: UInt32
        }
        
        var header = mach_header_64(magic: 0, cputype: 0, cpusubtype: 0, filetype: 0, ncmds: 0, sizeofcmds: 0, flags: 0, reserved: 0)
        fread(&header, MemoryLayout<mach_header_64>.size, 1, file)
        
        guard header.magic == 0xfeedfacf else {
            NSLog("%@", "Not a valid 64-bit Mach-O binary (magic: 0x\(String(header.magic, radix: 16)))")
            return nil
        }
        
        NSLog("%@", "Mach-O header read: ncmds=\(header.ncmds), cputype=0x\(String(header.cputype, radix: 16))")
        // Verify this is actually ARM64
        if header.cputype != CPU_ARM64 {
            NSLog("%@", "Binary is not ARM64 (cputype: 0x\(String(header.cputype, radix: 16)))")
            return nil
        }
        
        // Iterate load commands
        var currentOffset = Int(sliceOffset) + MemoryLayout<mach_header_64>.size
        
        for i in 0..<header.ncmds {
            fseek(file, currentOffset, SEEK_SET)
            
            struct load_command {
                var cmd: UInt32
                var cmdsize: UInt32
            }
            
            var cmd = load_command(cmd: 0, cmdsize: 0)
            fread(&cmd, MemoryLayout<load_command>.size, 1, file)
            
            NSLog("%@", "Load command \(i): cmd=0x\(String(cmd.cmd, radix: 16)), cmdsize=\(cmd.cmdsize)")
            if cmd.cmd == LC_MAIN {
                NSLog("%@", "Found LC_MAIN")
                fseek(file, currentOffset, SEEK_SET)
                
                struct entry_point_command {
                    var cmd: UInt32
                    var cmdsize: UInt32
                    var entryoff: UInt64
                    var stacksize: UInt64
                }
                
                var ep = entry_point_command(cmd: 0, cmdsize: 0, entryoff: 0, stacksize: 0)
                fread(&ep, MemoryLayout<entry_point_command>.size, 1, file)
                
                NSLog("%@", "LC_MAIN: entryOffset=0x\(String(ep.entryoff, radix: 16)), stackSize=0x\(String(ep.stacksize, radix: 16))")
                return LCMain(entryOffset: ep.entryoff, stackSize: ep.stacksize)
            }
            else if cmd.cmd == LC_UNIXTHREAD {
                NSLog("%@", "Found LC_UNIXTHREAD")
                fseek(file, currentOffset + MemoryLayout<load_command>.size, SEEK_SET)
                
                var flavor: UInt32 = 0
                var count: UInt32 = 0
                fread(&flavor, MemoryLayout<UInt32>.size, 1, file)
                fread(&count, MemoryLayout<UInt32>.size, 1, file)
                
                let ARM_THREAD_STATE64: UInt32 = 6
                NSLog("%@", "Thread flavor: \(flavor), count: \(count)")
                if flavor == ARM_THREAD_STATE64 {
                    NSLog("%@", "ARM_THREAD_STATE64 detected")
                    // Skip x0-x29 (30 registers), fp, lr, sp (3 more registers) = 33 * 8 bytes
                    fseek(file, 33 * 8, SEEK_CUR)
                    var pc: UInt64 = 0
                    fread(&pc, MemoryLayout<UInt64>.size, 1, file)
                    NSLog("%@", "LC_UNIXTHREAD: entryOffset=0x\(String(pc, radix: 16))")
                    return LCMain(entryOffset: pc, stackSize: 0)
                }
            }
            
            currentOffset += Int(cmd.cmdsize)
        }
        
        NSLog("%@", "No entry point found")
        return nil
    }

    static func getMemoryBase(for dylibPath: String) -> UnsafeMutableRawPointer? {
        // By full path: copies of a program for different runs share a name,
        // and earlier ones may still be loaded.
        let target = URL(fileURLWithPath: dylibPath).resolvingSymlinksInPath().path
        for i in 0..<_dyld_image_count() {
            guard let nameC = _dyld_get_image_name(i) else { continue }
            let imageName = String(cString: nameC)
            guard imageName == dylibPath || imageName == target,
                  let headerPtr = _dyld_get_image_header(i) else { continue }
            return UnsafeMutableRawPointer(mutating: headerPtr)
        }

        NSLog("%@", "No matching image found")
        return nil
    }

}

@available(iOS 16.0, *)
func containsNSApplication(_ path: String) -> Bool {
    guard let file = fopen(path, "rb") else { return false }
    defer { fclose(file) }
    
    var header = mach_header_64()
    fread(&header, MemoryLayout<mach_header_64>.size, 1, file)
    
    // Very simplified; real-world parsing needs to iterate load commands
    if header.magic != MH_MAGIC_64 { return false }
    
    // Iterate load commands
    fseek(file, 0, SEEK_SET)
    let size = Int(header.sizeofcmds)
    var cmds = [UInt8](repeating: 0, count: size)
    fseek(file, MemoryLayout<mach_header_64>.size, SEEK_SET)
    fread(&cmds, size, 1, file)
    
    let data = Data(cmds)
    return data.withUnsafeBytes { ptr in
        return ptr.contains(NSData(bytes: "_OBJC_CLASS_$_NSApplication", length: 23) as Data)
    }
}

func containsNSApplication15(_ path: String) -> Bool {
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
        return false
    }

    let symbol = "_OBJC_CLASS_$_NSApplication".utf8
    let symbolBytes = Array(symbol)

    let bytes = [UInt8](data)
    let symbolCount = symbolBytes.count
    let dataCount = bytes.count

    guard dataCount >= symbolCount else { return false }

    for i in 0...(dataCount - symbolCount) {
        var match = true
        for j in 0..<symbolCount {
            if bytes[i + j] != symbolBytes[j] {
                match = false
                break
            }
        }
        if match {
            return true
        }
    }

    return false
}


extension UIDevice {
    /// Returns the device's hostname using POSIX gethostname
    var hostname: String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = gethostname(&buffer, Int(NI_MAXHOST))
        if result == 0 {
            return String(cString: buffer)
        } else {
            return nil
        }
    }
}

