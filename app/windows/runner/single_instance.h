#ifndef RUNNER_SINGLE_INSTANCE_H_
#define RUNNER_SINGLE_INSTANCE_H_
#include <windows.h>
#include <string>
#include <vector>
namespace single_instance {
#ifdef _DEBUG
inline constexpr wchar_t kIdentity[] = L"Local\\VHDXReader.SingleInstance.Debug.7496E017";
inline constexpr wchar_t kWindowProperty[] = L"VHDXReader.Primary.Debug.7496E017";
#else
inline constexpr wchar_t kIdentity[] = L"Local\\VHDXReader.SingleInstance.7496E017";
inline constexpr wchar_t kWindowProperty[] = L"VHDXReader.Primary.7496E017";
#endif
inline constexpr ULONG_PTR kCopyData = 0x56484458;
class Instance {
 public:
  enum class Result { primary, forwarded, failed };
  Result Start(const std::vector<std::string>& paths);
  ~Instance();
 private:
  HANDLE mutex_ = nullptr;
  bool owner_ = false;
};
std::vector<std::string> ImageArguments();
}
#endif
