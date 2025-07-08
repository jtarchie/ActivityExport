import CoreLocation
import Foundation
import GPXKit
import HealthKit
import SWCompression

@MainActor
class WorkoutExportManager: ObservableObject {
  @Published var isExporting = false
  @Published var progress: Double = 0.0
  @Published var statusMessage = ""
  @Published var errorMessage: String?
  @Published var showingShareSheet = false
  @Published var exportedFileURL: URL?

  private let healthStore = HKHealthStore()
  private let fileManager = FileManager.default

  var isHealthKitAvailable: Bool {
    HKHealthStore.isHealthDataAvailable()
  }

  func exportActivities() async {
    guard isHealthKitAvailable else {
      errorMessage = "HealthKit is not available on this device"
      return
    }

    isExporting = true
    errorMessage = nil
    progress = 0.0
    statusMessage = "Requesting HealthKit permissions..."

    do {
      // Request permissions
      try await requestHealthKitPermissions()

      // Fetch workouts
      statusMessage = "Fetching workouts..."
      let workouts = try await fetchWorkouts()

      if workouts.isEmpty {
        statusMessage = "No workouts found"
        isExporting = false
        return
      }

      // Create temporary directory for GPX files
      let tempDir = createTempDirectory()
      var gpxFiles: [URL] = []

      // Process each workout
      for (index, workout) in workouts.enumerated() {
        statusMessage = "Processing workout \(index + 1) of \(workouts.count)..."
        progress = Double(index) / Double(workouts.count)

        if let gpxFile = await processWorkout(workout, in: tempDir) {
          gpxFiles.append(gpxFile)
        }
      }

      // Create tarball
      statusMessage = "Creating archive..."
      progress = 0.9

      let dateRange = getDateRange(from: workouts)
      let archiveURL = try await createTarball(from: gpxFiles, dateRange: dateRange)

      // Clean up temp files
      try fileManager.removeItem(at: tempDir)

      // Show share sheet
      progress = 1.0
      statusMessage = "Export complete!"
      exportedFileURL = archiveURL
      showingShareSheet = true
      isExporting = false

    } catch {
      errorMessage = "Export failed: \(error.localizedDescription)"
      isExporting = false
    }
  }

  private func requestHealthKitPermissions() async throws {
    let typesToRead: Set<HKObjectType> = [
      HKObjectType.workoutType(),
      HKSeriesType.workoutRoute(),
    ]

    return try await withCheckedThrowingContinuation { continuation in
      healthStore.requestAuthorization(toShare: [], read: typesToRead) { success, error in
        if let error = error {
          continuation.resume(throwing: error)
        } else if success {
          continuation.resume()
        } else {
          continuation.resume(
            throwing: NSError(
              domain: "HealthKit", code: 0,
              userInfo: [NSLocalizedDescriptionKey: "Permission denied"]))
        }
      }
    }
  }

