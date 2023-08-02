//
//  thanks_opa334dev_htrowii.m
//  kfd
//
//  Created by Seo Hyun-gyu on 2023/07/30.
//

#import <Foundation/Foundation.h>
#import <sys/mman.h>
#import <UIKit/UIKit.h>
#import "krw.h"
#import "proc.h"

#define FLAGS_PROT_SHIFT    7
#define FLAGS_MAXPROT_SHIFT 11
//#define FLAGS_PROT_MASK     0xF << FLAGS_PROT_SHIFT
//#define FLAGS_MAXPROT_MASK  0xF << FLAGS_MAXPROT_SHIFT
#define FLAGS_PROT_MASK    0x780
#define FLAGS_MAXPROT_MASK 0x7800

uint64_t getTask(void) {
    uint64_t proc = getProc(getpid());
    uint64_t proc_ro = kread64(proc + 0x18);
    uint64_t pr_task = kread64(proc_ro + 0x8);
    printf("[i] self proc->proc_ro->pr_task: 0x%llx\n", pr_task);
    return pr_task;
}

uint64_t kread_ptr(uint64_t kaddr) {
    uint64_t ptr = kread64(kaddr);
    if ((ptr >> 55) & 1) {
        return ptr | 0xFFFFFF8000000000;
    }

    return ptr;
}

void kreadbuf(uint64_t kaddr, void* output, size_t size)
{
    uint64_t endAddr = kaddr + size;
    uint32_t outputOffset = 0;
    unsigned char* outputBytes = (unsigned char*)output;
    
    for(uint64_t curAddr = kaddr; curAddr < endAddr; curAddr += 4)
    {
        uint32_t k = kread32(curAddr);

        unsigned char* kb = (unsigned char*)&k;
        for(int i = 0; i < 4; i++)
        {
            if(outputOffset == size) break;
            outputBytes[outputOffset] = kb[i];
            outputOffset++;
        }
        if(outputOffset == size) break;
    }
}

uint64_t vm_map_get_header(uint64_t vm_map_ptr)
{
    return vm_map_ptr + 0x10;
}

uint64_t vm_map_header_get_first_entry(uint64_t vm_header_ptr)
{
    return kread_ptr(vm_header_ptr + 0x8);
}

uint64_t vm_map_entry_get_next_entry(uint64_t vm_entry_ptr)
{
    return kread_ptr(vm_entry_ptr + 0x8);
}


uint32_t vm_header_get_nentries(uint64_t vm_header_ptr)
{
    return kread32(vm_header_ptr + 0x20);
}

void vm_entry_get_range(uint64_t vm_entry_ptr, uint64_t *start_address_out, uint64_t *end_address_out)
{
    uint64_t range[2];
    kreadbuf(vm_entry_ptr + 0x10, &range[0], sizeof(range));
    if (start_address_out) *start_address_out = range[0];
    if (end_address_out) *end_address_out = range[1];
}


//void vm_map_iterate_entries(uint64_t vm_map_ptr, void (^itBlock)(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop))
void vm_map_iterate_entries(uint64_t vm_map_ptr, void (^itBlock)(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop))
{
    uint64_t header = vm_map_get_header(vm_map_ptr);
    uint64_t entry = vm_map_header_get_first_entry(header);
    uint64_t numEntries = vm_header_get_nentries(header);

    while (entry != 0 && numEntries > 0) {
        uint64_t start = 0, end = 0;
        vm_entry_get_range(entry, &start, &end);

        BOOL stop = NO;
        itBlock(start, end, entry, &stop);
        if (stop) break;

        entry = vm_map_entry_get_next_entry(entry);
        numEntries--;
    }
}

uint64_t vm_map_find_entry(uint64_t vm_map_ptr, uint64_t address)
{
    __block uint64_t found_entry = 0;
        vm_map_iterate_entries(vm_map_ptr, ^(uint64_t start, uint64_t end, uint64_t entry, BOOL *stop) {
            if (address >= start && address < end) {
                found_entry = entry;
                *stop = YES;
            }
        });
        return found_entry;
}

void vm_map_entry_set_prot(uint64_t entry_ptr, vm_prot_t prot, vm_prot_t max_prot)
{
    uint64_t flags = kread64(entry_ptr + 0x48);
    uint64_t new_flags = flags;
    new_flags = (new_flags & ~FLAGS_PROT_MASK) | ((uint64_t)prot << FLAGS_PROT_SHIFT);
    new_flags = (new_flags & ~FLAGS_MAXPROT_MASK) | ((uint64_t)max_prot << FLAGS_MAXPROT_SHIFT);
    if (new_flags != flags) {
        kwrite64(entry_ptr + 0x48, new_flags);
    }
}

uint64_t start = 0, end = 0;

uint64_t task_get_vm_map(uint64_t task_ptr)
{
    return kread_ptr(task_ptr + 0x28);
}

