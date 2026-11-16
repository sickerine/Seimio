// The few luna-service2 C functions the plugin uses, declared from webOS OSE lunaservice.h
// (the full header pulls in PmLogLib and payload headers the SDK doesn't have).
#pragma once
#include <glib.h>
extern "C" {
typedef unsigned long LSMessageToken;
struct LSError { int error_code; char *message; const char *file; int line; const char *func; void *padding; unsigned long magic; };
typedef struct LSHandle LSHandle;
typedef struct LSMessage LSMessage;
typedef bool (*LSFilterFunc)(LSHandle *sh, LSMessage *reply, void *ctx);
bool LSErrorInit(LSError *error);
void LSErrorFree(LSError *error);
bool LSRegister(const char *name, LSHandle **sh, LSError *lserror);
bool LSGmainContextAttach(LSHandle *sh, GMainContext *mainContext, LSError *lserror);
bool LSCall(LSHandle *sh, const char *uri, const char *payload, LSFilterFunc callback, void *user_data, LSMessageToken *ret_token, LSError *lserror);
bool LSCallCancel(LSHandle *sh, LSMessageToken token, LSError *lserror);
const char *LSMessageGetPayload(LSMessage *message);
LSMessageToken LSMessageGetResponseToken(LSMessage *reply);
const char *LSHandleGetName(LSHandle *sh);
}
