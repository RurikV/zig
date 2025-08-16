//! By convention, root.zig is the root source file when making a library. If
//! you are making an executable, the convention is to delete this file and
//! start with main.zig instead.
const std = @import("std");
const testing = std.testing;
const math = std.math;

// Error types for quadratic equation solver
pub const QuadraticError = error{
    InvalidCoefficientA,  // a cannot be 0 or invalid
    InvalidInput,         // NaN or infinity in coefficients
    OutOfMemory,          // Memory allocation failed
};

// Constants for floating point comparison
const EPSILON: f64 = 1e-10;

/// Solves quadratic equation ax² + bx + c = 0
/// Returns array of roots (empty if no real roots, 1-2 elements otherwise)
pub fn solve(allocator: std.mem.Allocator, a: f64, b: f64, c: f64) QuadraticError![]f64 {
    // Validate inputs for special values
    if (math.isNan(a) or math.isNan(b) or math.isNan(c) or
        math.isInf(a) or math.isInf(b) or math.isInf(c)) {
        return QuadraticError.InvalidInput;
    }
    
    // Check if 'a' is effectively zero (using epsilon comparison)
    if (@abs(a) < EPSILON) {
        return QuadraticError.InvalidCoefficientA;
    }
    
    // Calculate discriminant: b² - 4ac
    const discriminant = b * b - 4.0 * a * c;
    
    if (discriminant < 0) {
        // No real roots
        return allocator.alloc(f64, 0);
    } else if (@abs(discriminant) < EPSILON) {
        // One root (discriminant ≈ 0)
        const root = -b / (2.0 * a);
        var roots = try allocator.alloc(f64, 1);
        roots[0] = root;
        return roots;
    } else {
        // Two distinct roots
        const sqrt_discriminant = @sqrt(discriminant);
        const root1 = (-b + sqrt_discriminant) / (2.0 * a);
        const root2 = (-b - sqrt_discriminant) / (2.0 * a);
        
        var roots = try allocator.alloc(f64, 2);
        roots[0] = root1;
        roots[1] = root2;
        return roots;
    }
}

pub export fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    std.debug.print("[TEST] Running basic add functionality test...\n", .{});
    try testing.expect(add(3, 7) == 10);
    std.debug.print("[TEST] Basic add functionality test passed!\n", .{});
}

// TDD Test 1: x² + 1 = 0 should have no real roots
test "quadratic equation x^2 + 1 = 0 has no real roots" {
    std.debug.print("[TEST] Running quadratic equation x^2 + 1 = 0 (no real roots) test...\n", .{});
    const allocator = testing.allocator;
    const roots = try solve(allocator, 1.0, 0.0, 1.0); // a=1, b=0, c=1
    defer allocator.free(roots);
    
    try testing.expect(roots.len == 0); // Should return empty array
    std.debug.print("[TEST] No real roots test passed! Found {} roots as expected.\n", .{roots.len});
}

// TDD Test 2: x² - 1 = 0 should have two distinct real roots: x1=1, x2=-1
test "quadratic equation x^2 - 1 = 0 has two distinct roots" {
    std.debug.print("[TEST] Running quadratic equation x^2 - 1 = 0 (two distinct roots) test...\n", .{});
    const allocator = testing.allocator;
    const roots = try solve(allocator, 1.0, 0.0, -1.0); // a=1, b=0, c=-1
    defer allocator.free(roots);
    
    try testing.expect(roots.len == 2); // Should return two roots
    
    // Sort roots to ensure consistent order for testing
    if (roots.len == 2) {
        const x1 = @min(roots[0], roots[1]);
        const x2 = @max(roots[0], roots[1]);
        
        try testing.expectApproxEqAbs(-1.0, x1, 1e-10); // x1 = -1
        try testing.expectApproxEqAbs(1.0, x2, 1e-10);  // x2 = 1
        std.debug.print("[TEST] Two distinct roots test passed! Found roots: x1={d}, x2={d}\n", .{x1, x2});
    }
}

// TDD Test 3: Quadratic equation with discriminant < epsilon but > 0 (single root case)
// Using coefficients: a=1, b=2, c=1-2.5e-12
// Discriminant = 4 - 4(1)(1-2.5e-12) = 4 - 4 + 1e-11 = 1e-11 (which is > 0 but < EPSILON=1e-10)
test "quadratic equation with small positive discriminant has one root" {
    std.debug.print("[TEST] Running quadratic equation with small positive discriminant test...\n", .{});
    const allocator = testing.allocator;
    const a: f64 = 1.0;
    const b: f64 = 2.0;
    const c: f64 = 1.0 - 2.5e-12; // This creates discriminant = 1e-11
    
    const roots = try solve(allocator, a, b, c);
    defer allocator.free(roots);
    
    try testing.expect(roots.len == 1); // Should return one root (treated as single due to epsilon)
    
    // Expected root: -b/(2a) = -2/2 = -1
    try testing.expectApproxEqAbs(-1.0, roots[0], 1e-9); // x ≈ -1
    std.debug.print("[TEST] Small positive discriminant test passed! Found single root: x={d}\n", .{roots[0]});
}

