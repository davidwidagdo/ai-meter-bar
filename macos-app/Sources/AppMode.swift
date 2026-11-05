import Foundation

enum AppMode {
    static let isDemo = CommandLine.arguments.contains("--demo-data")
}
