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
    var body: some View {
        TabView(content: {})
            .fullScreenCover(isPresented: .constant(true), content: {
                FirstLaunchView()
            })
    }
}

#Preview {
    ContentView()
}