// Additional Test: Perfect square case (discriminant exactly zero)
test "quadratic equation x^2 + 2x + 1 = 0 perfect square" {
    std.debug.print("[TEST] Running quadratic equation x^2 + 2x + 1 = 0 (perfect square) test...\n", .{});
    const allocator = testing.allocator;
    const roots = try solve(allocator, 1.0, 2.0, 1.0); // a=1, b=2, c=1 (discriminant = 0)
    defer allocator.free(roots);
    
    try testing.expect(roots.len == 1); // Should return one root
    try testing.expectApproxEqAbs(-1.0, roots[0], 1e-10); // x = -1
    std.debug.print("[TEST] Perfect square test passed! Found single root: x={d}\n", .{roots[0]});
}

// TDD Test 4: a = 0 should throw InvalidCoefficientA exception
test "coefficient a cannot be zero" {
    std.debug.print("[TEST] Running coefficient a cannot be zero test...\n", .{});
    const allocator = testing.allocator;
    
    // Test exact zero
    try testing.expectError(QuadraticError.InvalidCoefficientA, solve(allocator, 0.0, 2.0, 1.0));
    std.debug.print("[TEST] ✓ Exact zero a=0.0 correctly rejected\n", .{});
    
    // Test very small value (less than epsilon)
    try testing.expectError(QuadraticError.InvalidCoefficientA, solve(allocator, 1e-15, 2.0, 1.0));
    std.debug.print("[TEST] ✓ Very small positive a=1e-15 correctly rejected\n", .{});
    
    // Test negative very small value
    try testing.expectError(QuadraticError.InvalidCoefficientA, solve(allocator, -1e-15, 2.0, 1.0));
    std.debug.print("[TEST] ✓ Very small negative a=-1e-15 correctly rejected\n", .{});
    std.debug.print("[TEST] Coefficient a cannot be zero test passed!\n", .{});
}

// TDD Test 5: Special double values (NaN, infinity) should throw InvalidInput exception
test "special double values should be rejected" {
    std.debug.print("[TEST] Running special double values should be rejected test...\n", .{});
    const allocator = testing.allocator;
    
    // Test NaN in coefficient a
    try testing.expectError(QuadraticError.InvalidInput, solve(allocator, math.nan(f64), 1.0, 1.0));
    std.debug.print("[TEST] ✓ NaN in coefficient a correctly rejected\n", .{});
    
    // Test NaN in coefficient b
    try testing.expectError(QuadraticError.InvalidInput, solve(allocator, 1.0, math.nan(f64), 1.0));
    std.debug.print("[TEST] ✓ NaN in coefficient b correctly rejected\n", .{});
    
    // Test NaN in coefficient c
    try testing.expectError(QuadraticError.InvalidInput, solve(allocator, 1.0, 1.0, math.nan(f64)));
    std.debug.print("[TEST] ✓ NaN in coefficient c correctly rejected\n", .{});
    
    // Test positive infinity in coefficient a
    try testing.expectError(QuadraticError.InvalidInput, solve(allocator, math.inf(f64), 1.0, 1.0));
    std.debug.print("[TEST] ✓ Positive infinity in coefficient a correctly rejected\n", .{});
    
    // Test positive infinity in coefficient b
    try testing.expectError(QuadraticError.InvalidInput, solve(allocator, 1.0, math.inf(f64), 1.0));
    std.debug.print("[TEST] ✓ Positive infinity in coefficient b correctly rejected\n", .{});
    
    // Test positive infinity in coefficient c
    try testing.expectError(QuadraticError.InvalidInput, solve(allocator, 1.0, 1.0, math.inf(f64)));
    std.debug.print("[TEST] ✓ Positive infinity in coefficient c correctly rejected\n", .{});
    
    // Test negative infinity in coefficient a
    try testing.expectError(QuadraticError.InvalidInput, solve(allocator, -math.inf(f64), 1.0, 1.0));
    std.debug.print("[TEST] ✓ Negative infinity in coefficient a correctly rejected\n", .{});
    
    // Test negative infinity in coefficient b
    try testing.expectError(QuadraticError.InvalidInput, solve(allocator, 1.0, -math.inf(f64), 1.0));
    std.debug.print("[TEST] ✓ Negative infinity in coefficient b correctly rejected\n", .{});
    
    // Test negative infinity in coefficient c
    try testing.expectError(QuadraticError.InvalidInput, solve(allocator, 1.0, 1.0, -math.inf(f64)));
    std.debug.print("[TEST] ✓ Negative infinity in coefficient c correctly rejected\n", .{});
    
    std.debug.print("[TEST] Special double values test passed! All 9 special value cases handled correctly.\n", .{});
}