#pragma mark overwrite2
uint64_t funVnodeOverwrite2(char* to, char* from) {
    printf("attempting opa's method\n");
    printf("writing to %s", to);
    int to_file_index = open(to, O_RDONLY);
    if (to_file_index == -1)  {
        printf("to file nonexistent\n)");
        return -1;
    }
    
    off_t to_file_size = lseek(to_file_index, 0, SEEK_END);
    
    printf(" from %s\n", from);
    int from_file_index = open(from, O_RDONLY);
    if (from_file_index == -1) return -1;
    off_t from_file_size = lseek(from_file_index, 0, SEEK_END);
    
    
    if(to_file_size < from_file_size) {
        close(from_file_index);
        close(to_file_index);
        printf("[-] File is too big to overwrite!\n");
        return -1;
    }

    //mmap as read only
    printf("mmap as readonly\n");
    char* to_file_data = mmap(NULL, to_file_size, PROT_READ, MAP_SHARED, to_file_index, 0);
    if (to_file_data == MAP_FAILED) {
        close(to_file_index);
        // Handle error mapping source file
        return 0;
    }
    
    // set prot to re-
    printf("task_get_vm_map -> vm ptr\n");
    uint64_t vm_ptr = task_get_vm_map(getTask());
    uint64_t entry_ptr = vm_map_find_entry(vm_ptr, (uint64_t)to_file_data);
    printf("set prot to rw-\n");
    vm_map_entry_set_prot(entry_ptr, PROT_READ | PROT_WRITE, PROT_READ | PROT_WRITE);
    
    char* from_file_data = mmap(NULL, from_file_size, PROT_READ, MAP_PRIVATE, from_file_index, 0);
    if (from_file_data == MAP_FAILED) {
        perror("[-] Failed mmap (from_mapped)");
        close(from_file_index);
        close(to_file_index);
        return -1;
    }
    
    printf("it is writable!!\n");
    memcpy(to_file_data, from_file_data, from_file_size);

    // Cleanup
    munmap(from_file_data, from_file_size);
    munmap(to_file_data, to_file_size);
    
    close(from_file_index);
    close(to_file_index);

    // Return success or error code
    return 0;
}

uint64_t funVnodeOverwriteWithBytes(const char* filename, off_t file_offset, const void* overwrite_data, size_t overwrite_length, bool unmapAtEnd) {
    printf("attempting opa's method\n");
    int file_index = open(filename, O_RDONLY);
    if (file_index == -1) return -1;
    off_t file_size = lseek(file_index, 0, SEEK_END);
    
    if (file_size < file_offset + overwrite_length) {
        close(file_index);
        printf("[-] Offset + length is beyond the file size!\n");
        return -1;
    }
    
//     mmap as read-write
    printf("mmap as read only\n");
    char* file_data = mmap(NULL, file_size, PROT_READ, MAP_PRIVATE, file_index, 0);
    if (file_data == MAP_FAILED) {
        printf("failed mmap...\n try again");
        close(file_index);
        // Handle error mapping the file
        return -1;
    }
    
    printf("task_get_vm_map -> vm ptr\n");
    uint64_t task_ptr = getTask();
    uint64_t vm_ptr = task_get_vm_map(task_ptr);
    printf("entry_ptr\n");
    uint64_t entry_ptr = vm_map_find_entry(vm_ptr, (uint64_t)file_data);
    printf("set prot to rw-\n");
    vm_map_entry_set_prot(entry_ptr, PROT_READ | PROT_WRITE, PROT_READ | PROT_WRITE);
    
    printf("Writing data at offset %lld\n", file_offset);
    memcpy(file_data + file_offset, overwrite_data, overwrite_length);
    
//    if (unmapAtEnd) {
        munmap(file_data, file_size);
        close(file_index);
//    }

    return 1;
}

uint64_t funVnodeOverwriteTccdPlist(char* path) {
    const char* plistFilePath = "/System/Library/LaunchDaemons/com.apple.tccd.plist";
    const char* oldString = "/System/Library/PrivateFrameworks/TCC.framework/Support/tccd";
    const char* newString = path;
    // Open the plist file for reading
    printf("opening plist file\n");
    FILE* file = fopen(plistFilePath, "r");
    if (!file) {
        fprintf(stderr, "Failed to open the property list file.\n");
        return 1;
    }
    // Find the file size
    fseek(file, 0, SEEK_END);
    long fileSize = ftell(file);
    fseek(file, 0, SEEK_SET);
    // Allocate memory to store the content
    char* content = (char*)malloc(fileSize + 1); // Add 1 for null terminator
    if (!content) {
        fprintf(stderr, "Memory allocation failed.\n");
        fclose(file);
        return 1;
    }
    // Read the content of the plist file
    size_t bytesRead = fread(content, 1, fileSize, file);
    fclose(file);
    if (bytesRead != (size_t)fileSize) {
        fprintf(stderr, "Error while reading the property list file.\n");
        free(content);
        return 1;
    }
    content[fileSize] = '\0'; // Null-terminate the content
    // Find the position of the old string in the content
    char* position = strstr(content, oldString);
    if (!position) {
        fprintf(stderr, "The old string was not found in the property list.\n");
        free(content);
        return 1;
    }
    // Calculate the offset of the old string within the file
    off_t oldStringOffset = position - content;
    // Write the new string into the plist file using the provided function
    printf("overwriting tccd plist with bytes\n");
    uint64_t result = funVnodeOverwriteWithBytes(plistFilePath, oldStringOffset, newString, strlen(newString), true);
    if (result != 0) {
        fprintf(stderr, "Failed to overwrite the old string with the new string.\n");
        free(content);
        return 1;
    }
    // Free dynamically allocated memory
    free(content);
    printf("Property list file successfully modified.\n");
    return 0;
}
