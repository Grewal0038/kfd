#import "boot_info.h"
#import "launchctl.h"
#import <Foundation/Foundation.h>
#import <spawn.h>

int main(int argc, char *argv[]) {
  NSLog(@"[jbinit] Hello, World!");
  int ret = launchctl_load(
      prebootPath(@"basebin/LaunchDaemons/kr.h4ck.jailbreakd.plist")
          .fileSystemRepresentation,
      false);
  NSLog(@"[jbinit] launchctl_load ret: %d\n", ret);

  return 0;
}