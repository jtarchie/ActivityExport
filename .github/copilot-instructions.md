# Project Overview

This repository contains an iOS app called "ActivityExport" that exports HealthKit workout activities as GPX files. The app uses Swift, SwiftUI, and integrates with HealthKit, GPXKit, and SWCompression for exporting and archiving workout data.

## Folder Structure

- `/ActivityExport/`: Main app source code, including SwiftUI views and managers.
- `/ActivityExportTests/`: Unit tests for the app.
- `/ActivityExportUITests/`: UI tests for the app.
- `/ActivityExport.xcodeproj/`: Xcode project files and configuration.
- `/Taskfile.yml`: Task runner configuration for formatting and static analysis.

## Libraries and Frameworks

- **SwiftUI**: For building the user interface.
- **HealthKit**: For accessing workout and route data.
- **GPXKit**: For generating GPX files from workout routes.
- **SWCompression**: For creating compressed tar archives of exported files.
- **Testing**: For unit tests.

## Coding Standards and Best Practices

- Use Swift 5.0+ and SwiftUI idioms.
- Prefer `@MainActor` for UI-related classes and methods.
- Use `@Published` properties for observable state in view models.
- Use async/await for asynchronous operations.
- Always check and handle HealthKit permissions and errors gracefully.
- Use descriptive and localized strings for user-facing text.
- Follow Apple's Human Interface Guidelines for iOS apps.
- Use dependency injection for testability where possible.
- Write unit and UI tests for critical features.
- Use `Task` for launching async operations from UI actions.
- Keep view models and views separated for maintainability.
- Use `ProgressView` for indicating long-running operations.
- Clean up temporary files after export.
- Use semantic naming for files and variables.
- Prefer structs for value types and classes for reference types.
- Use `let` for constants and `var` for variables.
- Document public methods and types with Swift documentation comments.

## UI Guidelines

- Use system icons and colors for a native look.
- Provide clear feedback to users during long operations.
- Use sheets for sharing/exporting files.
- Display error messages in red and status messages in secondary color.
- Support both iPhone and iPad interface orientations.

## Additional Notes

- All HealthKit access must be privacy-conscious and require user consent.
- GPX files should include workout UUIDs for traceability.
- The app should handle the absence of workouts gracefully.
- Use the provided `Taskfile.yml` for formatting and static analysis before committing code.
