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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        List(content: {
            ForEach(group.records.reversed(), content: { record in
                NavigationLink(destination: {
                    RecordView(record: record)
                }, label: {
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
                        : AnyLayout(HStackLayout(spacing: 4))
                    VStack(alignment: .leading, spacing: 2, content: {
                        layout {
                            Circle()
                                .fill(record.foregroundColor)
                                .frame(width: 12, height: 12)
                                .overlay { Circle().strokeBorder(.primary, lineWidth: 1) }
                                .accessibilityHidden(true)
                            Text(record.method)
                                .font(.subheadline)
                                .fontWeight(.bold)
                                .foregroundStyle(.primary)
                            Text(record.code, format: .number)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Text(record.phrase)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(record.path)
                            .font(.body)
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                            .truncationMode(.middle)
                    })
                    .padding(.vertical, 4)
                    .accessibilityElement(children: .combine)
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
