//
//  ContentView.swift
//  Interceptor
//
//  Created by devonly on 2025/08/11.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Mudmouth
import SwiftUI
import SwiftyLogger

struct ContentView: View {
    @Environment(\.isFirstLaunch) private var isFirstLaunch: Binding<Bool>
    @State private var isPresented: Bool = false

    var body: some View {
        NavigationView(content: {
            TabView(content: {})
                .toolbar(content: {
                    ToolbarItem(placement: .navigation, content: {
                        Button(action: {
                            isPresented.toggle()
                        }, label: {
                            Image(systemName: "gearshape.fill")
                        })
                    })
                })
                .navigationBarTitleDisplayMode(.inline)
        })
        .fullScreenCover(isPresented: isFirstLaunch, content: {
            FirstLaunchView()
        })
        .fullScreenCover(isPresented: $isPresented, content: {
            SettingsView()
        })
    }
}

#Preview {
    ContentView()
        .environmentIsFirstLaunch()
        .environment(Mudmouth())
}
