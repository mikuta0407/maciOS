//
//  maciOSApp.swift
//  maciOS
//
//  Created by Stossy11 on 22/08/2025.
//

import SwiftUI
import CoreGraphics
import Combine
import UIKit

@main
struct maciOSApp: App {
    @StateObject private var mouse = MouseTracker.shared
    @State var cursor = UIImage()

    init() {
        // On a device NSLog only reaches the system log; send it to stderr too,
        // so it shows in the app logs and Documents/maciOS.log.
        setenv("CFLOG_FORCE_STDERR", "1", 1)
        maciOS_trace_start()
        maciOS_trace_line("app: started")
        Self.raiseFileLimit()
        // Before any view appears: the terminal's shell is loaded from
        // ContentView's onAppear, which runs before this scene's.
        setenv("LC_HOME_PATH", getenv("HOME"), 1)
        #if !targetEnvironment(simulator)
        init_bypassDyldLibValidation()
        #endif
    }
    
    /// Guests share the app's descriptors, and the default soft limit on a
    /// device is 256. The kernel still allows at most OPEN_MAX (10240), and
    /// guests are kept below that (guest_keep_fd in GuestSpawn.m). The
    /// highest soft limit it takes is not readable (sysctl is denied), so try
    /// large ones first.
    private static func raiseFileLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let before = limit.rlim_cur
        for candidate: rlim_t in [1 << 20, 262_144, 65_536, 32_768, 24_576, 16_384, 10_240] where candidate > before {
            var raised = limit
            raised.rlim_cur = min(candidate, limit.rlim_max)
            if setrlimit(RLIMIT_NOFILE, &raised) == 0 { break }
        }
        getrlimit(RLIMIT_NOFILE, &limit)
        maciOS_trace_line("app: open file limit \(before) -> \(limit.rlim_cur)")
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .padding(.top)
                .overlay {
                    
                    if mouse.shown {
                        GeometryReader { geo in
                            ZStack {
                                Image(uiImage: cursor)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 30, height: 30)
                                    .position(
                                        x: mouse.location.x - geo.frame(in: .global).minX,
                                        y: mouse.location.y - geo.frame(in: .global).minY
                                    )
                                    .offset(x: 15, y: 15)
                            }
                        }
                    }
                }
                .onAppear {
                    maciOS_trace_line("app: window appeared")
                    
                    let binURL = URL.documentsDirectory.appendingPathComponent("bin")
                    try? FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: false)
                }
                .onAppear {
                    if let window = UIApplication.shared.connectedScenes
                        .compactMap({ $0 as? UIWindowScene })
                        .first?.windows.first {
                        MouseTracker.shared.attach(to: window)
                    }

                    let cursorImage = UIImage(named: "Normal") ?? UIImage()
                    cursor = cursorImage

                    // show overlay window
                    CursorWindow.shared.makeKeyAndVisible()
                    
                    // hook mouse updates
                    MouseTracker.shared.onMove = { point in
                        CursorWindow.shared.updateCursor(image: cursorImage, at: point)
                    }
                    
                    NSWindowController.description()
                }
        }
    }
}

class CursorWindow: UIWindow {
    static let shared = CursorWindow()

    private let cursorView = UIImageView()

    private init() {
        // Created from onAppear, by which point the app's window scene is connected.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
        super.init(windowScene: scene)
        windowLevel = .alert + 1   // ensures it's above alerts
        backgroundColor = .clear
        isHidden = false
        isUserInteractionEnabled = false

        cursorView.contentMode = .scaleAspectFit
        cursorView.frame.size = CGSize(width: 30, height: 30)
        addSubview(cursorView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateCursor(image: UIImage, at point: CGPoint) {
        cursorView.image = image
        cursorView.center = point
    }
}


class MouseTracker: NSObject, ObservableObject, UIGestureRecognizerDelegate {
    static let shared = MouseTracker()
    let coordinator = Coordinator()
    
    @Published var shown = false
    @Published var location: CGPoint = .zero
    @Published var onMove: (CGPoint) -> Void = { _ in }
    
    private var lastLocation: CGPoint = .zero
    
    func attach(to window: UIWindow) {
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(handleMouse(_:)))
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleMouse(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        let pointerInteraction = UIPointerInteraction(delegate: coordinator)
        
        hover.delegate = self
        pan.delegate = self
        
        window.addGestureRecognizer(hover)
        window.addGestureRecognizer(pan)
        window.addInteraction(pointerInteraction)
    }
    
    @objc private func handleMouse(_ gesture: UIGestureRecognizer) {
        guard let view = gesture.view else { return }
        let loc = gesture.location(in: view)
        
        if let gesture = gesture as? UIHoverGestureRecognizer {
            shown = gesture.state != .cancelled
        }
        
        onMove(loc)
        
        self.location = loc
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
    
    class Coordinator: NSObject, UIPointerInteractionDelegate {
        func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
            return UIPointerStyle.hidden()
        }
    }
}

struct NonRetinaScalingModifier: ViewModifier {
    func body(content: Content) -> some View {
        GeometryReader { geometry in
            let bounds = geometry.size
            let screen = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
            let native = screen?.nativeBounds.size ?? bounds
            let nativeScale = screen?.nativeScale ?? 1
            
            let targetWidthPoints = native.width / nativeScale
            let targetHeightPoints = native.height / nativeScale
            
            let scaleFactor = min(bounds.width / targetWidthPoints,
                                  bounds.height / targetHeightPoints)
            
            content
                .frame(width: targetWidthPoints, height: targetHeightPoints)
                .scaleEffect(scaleFactor)
                .position(x: bounds.width / 2, y: bounds.height / 2) // center
        }
        
    }
}


func mach_task_self() -> mach_port_t {
    return mach_task_self_
}


