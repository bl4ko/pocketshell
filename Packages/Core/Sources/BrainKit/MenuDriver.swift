import Foundation
import MonitorKit
import TmuxKit

public protocol MenuItem: Sendable {
    var number: Int { get }
    var isHighlighted: Bool { get }
}

public protocol MenuView: Sendable {
    associatedtype Item: MenuItem
    var items: [Item] { get }
    var moreAbove: Bool { get }
    var moreBelow: Bool { get }
}

extension MenuView {
    public var highlightedNumber: Int? { items.first(where: \.isHighlighted)?.number }
}

extension ModelRow: MenuItem {}

extension ModelPicker: MenuView {
    public var items: [ModelRow] { rows }
}

extension InteractivePrompt.Option: MenuItem {
    public var isHighlighted: Bool { highlighted }
}

extension InteractivePrompt: MenuView {
    public var items: [Option] { options.filter { !$0.isChat } }
}

@MainActor
public struct MenuDriver<View: MenuView> {
    public let agent: BrainAgent
    let exec: @MainActor (String) async -> String?
    let sleep: @MainActor (Duration) async -> Void
    let parse: (String) -> View?
    let same: (View, View) -> Bool

    public init(
        agent: BrainAgent, exec: @escaping @MainActor (String) async -> String?,
        sleep: @escaping @MainActor (Duration) async -> Void, parse: @escaping (String) -> View?,
        same: @escaping (View, View) -> Bool
    ) {
        self.agent = agent
        self.exec = exec
        self.sleep = sleep
        self.parse = parse
        self.same = same
    }

    public func screen() async -> String? {
        await exec(AgentControl.screenCommand(agent))
    }

    public func press(_ keys: [MenuKey]) async -> Bool {
        guard !keys.isEmpty else { return true }
        return await exec(AgentControl.keysCommand(agent, keys)) != nil
    }

    public func type(_ text: String) async -> Bool {
        await exec(AgentControl.textCommand(agent, text: text)) != nil
    }

    public func wait(tries: Int = 12, _ condition: (View) -> Bool) async -> View? {
        for _ in 0..<tries {
            await sleep(.milliseconds(150))
            guard let screen = await screen(), let view = parse(screen), condition(view) else { continue }
            return view
        }
        return nil
    }

    public func move(from view: View, to number: Int) async -> View? {
        guard let highlighted = view.highlightedNumber else { return nil }
        if highlighted == number { return view }
        let keys = Array(repeating: number < highlighted ? MenuKey.up : .down, count: abs(number - highlighted))
        guard await press(keys) else { return nil }
        return await wait { same(view, $0) && $0.highlightedNumber == number }
    }

    public func collect(_ first: View) async -> (items: [View.Item], last: View) {
        var found: [Int: View.Item] = [:]
        var view = first
        func merge(_ next: View) {
            for item in next.items where found[item.number] == nil { found[item.number] = item }
        }
        merge(view)
        var steps = 0
        while view.moreAbove, let top = view.items.first?.number, top > 1, steps < 20 {
            steps += 1
            guard let moved = await move(from: view, to: max(1, top - max(1, view.items.count - 1))) else { break }
            view = moved
            merge(view)
        }
        while view.moreBelow, let bottom = view.items.last?.number, steps < 40 {
            steps += 1
            guard let moved = await move(from: view, to: bottom + 1) else { break }
            view = moved
            merge(view)
        }
        return (found.values.sorted { $0.number < $1.number }, view)
    }
}
