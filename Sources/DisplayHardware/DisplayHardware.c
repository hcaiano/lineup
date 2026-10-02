#include "DisplayHardware.h"

#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CoreGraphics.h>
#include <ColorSync/ColorSync.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/graphics/IOGraphicsLib.h>
#include <IOKit/i2c/IOI2CInterface.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Apple does not expose native brightness or Apple Silicon DDC in public SDKs.
// Resolve optional system symbols at runtime and fail closed when they disappear.
typedef CFDictionaryRef (*DisplayInfoFunction)(CGDirectDisplayID);
typedef int (*GetBrightnessFunction)(CGDirectDisplayID, float *);
typedef int (*SetBrightnessFunction)(CGDirectDisplayID, float);
typedef CFTypeRef (*CreateAVFunction)(CFAllocatorRef, io_service_t);
typedef IOReturn (*CopyEDIDFunction)(CFTypeRef, CFDataRef *);
typedef IOReturn (*AVI2CFunction)(CFTypeRef, uint32_t, uint32_t, void *, uint32_t);
typedef void (*DisplayServiceFunction)(CGDirectDisplayID, io_service_t *);

static DisplayInfoFunction displayInfo;
static GetBrightnessFunction getBrightness;
static SetBrightnessFunction setBrightness;
static CreateAVFunction createAV;
static CopyEDIDFunction copyEDID;
static AVI2CFunction readAV;
static AVI2CFunction writeAV;
static DisplayServiceFunction displayService;
static pthread_once_t symbolsOnce = PTHREAD_ONCE_INIT;

static void loadSymbols(void) {
    // Keep these images loaded for the process lifetime so function pointers stay valid.
    void *core = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY | RTLD_LOCAL);
    void *brightness = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY | RTLD_LOCAL);
    void *io = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY | RTLD_LOCAL);
    void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY | RTLD_LOCAL);
    if (core) displayInfo = (DisplayInfoFunction)dlsym(core, "CoreDisplay_DisplayCreateInfoDictionary");
    if (brightness) {
        getBrightness = (GetBrightnessFunction)dlsym(brightness, "DisplayServicesGetBrightness");
        setBrightness = (SetBrightnessFunction)dlsym(brightness, "DisplayServicesSetBrightness");
    }
    if (io) {
        createAV = (CreateAVFunction)dlsym(io, "IOAVServiceCreateWithService");
        copyEDID = (CopyEDIDFunction)dlsym(io, "IOAVServiceCopyEDID");
        readAV = (AVI2CFunction)dlsym(io, "IOAVServiceReadI2C");
        writeAV = (AVI2CFunction)dlsym(io, "IOAVServiceWriteI2C");
    }
    if (sky) displayService = (DisplayServiceFunction)dlsym(sky, "CGSServiceForDisplayNumber");
}

struct LDDisplayConnection {
    CGDirectDisplayID displayID;
    CFUUIDRef displayUUID;
    uint32_t vendor, product, serial;
    bool native, ioAV;
    io_service_t service, interface;
    uint64_t serviceID, interfaceID;
    IOOptionBits replyTransaction;
    CFTypeRef av;
    uint8_t edid[128];
};

static bool sameIdentity(uint32_t displayID, uint32_t vendor, uint32_t product, uint32_t serial) {
    return CGDisplayVendorNumber(displayID) == vendor && CGDisplayModelNumber(displayID) == product
        && CGDisplaySerialNumber(displayID) == serial;
}

static bool uniqueOnlineIdentity(uint32_t vendor, uint32_t product, uint32_t serial) {
    uint32_t count = 0;
    if (!vendor || !product || CGGetOnlineDisplayList(0, NULL, &count) != kCGErrorSuccess || !count) return false;
    CGDirectDisplayID *ids = calloc(count, sizeof(*ids));
    if (!ids) return false;
    bool success = CGGetOnlineDisplayList(count, ids, &count) == kCGErrorSuccess;
    uint32_t matches = 0;
    if (success) for (uint32_t i = 0; i < count; i++) if (sameIdentity(ids[i], vendor, product, serial)) matches++;
    free(ids);
    return success && matches == 1;
}

