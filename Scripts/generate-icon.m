#import <Cocoa/Cocoa.h>

// Run from the repository root; writes the iconset used by iconutil.
int main(void) {
    @autoreleasepool {
        NSString *directory = @"build/CommandDrag.iconset";
        NSError *error = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtPath:directory
                withIntermediateDirectories:YES attributes:nil error:&error]) {
            NSLog(@"%@", error);
            return 1;
        }
        for (NSNumber *base in @[@16, @32, @128, @256, @512]) {
            for (NSInteger scale = 1; scale <= 2; scale++) {
                NSInteger pixels = base.integerValue * scale;
                NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
                    initWithBitmapDataPlanes:NULL pixelsWide:pixels pixelsHigh:pixels
                    bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO
                    colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
                [NSGraphicsContext saveGraphicsState];
                [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap]];
                NSAffineTransform *transform = [NSAffineTransform transform];
                [transform scaleBy:(CGFloat)pixels / 1024];
                [transform concat];

                NSBezierPath *tile = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(64, 64, 896, 896)
                    xRadius:200 yRadius:200];
                NSGradient *gradient = [[NSGradient alloc]
                    initWithStartingColor:[NSColor colorWithSRGBRed:0.10 green:0.30 blue:0.75 alpha:1]
                    endingColor:[NSColor colorWithSRGBRed:0.23 green:0.64 blue:0.98 alpha:1]];
                [gradient drawInBezierPath:tile angle:65];

                // A window outline, Command symbol, and diagonal resize arrow.
                [[NSColor whiteColor] setStroke];
                NSBezierPath *window = [NSBezierPath bezierPathWithRoundedRect:NSMakeRect(210, 290, 604, 450)
                    xRadius:42 yRadius:42];
                window.lineWidth = 32;
                [window stroke];
                NSBezierPath *titleBar = [NSBezierPath bezierPath];
                [titleBar moveToPoint:NSMakePoint(210, 640)];
                [titleBar lineToPoint:NSMakePoint(814, 640)];
                titleBar.lineWidth = 24;
                [titleBar stroke];
                NSDictionary *attributes = @{
                    NSFontAttributeName: [NSFont systemFontOfSize:250 weight:NSFontWeightMedium],
                    NSForegroundColorAttributeName: NSColor.whiteColor
                };
                NSString *command = @"⌘";
                NSSize textSize = [command sizeWithAttributes:attributes];
                [command drawAtPoint:NSMakePoint(512 - textSize.width / 2, 315) withAttributes:attributes];

                NSBezierPath *arrow = [NSBezierPath bezierPath];
                [arrow moveToPoint:NSMakePoint(680, 394)];
                [arrow lineToPoint:NSMakePoint(840, 234)];
                [arrow moveToPoint:NSMakePoint(680, 294)];
                [arrow lineToPoint:NSMakePoint(680, 394)];
                [arrow lineToPoint:NSMakePoint(780, 394)];
                [arrow moveToPoint:NSMakePoint(740, 234)];
                [arrow lineToPoint:NSMakePoint(840, 234)];
                [arrow lineToPoint:NSMakePoint(840, 334)];
                arrow.lineWidth = 38;
                arrow.lineCapStyle = NSLineCapStyleRound;
                arrow.lineJoinStyle = NSLineJoinStyleRound;
                // A blue underlay separates the arrow from the window outline.
                [[NSColor colorWithSRGBRed:0.13 green:0.37 blue:0.80 alpha:1] setStroke];
                arrow.lineWidth = 76;
                [arrow stroke];
                [[NSColor whiteColor] setStroke];
                arrow.lineWidth = 38;
                [arrow stroke];
                [NSGraphicsContext restoreGraphicsState];

                NSString *name = [NSString stringWithFormat:@"icon_%@x%@%@.png",
                    base, base, scale == 2 ? @"@2x" : @""];
                NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                if (![png writeToFile:[directory stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:&error]) {
                    NSLog(@"%@", error);
                    return 1;
                }
            }
        }
    }
    return 0;
}
