import Foundation

func jsonObject(_ value: JSONValue?) -> [String: JSONValue]? {
    value?.objectValue
}

func jsonString(_ value: JSONValue?) -> String? {
    value?.stringValue
}

func jsonNumber(_ value: JSONValue?) -> Double? {
    guard case let .number(number) = value else { return nil }
    return number
}

func jsonInteger(_ value: JSONValue?) -> Int? {
    guard let number = jsonNumber(value) else { return nil }
    return Int(number)
}

func jsonBoolean(_ value: JSONValue?) -> Bool? {
    guard case let .boolean(value) = value else { return nil }
    return value
}

func jsonArray(_ value: JSONValue?) -> [JSONValue] {
    value?.arrayValue ?? []
}

func jsonStringArray(_ value: JSONValue?) -> [String] {
    jsonArray(value).compactMap(\JSONValue.stringValue)
}

func jsonTextParts(_ values: [JSONValue?]) -> String {
    values
        .flatMap { value -> [JSONValue] in
            if let string = value?.stringValue {
                return [.string(string)]
            }
            if let object = jsonObject(value), let text = object["text"]?.stringValue {
                return [.string(text)]
            }
            return jsonArray(value)
        }
        .compactMap { value in
            if let text = value.stringValue {
                return text
            }
            return jsonObject(value)?["text"]?.stringValue
        }
        .joined(separator: "\n")
}

func formatJSONValue(_ value: JSONValue?) -> String {
    guard let value else { return "" }
    if let string = value.stringValue {
        return string
    }
    return value.prettyPrinted()
}