static bool registryServiceIsActive(uint64_t entryID) {
    if (!entryID) return false;
    io_service_t active = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(entryID));
    if (!active) return false;
    IOObjectRelease(active);
    return true;
}

static bool copyValidEDID(CFTypeRef av, uint8_t *bytes) {
    CFDataRef data = NULL;
    IOReturn result = copyEDID(av, &data);
    bool valid = result == kIOReturnSuccess && data && CFGetTypeID(data) == CFDataGetTypeID()
        && CFDataGetLength(data) >= 128;
    if (valid) {
        const uint8_t *source = CFDataGetBytePtr(data);
        const uint8_t header[] = {0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x00};
        uint8_t checksum = 0;
        for (int i = 0; i < 128; i++) checksum = (uint8_t)(checksum + source[i]);
        valid = !memcmp(source, header, sizeof(header)) && checksum == 0;
        if (valid) memcpy(bytes, source, 128);
    }
    if (data) CFRelease(data);
    return valid;
}

#if defined(__arm64__)
static bool edidMatches(const uint8_t *edid, uint32_t vendor, uint32_t product, uint32_t serial) {
    uint32_t edidVendor = ((uint32_t)edid[8] << 8) | edid[9];
    uint32_t edidProduct = ((uint32_t)edid[11] << 8) | edid[10];
    uint32_t edidSerial = (uint32_t)edid[12] | ((uint32_t)edid[13] << 8)
        | ((uint32_t)edid[14] << 16) | ((uint32_t)edid[15] << 24);
    return vendor == edidVendor && product == edidProduct && serial == edidSerial;
}
#endif

static bool connectionIsValid(const LDDisplayConnection *connection) {
    if (!connection || !CGDisplayIsOnline(connection->displayID)
        || !sameIdentity(connection->displayID, connection->vendor, connection->product, connection->serial)) return false;
    CFUUIDRef current = CGDisplayCreateUUIDFromDisplayID(connection->displayID);
    bool valid = current && connection->displayUUID && CFEqual(current, connection->displayUUID);
    if (current) CFRelease(current);
    if (!valid || connection->native) return valid;
    if (!registryServiceIsActive(connection->serviceID)) return false;
    if (connection->ioAV) {
        uint8_t currentEDID[128];
        return uniqueOnlineIdentity(connection->vendor, connection->product, connection->serial)
            && copyValidEDID(connection->av, currentEDID) && !memcmp(currentEDID, connection->edid, 128);
    }
    return registryServiceIsActive(connection->interfaceID);
}

static LDDisplayConnection *newConnection(uint32_t displayID) {
    if (!CGDisplayIsOnline(displayID)) return NULL;
    LDDisplayConnection *connection = calloc(1, sizeof(*connection));
    if (!connection) return NULL;
    connection->displayID = displayID;
    connection->displayUUID = CGDisplayCreateUUIDFromDisplayID(displayID);
    connection->vendor = CGDisplayVendorNumber(displayID);
    connection->product = CGDisplayModelNumber(displayID);
    connection->serial = CGDisplaySerialNumber(displayID);
    if (!connection->displayUUID) { LDDisplayClose(connection); return NULL; }
    return connection;
}

void LDDisplayClose(LDDisplayConnection *connection) {
    if (!connection) return;
    if (connection->displayUUID) CFRelease(connection->displayUUID);
    if (connection->av) CFRelease(connection->av);
    if (connection->interface) IOObjectRelease(connection->interface);
    if (connection->service) IOObjectRelease(connection->service);
    free(connection);
}

void LDDisplayGetUUID(uint32_t displayID, char *buffer, uint32_t bufferLength) {
    if (!buffer || !bufferLength) return;
    buffer[0] = 0;
    CFUUIDRef uuid = CGDisplayCreateUUIDFromDisplayID(displayID);
    if (!uuid) return;
    CFStringRef string = CFUUIDCreateString(kCFAllocatorDefault, uuid);
    if (string) { CFStringGetCString(string, buffer, bufferLength, kCFStringEncodingUTF8); CFRelease(string); }
    CFRelease(uuid);
}

