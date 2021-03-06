//
//  FLDownloader.m
//  FileSafe
//
//  Created by Lombardo on 17/11/13.
//
//

#import "FLDownloader.h"
#import "FLDownloadTask.h"

/**
 Private category for FLDownloadTask
 */
@interface FLDownloadTask (Private)

- (id)initPrivate;
- (void)cancelPrivate;
@property (weak, nonatomic, readwrite) NSURLSessionDownloadTask *downloadTask;
@property (strong, nonatomic, readwrite) NSURL *url;

@end


/**
 Constant to archive - unarchive Downloads dictionary
 */
static NSString *kFLDownloadUserDefaultsObject = @"kFLDownloadUserDefaultsObject";

@interface FLDownloader ()

@property (weak, nonatomic) NSURLSession *backgroundSession;
@property (copy, nonatomic, readwrite) NSMutableDictionary *tasks;

@end

static FLDownloader *sharedDownloader = nil;
static NSString *kFLDownloaderBackgroundSessionIdentifier = @"com.FLDownloader.backgroundSession";

@implementation FLDownloader

#pragma mark - init

+(id)sharedDownloader
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        if (sharedDownloader == nil) {
            sharedDownloader = [[self alloc] initPrivate];
        }
    });
    return sharedDownloader;
}

// this is a private init method (hidden). The real init method raise an exception. Like a real init method
// here we call [super init]
- (id)initPrivate
{
    if (self = [super init]) {
        _backgroundSession = nil;
        _tasks = nil;
        _defaultFilePath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory , NSUserDomainMask, YES) lastObject];
        
        // load the tasks from preferences. Don't use to initialize _tasks since the returned object is immutable
        [self tasks];
        
        // create the session
        [self createSession];
    }
    return self;
}

// raise an exception
- (id)init {
    
    [NSException exceptionWithName:@"InvalidOperation" reason:@"Cannot invoke init on a Singleton class. Use sharedDownloader." userInfo:nil];
    return nil;
}

#pragma mark - Setters and Getters

/**
 This method lists all the downloads started.
 First, if _downloads is not set, it tries to unarchive a list of downloads from NSUserDefaults (list of download not completed). Then, if the list is empty, initialize a new NSMutableDictionary
 You should save the dictionary to NSUserDefaults with [self saveDownloads] every time an object is added or removed.
 */
-(NSDictionary *)tasks
{
    if (!_tasks)
    {
        NSDictionary *loadedDownload = nil;
        
        @try {
            NSData *downloadData = [[NSUserDefaults standardUserDefaults] objectForKey:kFLDownloadUserDefaultsObject];
            loadedDownload = [NSKeyedUnarchiver unarchiveObjectWithData:downloadData];
        }
        @catch (NSException *exception) {
            // clean NSUserDefaults
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:kFLDownloadUserDefaultsObject];
            [[NSUserDefaults standardUserDefaults] synchronize];
        }
        
        
        if (!loadedDownload || ![loadedDownload isKindOfClass:[NSDictionary class]])
        {
            _tasks = [NSMutableDictionary dictionary];
        } else {
            _tasks = [loadedDownload mutableCopy];
        }
    }
    
    return [[NSDictionary alloc] initWithDictionary:_tasks];
}


#pragma mark - Private Methods

-(void)createSession
{
    // ensure that the session identifier is unique adding the name of the application
    NSString *sessionIdentifier = [kFLDownloaderBackgroundSessionIdentifier stringByAppendingString:[[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"]];
    
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration backgroundSessionConfiguration:sessionIdentifier];
    configuration.HTTPMaximumConnectionsPerHost = 10;
    
    self.backgroundSession = [NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:[NSOperationQueue mainQueue]];
    
    // get a list of the downloadTasks associated to this session
    [self.backgroundSession getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {
        
        if ([downloadTasks count] > 0)
        {
            
            for (NSURLSessionDownloadTask *task in downloadTasks) {
                // there are outstanding tasks - reset the tasks dictionary
                // check if the tasks are correctly loaded from the saved dictionary, if there is some incongrouence delete the task
                
                FLDownloadTask *associatedTask = [_tasks objectForKey:task.originalRequest.URL];
                
                if (associatedTask)
                {
                    associatedTask.downloadTask = task;
                } else {
                    [task cancel];
                }
            }
            
            [self saveDownloads];
        } else {
            // restart outstanding tasks. Use a delay to permit the delivery of delegate messages if the app has been awaken by the system
            double delayInSeconds = 5.0;
            dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
            dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
                if ([_tasks count] > 0){
                    // if there are outstanding tasks not associated with a session, start them
                    // note: when the system wake up the app because a download have been finished
                    
                    for (FLDownloadTask *task in [_tasks allValues]) {
                        
                        NSURLRequest *request = [NSURLRequest requestWithURL:task.url];
                        
                        NSURLSessionDownloadTask *downloadTask = [self.backgroundSession downloadTaskWithRequest:request];
                        
                        task.downloadTask = downloadTask;
                    }
                }
                
            });
        }
    }];
}

