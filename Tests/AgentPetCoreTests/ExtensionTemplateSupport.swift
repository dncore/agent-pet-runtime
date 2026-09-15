import Foundation

/// The events a generated extension registers, read off the file that will be
/// installed rather than from a list kept beside it.
///
/// Shared by the two suites that own the two halves of one template: a second
/// copy of this parse would drift from the first the moment a registration
/// changed shape, and the suite that stopped parsing would keep passing.
func listenedEvents(inGeneratedFile source: String) -> Set<String> {
    Set(
        source.components(separatedBy: "pi.on(\"").dropFirst().compactMap { chunk in
            chunk.split(separator: "\"").first.map(String.init)
        }
    )
}