void LDDisplayGetName(uint32_t displayID, char *buffer, uint32_t bufferLength) {
    if (!buffer || !bufferLength) return;
    buffer[0] = 0;
    pthread_once(&symbolsOnce, loadSymbols);
    if (!displayInfo) return;
    CFDictionaryRef info = displayInfo(displayID);
    if (!info) return;
    CFTypeRef value = CFDictionaryGetValue(info, CFSTR("DisplayProductName"));
    if (value && CFGetTypeID(value) == CFDictionaryGetTypeID()) {
        CFDictionaryRef names = value;
        CFTypeRef name = CFDictionaryGetValue(names, CFSTR("en_US"));
        if (!name && CFDictionaryGetCount(names) > 0) {
            CFIndex count = CFDictionaryGetCount(names);
            const void **values = calloc((size_t)count, sizeof(*values));
            if (values) { CFDictionaryGetKeysAndValues(names, NULL, values); name = values[0]; free(values); }
        }
        if (name && CFGetTypeID(name) == CFStringGetTypeID()) CFStringGetCString(name, buffer, bufferLength, kCFStringEncodingUTF8);
    }
    CFRelease(info);
}

LDDisplayConnection *LDDisplayOpenNative(uint32_t displayID, LDHardwareResult *result) {
    pthread_once(&symbolsOnce, loadSymbols);
    *result = LDHardwareUnsupported;
    if (!CGDisplayIsBuiltin(displayID) && CGDisplayVendorNumber(displayID) != 0x610) return NULL;
    if (!getBrightness || !setBrightness) { *result = LDHardwareAPIUnavailable; return NULL; }
    LDDisplayConnection *connection = newConnection(displayID);
    if (!connection) { *result = LDHardwareDisconnected; return NULL; }
    connection->native = true;
    float level = 0;
    *result = LDDisplayReadNative(connection, &level);
    if (*result != LDHardwareSuccess) { LDDisplayClose(connection); return NULL; }
    return connection;
}

LDHardwareResult LDDisplayReadNative(LDDisplayConnection *connection, float *value) {
    if (!connectionIsValid(connection)) return LDHardwareDisconnected;
    if (!connection->native || !getBrightness) return LDHardwareUnsupported;
    if (getBrightness(connection->displayID, value) || !isfinite(*value) || *value < 0 || *value > 1) return LDHardwareCommunicationFailed;
    return LDHardwareSuccess;
}

LDHardwareResult LDDisplayWriteNative(LDDisplayConnection *connection, float value) {
    if (!connectionIsValid(connection)) return LDHardwareDisconnected;
    if (!connection->native || !setBrightness) return LDHardwareUnsupported;
    if (!isfinite(value) || value < 0 || value > 1) return LDHardwareInvalidPacket;
    return setBrightness(connection->displayID, value) ? LDHardwareCommunicationFailed : LDHardwareSuccess;
}

#if defined(__arm64__)
static LDHardwareResult openAVConnection(LDDisplayConnection *connection) {
    if (!createAV || !copyEDID || !readAV || !writeAV) return LDHardwareAPIUnavailable;
    if (!uniqueOnlineIdentity(connection->vendor, connection->product, connection->serial)) return LDHardwareAmbiguous;
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) != KERN_SUCCESS)
        return LDHardwareUnsupported;
    uint32_t matches = 0;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        CFTypeRef location = IORegistryEntryCreateCFProperty(service, CFSTR("Location"), kCFAllocatorDefault, 0);
        bool external = location && CFGetTypeID(location) == CFStringGetTypeID() && CFEqual(location, CFSTR("External"));
        if (location) CFRelease(location);
        CFTypeRef av = external ? createAV(kCFAllocatorDefault, service) : NULL;
        uint8_t edid[128];
        if (av && copyValidEDID(av, edid) && edidMatches(edid, connection->vendor, connection->product, connection->serial)) {
            matches++;
            if (matches == 1) {
                connection->av = av;
                connection->service = service;
                memcpy(connection->edid, edid, 128);
                IORegistryEntryGetRegistryEntryID(service, &connection->serviceID);
                continue;
            }
        }
        if (av) CFRelease(av);
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    if (matches != 1) return matches > 1 ? LDHardwareAmbiguous : LDHardwareUnsupported;
    connection->ioAV = true;
    return connection->serviceID ? LDHardwareSuccess : LDHardwareDisconnected;
}
#else
static uint32_t dictionaryNumber(CFDictionaryRef dictionary, CFStringRef key) {
    CFTypeRef value = CFDictionaryGetValue(dictionary, key);
    int64_t number = 0;
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID() || !CFNumberGetValue(value, kCFNumberSInt64Type, &number)) return 0;
    return (uint32_t)number;
}

