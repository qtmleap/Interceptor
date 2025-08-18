//
//  RecordsView.swift
//  Interceptor
//
//  Created by devonly on 2025/08/16.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import Mudmouth
import NIOHTTP1
import SwiftUI
@_spi(Advanced) import SwiftUIIntrospect

struct RecordsView: View {
    let group: RecordGroup

    var body: some View {
        List(content: {
            ForEach(group.records.reversed(), content: { record in
                NavigationLink(destination: {
                    RecordView(record: record)
                }, label: {
                    VStack(alignment: .leading, spacing: 0, content: {
                        HStack(spacing: 4, content: {
                            Circle()
                                .fill(record.foregroundColor)
                                .frame(width: 12, height: 12)
                            Text(record.method)
                                .font(.system(size: 14))
                                .fontWeight(.bold)
                                .foregroundStyle(record.foregroundColor)
                            Text(record.code, format: .number)
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                            Text(record.phrase)
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        })
                        Text(record.path)
                            .lineLimit(1)
                    })
                    .padding(1)
                })
            })
        })
        .listStyle(.plain)
        .navigationTitle(group.host)
        .navigationBarTitleDisplayMode(.inline)
    }
}

extension Record {
    var foregroundColor: Color {
        switch method {
            case HTTPMethod.GET.rawValue:
                .blue
            case HTTPMethod.POST.rawValue:
                .green
            case HTTPMethod.PATCH.rawValue:
                .orange
            case HTTPMethod.PUT.rawValue:
                .pink
            case HTTPMethod.DELETE.rawValue:
                .red
            default:
                .primary
        }
    }
}

#Preview {
    NavigationView(content: {
        RecordsView(group: .init())
    })
    .introspect(.navigationSplitView, on: .iOS(.v17...), customize: { controller in
        controller.preferredDisplayMode = .oneBesideSecondary
        controller.preferredSplitBehavior = .displace
        controller.presentsWithGesture = false
    })
}
