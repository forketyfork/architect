#include "libproc.h"
#include <libproc.h>
#include <sys/proc_info.h>

#include <string.h>

int architect_proc_pid_cwd(int pid, char *buffer, unsigned long buffer_size) {
    if (buffer == NULL || buffer_size == 0) return -1;

    struct proc_vnodepathinfo vnode_info = {0};
    const int result = proc_pidinfo(
        pid,
        PROC_PIDVNODEPATHINFO,
        0,
        &vnode_info,
        sizeof(vnode_info)
    );
    if (result <= 0) return result;

    const char *path = vnode_info.pvi_cdir.vip_path;
    const size_t path_capacity = sizeof(vnode_info.pvi_cdir.vip_path);
    size_t path_length = 0;
    while (path_length < path_capacity && path[path_length] != '\0') {
        path_length += 1;
    }

    if (path_length == path_capacity || path_length >= buffer_size) {
        return ARCHITECT_PROC_CWD_BUFFER_TOO_SMALL;
    }

    memcpy(buffer, path, path_length);
    buffer[path_length] = '\0';
    return (int)path_length;
}
