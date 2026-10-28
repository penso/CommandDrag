#import <Cocoa/Cocoa.h>

// Run from the repository root to regenerate both Finder background resolutions.
int main(void) {
    @autoreleasepool {
        for (NSInteger scale = 1; scale <= 2; scale++) {
            NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                               pixelsWide:640 * scale
                                                                               pixelsHigh:480 * scale
                                                                            bitsPerSample:8
                                                                          samplesPerPixel:4
                                                                                 hasAlpha:YES
                                                                                 isPlanar:NO
                                                                           colorSpaceName:NSDeviceRGBColorSpace
                                                                              bytesPerRow:0
                                                                             bitsPerPixel:0];
            if (!bitmap) return 1;
            [NSGraphicsContext saveGraphicsState];
            [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
            NSAffineTransform *transform = [NSAffineTransform transform];
            [transform scaleBy:(CGFloat)scale];
            [transform concat];
            [[NSColor colorWithSRGBRed:0.96 green:0.97 blue:0.99 alpha:1] setFill];
            NSRectFill(NSMakeRect(0, 0, 640, 480));
            NSArray<NSString *> *lines = @[
                @"Install CommandDrag", @"Drag CommandDrag to Applications", @"Then open it from Applications.",
                @"Move · Resize · Focus on hover"
            ];
            CGFloat sizes[] = {28, 17, 14, 13};
            CGFloat positions[] = {405, 370, 151, 95};
            for (NSUInteger i = 0; i < lines.count; i++) {
                NSDictionary *attributes = @{
                    NSFontAttributeName: [NSFont systemFontOfSize:sizes[i]
                                                           weight:i == 0 ? NSFontWeightSemibold : NSFontWeightRegular],
                    NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.16 green:0.23 blue:0.35 alpha:1]
                };
                CGFloat width = [lines[i] sizeWithAttributes:attributes].width;
                [lines[i] drawAtPoint:NSMakePoint((640 - width) / 2, positions[i]) withAttributes:attributes];
            }
            [[NSColor colorWithSRGBRed:0.20 green:0.46 blue:0.88 alpha:1] setStroke];
            NSBezierPath *arrow = [NSBezierPath bezierPath];
            arrow.lineWidth = 5;
            arrow.lineCapStyle = NSLineCapStyleRound;
            arrow.lineJoinStyle = NSLineJoinStyleRound;
            [arrow moveToPoint:NSMakePoint(286, 280)];
            [arrow lineToPoint:NSMakePoint(354, 280)];
            [arrow moveToPoint:NSMakePoint(339, 295)];
            [arrow lineToPoint:NSMakePoint(354, 280)];
            [arrow lineToPoint:NSMakePoint(339, 265)];
            [arrow stroke];
            [NSGraphicsContext restoreGraphicsState];
            NSString *path = scale == 1 ? @"assets/dmg-background.png" : @"assets/dmg-background@2x.png";
            NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
            if (![png writeToFile:path atomically:YES]) return 1;
        }
    }
    return 0;
}
