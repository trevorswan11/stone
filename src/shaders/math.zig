/// A minimal, SIMD-native 4D Vector representation, aligning with the core module.
pub const Vec4 = extern struct {
    raw: @Vector(4, f32),

    pub fn init(vals: [4]f32) Vec4 {
        var out: Vec4 = undefined;
        inline for (0..4) |i| {
            out.raw[i] = vals[i];
        }
        return out;
    }

    pub fn dot(self: Vec4, other: Vec4) f32 {
        return @reduce(.Add, self.raw * other.raw);
    }
};

/// A minimal, SIMD-native 4D Matrix representation, aligning with the core module.
pub const Mat4 = extern struct {
    raw: [4]Vec4,

    pub fn mulVec(self: Mat4, vec: Vec4) Vec4 {
        var out: Vec4 = undefined;
        inline for (0..4) |i| {
            out.raw[i] = self.raw[i].dot(vec);
        }
        return out;
    }

    pub fn mul(self: Mat4, other: Mat4) Mat4 {
        var out: Mat4 = undefined;
        const other_T = other.transpose();
        inline for (0..4) |i| {
            inline for (0..4) |k| {
                out.raw[i].raw[k] = self.raw[i].dot(other_T.raw[k]);
            }
        }
        return out;
    }

    fn transpose(self: Mat4) Mat4 {
        var out: Mat4 = undefined;
        inline for (0..4) |i| {
            inline for (0..4) |j| {
                out.raw[j].raw[i] = self.raw[i].raw[j];
            }
        }
        return out;
    }
};