static io_service_t copyUniqueFramebuffer(LDDisplayConnection *connection) {
    if (!uniqueOnlineIdentity(connection->vendor, connection->product, connection->serial)) return 0;
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOFramebuffer"), &iterator) != KERN_SUCCESS) return 0;
    io_service_t found = 0, service;
    unsigned matches = 0;
    while ((service = IOIteratorNext(iterator))) {
        CFDictionaryRef info = IODisplayCreateInfoDictionary(service, kIODisplayOnlyPreferredName);
        bool match = info && dictionaryNumber(info, CFSTR(kDisplayVendorID)) == connection->vendor
            && dictionaryNumber(info, CFSTR(kDisplayProductID)) == connection->product
            && dictionaryNumber(info, CFSTR(kDisplaySerialNumber)) == connection->serial;
        if (info) CFRelease(info);
        if (match) { matches++; if (matches == 1) { found = service; continue; } }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    if (matches != 1 && found) { IOObjectRelease(found); found = 0; }
    return found;
}

static LDHardwareResult openI2CConnection(LDDisplayConnection *connection) {
    io_service_t framebuffer = 0;
    if (displayService) displayService(connection->displayID, &framebuffer);
    if (!framebuffer) framebuffer = copyUniqueFramebuffer(connection);
    if (!framebuffer) return LDHardwareUnsupported;
    connection->service = framebuffer;
    if (IORegistryEntryGetRegistryEntryID(framebuffer, &connection->serviceID) != KERN_SUCCESS) return LDHardwareDisconnected;
    IOItemCount busCount = 0;
    if (IOFBGetI2CInterfaceCount(framebuffer, &busCount) != KERN_SUCCESS) return LDHardwareUnsupported;
    unsigned matches = 0;
    for (IOOptionBits bus = 0; bus < busCount; bus++) {
        io_service_t interface = 0;
        if (IOFBCopyI2CInterfaceForBus(framebuffer, bus, &interface) != KERN_SUCCESS) continue;
        CFTypeRef types = IORegistryEntryCreateCFProperty(interface, CFSTR(kIOI2CTransactionTypesKey), kCFAllocatorDefault, 0);
        int64_t supported = 0;
        if (types && CFGetTypeID(types) == CFNumberGetTypeID()) CFNumberGetValue(types, kCFNumberSInt64Type, &supported);
        if (types) CFRelease(types);
        IOOptionBits reply = (supported & (1 << kIOI2CDDCciReplyTransactionType)) ? kIOI2CDDCciReplyTransactionType
            : (supported & (1 << kIOI2CSimpleTransactionType)) ? kIOI2CSimpleTransactionType : kIOI2CNoTransactionType;
        if (reply != kIOI2CNoTransactionType && (supported & (1 << kIOI2CSimpleTransactionType))) {
            matches++;
            if (matches == 1) {
                connection->interface = interface;
                connection->replyTransaction = reply;
                IORegistryEntryGetRegistryEntryID(interface, &connection->interfaceID);
                continue;
            }
        }
        IOObjectRelease(interface);
    }
    if (matches != 1) return matches > 1 ? LDHardwareAmbiguous : LDHardwareUnsupported;
    return connection->interfaceID ? LDHardwareSuccess : LDHardwareDisconnected;
}
#endif

LDDisplayConnection *LDDisplayOpenDDC(uint32_t displayID, LDHardwareResult *result) {
    pthread_once(&symbolsOnce, loadSymbols);
    *result = LDHardwareUnsupported;
    if (CGDisplayIsBuiltin(displayID)) return NULL;
    LDDisplayConnection *connection = newConnection(displayID);
    if (!connection) { *result = LDHardwareDisconnected; return NULL; }
#if defined(__arm64__)
    *result = openAVConnection(connection);
#else
    *result = openI2CConnection(connection);
#endif
    if (*result != LDHardwareSuccess) { LDDisplayClose(connection); return NULL; }
    return connection;
}

bool LDDisplayDDCUsesIOAV(const LDDisplayConnection *connection) { return connection && connection->ioAV; }

static bool permittedPacket(const LDDisplayConnection *connection, const uint8_t *bytes, uint32_t length, uint32_t replyLength) {
    if (!bytes || connection->native) return false;
    uint32_t start = connection->ioAV ? 0 : 1;
    if (!connection->ioAV && (length < 1 || bytes[0] != 0x51)) return false;
    bool read = replyLength == 11 && length == start + 4 && bytes[start] == 0x82 && bytes[start + 1] == 0x01;
    bool write = replyLength == 0 && length == start + 6 && bytes[start] == 0x84 && bytes[start + 1] == 0x03;
    if (!read && !write) return false;
    uint8_t control = bytes[start + 2];
    if (control != 0x10 && control != 0x62) return false;
    uint8_t checksum = connection->ioAV && read ? 0x6e : 0x6e ^ 0x51;
    for (uint32_t i = start; i + 1 < length; i++) checksum ^= bytes[i];
    return checksum == bytes[length - 1];
}

LDHardwareResult LDDisplayExchange(LDDisplayConnection *connection,
                                  const uint8_t *send, uint32_t sendLength,
                                  uint8_t *reply, uint32_t replyLength) {
    if (!connectionIsValid(connection)) return LDHardwareDisconnected;
    if (!permittedPacket(connection, send, sendLength, replyLength) || (replyLength && !reply)) return LDHardwareInvalidPacket;
    // DDC controllers need a quiet interval, including between consecutive writes.
    usleep(10000);
    if (!connectionIsValid(connection)) return LDHardwareDisconnected;
    if (connection->ioAV) {
        IOReturn result = writeAV(connection->av, 0x37, 0x51, (void *)send, sendLength);
        if (result != kIOReturnSuccess) return LDHardwareCommunicationFailed;
        if (replyLength) {
            usleep(50000);
            if (!connectionIsValid(connection)) return LDHardwareDisconnected;
            result = readAV(connection->av, 0x37, 0, reply, replyLength);
        }
        return result == kIOReturnSuccess ? LDHardwareSuccess : LDHardwareCommunicationFailed;
    }
    IOI2CConnectRef connect = NULL;
    if (IOI2CInterfaceOpen(connection->interface, 0, &connect) != kIOReturnSuccess || !connect) return LDHardwareCommunicationFailed;
    IOI2CRequest request = {0};
    request.sendAddress = 0x6e;
    request.sendTransactionType = kIOI2CSimpleTransactionType;
    request.sendBuffer = (vm_address_t)send;
    request.sendBytes = sendLength;
    if (replyLength) {
        request.minReplyDelay = 50000000; // IOI2CRequest specifies nanoseconds.
        request.replyAddress = 0x6f;
        request.replySubAddress = 0x51;
        request.replyTransactionType = connection->replyTransaction;
        request.replyBuffer = (vm_address_t)reply;
        request.replyBytes = replyLength;
    }
    IOReturn result = IOI2CSendRequest(connect, 0, &request);
    IOI2CInterfaceClose(connect, 0);
    return result == kIOReturnSuccess && request.result == kIOReturnSuccess ? LDHardwareSuccess : LDHardwareCommunicationFailed;
}