/**
 Save the download list to the disk
 */
-(void)saveDownloads
{
    if ([self.tasks count] > 0)
    {
        NSData *notFinishedDownloads = [NSKeyedArchiver archivedDataWithRootObject:[_tasks copy]];
        
        [[NSUserDefaults standardUserDefaults] setObject:notFinishedDownloads forKey:kFLDownloadUserDefaultsObject];
       
        
    } else {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:kFLDownloadUserDefaultsObject];
    }
    
    [[NSUserDefaults standardUserDefaults] synchronize];
    
}

/**
 Obtain an URL from a NSURLSessionDownloadTask
 */
-(NSURL *)urlForNSURLSessionDownloadTask:(NSURLSessionDownloadTask *)task
{
    return task.originalRequest.URL;
}

-(NSString *)changeNameIfFileAtPathExists:(NSString *)filePathComplete
{
    // ------------------------------ FILENAME CHECK ------------------------------ //
    // First: check the filename. If exists, adds (01) ... (99) to the filename
    NSString *finalFilePath = filePathComplete;
    NSString *fileName = [finalFilePath lastPathComponent];
    NSString *fileNameWithoutExtension = [fileName stringByDeletingPathExtension];
    NSString *fileExtension = [fileName pathExtension];
    NSString *fileDirectory = [finalFilePath stringByDeletingLastPathComponent];
    NSString *thePoint = @".";
    
    // the main counter
    int counter = 0;
    
    // loop to increase the counter everytime an existent file is found
    while ([[NSFileManager defaultManager] fileExistsAtPath:finalFilePath]) {
        counter++;
        fileName = [NSString stringWithFormat:@"%@(%i)%@%@", fileNameWithoutExtension, counter, thePoint, fileExtension];
        finalFilePath = [fileDirectory stringByAppendingPathComponent:fileName];
    }
    
    return finalFilePath;
    // ---------------------------- FILENAME CHECK END ---------------------------- //
}

#pragma mark - Public methods

/**
 Create and return a download task for a given URL. If the download already task exists, simply returns it.
 */
-(FLDownloadTask *)downloadTaskForURL:(NSURL *)url
{
    return [self downloadTaskForURL:url withResumeData:nil];
}

-(FLDownloadTask *)downloadTaskForURL:(NSURL *)url withResumeData:(NSData *)data
{
    if ([self.tasks objectForKey:url])
        return [self.tasks objectForKey:url];
    
    FLDownloadTask *task = [[FLDownloadTask alloc] initPrivate];
    task.url = url;
    
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    
    NSURLSessionDownloadTask *downloadTask = nil;
    
    if (data)
    {
         downloadTask = [self.backgroundSession downloadTaskWithResumeData:data];
    }
    else
    {
         downloadTask = [self.backgroundSession downloadTaskWithRequest:request];
    }

    task.downloadTask = downloadTask;
    
    // add the task to the dictionary
    [_tasks setObject:task forKey:url];
    
    [self saveDownloads];
    
    return task;
}

-(BOOL)cancelDownloadTaskForURL:(NSURL *)url
{
    FLDownloadTask *task = [_tasks objectForKey:url];
    
    if (task)
    {
        [task cancelPrivate];
        [_tasks removeObjectForKey:url];
        [self saveDownloads];
        return YES;
    }
    
    return NO;
}

#pragma mark - NSURLSessionDelegate

