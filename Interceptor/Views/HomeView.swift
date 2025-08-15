//
//  HomeView.swift
//  Interceptor
//
//  Created by devonly on 2025/08/16.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import CoreData
import Mudmouth
import SwiftUI
import SwiftyLogger

struct HomeView: View {
    @State private var isPresented: Bool = false

    var body: some View {
        List(content: {})
            .navigationTitle(Text("TITLE_HOME"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: {
                ToolbarItem(placement: .topBarLeading, content: {
                    Button(action: {
                        isPresented.toggle()
                    }, label: {
                        Image(systemName: "trash.fill")
                    })
                    .confirmationDialog(NSLocalizedString("LABEL_CLEAR_REQUESTS", comment: ""), isPresented: $isPresented, actions: {
                        Button(role: .destructive, action: {}, label: {
                            Text("LABEL_CLEAR")
                        })
                    }, message: {
                        Text("LABEL_CLEAR_REQUESTS_DESC")
                    })
                })
            })
    }
}

#Preview {
    HomeView()
}
