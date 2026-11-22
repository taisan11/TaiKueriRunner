#import "MGKeysBridge.h"
#include "../../Vendor/MGKeys/mapping.h"
#include "../../Vendor/MGKeys/mapping-legacy.h"

// MGKeys (MIT), PoomSmart. Fixed snapshot; no runtime network requests.
NSDictionary<NSString *, NSString *> *TKMobileGestaltKeyNames(void) {
    NSMutableDictionary<NSString *, NSString *> *names = [NSMutableDictionary dictionary];
    for (size_t i = 0; keyMappingTableLegacy[i].obfuscatedKey; i++) {
        const struct tKeyMapping item = keyMappingTableLegacy[i];
        if (item.key) names[@(item.obfuscatedKey)] = @(item.key);
    }
    for (size_t i = 0; keyMappingTable[i].obfuscatedKey; i++) {
        const struct tKeyMapping item = keyMappingTable[i];
        if (item.key) names[@(item.obfuscatedKey)] = @(item.key);
    }
    return names;
}
