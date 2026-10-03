import Foundation

func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
    regex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
}
