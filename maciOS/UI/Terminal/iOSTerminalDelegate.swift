//
//  iOSTerminalDelegate.swift
//  maciOS
//
//  Created by Stossy11 on 24/08/2025.
//

import SwiftUI
import Combine
import SwiftTerm

class iOSTerminalDelegate: NSObject, TerminalViewDelegate, ObservableObject {
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    
    private var stderrPending = Data()
    
    @AppStorage("HideErrorLogs") var hideLogs = true
    
    private var originalStdout: Int32 = -1
    private var originalStderr: Int32 = -1
    
    var terminalView: TerminalView?
    
    override init() {
        super.init()
        setupRedirection()
    }
    
    func setTerminalView(_ terminalView: TerminalView) {
        self.terminalView = terminalView
        let terminal = terminalView.getTerminal()
        // SwiftTerm prints parser diagnostics with print(), which would land on
        // the guest's stdout pipe and be fed back into the terminal.
        terminal.silentLog = true
        updateTerminalSize(rows: UInt16(terminal.rows), cols: UInt16(terminal.cols))
    }
    
    private func setupRedirection() {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe
        
        originalStdout = dup(STDOUT_FILENO)
        originalStderr = dup(STDERR_FILENO)
        
        setvbuf(stdout, nil, _IONBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
        
        dup2(outputPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(errorPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)
        
        vtty_attach_stdin()
        vtty_register_output_fd(STDOUT_FILENO)
        vtty_register_output_fd(STDERR_FILENO)
        vtty_set_echo_handler { [weak self] data in
            self?.feed(data)
        }
        
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.mirror(data, to: self.originalStdout)
            self.feed(vtty_process_output(data))
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.mirror(data, to: self.originalStderr)
            let visible = self.filterHostLogs(data)
            if !visible.isEmpty {
                self.feed(vtty_process_output(visible))
            }
        }
    }
    
    private func mirror(_ data: Data, to fd: Int32) {
        guard fd != -1 else { return }
        _ = data.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress, data.count)
        }
    }
    
    private func feed(_ data: Data) {
        let bytes = [UInt8](data)
        DispatchQueue.main.async { [weak self] in
            self?.terminalView?.feed(byteArray: bytes[...])
        }
    }
    
    /// The host app's own NSLog output also lands on stderr. Drop complete
    /// lines that look like host logs and pass everything else through
    /// untouched, including partial lines such as prompts.
    private func filterHostLogs(_ data: Data) -> Data {
        guard hideLogs else { return data }
        stderrPending.append(data)
        var visible = Data()
        while let newline = stderrPending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = stderrPending[stderrPending.startIndex...newline]
            stderrPending.removeSubrange(stderrPending.startIndex...newline)
            if !isHostLog(String(decoding: line, as: UTF8.self)) {
                visible.append(line)
            }
        }
        if !stderrPending.isEmpty && !isHostLog(String(decoding: stderrPending, as: UTF8.self)) {
            visible.append(stderrPending)
            stderrPending.removeAll()
        }
        return visible
    }
    
    private func isHostLog(_ line: String) -> Bool {
        if line.contains("\(Bundle.main.bundleName)["), line.contains("]"), line.contains(":") { return true }
        if line.contains("OSLOG-"), !line.contains("Failed to load dylib: dlopen") { return true }
        return false
    }
    
    // MARK: - TerminalViewDelegate
    
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        updateTerminalSize(rows: UInt16(newRows), cols: UInt16(newCols))
    }
    
    func setTerminalTitle(source: TerminalView, title: String) {
        // Handle title changes
    }
    
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        // Handle directory changes
    }
    
    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            vtty_receive_input(base, buffer.count)
        }
    }

    func scrolled(source: TerminalView, position: Double) {
        // Handle scrolling
    }
    
    func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {
        if let url = URL(string: link) {
            #if os(iOS)
            UIApplication.shared.open(url)
            #endif
        }
    }
    
    func bell(source: TerminalView) {
        #if os(iOS)
        let impactGenerator = UIImpactFeedbackGenerator(style: .light)
        impactGenerator.impactOccurred()
        #endif
    }
    
    func clipboardCopy(source: TerminalView, content: Data) {
        if let string = String(data: content, encoding: .utf8) {
            #if os(iOS)
            UIPasteboard.general.string = string
            #endif
        }
    }
    
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {
        // Handle iTerm2 specific content
    }
    
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        // Handle visual changes
    }
    
    deinit {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
    }
}

extension Bundle {
    var bundleName: String {
        return object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Unknown"
    }
}
