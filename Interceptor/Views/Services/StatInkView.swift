//
//  StatInkView.swift
//  Interceptor
//
//  Created by devonly on 2025/08/14.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import SwiftUI

struct StatInkView: View {
    @State private var apiKey: String = ""
    
    var body: some View {
        Form(content: {
            Button(action: {
                UIApplication.shared.open(URL(string: "https://stat.ink/profile")!)
            }, label: {
                Text("BUTTON_API_KEY")
            })
            SecureField(text: $apiKey, prompt: Text("FIELD_API_KEY"), label: {
                Text("FIELD_API_KEY")
            })
        })
        .navigationTitle(Text("TITLE_SERVICE_STATINK"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationView(content: {
        StatInkView()
    })
}
