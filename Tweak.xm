// Tweak.xm - 抓包+重写插件 v4
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static BOOL enableCapture = NO;
static NSMutableArray *reqs;
static const int MAX_REQS = 200;
static NSString *rewriteFind = @"";
static NSString *rewriteRepl = @"";

static void addReq(NSDictionary *r) {
    if (!reqs) reqs = [NSMutableArray new];
    [reqs addObject:r];
    if (reqs.count > MAX_REQS) [reqs removeObjectsInRange:NSMakeRange(0, reqs.count-MAX_REQS)];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"CapNewReq" object:nil];
}

// 按 task 累计响应数据
static NSMapTable *taskMap;

#pragma mark - UI

@interface CapUI : NSObject <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UIButton *btn;
@property (nonatomic, strong) UIView *panel;
@property (nonatomic, strong) UITableView *tv;
@property (nonatomic, strong) UILabel *statusLbl;
@end

@implementation CapUI

- (void)showPanel {
    if (_panel) { [_panel removeFromSuperview]; _panel = nil; return; }
    UIWindow *w = [UIApplication sharedApplication].keyWindow;
    _panel = [[UIView alloc] initWithFrame:CGRectMake(0, 50, w.frame.size.width, w.frame.size.height-100)];
    _panel.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.97];
    [w addSubview:_panel];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(10, 10, 200, 24)];
    title.text = @"抓包面板"; title.textColor = [UIColor whiteColor];
    title.font = [UIFont boldSystemFontOfSize:18];
    [_panel addSubview:title];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(w.frame.size.width-50, 10, 40, 24);
    [closeBtn setTitle:@"关闭" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:closeBtn];

    _statusLbl = [[UILabel alloc] initWithFrame:CGRectMake(10, 38, 100, 22)];
    _statusLbl.font = [UIFont systemFontOfSize:13];
    [_panel addSubview:_statusLbl];
    [self refreshStatus];

    UIButton *toggleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    toggleBtn.frame = CGRectMake(110, 38, 60, 22);
    [toggleBtn setTitle:@"开关" forState:UIControlStateNormal];
    [toggleBtn setTitleColor:[UIColor yellowColor] forState:UIControlStateNormal];
    toggleBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    [toggleBtn addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:toggleBtn];

    UIButton *rwBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    rwBtn.frame = CGRectMake(180, 38, 60, 22);
    [rwBtn setTitle:@"重写" forState:UIControlStateNormal];
    [rwBtn setTitleColor:[UIColor orangeColor] forState:UIControlStateNormal];
    rwBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    [rwBtn addTarget:self action:@selector(editRewrite) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:rwBtn];

    UIButton *clearBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    clearBtn.frame = CGRectMake(250, 38, 50, 22);
    [clearBtn setTitle:@"清空" forState:UIControlStateNormal];
    [clearBtn setTitleColor:[UIColor redColor] forState:UIControlStateNormal];
    clearBtn.titleLabel.font = [UIFont systemFontOfSize:12];
    [clearBtn addTarget:self action:@selector(clear) forControlEvents:UIControlEventTouchUpInside];
    [_panel addSubview:clearBtn];

    _tv = [[UITableView alloc] initWithFrame:CGRectMake(0, 68, w.frame.size.width, _panel.frame.size.height-68) style:UITableViewStylePlain];
    _tv.backgroundColor = [UIColor blackColor];
    _tv.dataSource = self; _tv.delegate = self;
    [_tv registerClass:[UITableViewCell class] forCellReuseIdentifier:@"c"];
    [_panel addSubview:_tv];

    [[NSNotificationCenter defaultCenter] addObserverForName:@"CapNewReq" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        [self.tv reloadData];
    }];
}

- (void)refreshStatus {
    _statusLbl.text = enableCapture ? @"● 抓包中" : @"○ 已关";
    _statusLbl.textColor = enableCapture ? [UIColor greenColor] : [UIColor grayColor];
}
- (void)close { [_panel removeFromSuperview]; _panel = nil; }
- (void)toggle { enableCapture = !enableCapture; [self refreshStatus]; }
- (void)clear { [reqs removeAllObjects]; [_tv reloadData]; }

