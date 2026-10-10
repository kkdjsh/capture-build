// Tweak.xm - 抓包插件 v3 (网球风格)
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL enableCapture = NO;
static NSMutableArray *reqs; // each: dict with method/url/status/reqHeaders/reqBody/respBody/time
static const int MAX_REQS = 200;

static void addReq(NSDictionary *r) {
    if (!reqs) reqs = [NSMutableArray new];
    [reqs addObject:r];
    if (reqs.count > MAX_REQS) [reqs removeObjectsInRange:NSMakeRange(0, reqs.count-MAX_REQS)];
    // 通知 UI 刷新
    [[NSNotificationCenter defaultCenter] postNotificationName:@"CapNewReq" object:nil];
}

#pragma mark - UI

@interface CapListVC : UIViewController <UITableViewDataSource, UITableViewDelegate>
@end

@interface CapUI : NSObject
@property (nonatomic, strong) UIButton *btn;
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, strong) UIView *panel;
@end

@implementation CapUI

- (void)showPanel {
    if (_panel) { [_panel removeFromSuperview]; _panel = nil; return; }
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 50, w.frame.size.width, w.frame.size.height-100)];
    _panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.97];
    [w addSubview:_panel];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, 200, 24)];
    title.text = @"抓包"; title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:18];
    [_panel addSubview:title];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(w.frame.size.width-50, 10, 40, 24);
    [closeBtn setTitle:@"关闭" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:closeBtn];

    UIButton *toggleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    toggleBtn.frame = CGRectMake(10, 38, 80, 24);
    [toggleBtn setTitleColor:[UIColor greenColor] forState:UIControlStateNormal];
    toggleBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    [toggleBtn addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:toggleBtn];
    toggleBtn.tag = 99;

    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    clearBtn.frame = CGRectMake(100, 38, 60, 24);
    [clearBtn setTitle:@"清空" forState:UIControlStateNormal];
    [clearBtn setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal];
    clearBtn.titleLabel.font = [UIFont systemFontOfSize:13];
    [clearBtn addTarget:self action:@selector(clear) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:clearBtn];

    _tv = [[UITableView alloc] initWithFrame:CGRectMake(0, 70, w.frame.size.width, _panel.frame.size.height-70) style:UITableViewStylePlain];
    _tv.backgroundColor = [UIColor blackColor];
    _tv.dataSource = self;
    _tv.delegate = self;
    [_tv registerClass:[UITableViewCell class] forCellReuseIdentifier:@"c"];
    [_panel addSubview:_tv];

    [self refreshToggle:toggleBtn];

    [[NSNotificationCenter defaultCenter] addObserverForName:@"CapNewReq" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        [self.tv reloadData];
    }];
}

- (void)refreshToggle:(UIButton*)b {
    b = [_panel viewWithTag:99];
    [b setTitle:enableCapture ? @"● 抓包中" : @"○ 已关" forState:UIControlStateNormal];
}

- (void)closePanel { [_panel removeFromSuperview]; _panel = nil; }
- (void)toggle {
    enableCapture = !enableCapture;
    [self refreshToggle:nil];
}
- (void)clear { [reqs removeAllObjects]; [_tv reloadData]; }

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return reqs.count; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    NSDictionary *r = reqs[ip.row];
    NSString *m = r[@"method"] ?: @"?";
    NSString *u = r[@"url"] ?: @"";
    NSString *st = r[@"status"] ?: @"";
    c.textLabel.text = [NSString stringWithFormat:@"[%@] %@ %@", m, st, u];
    c.textLabel.textColor = [UIColor greenColor];
    c.textLabel.font = [UIFont fontWithName:@"Courier" size:9];
    c.backgroundColor = [UIColor blackColor];
    return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *r = reqs[ip.row];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:r[@"url"] message:nil preferredStyle:UIAlertControllerStyleAlert];
    NSMutableString *msg = [NSMutableString new];
    [msg appendFormat:@"Method: %@\n", r[@"method"]];
    [msg appendFormat:@"Status: %@\n\n", r[@"status"]];
    if (r[@"reqHeaders"]) [msg appendFormat:@"Req Headers: %@\n\n", r[@"reqHeaders"]];
    if (r[@"reqBody"]) [msg appendFormat:@"Req Body: %@\n\n", r[@"reqBody"]];
    if (r[@"respBody"]) [msg appendFormat:@"Resp Body: %@", r[@"respBody"]];
    a.message = msg.length>3000 ? [msg substringToIndex:3000] : msg;
    [a addAction:[UIAlertAction actionWithTitle:@"关闭" style:UIAlertActionStyleCancel handler:nil]];
    [[[UIApplication sharedApplication] keyWindow].rootViewController presentViewController:a animated:YES completion:nil];
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
    NSMutableURLRequest *m = [request mutableCopy];
    NSString *method = m.HTTPMethod ?: @"GET";
    NSString *url = m.URL.absoluteString;
    NSMutableDictionary *rec = [NSMutableDictionary new];
    rec[@"method"] = method; rec[@"url"] = url;
    if (enableCapture) {
        rec[@"reqHeaders"] = m.allHTTPHeaderFields ?: @{};
        if (m.HTTPBody) rec[@"reqBody"] = [[NSString alloc] initWithData:m.HTTPBody encoding:NSUTF8StringEncoding] ?: @"";
    }
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *d, NSURLResponse *r, NSError *e) {
        if (enableCapture && d) {
            rec[@"status"] = [NSString stringWithFormat:@"%ld", (long)[(NSHTTPURLResponse*)r statusCode]];
            rec[@"respBody"] = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
            addReq(rec);
        }
        completionHandler(d, r, e);
    };
    return %orig(m, wrapped);
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    NSMutableDictionary *rec = [NSMutableDictionary new];
    rec[@"method"] = @"GET"; rec[@"url"] = url.absoluteString;
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *d, NSURLResponse *r, NSError *e) {
        if (enableCapture && d) {
            rec[@"status"] = [NSString stringWithFormat:@"%ld", (long)[(NSHTTPURLResponse*)r statusCode]];
            rec[@"respBody"] = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
            addReq(rec);
        }
        completionHandler(d, r, e);
    };
    return %orig(url, wrapped);
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

%ctor {
    dispatch_async(dispatch_get_main_queue(), ^{
        capUI = [CapUI new];
        UIWindow *w = [UIApplication sharedApplication].keyWindow;
        capUI.btn = [UIButton buttonWithType:UIButtonTypeSystem];
        capUI.btn.frame = CGRectMake(w.frame.size.width-56, 300, 44, 44);
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
