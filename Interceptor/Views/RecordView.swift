//
//  RecordView.swift
//  Interceptor
//
//  Created by devonly on 2025/08/16.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import Mudmouth
import SwiftUI

struct RecordView: View {
    let record: Record
    @State private var isExpanded: Bool = true

    var body: some View {
        List(content: {
            DisclosureGroup(isExpanded: $isExpanded, content: {
                ForEach(record.headers, id: \.self, content: { header in
                    VStack(alignment: .leading, content: {
                        Text(header.key)
                        Text(header.value)
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    })
                    .padding(0)
                })
                .listRowSeparator(.visible)
            }, label: {
                Text("LABEL_RECORD_HEADER")
                    .font(.title2)
                    .fontWeight(.bold)
            })
            .listRowSeparator(.hidden)
        })
        .onAppear(perform: {
            print(record.headers)
        })
        .listStyle(.plain)
        .navigationTitle(record.path)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    HomeView()
}
