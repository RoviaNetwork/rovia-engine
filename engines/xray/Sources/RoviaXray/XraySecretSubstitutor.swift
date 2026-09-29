import Foundation

public enum XraySecretSubstitutionError: Error, Equatable, Sendable {
    case invalidJSON
    case unknownKey(String)
    case secretNotUTF8(String)
}

/// Replaces the `__ROVIA_SECRET::<key>__` placeholders the compiler emits
/// with Keychain bytes, inside the tunnel extension just before `runXray`.
///
/// Matching is by whole string value, not substring: the compiler only ever
/// emits placeholders as complete `id`/`password` values, so a partial
/// match would mean a hand-edited config and is refused by construction
/// (there is simply no code path for it). The walk re-encodes with sorted
/// keys, so substitution is deterministic byte-for-byte for identical
/// inputs.
public enum XraySecretSubstitutor {
    public static func secretKeys(in configJSON: Data) throws -> [String] {
        let json = try parse(configJSON)
        var keys: [String] = []
        collect(from: json, into: &keys)
        return keys
    }

    public static func substituting(
        _ secrets: [String: Data],
        in configJSON: Data
    ) throws -> Data {
        let json = try parse(configJSON)
        let substituted = try walk(json) { value in
            guard let key = placeholderKey(value) else { return value }
            guard let secret = secrets[key] else {
                throw XraySecretSubstitutionError.unknownKey(key)
            }
            guard let text = String(data: secret, encoding: .utf8) else {
                throw XraySecretSubstitutionError.secretNotUTF8(key)
            }
            return text
        }
        return try JSONSerialization.data(withJSONObject: substituted, options: [.sortedKeys])
    }

    private static func parse(_ data: Data) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(with: data)
        } catch {
            throw XraySecretSubstitutionError.invalidJSON
        }
    }

    private static func placeholderKey(_ value: String) -> String? {
        let prefix = "__ROVIA_SECRET::"
        let suffix = "__"
        guard value.hasPrefix(prefix), value.hasSuffix(suffix), value.count > prefix.count + suffix.count else {
            return nil
        }
        return String(value.dropFirst(prefix.count).dropLast(suffix.count))
    }

    private static func collect(from json: Any, into keys: inout [String]) {
        switch json {
        case let value as String:
            if let key = placeholderKey(value), !keys.contains(key) {
                keys.append(key)
            }
        case let array as [Any]:
            for item in array { collect(from: item, into: &keys) }
        case let object as [String: Any]:
            for item in object.values { collect(from: item, into: &keys) }
        default:
            break
        }
    }

    private static func walk(_ json: Any, replace: (String) throws -> String) throws -> Any {
        switch json {
        case let value as String:
            return try replace(value)
        case let array as [Any]:
            return try array.map { try walk($0, replace: replace) }
        case let object as [String: Any]:
            return try object.mapValues { try walk($0, replace: replace) }
        default:
            return json
        }
    }
}
