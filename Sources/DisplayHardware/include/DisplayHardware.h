#ifndef LINEUP_DISPLAY_HARDWARE_H
#define LINEUP_DISPLAY_HARDWARE_H

#include <stdbool.h>
#include <stdint.h>

typedef struct LDDisplayConnection LDDisplayConnection;

typedef enum {
    LDHardwareSuccess = 0,
    LDHardwareUnsupported = 1,
    LDHardwareAmbiguous = 2,
    LDHardwareDisconnected = 3,
    LDHardwareCommunicationFailed = 4,
    LDHardwareInvalidPacket = 5,
    LDHardwareAPIUnavailable = 6,
} LDHardwareResult;

// All operations belong to the caller's serial display queue. Open and metadata calls
// only read hardware. The two explicit write entry points are the only level writes.
void LDDisplayGetName(uint32_t displayID, char *buffer, uint32_t bufferLength);
void LDDisplayGetUUID(uint32_t displayID, char *buffer, uint32_t bufferLength);
LDDisplayConnection *LDDisplayOpenNative(uint32_t displayID, LDHardwareResult *result);
LDDisplayConnection *LDDisplayOpenDDC(uint32_t displayID, LDHardwareResult *result);
void LDDisplayClose(LDDisplayConnection *connection);
bool LDDisplayDDCUsesIOAV(const LDDisplayConnection *connection);
LDHardwareResult LDDisplayReadNative(LDDisplayConnection *connection, float *value);
LDHardwareResult LDDisplayWriteNative(LDDisplayConnection *connection, float value);

// The payload includes the I2C host address for Intel and omits it for IOAVService.
// Only Get/Set VCP brightness (0x10) and speaker volume (0x62) packets are accepted.
LDHardwareResult LDDisplayExchange(LDDisplayConnection *connection,
                                  const uint8_t *send, uint32_t sendLength,
                                  uint8_t *reply, uint32_t replyLength);

#endif
