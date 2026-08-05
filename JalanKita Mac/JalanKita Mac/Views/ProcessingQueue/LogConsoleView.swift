//
//  LogConsoleView.swift
//  JalanKita Mac
//

import SwiftUI

struct LogConsoleView: View {
    let lines: [LogLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("LOG").font(.caption2.weight(.bold)).tracking(0.6).foregroundStyle(.white.opacity(0.6))
                Spacer()
                Text("mengikuti keluaran").font(.caption2).foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider().overlay(Color.white.opacity(0.1))

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Text(line.time)
                                .foregroundStyle(.white.opacity(0.4))
                            Text(line.message)
                                .foregroundStyle(line.isWarning ? Color.yellow.opacity(0.85) : .white.opacity(0.85))
                        }
                        .font(.data(11.5))
                    }
                }
                .padding(14)
            }
        }
        .background(Color.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 10))
    }
}
