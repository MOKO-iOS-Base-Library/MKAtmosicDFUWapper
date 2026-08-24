//
//  MKAtmosicDFUWapper.m
//  MKAtmosicDFUWapper
//
//  Created by aa on 2026/8/24.
//  Copyright © 2026 lovexiaoxia. All rights reserved.
//

#import "MKAtmosicDFUWapper.h"
#import "MKAtmosicDFUWapper-Swift.h"

@interface MKAtmosicDFUWapper ()

@property (nonatomic, strong) AtmosicDFUWrapper *swiftWrapper;

@end

@implementation MKAtmosicDFUWapper

- (void)startOTAWithFilePath:(NSString *)filePath
                  peripheral:(id)peripheral
               progressBlock:(void (^)(CGFloat))progressBlock
                    sucBlock:(void (^)(void))sucBlock
                 failedBlock:(void (^)(NSError *))failedBlock {
    self.swiftWrapper = [[AtmosicDFUWrapper alloc] init];
    [self.swiftWrapper startOTAWithFilePath:filePath
                                 peripheral:peripheral
                              progressBlock:progressBlock
                                   sucBlock:sucBlock
                                failedBlock:failedBlock];
}

- (void)cancel {
    [self.swiftWrapper cancel];
    self.swiftWrapper = nil;
}

@end
