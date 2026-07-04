//
//  WhiskyWineDownloadView.swift
//  Whisky
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import SwiftUI
import WhiskyKit

struct WhiskyWineDownloadView: View {
    @State private var completedBytes: Int64 = 0
    @State private var totalBytes: Int64 = 0
    @State private var downloadSpeed: Double = 0
    @State private var startTime: Date?
    @State private var downloadError: String?
    @State private var isDownloading = true
    @Binding var tarLocation: URL
    @Binding var path: [SetupStage]

    private var clampedProgress: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(completedBytes) / Double(totalBytes), 0), 1)
    }

    var body: some View {
        VStack {
            VStack {
                Text("setup.whiskywine.download")
                    .font(.title)
                    .fontWeight(.bold)
                Text("setup.whiskywine.download.subtitle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                if let downloadError {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundStyle(.orange)
                        Text(downloadError)
                            .font(.subheadline)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        Button("Try Again") {
                            startDownload()
                        }
                    }
                } else if isDownloading {
                    VStack {
                        if totalBytes > 0 {
                            ProgressView(value: clampedProgress)
                        } else {
                            ProgressView()
                        }
                        HStack {
                            HStack {
                                Text(String(format: String(localized: "setup.whiskywine.progress"),
                                            formatBytes(bytes: completedBytes),
                                            formatBytes(bytes: totalBytes)))
                                + Text(String(" "))
                                + (shouldShowEstimate() ?
                                   Text(String(format: String(localized: "setup.whiskywine.eta"),
                                               formatRemainingTime(remainingBytes: totalBytes - completedBytes)))
                                   : Text(String()))
                                Spacer()
                            }
                            .font(.subheadline)
                            .monospacedDigit()
                        }
                    }
                    .padding(.horizontal)
                }
                Spacer()
            }
            Spacer()
        }
        .frame(width: 400, height: 200)
        .onAppear {
            startDownload()
        }
    }

    func startDownload() {
        downloadError = nil
        isDownloading = true
        completedBytes = 0
        totalBytes = 0
        startTime = Date()

        Task {
            do {
                let url = try await WhiskyWineInstaller.downloadLibraries { received, expected in
                    Task { @MainActor in
                        let currentTime = Date()
                        let elapsedTime = currentTime.timeIntervalSince(startTime ?? currentTime)
                        if received > 0, elapsedTime > 0 {
                            downloadSpeed = Double(received) / elapsedTime
                        }
                        if expected > 0 {
                            totalBytes = expected
                        }
                        completedBytes = received
                    }
                }
                await MainActor.run {
                    tarLocation = url
                    isDownloading = false
                    proceed()
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadError = error.localizedDescription
                }
            }
        }
    }

    func formatBytes(bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.zeroPadsFractionDigits = true
        return formatter.string(fromByteCount: bytes)
    }

    func shouldShowEstimate() -> Bool {
        let elapsedTime = Date().timeIntervalSince(startTime ?? Date())
        return Int(elapsedTime.rounded()) > 5 && completedBytes != 0 && totalBytes > 0
    }

    func formatRemainingTime(remainingBytes: Int64) -> String {
        guard downloadSpeed > 0, remainingBytes > 0 else { return "" }
        let remainingTimeInSeconds = Double(remainingBytes) / downloadSpeed

        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .full
        if shouldShowEstimate() {
            return formatter.string(from: TimeInterval(remainingTimeInSeconds)) ?? ""
        } else {
            return ""
        }
    }

    func proceed() {
        path.append(.whiskyWineInstall)
    }
}
