//
//  RecordsView.swift
//  Interceptor
//
//  Created by devonly on 2025/08/16.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import Mudmouth
import SwiftUI

struct RecordsView: View {
    let group: RecordGroup

    var body: some View {
        List(content: {
            ForEach(group.records, content: { record in
                NavigationLink(destination: {
                    RecordView(record: record)
                }, label: {
                    VStack(alignment: .leading, content: {
                        Text(record.method)
                            .font(.caption)
                            .fontWeight(.bold)
                        Text(record.path)
                            .lineLimit(1)
                    })
                })
            })
        })
        .listStyle(.plain)
        .navigationTitle(group.host)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    HomeView()
}
