//
//  Services.swift
//  Interceptor
//
//  Created by devonly on 2025/08/14.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import SwiftUI

struct Services: View {
    var body: some View {
        Section(content: {
            NavigationLink(destination: {
                EmptyView()
            }, label: {
                LabeledContent(content: {
                    Text("stat.ink")
                }, label: {
                    Text("stat.ink")
                })
            })
        }, header: {
            Text("HEADER_LINK_SERVICES")
        }, footer: {
            Text("FOOTER_LINK_SERVICES")
        })
    }
}

#Preview {
    NavigationView(content: {
        Form(content: {
            Services()
        })
    })
}
