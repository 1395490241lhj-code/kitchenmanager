import Foundation
import SwiftUI
import UIKit
import Combine

/// Ephemeral state for a recipe being prepared. It deliberately never mutates
/// `Recipe`, inventory, or sync metadata.
@MainActor
final class RecipeCookingSession: ObservableObject {
    @Published var servings: Int
    @Published private(set) var checkedIngredientIndexes: Set<Int> = []
    @Published private(set) var completedStepIndexes: Set<Int> = []
    @Published private(set) var currentStepIndex = 0

    init(servings: Int = 1) {
        self.servings = min(max(servings, 1), 12)
    }

    func toggleIngredient(at index: Int) {
        if checkedIngredientIndexes.contains(index) { checkedIngredientIndexes.remove(index) }
        else { checkedIngredientIndexes.insert(index) }
    }

    func toggleStep(at index: Int) {
        if completedStepIndexes.contains(index) { completedStepIndexes.remove(index) }
        else { completedStepIndexes.insert(index) }
    }

    func moveToStep(_ index: Int, stepCount: Int) {
        guard stepCount > 0 else { currentStepIndex = 0; return }
        currentStepIndex = min(max(index, 0), stepCount - 1)
    }

    func next(stepCount: Int) { moveToStep(currentStepIndex + 1, stepCount: stepCount) }
    func previous(stepCount: Int) { moveToStep(currentStepIndex - 1, stepCount: stepCount) }
}

enum RecipeServingScaler {
    static func scaledText(_ text: String, multiplier: Double) -> String {
        guard multiplier != 1,
              let match = text.range(of: #"(?<![\d.])(\d+\s*/\s*\d+|\d+(?:\.\d+)?|½|¼|¾)"#, options: .regularExpression),
              let number = number(from: String(text[match])) else { return text }
        return text.replacingCharacters(in: match, with: display(number * multiplier))
    }

    static func display(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded.rounded() == rounded { return String(Int(rounded)) }
        let commonFractions: [(Double, String)] = [(0.25, "¼"), (0.5, "½"), (0.75, "¾")]
        if let fraction = commonFractions.first(where: { abs(rounded - $0.0) < 0.001 }) { return fraction.1 }
        return String(format: "%.2f", rounded).replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression).replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    private static func number(from text: String) -> Double? {
        switch text { case "½": return 0.5; case "¼": return 0.25; case "¾": return 0.75; default: break }
        let parts = text.components(separatedBy: "/")
        if parts.count == 2, let numerator = Double(parts[0].trimmingCharacters(in: .whitespaces)), let denominator = Double(parts[1].trimmingCharacters(in: .whitespaces)), denominator != 0 { return numerator / denominator }
        return Double(text)
    }
}

enum CookingTimerStatus: Equatable { case idle, running, paused, finished }

struct CookingTimerState: Equatable {
    private(set) var remainingSeconds = 0
    private(set) var status: CookingTimerStatus = .idle

    mutating func start(seconds: Int) { remainingSeconds = max(seconds, 1); status = .running }
    mutating func pause() { if status == .running { status = .paused } }
    mutating func resume() { if status == .paused, remainingSeconds > 0 { status = .running } }
    mutating func cancel() { remainingSeconds = 0; status = .idle }
    @discardableResult mutating func advance(seconds: Int = 1) -> Bool {
        guard status == .running else { return false }
        remainingSeconds = max(remainingSeconds - max(seconds, 0), 0)
        if remainingSeconds == 0 { status = .finished; return true }
        return false
    }
}

@MainActor
final class CookingTimerController: ObservableObject {
    @Published private(set) var state = CookingTimerState()
    private var task: Task<Void, Never>?

    deinit { task?.cancel() }

    func start(seconds: Int) { state.start(seconds: seconds); scheduleTicks() }
    func pause() { state.pause(); task?.cancel(); task = nil }
    func resume() { state.resume(); if state.status == .running { scheduleTicks() } }
    func cancel() { task?.cancel(); task = nil; state.cancel() }
    func advanceForTesting(seconds: Int = 1) { if state.advance(seconds: seconds) { task?.cancel(); task = nil } }

    private func scheduleTicks() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.advanceForTesting()
                if self?.state.status != .running { return }
            }
        }
    }
}

enum RecipeStepTimerSuggestion {
    static func seconds(in step: String) -> Int? {
        guard let range = step.range(of: #"\b(\d{1,3})\s*分钟"#, options: .regularExpression),
              let minutes = Int(step[range].replacingOccurrences(of: "分钟", with: "").trimmingCharacters(in: .whitespaces)),
              (1...180).contains(minutes) else { return nil }
        return minutes * 60
    }
}

@MainActor
protocol ScreenAwakeControlling: AnyObject {
    func activate()
    func deactivate()
}

@MainActor
final class ScreenAwakeController: ScreenAwakeControlling {
    private let read: @MainActor () -> Bool
    private let write: @MainActor (Bool) -> Void
    private var priorValue: Bool?

    init(read: @escaping @MainActor () -> Bool = { UIApplication.shared.isIdleTimerDisabled }, write: @escaping @MainActor (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }) {
        self.read = read; self.write = write
    }

    func activate() { if priorValue == nil { priorValue = read() }; write(true) }
    func deactivate() { guard let priorValue else { return }; write(priorValue); self.priorValue = nil }
}
