// Tweak.xm - 抓包+重写插件 v2
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

#pragma mark - UI Target

@interface CapUI : NSObject
@property (nonatomic, strong) UIButton *btn;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UITextView *tv;
@property (nonatomic, strong) UILabel *statusLbl;
@end
@implementation CapUI

- (void)showPanel {
    if (_panel) { [_panel removeFromSuperview]; _panel = nil; return; }
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    _panel = [[UIView alloc] initWithFrame:CGRectMake(30, 130, 310, 400)];
    _panel.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.96];
    _panel.layer.cornerRadius = 12;
    [w addSubview:_panel];

    UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, 290, 24)];
    t.text = @"抓包面板"; t.textColor = [UIColor whiteColor];
    t.font = [UIFont boldSystemFontOfSize:16]; t.textAlignment = NSTextAlignmentCenter;
    [_panel addSubview:t];

    _statusLbl = [[UILabel alloc] initWithFrame:CGRectMake(10, 38, 290, 20)];
    _statusLbl.font = [UIFont systemFontOfSize:13]; _statusLbl.textAlignment = NSTextAlignmentCenter;
    [_panel addSubview:_statusLbl];
    [self refreshStatus];

    NSArray *btns = @[@"开启抓包", @"关闭抓包", @"刷新日志", @"清空日志"];
    for (int i = 0; i < 4; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(10, 64+i*36, 290, 30);
        [b setTitle:btns[i] forState:UIControlStateNormal];
        b.backgroundColor = [UIColor colorWithRed:0.2 green:0.6 blue:1 alpha:0.9];
        b.layer.cornerRadius = 6;
        [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        b.tag = i;
        [b addTarget:self action:@selector(doBtn:) forControlEvents:UIControlEventTouchUpInside];
        [_panel addSubview:b];
    }
    _tv = [[UITextView alloc] initWithFrame:CGRectMake(10, 218, 290, 164)];
    _tv.backgroundColor = [UIColor blackColor];
    _tv.textColor = [UIColor greenColor];
    _tv.font = [UIFont fontWithName:@"Courier" size:8];
    _tv.editable = NO; _tv.text = @"日志";
    [_panel addSubview:_tv];
}

- (void)refreshStatus {
    _statusLbl.text = enableCapture ? @"● 抓包中" : @"○ 已关闭";
    _statusLbl.textColor = enableCapture ? [UIColor colorWithRed:0.3 green:1 blue:0.3 alpha:1] : [UIColor grayColor];
}

- (void)doBtn:(UIButton *)b {
    if (b.tag == 0) { enableCapture = YES; logLine(@">>> 抓包开启"); }
    else if (b.tag == 1) { enableCapture = NO; logLine(@">>> 抓包关闭"); }
    else if (b.tag == 2) { _tv.text = logLines.count ? [logLines componentsJoinedByString:@"\n"] : @"(无)"; }
    else { [logLines removeAllObjects]; _tv.text = @"(已清空)"; }
    [self refreshStatus];
}

- (void)btnTap { [self showPanel]; }

- (void)pan:(UIPanGestureRecognizer *)g {
    UIView *v = g.view; CGPoint p = [g translationInView:v.superview];
    CGRect f = v.frame; f.origin.x+=p.x; f.origin.y+=p.y; v.frame=f;
    [g setTranslation:CGPointZero inView:v.superview];
}
@end

static CapUI *capUI;

#pragma mark - Hook NSURLSession

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
        // === 请求重写示例 ===
        // [m setValue:@"FAKE" forHTTPHeaderField:@"X-Debug"];
        // m.URL = [NSURL URLWithString:@"https://example.com"];

        void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *d, NSURLResponse *r, NSError *e) {
            if (enableCapture && d) {
                NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
                NSInteger code = [(NSHTTPURLResponse*)r statusCode];
                logLine([NSString stringWithFormat:@"← %ld %@", (long)code, r.URL.absoluteString]);
                logLine([NSString stringWithFormat:@"  Resp: %@", s.length>300?[s substringToIndex:300]:s]);
                // === 响应重写示例 ===
                // NSString *ns = [s stringByReplacingOccurrencesOfString:@"old" withString:@"new"];
                // d = [ns dataUsingEncoding:NSUTF8StringEncoding];
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
    logLine(@"抓包插件 v2 已加载");
    dispatch_async(dispatch_get_main_queue(), ^{
        capUI = [CapUI new];
        UIWindow *w = [UIApplication sharedApplication].keyWindow;
        capUI.btn = [UIButton buttonWithType:UIButtonTypeSystem];
        capUI.btn.frame = CGRectMake(w.frame.size.width-56, 280, 44, 44);
        [capUI.btn setTitle:@"抓包" forState:UIControlStateNormal];
        capUI.btn.titleLabel.font = [UIFont systemFontOfSize:11];
        capUI.btn.backgroundColor = [UIColor colorWithRed:0.9 green:0.5 blue:0.2 alpha:0.9];
        capUI.btn.layer.cornerRadius = 22;
        [capUI.btn addTarget:capUI action:@selector(btnTap) forControlEvents:UIControlEventTouchUpInside];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:capUI action:@selector(pan:)];
        [capUI.btn addGestureRecognizer:pan];
        [w addSubview:capUI.btn];
    });
}