/* The last message a session receives.  A session will only become
 * invalid because of a systemic error or when it has been
 * explicitly invalidated, in which case it will receive an
 * { NSURLErrorDomain, NSURLUserCanceled } error.
 */
- (void)URLSession:(NSURLSession *)session didBecomeInvalidWithError:(NSError *)error
{
    
}

/* If an application has received an
 * -application:handleEventsForBackgroundURLSession:completionHandler:
 * message, the session delegate will receive this message to indicate
 * that all messages previously enqueued for this session have been
 * delivered.  At this time it is safe to invoke the previously stored
 * completion handler, or to begin any internal updates that will
 * result in invoking the completion handler.
 */
- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session
{
    
}

#pragma mark - NSURLSessionDownloadDelegate

/* Sent when a download task that has completed a download.  The delegate should
 * copy or move the file at the given location to a new location as it will be
 * removed when the delegate message returns. URLSession:task:didCompleteWithError: will
 * still be called.
 */
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location
{
    FLDownloadTask *task = [self.tasks objectForKey:[self urlForNSURLSessionDownloadTask:downloadTask]];
    
    NSError *error = nil;
    
    NSString *finalLocation = [task.destinationDirectory stringByAppendingPathComponent:task.fileName];
    
    finalLocation = [self changeNameIfFileAtPathExists:finalLocation];
    
    NSString *locationString = [location path];
    
    NSLog(@"Moving: %@ to: %@", locationString, finalLocation);
    
    // move the file
    BOOL success = NO;
    
    if (locationString && finalLocation)
    {
        success = [[NSFileManager defaultManager] moveItemAtPath:locationString toPath:finalLocation error:&error];
    } else {
        @try {
            // if the finalLocation is nil, maybe the default filename is not ok. Use a default one
            finalLocation = [task.destinationDirectory stringByAppendingPathComponent:@"file"];
            success = [[NSFileManager defaultManager] moveItemAtPath:locationString toPath:finalLocation error:&error];
        }
        @catch (NSException *exception) {
            NSLog(@"Error moving file after task finished: source or destination is nil");
        }
    }
    
    // remove the task
    [_tasks removeObjectForKey:task.url];
    [self saveDownloads];
    
    if (!success)
    {
        NSLog(@"Error moving file: %@ to destination %@. Error: %@", locationString, finalLocation, error.description);
        if (task.completionBlock)
            task.completionBlock(NO, error);
    } else {
        if (task.completionBlock)
            task.completionBlock(YES, nil);
        
        NSLog(@"File moved to: %@", finalLocation);
    }

}

/* Sent periodically to notify the delegate of download progress. */
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    FLDownloadTask *task = [self.tasks objectForKey:[self urlForNSURLSessionDownloadTask:downloadTask]];
    
    if (task.progressBlock)
        task.progressBlock(downloadTask.originalRequest.URL, bytesWritten, totalBytesWritten, totalBytesExpectedToWrite);
}

/* Sent when a download has been resumed. If a download failed with an
 * error, the -userInfo dictionary of the error will contain an
 * NSURLSessionDownloadTaskResumeData key, whose value is the resume
 * data.
 */
- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes
{
    
}

#pragma mark - NSURLSessionTaskDelegate

/**
 WARNING: even if this method is marked as optional, not implementing it will cause a BAD ACCESS on invalidateAndCancel on a session with outstanding tasks
 */
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{
    NSLog(@"Session %@ with task %@ finished with error %@", session, task, error);
    
    if (error)
    {
        // check if resume data are available
        if ([error.userInfo objectForKey:NSURLSessionDownloadTaskResumeData])
        {
            NSData *resumeData = [error.userInfo objectForKey:NSURLSessionDownloadTaskResumeData];
            NSString *urlString = [error.userInfo objectForKey:NSURLErrorFailingURLStringErrorKey];
            
            if ([self.tasks objectForKey:[NSURL URLWithString:urlString]])
            {
                FLDownloadTask *task = [self.tasks objectForKey:[NSURL URLWithString:urlString]];
                task.downloadTask = [self.backgroundSession downloadTaskWithResumeData:resumeData];
                [task start];
            }
            
        }
            
    }
}



@end
