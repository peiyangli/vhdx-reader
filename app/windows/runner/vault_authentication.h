#ifndef RUNNER_VAULT_AUTHENTICATION_H_
#define RUNNER_VAULT_AUTHENTICATION_H_
#include <windows.h>

// Host-owned bridge: no Flutter channel can mark an unlock as authenticated.
namespace vault_authentication {
void Install(HWND window);
void Detach(HWND window);
void CancelPending();
bool HandleMessage(UINT message, WPARAM attempt);
}
#endif
