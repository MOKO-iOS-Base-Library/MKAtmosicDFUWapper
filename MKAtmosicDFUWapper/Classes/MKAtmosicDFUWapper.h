//
//  MKAtmosicDFUWapper.h
//  MKAtmosicDFUWapper
//
//  Created by aa on 2026/8/24.
//  Copyright © 2026 lovexiaoxia. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MKAtmosicDFUWapper : NSObject

/// Start OTA firmware update.
/// @param filePath Local file path of the firmware archive.
/// @param peripheral The connected CBPeripheral to update.
/// @param progressBlock Called on main thread with progress 0.0~1.0.
/// @param sucBlock Called on main thread when firmware update succeeds.
/// @param failedBlock Called on main thread with an NSError on failure.
- (void)startOTAWithFilePath:(NSString *)filePath
                  peripheral:(id)peripheral
               progressBlock:(void (^)(CGFloat progress))progressBlock
                    sucBlock:(void (^)(void))sucBlock
                 failedBlock:(void (^)(NSError *error))failedBlock;

/// Cancel the ongoing OTA process and disconnect.
- (void)cancel;

@end

NS_ASSUME_NONNULL_END
