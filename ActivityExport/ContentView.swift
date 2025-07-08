//
//  ContentView.swift
//  ActivityExport
//
//  Created by JT Archie on 7/7/25.
//

import HealthKit
import SwiftUI

struct ContentView: View {
  @StateObject private var exportManager = WorkoutExportManager()

  var body: some View {
    NavigationView {
      VStack(spacing: 20) {
        Spacer()

        Image(systemName: "figure.run")
          .font(.system(size: 80))
          .foregroundColor(.blue)

        Text("Activity Export")
          .font(.largeTitle)
          .fontWeight(.bold)

        Text("Export your workout activities as GPX files")
          .font(.body)
          .foregroundColor(.secondary)
          .multilineTextAlignment(.center)

        Spacer()

        if exportManager.isExporting {
          VStack(spacing: 16) {
            ProgressView(value: exportManager.progress, total: 1.0)
              .progressViewStyle(LinearProgressViewStyle())

            Text(exportManager.statusMessage)
              .font(.caption)
              .foregroundColor(.secondary)

            Text("\(Int(exportManager.progress * 100))% Complete")
              .font(.headline)
          }
          .padding()
        } else {
          Button(action: {
            Task {
              await exportManager.exportActivities()
            }
          }) {
            HStack {
              Image(systemName: "square.and.arrow.up")
              Text("Export Activities")
            }
            .font(.headline)
            .foregroundColor(.white)
            .padding()
            .background(Color.blue)
            .cornerRadius(10)
          }
          .disabled(!exportManager.isHealthKitAvailable)
        }

        if let errorMessage = exportManager.errorMessage {
          Text(errorMessage)
            .foregroundColor(.red)
            .font(.caption)
            .padding()
        }

        Spacer()
      }
      .padding()
      .navigationTitle("Activity Export")
      .sheet(isPresented: $exportManager.showingShareSheet) {
        if let fileURL = exportManager.exportedFileURL {
          ShareSheet(items: [fileURL])
        }
      }
    }
  }
}

struct ShareSheet: UIViewControllerRepresentable {
  let items: [Any]

  func makeUIViewController(context: Context) -> UIActivityViewController {
    UIActivityViewController(activityItems: items, applicationActivities: nil)
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
  ContentView()
}
