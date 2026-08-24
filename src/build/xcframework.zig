/// Target for XCFramework builds. Kept separate so runtime code never imports
/// build-only declarations.
pub const Target = enum { native, universal };
