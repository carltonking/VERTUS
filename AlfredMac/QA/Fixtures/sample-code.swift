import Foundation

struct AlfredQAFixture {
    let title: String
    let enabled: Bool

    func summary() -> String {
        enabled ? "\(title): enabled" : "\(title): disabled"
    }
}

let fixture = AlfredQAFixture(title: "Selected Swift file reading", enabled: true)
print(fixture.summary())