  private func fetchWorkouts() async throws -> [HKWorkout] {
    return try await withCheckedThrowingContinuation { continuation in
      let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)

      let query = HKSampleQuery(
        sampleType: HKObjectType.workoutType(),
        predicate: nil,
        limit: HKObjectQueryNoLimit,
        sortDescriptors: [sortDescriptor]
      ) { query, samples, error in
        if let error = error {
          continuation.resume(throwing: error)
        } else {
          let workouts = samples as? [HKWorkout] ?? []
          continuation.resume(returning: workouts)
        }
      }

      healthStore.execute(query)
    }
  }

  private func processWorkout(_ workout: HKWorkout, in directory: URL) async -> URL? {
    do {
      let route = try await fetchWorkoutRoute(for: workout)
      let locations = try await fetchLocations(for: route)

      if !locations.isEmpty {
        let fileName = generateFileName(for: workout)
        let fileURL = directory.appendingPathComponent(fileName)
        let gpxData = generateGPX(from: locations, workout: workout)

        try gpxData.write(to: fileURL)
        return fileURL
      }
    } catch {
      print("Failed to process workout: \(error)")
    }

    return nil
  }

  private func fetchWorkoutRoute(for workout: HKWorkout) async throws -> HKWorkoutRoute? {
    return try await withCheckedThrowingContinuation { continuation in
      let predicate = HKQuery.predicateForObjects(from: workout)

      let query = HKAnchoredObjectQuery(
        type: HKSeriesType.workoutRoute(),
        predicate: predicate,
        anchor: nil,
        limit: HKObjectQueryNoLimit
      ) { query, samples, deletedObjects, anchor, error in
        if let error = error {
          continuation.resume(throwing: error)
        } else {
          let routes = samples as? [HKWorkoutRoute] ?? []
          continuation.resume(returning: routes.first)
        }
      }

      healthStore.execute(query)
    }
  }

  private func fetchLocations(for route: HKWorkoutRoute?) async throws -> [CLLocation] {
    guard let route = route else { return [] }

    return try await withCheckedThrowingContinuation { continuation in
      var allLocations: [CLLocation] = []

      let query = HKWorkoutRouteQuery(route: route) { query, locations, done, error in
        if let error = error {
          continuation.resume(throwing: error)
          return
        }

        if let locations = locations {
          allLocations.append(contentsOf: locations)
        }

        if done {
          continuation.resume(returning: allLocations)
        }
      }

      healthStore.execute(query)
    }
  }

  private func generateFileName(for workout: HKWorkout) -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd-HHmm"
    let dateString = dateFormatter.string(from: workout.startDate)

    let activityType = workout.workoutActivityType.displayName
    return "\(activityType)-\(dateString).gpx"
  }

  private func generateGPX(from locations: [CLLocation], workout: HKWorkout) -> Data {
    // Convert CLLocations to TrackPoints
    let trackPoints = locations.map { location in
      TrackPoint(
        coordinate: Coordinate(
          latitude: location.coordinate.latitude,
          longitude: location.coordinate.longitude,
          elevation: location.altitude
        ),
        date: location.timestamp
      )
    }

    // Create GPX track with required parameters
    let track = GPXTrack(
      date: workout.startDate,
      title:
        "\(workout.workoutActivityType.displayName) - \(DateFormatter.localizedString(from: workout.startDate, dateStyle: .short, timeStyle: .short))",
      description: "Exported from HealthKit workout data",
      trackPoints: trackPoints,
      type: workout.workoutActivityType.displayName.lowercased()
    )

    // Create GPX exporter
    let exporter = GPXExporter(track: track, creatorName: "ActivityExport")

    // Return the XML string as Data
    return exporter.xmlString.data(using: .utf8) ?? Data()
  }

  private func createTempDirectory() -> URL {
    let tempDir = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try? fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
    return tempDir
  }

  private func getDateRange(from workouts: [HKWorkout]) -> String {
    guard !workouts.isEmpty else { return "no-workouts" }

    let sortedWorkouts = workouts.sorted { $0.startDate < $1.startDate }
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"

    let startDate = dateFormatter.string(from: sortedWorkouts.first!.startDate)
    let endDate = dateFormatter.string(from: sortedWorkouts.last!.startDate)

    return startDate == endDate ? startDate : "\(startDate)-to-\(endDate)"
  }

  private func createTarball(from files: [URL], dateRange: String) async throws -> URL {
    let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
    let archiveURL = documentsURL.appendingPathComponent("activities-\(dateRange).tar.gz")

    // Remove existing file if it exists
    try? fileManager.removeItem(at: archiveURL)

    // Create tar archive
    var tarData = Data()

    for fileURL in files {
      let fileData = try Data(contentsOf: fileURL)
      let fileName = fileURL.lastPathComponent

      // Create tar entry
      let tarEntry = try TarContainer.create(
        from: [TarEntry(info: TarEntryInfo(name: fileName, type: .regular), data: fileData)]
      )
      tarData.append(tarEntry)
    }

    // Compress with gzip
    let compressedData = try GzipArchive.archive(data: tarData)
    try compressedData.write(to: archiveURL)

    return archiveURL
  }
}

extension HKWorkoutActivityType {
  var displayName: String {
    switch self {
    case .running: return "Running"
    case .walking: return "Walking"
    case .cycling: return "Cycling"
    case .swimming: return "Swimming"
    case .hiking: return "Hiking"
    case .yoga: return "Yoga"
    case .functionalStrengthTraining: return "Strength"
    case .traditionalStrengthTraining: return "Weight-Training"
    case .crossTraining: return "Cross-Training"
    case .elliptical: return "Elliptical"
    case .rowing: return "Rowing"
    case .stairs: return "Stairs"
    case .stepTraining: return "Step-Training"
    case .tennis: return "Tennis"
    case .basketball: return "Basketball"
    case .soccer: return "Soccer"
    case .golf: return "Golf"
    default: return "Workout"
    }
  }
}
