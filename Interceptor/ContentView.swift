//
//  ContentView.swift
//  Interceptor
//
//  Created by devonly on 2025/08/11.
//  Copyright © 2025 QuantumLeap, Corporation. All rights reserved.
//

import Mudmouth
import QuantumLeap
import SwiftUI

struct ContentView: View {
    @Environment(\.isFirstLaunch) private var isFirstLaunch
    var body: some View {
        TabView(content: {})
            .fullScreenCover(isPresented: .constant(true), content: {
                ConfigurationView()
            })
    }
}

#Preview {
    ContentView()
}
