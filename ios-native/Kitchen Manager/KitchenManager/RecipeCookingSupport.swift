import Foundation
import SwiftUI
import UIKit
import Combine
import UserNotifications

/// Ephemeral state for a recipe being prepared. It deliberately never mutates
/// `Recipe`, inventory, or sync metadata.
@MainActor
final class RecipeCookingSession: ObservableObject {
    @Published var servings: Int
    /// The recipe's own yield, so the session can tell "cook 4 servings of a
    /// 4-serving recipe" (unchanged quantities) from "cook 4 of a 1-serving
    /// recipe" (4x). Without it, `servings` was applied as a raw multiplier and
    /// a 4-serving recipe viewed at 4 人份 showed quantities for sixteen.
    let baseServings: Int?
    @Published private(set) var checkedIngredientIndexes: Set<Int> = []
    @Published private(set) var completedStepIndexes: Set<Int> = []
    @Published private(set) var currentStepIndex = 0

    init(servings: Int = 1, baseServings: Int? = nil) {
        self.servings = min(max(servings, 1), 12)
        self.baseServings = Recipe.validatedBaseServings(baseServings)
    }

    /// What to multiply written quantities by for display.
    ///
    /// `1` whenever the recipe never stated a yield: the quantities are then the
    /// only honest thing to show, and inventing a base of 1 would silently
    /// multiply them by the chosen headcount.
    var displayMultiplier: Double {
        RecipeQuantityScaler.factor(baseServings: baseServings, targetServings: servings) ?? 1
    }

    /// True only when the multiplier reflects a real base -> target conversion,
    /// so the UI can avoid claiming a scaled amount it did not compute.
    var isScaled: Bool {
        RecipeQuantityScaler.factor(baseServings: baseServings, targetServings: servings) != nil
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
    private(set) var endDate: Date?

    mutating func start(seconds: Int, now: Date = .now) {
        remainingSeconds = max(seconds, 1)
        endDate = now.addingTimeInterval(TimeInterval(remainingSeconds))
        status = .running
    }

    mutating func pause(now: Date = .now) {
        guard status == .running else { return }
        if refresh(now: now) { return }
        endDate = nil
        status = .paused
    }

    mutating func resume(now: Date = .now) {
        guard status == .paused, remainingSeconds > 0 else { return }
        endDate = now.addingTimeInterval(TimeInterval(remainingSeconds))
        status = .running
    }

    mutating func cancel() {
        remainingSeconds = 0
        endDate = nil
        status = .idle
    }

    @discardableResult mutating func refresh(now: Date = .now) -> Bool {
        guard status == .running, let endDate else { return false }
        remainingSeconds = max(Int(ceil(endDate.timeIntervalSince(now))), 0)
        if remainingSeconds == 0 {
            self.endDate = nil
            status = .finished
            return true
        }
        return false
    }
}

@MainActor
private enum CookingTimerNotificationScheduler {
    private static let identifier = "native-km-cooking-timer"

    static func schedule(at endDate: Date) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard !Task.isCancelled else { return }
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        default:
            return
        }

        let interval = endDate.timeIntervalSinceNow
        guard interval > 0 else { return }
        let content = UNMutableNotificationContent()
        content.title = "计时结束"
        content.body = "烹饪步骤计时已完成。"
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(interval, 1), repeats: false)
        )
        guard !Task.isCancelled else { return }
        try? await center.add(request)
    }

    static func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
    }
}

@MainActor
final class CookingTimerController: ObservableObject {
    @Published private(set) var state = CookingTimerState()
    private let scheduleNotification: @MainActor (Date) async -> Void
    private let cancelNotification: @MainActor () -> Void
    private var tickTask: Task<Void, Never>?
    private var notificationTask: Task<Void, Never>?

    init(
        scheduleNotification: @escaping @MainActor (Date) async -> Void = { endDate in
            await CookingTimerNotificationScheduler.schedule(at: endDate)
        },
        cancelNotification: @escaping @MainActor () -> Void = {
            CookingTimerNotificationScheduler.cancel()
        }
    ) {
        self.scheduleNotification = scheduleNotification
        self.cancelNotification = cancelNotification
    }

    deinit {
        tickTask?.cancel()
        notificationTask?.cancel()
    }

    func start(seconds: Int, now: Date = .now) {
        state.start(seconds: seconds, now: now)
        scheduleRunningTimer()
    }

    func pause() {
        state.pause()
        stopScheduling()
    }

    func resume() {
        state.resume()
        if state.status == .running { scheduleRunningTimer() }
    }

    func cancel() {
        stopScheduling()
        state.cancel()
    }

    func refresh(now: Date = .now) {
        guard state.refresh(now: now) else { return }
        stopScheduling()
    }

    private func scheduleTicks() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self?.refresh()
                if self?.state.status != .running { return }
            }
        }
    }

    private func scheduleRunningTimer() {
        scheduleTicks()
        notificationTask?.cancel()
        cancelNotification()
        guard let endDate = state.endDate else { return }
        notificationTask = Task {
            await scheduleNotification(endDate)
        }
    }

    private func stopScheduling() {
        tickTask?.cancel()
        tickTask = nil
        notificationTask?.cancel()
        notificationTask = nil
        cancelNotification()
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
