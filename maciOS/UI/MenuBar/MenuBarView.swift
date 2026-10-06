//
//  MenuBarView.swift
//  maciOS
//
//  Created by Stossy11 on 31/08/2025.
//

import SwiftUI
import UniformTypeIdentifiers

struct MenuBarView: View {
    @Binding var machO: [MachOPatcher]
    @AppStorage("HideErrorLogs") var hideLogs = true
    
    var body: some View {
        VStack {
            HStack {
                Button {
                    FileImporterManager.shared.importFiles(types: [.item]) { result in
                        switch result {
                        case .success(let urls):
                            machO.append(Execute.launch(executable: urls.first!))
                        case .failure(_):
                            break
                        }
                    }
                } label: {
                    Label("Run Executable", systemImage: "bolt")
                }
                
                Button {
                    hideLogs.toggle()
                } label: {
                    if hideLogs {
                        Label("Show App Logs", systemImage: "cog")
                    } else {
                        Label("Hide App Logs", systemImage: "cog")
                    }
                }
            }
            
            Spacer()
        }
        
    }
}
