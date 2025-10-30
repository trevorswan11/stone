template<typename T>
GLM_FUNC_QUALIFIER mat<4, 4, T, defaultp> perspective(T fovy, T aspect, T zNear, T zFar)
{
#        if GLM_CONFIG_CLIP_CONTROL == GLM_CLIP_CONTROL_LH_ZO
        return perspectiveLH_ZO(fovy, aspect, zNear, zFar);
#        elif GLM_CONFIG_CLIP_CONTROL == GLM_CLIP_CONTROL_LH_NO
        return perspectiveLH_NO(fovy, aspect, zNear, zFar);
#        elif GLM_CONFIG_CLIP_CONTROL == GLM_CLIP_CONTROL_RH_ZO
        return perspectiveRH_ZO(fovy, aspect, zNear, zFar);
#        elif GLM_CONFIG_CLIP_CONTROL == GLM_CLIP_CONTROL_RH_NO
        return perspectiveRH_NO(fovy, aspect, zNear, zFar);
#        endif
}

template<typename T>
GLM_FUNC_QUALIFIER mat<4, 4, T, defaultp> perspectiveRH_NO(T fovy, T aspect, T zNear, T zFar)
{
    assert(abs(aspect - std::numeric_limits<T>::epsilon()) > static_cast<T>(0));

    T const tanHalfFovy = tan(fovy / static_cast<T>(2));

    mat<4, 4, T, defaultp> Result(static_cast<T>(0));
    Result[0][0] = static_cast<T>(1) / (aspect * tanHalfFovy);
    Result[1][1] = static_cast<T>(1) / (tanHalfFovy);
    Result[2][2] = - (zFar + zNear) / (zFar - zNear);
    Result[2][3] = - static_cast<T>(1);
    Result[3][2] = - (static_cast<T>(2) * zFar * zNear) / (zFar - zNear);
    return Result;
}

GLM_FUNC_QUALIFIER mat<4, 4, T, Q> rotate(mat<4, 4, T, Q> const& m, T angle, vec<3, T, Q> const& v)
{
 T const a = angle;
 T const c = cos(a);
 T const s = sin(a);
 vec<3, T, Q> axis(normalize(v));
 vec<3, T, Q> temp((T(1) - c) * axis);
 mat<4, 4, T, Q> Rotate;
 Rotate[0][0] = c + temp[0] * axis[0];
 Rotate[0][1] = temp[0] * axis[1] + s * axis[2];
 Rotate[0][2] = temp[0] * axis[2] - s * axis[1];

 Rotate[1][0] = temp[1] * axis[0] - s * axis[2];
 Rotate[1][1] = c + temp[1] * axis[1];
 Rotate[1][2] = temp[1] * axis[2] + s * axis[0];

 Rotate[2][0] = temp[2] * axis[0] + s * axis[1];
 Rotate[2][1] = temp[2] * axis[1] - s * axis[0];
 Rotate[2][2] = c + temp[2] * axis[2];

 mat<4, 4, T, Q> Result;
 Result[0] = m[0] * Rotate[0][0] + m[1] * Rotate[0][1] + m[2] * Rotate[0][2];
 Result[1] = m[0] * Rotate[1][0] + m[1] * Rotate[1][1] + m[2] * Rotate[1][2];
 Result[2] = m[0] * Rotate[2][0] + m[1] * Rotate[2][1] + m[2] * Rotate[2][2];
 Result[3] = m[3];
 return Result;
}

 template<typename T, qualifier Q>
 GLM_FUNC_QUALIFIER mat<4, 4, T, Q> lookAtRH(vec<3, T, Q> const& eye, vec<3, T, Q> const& center, vec<3, T, Q> const& up)
 {
  vec<3, T, Q> const f(normalize(center - eye));
  vec<3, T, Q> const s(normalize(cross(f, up)));
  vec<3, T, Q> const u(cross(s, f));

  mat<4, 4, T, Q> Result(1);
  Result[0][0] = s.x;
  Result[1][0] = s.y;
  Result[2][0] = s.z;

  Result[0][1] = u.x;
  Result[1][1] = u.y;
  Result[2][1] = u.z;

  Result[0][2] =-f.x;
  Result[1][2] =-f.y;
  Result[2][2] =-f.z;

  Result[3][0] =-dot(s, eye);
  Result[3][1] =-dot(u, eye);
  Result[3][2] = dot(f, eye);
  return Result;
 }

 template<typename T, qualifier Q>
 GLM_FUNC_QUALIFIER mat<4, 4, T, Q> lookAtLH(vec<3, T, Q> const& eye, vec<3, T, Q> const& center, vec<3, T, Q> const& up)
 {
  vec<3, T, Q> const f(normalize(center - eye));
  vec<3, T, Q> const s(normalize(cross(up, f)));
  vec<3, T, Q> const u(cross(f, s));

  mat<4, 4, T, Q> Result(1);
  Result[0][0] = s.x;
  Result[1][0] = s.y;
  Result[2][0] = s.z;

  Result[0][1] = u.x;
  Result[1][1] = u.y;
  Result[2][1] = u.z;

  Result[0][2] = f.x;
  Result[1][2] = f.y;
  Result[2][2] = f.z;
  
  Result[3][0] = -dot(s, eye);
  Result[3][1] = -dot(u, eye);
  Result[3][2] = -dot(f, eye);
  return Result;
 }

 template<typename T, qualifier Q>
 GLM_FUNC_QUALIFIER mat<4, 4, T, Q> lookAt(vec<3, T, Q> const& eye, vec<3, T, Q> const& center, vec<3, T, Q> const& up)
 {
#       if (GLM_CONFIG_CLIP_CONTROL & GLM_CLIP_CONTROL_LH_BIT)
            return lookAtLH(eye, center, up);
#       else
            return lookAtRH(eye, center, up);
#       endif
 }