import SwiftUI

/// `@State` without the SwiftUI macro plugin, which ships with Xcode but not
/// the Command Line Tools this package builds with. SwiftUI finds the nested
/// `State` through `DynamicProperty` exactly as it would the macro's.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private let state: State<Value>
    init(wrappedValue: Value) { state = State(initialValue: wrappedValue) }
    var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }
    var projectedValue: Binding<Value> { state.projectedValue }
}
