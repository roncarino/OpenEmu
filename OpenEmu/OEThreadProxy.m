/*
 Copyright (c) 2013, OpenEmu Team
 
 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:
     * Redistributions of source code must retain the above copyright
       notice, this list of conditions and the following disclaimer.
     * Redistributions in binary form must reproduce the above copyright
       notice, this list of conditions and the following disclaimer in the
       documentation and/or other materials provided with the distribution.
     * Neither the name of the OpenEmu Team nor the
       names of its contributors may be used to endorse or promote products
       derived from this software without specific prior written permission.
 
 THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
 EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
 DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
 DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
  LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
 ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
  SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "OEThreadProxy.h"

@implementation OEProxy
{
    CFMutableDictionaryRef _cachedMethodSignatures;
@protected
    id _target;
}

+ (id)proxyWithTarget:(id)target;
{
    return [[self alloc] initWithTarget:target];
}

- (id)initWithTarget:(id)target;
{
    _cachedMethodSignatures = CFDictionaryCreateMutable(NULL, 0, NULL, &kCFTypeDictionaryValueCallBacks);
    _target = target;
    return self;
}

- (NSString *)description
{
    return [NSString stringWithFormat:@"<%s %p, target: %@>", object_getClassName(self), self, _target];
}

- (void)dealloc
{
    CFRelease(_cachedMethodSignatures);
}

- (BOOL)respondsToSelector:(SEL)aSelector
{
    return [_target respondsToSelector:aSelector] || [super respondsToSelector:aSelector];
}

- (id)forwardingTargetForSelector:(SEL)aSelector
{
    return _target;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel
{
    NSMethodSignature *signature = (__bridge NSMethodSignature *)CFDictionaryGetValue(_cachedMethodSignatures, sel);

    if(signature != nil)
        return signature;

    if([_target respondsToSelector:sel])
        signature = [_target methodSignatureForSelector:sel];

    if(signature == nil)
        signature = [super methodSignatureForSelector:sel];

    if(signature != nil)
        CFDictionaryAddValue(_cachedMethodSignatures, sel, (__bridge void *)signature);

    return signature;
}

- (void)forwardInvocation:(NSInvocation *)invocation
{
    [invocation setTarget:_target];
    [invocation invoke];
}

@end

@implementation OELoggingProxy

- (id)forwardingTargetForSelector:(SEL)aSelector
{
    DLog(@"Calling %@ on %@", NSStringFromSelector(aSelector), _target);
    return _target;
}

@end

@interface NSMethodSignature (OEMethodSignatureAdditions)
- (NSString *)OE_methodArgumentTypes;
- (NSUInteger)OE_numberOfBlockArguments;
@end

@implementation NSMethodSignature (OEMethodSignatureAdditions)

- (NSString *)OE_methodArgumentTypes
{
    NSMutableString *result = [NSMutableString stringWithUTF8String:[self methodReturnType]];
    for(NSUInteger i = 0, count = [self numberOfArguments]; i < count; i++)
        [result appendFormat:@"%s", [self getArgumentTypeAtIndex:i]];

    return result;
}

- (NSUInteger)OE_numberOfBlockArguments
{
    NSUInteger argumentCount = 0;
    for(NSUInteger i = 0, count = [self numberOfArguments]; i < count; i++)
    {
        const char *argumentType = [self getArgumentTypeAtIndex:i];
        if(argumentType[0] == '@' && argumentType[1] == '?')
            argumentCount++;
    }

    return argumentCount;
}

@end

@implementation OEThreadProxy

+ (id)threadProxyWithTarget:(id)target thread:(NSThread *)thread;
{
    return [[self alloc] initWithTarget:target thread:thread];
}

- (id)initWithTarget:(id)target
{
    return [self initWithTarget:target thread:[[NSThread alloc] init]];
}

- (id)initWithTarget:(id)target thread:(NSThread *)thread
{
    if((self = [super initWithTarget:target]))
        _thread = thread;

    return self;
}

- (id)forwardingTargetForSelector:(SEL)aSelector
{
    if([NSThread currentThread] == _thread)
    {
        NSLog(@"Will fast invoke: %@ with target: %@", _target, NSStringFromSelector(aSelector));
        return _target;
    }

    return nil;
}

- (void)forwardInvocation:(NSInvocation *)invocation
{
    if(![_target respondsToSelector:[invocation selector]])
        return;

    if([NSThread currentThread] == _thread)
        [invocation invokeWithTarget:_target];
    else
    {
        // We send the message to the background thread, which means
        // we will execute the method asynchronously. This requires
        // copying all stack block arguments to the heap or else
        // they will be deallocated before the background thread
        // can execute them.
        NSMethodSignature *signature = [invocation methodSignature];
        NSUInteger argCount = [signature numberOfArguments];

        // Keep track of the blocks we copied, after we told the
        // NSInvocation to retain the arguments we will have to
        // send release to the argument to balance our own copy.
#define BLOCK_ARGUMENTS_MAX_COUNT 8
        void *argumentsToRelease[BLOCK_ARGUMENTS_MAX_COUNT] = { NULL };
        NSUInteger argumentsToReleaseCount = 0;

        for(NSUInteger argIndex = 2; argIndex < argCount; argIndex++)
        {
            const char *type = [signature getArgumentTypeAtIndex:argIndex];
            if(type[0] == '@' && type[1] == '?')
            {
                void *argument = nil;
                [invocation getArgument:&argument atIndex:argIndex];
                if(argument == NULL) continue;

                extern const char *_Block_dump(const void *block);

                // Copy the block argument to the heap.
                argument = _Block_copy(argument);
                [invocation setArgument:&argument atIndex:argIndex];

                // Keep the argument pointer to be released later.
                NSAssert(argumentsToReleaseCount < BLOCK_ARGUMENTS_MAX_COUNT, @"There are more block arguments %ld for selector %@ signature %@ than the handled limit %d", [signature OE_numberOfBlockArguments], NSStringFromSelector([invocation selector]), [signature OE_methodArgumentTypes], BLOCK_ARGUMENTS_MAX_COUNT);
                argumentsToRelease[argumentsToReleaseCount++] = argument;
            }
        }

        // Retain the arguments, the invocation has to be executed on another thread.
        [invocation retainArguments];

        // Balance the _Block_copy done in the loop.
        for(NSUInteger i = 0; i < argumentsToReleaseCount; i++)
            _Block_release(argumentsToRelease[i]);

        [invocation performSelector:@selector(invokeWithTarget:) onThread:_thread withObject:_target waitUntilDone:NO];
    }
}

@end
