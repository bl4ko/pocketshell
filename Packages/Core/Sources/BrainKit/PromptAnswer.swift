import Foundation
import MonitorKit

extension AgentToolbox {
    func readPrompts(_ listed: [BrainAgent]) async -> [BrainAgent] {
        var agents = listed
        for index in agents.indices where agents[index].status == .waiting && agents[index].prompt == nil {
            guard case .herdr = agents[index].location,
                let screen = await io.exec(AgentControl.screenCommand(agents[index]))
            else { continue }
            agents[index].prompt = InteractivePrompt.read(screen)
        }
        return agents
    }

    public func answerPrompt(agentID: String, number: Int, expected: InteractivePrompt) async -> String {
        guard let agent = agents.first(where: { $0.id == agentID }) else { return Self.error("That agent is gone.") }
        guard let screen = await io.exec(AgentControl.screenCommand(agent)) else {
            return Self.error("The host is not connected.")
        }
        guard let current = InteractivePrompt.read(screen), current.question == expected.question,
            current.options.map(\.label) == expected.options.map(\.label),
            current.options.contains(where: { $0.number == number })
        else { return Self.error("\(agent.spokenName) no longer asks that question.") }
        return await perform(.answer(agentID: agentID, digit: String(number)))
    }

    nonisolated public static func failure(_ result: String) -> String? {
        guard let data = result.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["error"] as? String
    }
}
