/// A person's optional grammatical gender, used only to conjugate words in the Slavic
/// languages: "Anna ukończyła", "Jan ukończył" (design: Localisation › Grammatical
/// gender). Nonbinary, like none given, gets the neutral forms ("ukończył(a)").
public enum Gender: String, CaseIterable, Codable, Sendable {
    case male, female, nonbinary
}
