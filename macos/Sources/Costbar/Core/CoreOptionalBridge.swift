import CostbarKit

// The core spells an absent integer as a value plus a presence flag, because C
// has no optionals. Both directions of that translation live here.

extension costbar_optional_i64_t {
    var optional: Int64? { present == 0 ? nil : value }

    init(optional value: Int64?) {
        self.init(value: value ?? 0, present: value == nil ? 0 : 1)
    }
}
