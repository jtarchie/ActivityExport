import CoreLocation
import Foundation
import GPXKit
import HealthKit
import SWCompression

/// Structure to hold all workout-related sample data
struct WorkoutSampleData {
  let heartRate: [HKQuantitySample]
  let activeEnergy: [HKQuantitySample]
  let basalEnergy: [HKQuantitySample]
  let distance: [HKQuantitySample]
  let cyclingDistance: [HKQuantitySample]
  let swimmingDistance: [HKQuantitySample]
  let steps: [HKQuantitySample]
  let runningSpeed: [HKQuantitySample]
  let runningPower: [HKQuantitySample]
  let strideLength: [HKQuantitySample]
  let verticalOscillation: [HKQuantitySample]
  let groundContactTime: [HKQuantitySample]
  let cyclingSpeed: [HKQuantitySample]
  let cyclingPower: [HKQuantitySample]
  let cyclingCadence: [HKQuantitySample]
  let strokeCount: [HKQuantitySample]
  let temperature: [HKQuantitySample]
  let audioExposure: [HKQuantitySample]
  let altitude: [HKQuantitySample]
  let respiratoryRate: [HKQuantitySample]
  let vo2Max: [HKQuantitySample]
  let flightsClimbed: [HKQuantitySample]
  let walkingAsymmetry: [HKQuantitySample]
  let walkingDoubleSupportPercentage: [HKQuantitySample]
  let walkingStepLength: [HKQuantitySample]
  let sixMinuteWalkTestDistance: [HKQuantitySample]
  let stairAscentSpeed: [HKQuantitySample]
  let stairDescentSpeed: [HKQuantitySample]
}

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
    let typesToRead: Set<HKObjectType> = Set(
      [
        HKObjectType.workoutType(),
        HKSeriesType.workoutRoute(),
        HKQuantityType.quantityType(forIdentifier: .heartRate),
        HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned),
        HKQuantityType.quantityType(forIdentifier: .basalEnergyBurned),
        HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning),
        HKQuantityType.quantityType(forIdentifier: .distanceCycling),
        HKQuantityType.quantityType(forIdentifier: .distanceSwimming),
        HKQuantityType.quantityType(forIdentifier: .stepCount),
        HKQuantityType.quantityType(forIdentifier: .runningSpeed),
        HKQuantityType.quantityType(forIdentifier: .runningPower),
        HKQuantityType.quantityType(forIdentifier: .runningStrideLength),
        HKQuantityType.quantityType(forIdentifier: .runningVerticalOscillation),
        HKQuantityType.quantityType(forIdentifier: .runningGroundContactTime),
        HKQuantityType.quantityType(forIdentifier: .cyclingSpeed),
        HKQuantityType.quantityType(forIdentifier: .cyclingPower),
        HKQuantityType.quantityType(forIdentifier: .cyclingCadence),
        HKQuantityType.quantityType(forIdentifier: .swimmingStrokeCount),
        HKQuantityType.quantityType(forIdentifier: .bodyTemperature),
        HKQuantityType.quantityType(forIdentifier: .environmentalAudioExposure),
        HKQuantityType.quantityType(forIdentifier: .flightsClimbed),
        HKQuantityType.quantityType(forIdentifier: .respiratoryRate),
        HKQuantityType.quantityType(forIdentifier: .vo2Max),
        HKQuantityType.quantityType(forIdentifier: .walkingAsymmetryPercentage),
        HKQuantityType.quantityType(forIdentifier: .walkingDoubleSupportPercentage),
        HKQuantityType.quantityType(forIdentifier: .walkingStepLength),
        HKQuantityType.quantityType(forIdentifier: .sixMinuteWalkTestDistance),
        HKQuantityType.quantityType(forIdentifier: .stairAscentSpeed),
        HKQuantityType.quantityType(forIdentifier: .stairDescentSpeed),
      ].compactMap { $0 })

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
      let workoutSamples = await fetchWorkoutSamples(for: workout)
      let workoutEvents = await fetchWorkoutEvents(for: workout)

      if !locations.isEmpty {
        let fileName = generateFileName(for: workout)
        let fileURL = directory.appendingPathComponent(fileName)
        let gpxData = generateEnhancedGPX(
          from: locations, workout: workout, samples: workoutSamples, events: workoutEvents)

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

  /// Fetch all available workout-related samples during the workout timeframe
  private func fetchWorkoutSamples(for workout: HKWorkout) async -> WorkoutSampleData {
    let startDate = workout.startDate
    let endDate = workout.endDate
    let predicate = HKQuery.predicateForSamples(
      withStart: startDate, end: endDate, options: .strictStartDate)

    // Define all the sample types we want to fetch
    let sampleTypes: [HKQuantityTypeIdentifier] = [
      .heartRate, .activeEnergyBurned, .basalEnergyBurned, .distanceWalkingRunning,
      .distanceCycling, .distanceSwimming, .stepCount, .runningSpeed, .runningPower,
      .runningStrideLength, .runningVerticalOscillation, .runningGroundContactTime,
      .cyclingSpeed, .cyclingPower, .cyclingCadence, .swimmingStrokeCount,
      .bodyTemperature, .environmentalAudioExposure, .flightsClimbed, .respiratoryRate,
      .vo2Max, .walkingAsymmetryPercentage, .walkingDoubleSupportPercentage,
      .walkingStepLength, .sixMinuteWalkTestDistance, .stairAscentSpeed, .stairDescentSpeed,
    ]

    async let heartRateTask = fetchQuantitySamples(for: .heartRate, predicate: predicate)
    async let activeEnergyTask = fetchQuantitySamples(
      for: .activeEnergyBurned, predicate: predicate)
    async let basalEnergyTask = fetchQuantitySamples(for: .basalEnergyBurned, predicate: predicate)
    async let distanceTask = fetchQuantitySamples(
      for: .distanceWalkingRunning, predicate: predicate)
    async let cyclingDistanceTask = fetchQuantitySamples(
      for: .distanceCycling, predicate: predicate)
    async let swimmingDistanceTask = fetchQuantitySamples(
      for: .distanceSwimming, predicate: predicate)
    async let stepsTask = fetchQuantitySamples(for: .stepCount, predicate: predicate)
    async let runningSpeedTask = fetchQuantitySamples(for: .runningSpeed, predicate: predicate)
    async let runningPowerTask = fetchQuantitySamples(for: .runningPower, predicate: predicate)
    async let strideLengthTask = fetchQuantitySamples(
      for: .runningStrideLength, predicate: predicate)
    async let verticalOscillationTask = fetchQuantitySamples(
      for: .runningVerticalOscillation, predicate: predicate)
    async let groundContactTimeTask = fetchQuantitySamples(
      for: .runningGroundContactTime, predicate: predicate)
    async let cyclingSpeedTask = fetchQuantitySamples(for: .cyclingSpeed, predicate: predicate)
    async let cyclingPowerTask = fetchQuantitySamples(for: .cyclingPower, predicate: predicate)
    async let cyclingCadenceTask = fetchQuantitySamples(for: .cyclingCadence, predicate: predicate)
    async let strokeCountTask = fetchQuantitySamples(
      for: .swimmingStrokeCount, predicate: predicate)
    async let temperatureTask = fetchQuantitySamples(for: .bodyTemperature, predicate: predicate)
    async let audioExposureTask = fetchQuantitySamples(
      for: .environmentalAudioExposure, predicate: predicate)
    async let altitudeTask = fetchQuantitySamples(for: .distanceSwimming, predicate: predicate)  // Using as placeholder
    async let respiratoryRateTask = fetchQuantitySamples(
      for: .respiratoryRate, predicate: predicate)
    async let vo2MaxTask = fetchQuantitySamples(for: .vo2Max, predicate: predicate)
    async let flightsClimbedTask = fetchQuantitySamples(for: .flightsClimbed, predicate: predicate)
    async let walkingAsymmetryTask = fetchQuantitySamples(
      for: .walkingAsymmetryPercentage, predicate: predicate)
    async let walkingDoubleSupportTask = fetchQuantitySamples(
      for: .walkingDoubleSupportPercentage, predicate: predicate)
    async let walkingStepLengthTask = fetchQuantitySamples(
      for: .walkingStepLength, predicate: predicate)
    async let sixMinuteWalkTestTask = fetchQuantitySamples(
      for: .sixMinuteWalkTestDistance, predicate: predicate)
    async let stairAscentSpeedTask = fetchQuantitySamples(
      for: .stairAscentSpeed, predicate: predicate)
    async let stairDescentSpeedTask = fetchQuantitySamples(
      for: .stairDescentSpeed, predicate: predicate)

    let results = await (
      heartRate: heartRateTask,
      activeEnergy: activeEnergyTask,
      basalEnergy: basalEnergyTask,
      distance: distanceTask,
      cyclingDistance: cyclingDistanceTask,
      swimmingDistance: swimmingDistanceTask,
      steps: stepsTask,
      runningSpeed: runningSpeedTask,
      runningPower: runningPowerTask,
      strideLength: strideLengthTask,
      verticalOscillation: verticalOscillationTask,
      groundContactTime: groundContactTimeTask,
      cyclingSpeed: cyclingSpeedTask,
      cyclingPower: cyclingPowerTask,
      cyclingCadence: cyclingCadenceTask,
      strokeCount: strokeCountTask,
      temperature: temperatureTask,
      audioExposure: audioExposureTask,
      altitude: altitudeTask,
      respiratoryRate: respiratoryRateTask,
      vo2Max: vo2MaxTask,
      flightsClimbed: flightsClimbedTask,
      walkingAsymmetry: walkingAsymmetryTask,
      walkingDoubleSupport: walkingDoubleSupportTask,
      walkingStepLength: walkingStepLengthTask,
      sixMinuteWalkTest: sixMinuteWalkTestTask,
      stairAscentSpeed: stairAscentSpeedTask,
      stairDescentSpeed: stairDescentSpeedTask
    )

    return WorkoutSampleData(
      heartRate: results.heartRate,
      activeEnergy: results.activeEnergy,
      basalEnergy: results.basalEnergy,
      distance: results.distance,
      cyclingDistance: results.cyclingDistance,
      swimmingDistance: results.swimmingDistance,
      steps: results.steps,
      runningSpeed: results.runningSpeed,
      runningPower: results.runningPower,
      strideLength: results.strideLength,
      verticalOscillation: results.verticalOscillation,
      groundContactTime: results.groundContactTime,
      cyclingSpeed: results.cyclingSpeed,
      cyclingPower: results.cyclingPower,
      cyclingCadence: results.cyclingCadence,
      strokeCount: results.strokeCount,
      temperature: results.temperature,
      audioExposure: results.audioExposure,
      altitude: results.altitude,
      respiratoryRate: results.respiratoryRate,
      vo2Max: results.vo2Max,
      flightsClimbed: results.flightsClimbed,
      walkingAsymmetry: results.walkingAsymmetry,
      walkingDoubleSupportPercentage: results.walkingDoubleSupport,
      walkingStepLength: results.walkingStepLength,
      sixMinuteWalkTestDistance: results.sixMinuteWalkTest,
      stairAscentSpeed: results.stairAscentSpeed,
      stairDescentSpeed: results.stairDescentSpeed
    )
  }

  /// Fetch workout events (like laps, pauses, etc.)
  private func fetchWorkoutEvents(for workout: HKWorkout) async -> [HKWorkoutEvent] {
    return workout.workoutEvents ?? []
  }

  /// Fetch quantity samples for a specific type
  private func fetchQuantitySamples(
    for identifier: HKQuantityTypeIdentifier, predicate: NSPredicate
  ) async -> [HKQuantitySample] {
    guard let quantityType = HKQuantityType.quantityType(forIdentifier: identifier) else {
      return []
    }

    return await withCheckedContinuation { continuation in
      let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

      let query = HKSampleQuery(
        sampleType: quantityType,
        predicate: predicate,
        limit: HKObjectQueryNoLimit,
        sortDescriptors: [sortDescriptor]
      ) { query, samples, error in
        let quantitySamples = samples as? [HKQuantitySample] ?? []
        continuation.resume(returning: quantitySamples)
      }

      healthStore.execute(query)
    }
  }

  private func generateFileName(for workout: HKWorkout) -> String {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd-HHmm"
    let dateString = dateFormatter.string(from: workout.startDate)

    let activityType = workout.workoutActivityType.displayName
    let shortUUID = String(workout.uuid.uuidString.prefix(8))

    return "\(activityType)-\(dateString)-\(shortUUID).gpx"
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

    // Create GPX track with required parameters including UUID in description
    let track = GPXTrack(
      date: workout.startDate,
      title:
        "\(workout.workoutActivityType.displayName) - \(DateFormatter.localizedString(from: workout.startDate, dateStyle: .short, timeStyle: .short))",
      description: "Exported from HealthKit workout data. UUID: \(workout.uuid.uuidString)",
      trackPoints: trackPoints,
      type: workout.workoutActivityType.displayName.lowercased()
    )

    // Create GPX exporter
    let exporter = GPXExporter(track: track, creatorName: "ActivityExport")

    // Return the XML string as Data
    return exporter.xmlString.data(using: .utf8) ?? Data()
  }

  /// Enhanced GPX generation with comprehensive workout data
  private func generateEnhancedGPX(
    from locations: [CLLocation], workout: HKWorkout, samples: WorkoutSampleData,
    events: [HKWorkoutEvent]
  ) -> Data {
    var gpxString = """
      <?xml version="1.0" encoding="UTF-8"?>
      <gpx version="1.1" creator="ActivityExport" 
           xmlns="http://www.topografix.com/GPX/1/1" 
           xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" 
           xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1"
           xsi:schemaLocation="http://www.topografix.com/GPX/1/1 http://www.topografix.com/GPX/1/1/gpx.xsd http://www.garmin.com/xmlschemas/TrackPointExtension/v1 http://www.garmin.com/xmlschemas/TrackPointExtensionv1.xsd">
      """

    // Add metadata
    gpxString += """
        <metadata>
          <name>\(workout.workoutActivityType.displayName) - \(DateFormatter.localizedString(from: workout.startDate, dateStyle: .short, timeStyle: .short))</name>
          <desc>Exported from HealthKit workout data. UUID: \(workout.uuid.uuidString)</desc>
          <time>\(ISO8601DateFormatter().string(from: workout.startDate))</time>
      """

    // Add workout statistics as metadata
    let duration = workout.duration
    if let totalDistance = workout.totalDistance?.doubleValue(for: .meter()) {
      gpxString +=
        "    <keywords>Duration: \(Int(duration))s, Distance: \(String(format: "%.2f", totalDistance))m"
    }

    if let totalEnergy = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) {
      gpxString += ", Calories: \(Int(totalEnergy))kcal"
    }

    gpxString += "</keywords>\n"
    gpxString += "  </metadata>\n"

    // Create track with segments (laps if available)
    gpxString += """
        <trk>
          <name>\(workout.workoutActivityType.displayName)</name>
          <type>\(workout.workoutActivityType.displayName.lowercased())</type>
      """

    // Group locations into segments based on time gaps and workout events (representing laps)
    let segments = createTrackSegments(from: locations, events: events)

    for (segmentIndex, segment) in segments.enumerated() {
      gpxString += "    <trkseg>\n"

      for location in segment {
        gpxString += """
                <trkpt lat="\(location.coordinate.latitude)" lon="\(location.coordinate.longitude)">
          """

        // Add elevation if available
        if location.altitude != -1 && location.altitude > -1000 {
          gpxString += "        <ele>\(location.altitude)</ele>\n"
        }

        gpxString +=
          "        <time>\(ISO8601DateFormatter().string(from: location.timestamp))</time>\n"

        // Add extensions with additional data
        let extensions = createTrackPointExtensions(for: location, samples: samples)
        if !extensions.isEmpty {
          gpxString += "        <extensions>\n"
          gpxString += "          <gpxtpx:TrackPointExtension>\n"
          gpxString += extensions
          gpxString += "          </gpxtpx:TrackPointExtension>\n"
          gpxString += "        </extensions>\n"
        }

        gpxString += "      </trkpt>\n"
      }

      gpxString += "    </trkseg>\n"
    }

    gpxString += "  </trk>\n"

    // Add waypoints for significant data points and workout events
    let waypoints = createWaypoints(from: samples, workout: workout, events: events)
    for waypoint in waypoints {
      gpxString += waypoint
    }

    gpxString += "</gpx>"

    return gpxString.data(using: .utf8) ?? Data()
  }

  /// Create track segments based on time gaps and workout events (laps)
  private func createTrackSegments(from locations: [CLLocation], events: [HKWorkoutEvent])
    -> [[CLLocation]]
  {
    guard !locations.isEmpty else { return [] }

    var segments: [[CLLocation]] = []
    var currentSegment: [CLLocation] = []

    // Get lap markers from workout events
    let lapEvents = events.filter { event in
      event.type == .lap || event.type == .pause || event.type == .resume
    }.sorted { $0.dateInterval.start < $1.dateInterval.start }

    let maxGapInterval: TimeInterval = 30  // 30 seconds gap indicates new segment/lap

    var lapEventIndex = 0

    for (index, location) in locations.enumerated() {
      // Check if we've hit a lap event
      while lapEventIndex < lapEvents.count
        && location.timestamp >= lapEvents[lapEventIndex].dateInterval.start
      {

        if lapEvents[lapEventIndex].type == .lap && !currentSegment.isEmpty {
          // End current segment at lap marker
          segments.append(currentSegment)
          currentSegment = [location]
          lapEventIndex += 1
          continue
        } else if lapEvents[lapEventIndex].type == .pause && !currentSegment.isEmpty {
          // End segment at pause
          segments.append(currentSegment)
          currentSegment = []
          lapEventIndex += 1
          continue
        } else if lapEvents[lapEventIndex].type == .resume {
          // Start new segment at resume
          if currentSegment.isEmpty {
            currentSegment = [location]
          }
          lapEventIndex += 1
          continue
        }
        lapEventIndex += 1
      }

      if index == 0 {
        currentSegment.append(location)
      } else {
        let previousLocation = locations[index - 1]
        let timeDifference = location.timestamp.timeIntervalSince(previousLocation.timestamp)

        if timeDifference > maxGapInterval && !currentSegment.isEmpty {
          // Start new segment due to time gap
          segments.append(currentSegment)
          currentSegment = [location]
        } else {
          currentSegment.append(location)
        }
      }
    }

    // Add the last segment
    if !currentSegment.isEmpty {
      segments.append(currentSegment)
    }

    return segments.isEmpty ? [locations] : segments
  }

  /// Create track point extensions with additional sensor data
  private func createTrackPointExtensions(for location: CLLocation, samples: WorkoutSampleData)
    -> String
  {
    var extensions = ""
    let timestamp = location.timestamp
    let tolerance: TimeInterval = 5.0  // 5 second tolerance for matching samples

    // Heart rate
    if let heartRateSample = findClosestSample(
      to: timestamp, in: samples.heartRate, tolerance: tolerance)
    {
      let heartRate = Int(
        heartRateSample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute())))
      extensions += "            <gpxtpx:hr>\(heartRate)</gpxtpx:hr>\n"
    }

    // Cadence (running or cycling)
    if let cadenceSample = findClosestSample(
      to: timestamp, in: samples.cyclingCadence, tolerance: tolerance)
    {
      let cadence = Int(
        cadenceSample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute())))
      extensions += "            <gpxtpx:cad>\(cadence)</gpxtpx:cad>\n"
    }

    // Calculate running cadence from step count (steps per minute)
    if let stepSample = findClosestSample(to: timestamp, in: samples.steps, tolerance: tolerance) {
      let steps = stepSample.quantity.doubleValue(for: HKUnit.count())
      let duration = tolerance * 2  // rough duration estimate
      let cadence = Int((steps / (duration / 60.0)) / 2)  // steps per minute divided by 2 for cadence
      if cadence > 0 && cadence < 250 {  // reasonable cadence range
        extensions += "            <gpxtpx:cad>\(cadence)</gpxtpx:cad>\n"
      }
    }

    // Speed
    let speedSamples = samples.runningSpeed + samples.cyclingSpeed
    if let speedSample = findClosestSample(to: timestamp, in: speedSamples, tolerance: tolerance) {
      let speed = speedSample.quantity.doubleValue(
        for: HKUnit.meter().unitDivided(by: HKUnit.second()))
      extensions += "            <gpxtpx:speed>\(speed)</gpxtpx:speed>\n"
    }

    // Power
    let powerSamples = samples.runningPower + samples.cyclingPower
    if let powerSample = findClosestSample(to: timestamp, in: powerSamples, tolerance: tolerance) {
      let power = Int(powerSample.quantity.doubleValue(for: HKUnit.watt()))
      extensions += "            <gpxtpx:power>\(power)</gpxtpx:power>\n"
    }

    // Temperature
    if let tempSample = findClosestSample(
      to: timestamp, in: samples.temperature, tolerance: tolerance)
    {
      let temp = tempSample.quantity.doubleValue(for: HKUnit.degreeCelsius())
      extensions += "            <gpxtpx:atemp>\(temp)</gpxtpx:atemp>\n"
    }

    // Additional custom extensions for running metrics
    if let strideLengthSample = findClosestSample(
      to: timestamp, in: samples.strideLength, tolerance: tolerance)
    {
      let strideLength = strideLengthSample.quantity.doubleValue(for: HKUnit.meter())
      extensions += "            <gpxtpx:Extensions>\n"
      extensions += "              <RunningDynamics>\n"
      extensions += "                <StrideLength>\(strideLength)</StrideLength>\n"

      // Add other running dynamics if available
      if let verticalOscillationSample = findClosestSample(
        to: timestamp, in: samples.verticalOscillation, tolerance: tolerance)
      {
        let verticalOscillation =
          verticalOscillationSample.quantity.doubleValue(for: HKUnit.meter()) * 100  // Convert to cm
        extensions +=
          "                <VerticalOscillation>\(verticalOscillation)</VerticalOscillation>\n"
      }

      if let groundContactTimeSample = findClosestSample(
        to: timestamp, in: samples.groundContactTime, tolerance: tolerance)
      {
        let groundContactTime =
          groundContactTimeSample.quantity.doubleValue(for: HKUnit.second()) * 1000  // Convert to ms
        extensions +=
          "                <GroundContactTime>\(groundContactTime)</GroundContactTime>\n"
      }

      extensions += "              </RunningDynamics>\n"
      extensions += "            </gpxtpx:Extensions>\n"
    }

    // Add comprehensive custom extensions for advanced metrics
    var hasCustomExtensions = false
    var customExtensions = ""

    // Energy data
    if let energySample = findClosestSample(
      to: timestamp, in: samples.activeEnergy, tolerance: tolerance)
    {
      let energy = energySample.quantity.doubleValue(for: HKUnit.kilocalorie())
      if !hasCustomExtensions {
        customExtensions += "            <gpxtpx:Extensions>\n"
        hasCustomExtensions = true
      }
      customExtensions += "              <Energy>\n"
      customExtensions += "                <ActiveCalories>\(energy)</ActiveCalories>\n"

      // Add basal energy if available
      if let basalEnergySample = findClosestSample(
        to: timestamp, in: samples.basalEnergy, tolerance: tolerance)
      {
        let basalEnergy = basalEnergySample.quantity.doubleValue(for: HKUnit.kilocalorie())
        customExtensions += "                <BasalCalories>\(basalEnergy)</BasalCalories>\n"
      }

      customExtensions += "              </Energy>\n"
    }

    // Respiratory and fitness metrics
    if let respiratoryRateSample = findClosestSample(
      to: timestamp, in: samples.respiratoryRate, tolerance: tolerance)
    {
      let respiratoryRate = respiratoryRateSample.quantity.doubleValue(
        for: HKUnit.count().unitDivided(by: HKUnit.minute()))
      if !hasCustomExtensions {
        customExtensions += "            <gpxtpx:Extensions>\n"
        hasCustomExtensions = true
      }
      customExtensions += "              <Physiology>\n"
      customExtensions +=
        "                <RespiratoryRate>\(Int(respiratoryRate))</RespiratoryRate>\n"
      customExtensions += "              </Physiology>\n"
    }

    // Walking dynamics for gait analysis
    let walkingSamples = [
      ("WalkingAsymmetry", samples.walkingAsymmetry, HKUnit.percent()),
      ("WalkingDoubleSupportPercentage", samples.walkingDoubleSupportPercentage, HKUnit.percent()),
      ("WalkingStepLength", samples.walkingStepLength, HKUnit.meter()),
    ]

    var walkingData = ""
    for (name, sampleArray, unit) in walkingSamples {
      if let sample = findClosestSample(to: timestamp, in: sampleArray, tolerance: tolerance) {
        let value = sample.quantity.doubleValue(for: unit)
        if walkingData.isEmpty {
          walkingData += "              <WalkingDynamics>\n"
        }
        walkingData += "                <\(name)>\(value)</\(name)>\n"
      }
    }

    if !walkingData.isEmpty {
      if !hasCustomExtensions {
        customExtensions += "            <gpxtpx:Extensions>\n"
        hasCustomExtensions = true
      }
      customExtensions += walkingData
      customExtensions += "              </WalkingDynamics>\n"
    }

    // Environmental data
    if let flightsSample = findClosestSample(
      to: timestamp, in: samples.flightsClimbed, tolerance: tolerance)
    {
      let flights = flightsSample.quantity.doubleValue(for: HKUnit.count())
      if !hasCustomExtensions {
        customExtensions += "            <gpxtpx:Extensions>\n"
        hasCustomExtensions = true
      }
      customExtensions += "              <Environment>\n"
      customExtensions += "                <FlightsClimbed>\(Int(flights))</FlightsClimbed>\n"
      customExtensions += "              </Environment>\n"
    }

    // Activity-specific metrics
    if let stairAscentSample = findClosestSample(
      to: timestamp, in: samples.stairAscentSpeed, tolerance: tolerance)
    {
      let stairSpeed = stairAscentSample.quantity.doubleValue(
        for: HKUnit.meter().unitDivided(by: HKUnit.second()))
      if !hasCustomExtensions {
        customExtensions += "            <gpxtpx:Extensions>\n"
        hasCustomExtensions = true
      }
      customExtensions += "              <Movement>\n"
      customExtensions += "                <StairAscentSpeed>\(stairSpeed)</StairAscentSpeed>\n"

      // Add descent speed if available
      if let stairDescentSample = findClosestSample(
        to: timestamp, in: samples.stairDescentSpeed, tolerance: tolerance)
      {
        let descentSpeed = stairDescentSample.quantity.doubleValue(
          for: HKUnit.meter().unitDivided(by: HKUnit.second()))
        customExtensions +=
          "                <StairDescentSpeed>\(descentSpeed)</StairDescentSpeed>\n"
      }

      customExtensions += "              </Movement>\n"
    }

    if hasCustomExtensions {
      customExtensions += "            </gpxtpx:Extensions>\n"
      extensions += customExtensions
    }

    return extensions
  }

  /// Create waypoints for significant data points and workout events
  private func createWaypoints(
    from samples: WorkoutSampleData, workout: HKWorkout, events: [HKWorkoutEvent]
  ) -> [String] {
    var waypoints: [String] = []

    // Add start waypoint with comprehensive workout info
    var workoutInfo =
      "Activity: \(workout.workoutActivityType.displayName), Duration: \(Int(workout.duration))s"

    if let totalDistance = workout.totalDistance?.doubleValue(for: .meter()) {
      workoutInfo += ", Distance: \(String(format: "%.2f", totalDistance))m"
    }

    if let totalEnergy = workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) {
      workoutInfo += ", Calories: \(Int(totalEnergy))kcal"
    }

    waypoints.append(
      """
        <wpt lat="0" lon="0">
          <time>\(ISO8601DateFormatter().string(from: workout.startDate))</time>
          <name>Workout Start</name>
          <desc>\(workoutInfo)</desc>
        </wpt>
      """)

    // Add lap waypoints from workout events
    let lapEvents = events.filter { $0.type == .lap }
    for (index, lapEvent) in lapEvents.enumerated() {
      waypoints.append(
        """
          <wpt lat="0" lon="0">
            <time>\(ISO8601DateFormatter().string(from: lapEvent.dateInterval.start))</time>
            <name>Lap \(index + 1)</name>
            <desc>Lap marker at \(DateFormatter.localizedString(from: lapEvent.dateInterval.start, dateStyle: .none, timeStyle: .medium))</desc>
          </wpt>
        """)
    }

    // Add significant power/speed peaks as waypoints
    let powerSamples = samples.runningPower + samples.cyclingPower
    if let maxPowerSample = powerSamples.max(by: {
      $0.quantity.doubleValue(for: HKUnit.watt()) < $1.quantity.doubleValue(for: HKUnit.watt())
    }) {
      let power = Int(maxPowerSample.quantity.doubleValue(for: HKUnit.watt()))
      waypoints.append(
        """
          <wpt lat="0" lon="0">
            <time>\(ISO8601DateFormatter().string(from: maxPowerSample.startDate))</time>
            <name>Max Power</name>
            <desc>Peak power: \(power) watts</desc>
          </wpt>
        """)
    }

    // Add max heart rate waypoint
    if let maxHRSample = samples.heartRate.max(by: {
      $0.quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute()))
        < $1.quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute()))
    }) {
      let heartRate = Int(
        maxHRSample.quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute())))
      waypoints.append(
        """
          <wpt lat="0" lon="0">
            <time>\(ISO8601DateFormatter().string(from: maxHRSample.startDate))</time>
            <name>Max Heart Rate</name>
            <desc>Peak heart rate: \(heartRate) bpm</desc>
          </wpt>
        """)
    }

    // Add max speed waypoint
    let speedSamples = samples.runningSpeed + samples.cyclingSpeed
    if let maxSpeedSample = speedSamples.max(by: {
      $0.quantity.doubleValue(for: HKUnit.meter().unitDivided(by: HKUnit.second()))
        < $1.quantity.doubleValue(for: HKUnit.meter().unitDivided(by: HKUnit.second()))
    }) {
      let speed = maxSpeedSample.quantity.doubleValue(
        for: HKUnit.meter().unitDivided(by: HKUnit.second()))
      let speedKmh = speed * 3.6
      let paceMinPerKm = speed > 0 ? (1000.0 / 60.0) / speed : 0
      waypoints.append(
        """
          <wpt lat="0" lon="0">
            <time>\(ISO8601DateFormatter().string(from: maxSpeedSample.startDate))</time>
            <name>Max Speed</name>
            <desc>Peak speed: \(String(format: "%.1f", speedKmh)) km/h, Pace: \(String(format: "%.1f", paceMinPerKm)) min/km</desc>
          </wpt>
        """)
    }

    // Add VO2 Max data if available (usually not real-time but workout-related)
    if let vo2MaxSample = samples.vo2Max.first {
      let vo2Max = vo2MaxSample.quantity.doubleValue(
        for: HKUnit.literUnit(with: .milli).unitDivided(by: HKUnit.gramUnit(with: .kilo))
          .unitDivided(by: HKUnit.minute()))
      waypoints.append(
        """
          <wpt lat="0" lon="0">
            <time>\(ISO8601DateFormatter().string(from: vo2MaxSample.startDate))</time>
            <name>VO2 Max</name>
            <desc>VO2 Max: \(String(format: "%.1f", vo2Max)) ml/kg/min</desc>
          </wpt>
        """)
    }

    // Add respiratory rate peaks
    if let maxRespiratoryRateSample = samples.respiratoryRate.max(by: {
      $0.quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute()))
        < $1.quantity.doubleValue(for: HKUnit.count().unitDivided(by: HKUnit.minute()))
    }) {
      let respiratoryRate = Int(
        maxRespiratoryRateSample.quantity.doubleValue(
          for: HKUnit.count().unitDivided(by: HKUnit.minute())))
      waypoints.append(
        """
          <wpt lat="0" lon="0">
            <time>\(ISO8601DateFormatter().string(from: maxRespiratoryRateSample.startDate))</time>
            <name>Max Respiratory Rate</name>
            <desc>Peak respiratory rate: \(respiratoryRate) breaths/min</desc>
          </wpt>
        """)
    }

    // Add elevation gain summary if flights climbed is available
    let totalFlights = samples.flightsClimbed.reduce(0.0) { sum, sample in
      sum + sample.quantity.doubleValue(for: HKUnit.count())
    }

    if totalFlights > 0 {
      waypoints.append(
        """
          <wpt lat="0" lon="0">
            <time>\(ISO8601DateFormatter().string(from: workout.startDate))</time>
            <name>Elevation Summary</name>
            <desc>Total flights climbed: \(Int(totalFlights))</desc>
          </wpt>
        """)
    }

    // Add average pace calculation for running/walking activities
    if workout.workoutActivityType == .running || workout.workoutActivityType == .walking {
      let runningSpeeds = samples.runningSpeed
      if !runningSpeeds.isEmpty {
        let avgSpeed =
          runningSpeeds.reduce(0.0) { sum, sample in
            sum + sample.quantity.doubleValue(for: HKUnit.meter().unitDivided(by: HKUnit.second()))
          } / Double(runningSpeeds.count)

        let avgPaceMinPerKm = avgSpeed > 0 ? (1000.0 / 60.0) / avgSpeed : 0
        waypoints.append(
          """
            <wpt lat="0" lon="0">
              <time>\(ISO8601DateFormatter().string(from: workout.startDate))</time>
              <name>Average Pace</name>
              <desc>Average pace: \(String(format: "%.1f", avgPaceMinPerKm)) min/km</desc>
            </wpt>
          """)
      }
    }

    return waypoints
  }

  /// Find the closest sample to a given timestamp
  private func findClosestSample(
    to timestamp: Date, in samples: [HKQuantitySample], tolerance: TimeInterval
  ) -> HKQuantitySample? {
    let candidateSample = samples.min { sample1, sample2 in
      let diff1 = abs(sample1.startDate.timeIntervalSince(timestamp))
      let diff2 = abs(sample2.startDate.timeIntervalSince(timestamp))
      return diff1 < diff2
    }

    guard let sample = candidateSample,
      abs(sample.startDate.timeIntervalSince(timestamp)) <= tolerance
    else {
      return nil
    }

    return sample
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

    // Create all tar entries first
    var tarEntries: [TarEntry] = []
    let totalFiles = files.count

    for (index, fileURL) in files.enumerated() {
      // Update progress for tar creation (90% to 95%)
      let tarProgress = 0.9 + (Double(index) / Double(totalFiles)) * 0.05
      await MainActor.run {
        self.progress = tarProgress
        self.statusMessage = "Creating archive... (\(index + 1)/\(totalFiles))"
      }

      let fileData = try Data(contentsOf: fileURL)
      let fileName = fileURL.lastPathComponent

      // Create tar entry (but don't create the container yet)
      let tarEntry = TarEntry(info: TarEntryInfo(name: fileName, type: .regular), data: fileData)
      tarEntries.append(tarEntry)
    }

    // Create a single tar container with all entries
    let tarData = try TarContainer.create(from: tarEntries)

    // Update progress for compression (95% to 100%)
    await MainActor.run {
      self.progress = 0.95
      self.statusMessage = "Compressing archive..."
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
    case .downhillSkiing: return "Skiing"
    case .snowboarding: return "Snowboarding"
    case .skatingSports: return "Skating"
    case .paddleSports: return "Paddle-Sports"
    case .climbing: return "Climbing"
    case .equestrianSports: return "Equestrian"
    case .fishing: return "Fishing"
    case .hunting: return "Hunting"
    case .play: return "Play"
    case .snowSports: return "Snow-Sports"
    case .surfingSports: return "Surfing"
    case .waterSports: return "Water-Sports"
    case .wrestling: return "Wrestling"
    case .other: return "Other"
    default: return "Workout"
    }
  }

  /// Returns the preferred data types for this activity type
  var preferredDataTypes: [HKQuantityTypeIdentifier] {
    switch self {
    case .running, .walking, .hiking:
      return [
        .heartRate, .runningSpeed, .runningPower, .runningStrideLength, .runningVerticalOscillation,
        .runningGroundContactTime, .stepCount, .distanceWalkingRunning,
      ]
    case .cycling:
      return [.heartRate, .cyclingSpeed, .cyclingPower, .cyclingCadence, .distanceCycling]
    case .swimming:
      return [.heartRate, .swimmingStrokeCount, .distanceSwimming]
    case .rowing:
      return [.heartRate, .cyclingPower, .cyclingCadence]  // Rowing uses cycling metrics
    default:
      return [.heartRate, .activeEnergyBurned, .stepCount]
    }
  }
}