- (void)editRewrite {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"响应重写" message:@"查找(留空关闭)" preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"查找内容"; f.text = rewriteFind; }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"替换为"; f.text = rewriteRepl; }];
    [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *_) {
        rewriteFind = a.textFields[0].text ?: @"";
        rewriteRepl = a.textFields[1].text ?: @"";
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [[[UIApplication sharedApplication] keyWindow].rootViewController presentViewController:a animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return reqs.count; }
- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c" forIndexPath:ip];
    NSDictionary *r = reqs[ip.row];
    c.textLabel.text = [NSString stringWithFormat:@"[%@] %@ %@", r[@"method"]?:@"?", r[@"status"]?:@"", r[@"url"]?:@""];
    c.textLabel.textColor = [UIColor greenColor];
    c.textLabel.font = [UIFont fontWithName:@"Courier" size:9];
    c.backgroundColor = [UIColor blackColor];
    return c;
}
- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *r = reqs[ip.row];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:r[@"url"] message:nil preferredStyle:UIAlertControllerStyleAlert];
    NSMutableString *msg = [NSMutableString new];
    [msg appendFormat:@"Method: %@\nStatus: %@\n\n", r[@"method"], r[@"status"]];
    if (r[@"reqHeaders"]) [msg appendFormat:@"ReqH: %@\n\n", r[@"reqHeaders"]];
    if (r[@"reqBody"]) [msg appendFormat:@"ReqB: %@\n\n", r[@"reqBody"]];
    if (r[@"respBody"]) [msg appendFormat:@"RespB: %@", r[@"respBody"]];
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

#pragma mark - Hook NSURLSession (completionHandler 模式)

%hook NSURLSession
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    NSMutableURLRequest *m = [request mutableCopy];
    NSMutableDictionary *rec = [NSMutableDictionary new];
    rec[@"method"] = m.HTTPMethod ?: @"GET";
    rec[@"url"] = m.URL.absoluteString;
    if (enableCapture) {
        rec[@"reqHeaders"] = m.allHTTPHeaderFields ?: @{};
        if (m.HTTPBody) rec[@"reqBody"] = [[NSString alloc] initWithData:m.HTTPBody encoding:NSUTF8StringEncoding] ?: @"";
    }
    void (^wrapped)(NSData *, NSURLResponse *, NSError *) = ^(NSData *d, NSURLResponse *r, NSError *e) {
        if (enableCapture && d) {
            rec[@"status"] = [NSString stringWithFormat:@"%ld", (long)[(NSHTTPURLResponse*)r statusCode]];
            NSString *body = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
            // 响应重写
            if (rewriteFind.length > 0 && [body containsString:rewriteFind]) {
                body = [body stringByReplacingOccurrencesOfString:rewriteFind withString:rewriteRepl];
                d = [body dataUsingEncoding:NSUTF8StringEncoding];
                rec[@"rewritten"] = @"YES";
            }
            rec[@"respBody"] = body;
            addReq(rec);
        }
        completionHandler(d, r, e);
    };
    return %orig(m, wrapped);
}
%end

#pragma mark - Hook delegate 模式 (NSURLSession delegate 回调)

%hook NSObject
// SSL Pinning 绕过
- (void)URLSession:(NSURLSession *)session didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
  completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        NSURLCredential *cred = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
        completionHandler(NSURLSessionAuthChallengeUseCredential, cred);
    } else {
        %orig;
    }
}
// 收到响应头
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    if (enableCapture) {
        NSMutableDictionary *rec = [NSMutableDictionary new];
        rec[@"url"] = response.URL.absoluteString;
        rec[@"status"] = [NSString stringWithFormat:@"%ld", (long)[(NSHTTPURLResponse*)response statusCode]];
        rec[@"method"] = dataTask.originalRequest.HTTPMethod ?: @"?";
        NSMutableData *d = [NSMutableData new];
        objc_setAssociatedObject(dataTask, "rec", rec, OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(dataTask, "acc", d, OBJC_ASSOCIATION_RETAIN);
    }
    %orig;
}
// 收到响应数据(分片)
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (enableCapture) {
        NSMutableData *acc = objc_getAssociatedObject(dataTask, "acc");
        if (acc) [acc appendData:data];
    }
    %orig;
}
// 请求完成
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (enableCapture) {
        NSMutableDictionary *rec = objc_getAssociatedObject(task, "rec");
        NSMutableData *acc = objc_getAssociatedObject(task, "acc");
        if (rec && acc) {
            NSString *body = [[NSString alloc] initWithData:acc encoding:NSUTF8StringEncoding] ?: @"";
            if (rewriteFind.length > 0 && [body containsString:rewriteFind]) {
                body = [body stringByReplacingOccurrencesOfString:rewriteFind withString:rewriteRepl];
            }
            rec[@"respBody"] = body;
            addReq(rec);
        }
    }
    %orig;
}
%end

#pragma mark - init

%ctor {
    taskMap = [NSMapTable weakToWeakObjectsMapTable];
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
