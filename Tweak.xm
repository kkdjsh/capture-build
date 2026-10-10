// Tweak.xm - 抓包+重写插件
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL enableCapture = NO;
static NSMutableArray *logLines;
static const int MAX_LOG = 100;

static void logLine(NSString *s) {
    if (!logLines) logLines = [NSMutableArray new];
    NSDateFormatter *f = [NSDateFormatter new]; f.dateFormat = @"HH:mm:ss";
    NSString *line = [NSString stringWithFormat:@"[%@] %@", [f stringFromDate:[NSDate date]], s];
    [logLines addObject:line];
    if (logLines.count > MAX_LOG) [logLines removeObjectsInRange:NSMakeRange(0, logLines.count-MAX_LOG)];
    NSLog(@"[Cap] %@", line);
}

#pragma mark - UI

static UIButton *capBtn;
static UIView *panel;
static UITextView *tv;
static UILabel *statusLbl;

static void refreshStatus() {
    statusLbl.text = enableCapture ? @"● 抓包中" : @"○ 已关闭";
    statusLbl.textColor = enableCapture ? [UIColor colorWithRed:0.3 green:1 blue:0.3 alpha:1] : [UIColor grayColor];
}

static void showPanel() {
    if (panel) { [panel removeFromSuperview]; panel = nil; return; }
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    panel = [[UIView alloc] initWithFrame:CGRectMake(30, 130, 310, 400)];
    panel.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.96];
    panel.layer.cornerRadius = 12;
    [w addSubview:panel];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, 290, 24)];
    t.text = @"抓包面板"; t.textColor = [UIColor whiteColor];
    t.font = [UIFont boldSystemFontOfSize:16]; t.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:t];

    statusLbl = [[UILabel alloc] initWithFrame:CGRectMake(10, 38, 290, 20)];
    statusLbl.font = [UIFont systemFontOfSize:13]; statusLbl.textAlignment = NSTextAlignmentCenter;
    [panel addSubview:statusLbl];
    refreshStatus();

    NSArray *btns = @[@"开启抓包", @"关闭抓包", @"刷新日志", @"清空日志"];
    for (int i = 0; i < 4; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(10, 64+i*36, 290, 30);
        [b setTitle:btns[i] forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1 alpha:0.9];
        b.layer.cornerRadius = 6;
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.tag = i;
        [b addTarget:nil action:NSSelectorFromString(@"capBtn:") forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(b, "idx", @(i), OBJC_ASSOCIATION_RETAIN);
        [panel addSubview:b];
    }
    tv = [[UITextView alloc] initWithFrame:CGRectMake(10, 218, 290, 164)];
    tv.backgroundColor = [UIColor blackColor];
    tv.textColor = [UIColor greenColor];
    tv.font = [UIFont fontWithName:@"Courier" size:8];
    tv.editable = NO; tv.text = @"日志";
    [panel addSubview:tv];
}

static void refreshLog() {
    tv.text = logLines.count ? [logLines componentsJoinedByString:@"\n"] : @"(无日志)";
}

#pragma mark - Hook

%hook NSURLSessionConfiguration
+ (NSURLSessionConfiguration *)defaultSessionConfiguration {
    NSURLSessionConfiguration *c = %orig;
    c.TLSMinimumSupportedProtocol = kTLSProtocol12;
    return c;
}
%end

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (enableCapture) {
        NSMutableURLRequest *m = [request mutableCopy];
        logLine([NSString stringWithFormat:@"→ %@ %@", m.HTTPMethod, m.URL.absoluteString]);
        if (m.allHTTPHeaderFields) logLine([NSString stringWithFormat:@"  H: %@", m.allHTTPHeaderFields]);
        if (m.HTTPBody) {
            NSString *b = [[NSString alloc] initWithData:m.HTTPBody encoding:NSUTF8StringEncoding];
            logLine([NSString stringWithFormat:@"  Body: %@", b.length>300?[b substringToIndex:300]:b]);
        }
        void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *d, NSURLResponse *r, NSError *e) {
            if (enableCapture && d) {
                NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
                NSInteger code = [(NSHTTPURLResponse*)r statusCode];
                logLine([NSString stringWithFormat:@"← %ld %@", (long)code, r.URL.absoluteString]);
                logLine([NSString stringWithFormat:@"  Resp: %@", s.length>300?[s substringToIndex:300]:s]);
            }
            completionHandler(d, r, e);
        };
        return %orig(m, wrapped);
    }
    return %orig;
}
%end

// SSL Pinning 绕过
%hook NSObject
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
  completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        NSURLCredential *cred = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
        completionHandler(NSURLSessionAuthChallengeUseCredential, cred);
    } else {
        %orig;
    }
}
%end

#pragma mark - init

%ctor {
    logLine(@"抓包插件 v1 已加载");
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = [UIApplication sharedApplication].keyWindow;
        capBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        capBtn.frame = CGRectMake(w.frame.size.width-56, 280, 44, 44);
        [capBtn setTitle:@"抓包" forState:UIControlStateNormal];
        capBtn.titleLabel.font = [UIFont systemFontOfSize:11];
        capBtn.backgroundColor = [UIColor colorWithRed:0.9 green:0.5 blue:0.2 alpha:0.9];
        capBtn.layer.cornerRadius = 22;
        [capBtn addTarget:nil action:NSSelectorFromString(@"showPanel") forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:nil action:NSSelectorFromString(@"pan:")];
        [capBtn addGestureRecognizer:pan];
        [w addSubview:capBtn];
    });
}
