/* muxq.c — read-only NVKMS mux probe for the AERO X16.
 *
 * Opens /dev/nvidia-modeset, allocates an NVKMS device for the dGPU,
 * queries each disp for mux-capable dpys, and reads mux state.
 * Optionally exercises the DRM GRANT_PERMISSIONS (sub-owner) path
 * that a future SWITCH_MUX client would need.
 *
 * Build: see build.sh next to this file.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <sys/ioctl.h>
#include <drm/drm.h>

#include "nvtypes.h"
#include "nvkms-ioctl.h"
#include "nvkms-api.h"
#include "nvUnixVersion.h"
#include "nv_drm_common_ioctl.h"

static int kms_ioctl(int fd, NvU32 cmd, void *params, NvU32 size)
{
    struct NvKmsIoctlParams p = {
        .cmd = cmd,
        .size = size,
        .address = (NvU64)(uintptr_t)params,
    };
    return ioctl(fd, NVKMS_IOCTL_IOWR, &p);
}

static void dump_dpylist(const char *name, NVDpyIdList list)
{
    NVDpyId d;
    int n = 0;
    printf("  %-10s mask=0x%08x :", name, nvDpyIdListToNvU32(list));
    FOR_ALL_DPY_IDS(d, list) {
        printf(" " NV_DPY_ID_PRINT_FORMAT, nvDpyIdToNvU32(d));
        n++;
    }
    if (!n) printf(" (none)");
    printf("\n");
}

int main(int argc, char **argv)
{
    int kms = open("/dev/nvidia-modeset", O_RDWR | O_CLOEXEC);
    if (kms < 0) {
        perror("open /dev/nvidia-modeset");
        return 1;
    }

    /* 1. ALLOC_DEVICE — find the GPU by probing rmDeviceIds */
    struct NvKmsAllocDeviceParams ap;
    int dev_ok = -1;
    for (NvU32 id = 0; id < 8 && dev_ok < 0; id++) {
        memset(&ap, 0, sizeof(ap));
        snprintf(ap.request.versionString,
                 sizeof(ap.request.versionString), "%s", NV_VERSION_STRING);
        ap.request.deviceId.rmDeviceId = id;
        ap.request.enableConsoleHotplugHandling = TRUE;
        if (kms_ioctl(kms, NVKMS_IOCTL_ALLOC_DEVICE, &ap, sizeof(ap)) == 0 &&
            ap.reply.status == NVKMS_ALLOC_DEVICE_STATUS_SUCCESS)
            dev_ok = id;
    }
    if (dev_ok < 0) {
        fprintf(stderr, "ALLOC_DEVICE failed for rmDeviceId 0..7 "
                "(last status=%d, errno=%d)\n", ap.reply.status, errno);
        return 1;
    }
    printf("device: rmDeviceId=%d handle=0x%x subDevMask=0x%x numDisps=%u numHeads=%u\n",
           dev_ok, ap.reply.deviceHandle, ap.reply.subDeviceMask,
           ap.reply.numDisps, ap.reply.numHeads);

    /* 2. QUERY_DISP per disp — muxDpys is the money field */
    NVDpyIdList allMux = nvEmptyDpyIdList();
    NvKmsDispHandle muxDisp = 0;
    for (NvU32 d = 0; d < ap.reply.numDisps; d++) {
        struct NvKmsQueryDispParams q;
        memset(&q, 0, sizeof(q));
        q.request.deviceHandle = ap.reply.deviceHandle;
        q.request.dispHandle = ap.reply.dispHandles[d];
        if (kms_ioctl(kms, NVKMS_IOCTL_QUERY_DISP, &q, sizeof(q)) != 0) {
            printf("disp %u: QUERY_DISP failed errno=%d\n", d, errno);
            continue;
        }
        printf("disp %u (handle=0x%x) connectors=%u gpu='%s'\n",
               d, ap.reply.dispHandles[d], q.reply.numConnectors,
               q.reply.gpuString);
        dump_dpylist("valid",  q.reply.validDpys);
        dump_dpylist("boot",   q.reply.bootDpys);
        dump_dpylist("mux",    q.reply.muxDpys);
        allMux = nvAddDpyIdListToDpyIdList(allMux, q.reply.muxDpys);
        if (!nvDpyIdListIsEmpty(q.reply.muxDpys) && !muxDisp)
            muxDisp = ap.reply.dispHandles[d];
    }

    if (nvDpyIdListIsEmpty(allMux)) {
        printf("\nresult: NO mux-capable displays — DFP_INIT_MUX_DATA did not "
               "succeed for any dpy.\n"
               "This is the gate that needs ACPI EDID + GSP mux support.\n");
        return 2;
    }

    /* 3. GET_MUX_STATE for each mux dpy (no permission needed) */
    NVDpyId dpy;
    FOR_ALL_DPY_IDS(dpy, allMux) {
        struct NvKmsGetMuxStateParams g;
        memset(&g, 0, sizeof(g));
        g.request.deviceHandle = ap.reply.deviceHandle;
        g.request.dispHandle = muxDisp;
        g.request.dpyId = dpy;
        if (kms_ioctl(kms, NVKMS_IOCTL_GET_MUX_STATE, &g, sizeof(g)) == 0)
            printf("mux dpy " NV_DPY_ID_PRINT_FORMAT " state=%u "
                   "(1=integrated 2=discrete)\n",
                   nvDpyIdToNvU32(dpy), g.reply.state);
        else
            printf("mux dpy " NV_DPY_ID_PRINT_FORMAT
                   " GET_MUX_STATE failed errno=%d\n",
                   nvDpyIdToNvU32(dpy), errno);
    }

    /* 4. Try the sub-owner permission path via DRM master on the nvidia card.
     * Find the DRM card bound to the nvidia driver. */
    for (int c = 0; c < 8; c++) {
        char path[64], drv[128];
        snprintf(path, sizeof(path), "/dev/dri/card%d", c);
        char link[256];
        snprintf(link, sizeof(link), "/sys/class/drm/card%d/device/driver", c);
        ssize_t l = readlink(link, drv, sizeof(drv) - 1);
        if (l < 0) continue;
        drv[l] = 0;
        if (!strstr(drv, "nvidia")) continue;

        int drm = open(path, O_RDWR | O_CLOEXEC);
        if (drm < 0) { perror(path); continue; }
        if (ioctl(drm, DRM_IOCTL_SET_MASTER, 0) != 0 && errno != EINVAL) {
            printf("%s: SET_MASTER failed errno=%d (master held elsewhere?)\n",
                   path, errno);
            close(drm);
            continue;
        }
        printf("%s: DRM master acquired\n", path);

        FOR_ALL_DPY_IDS(dpy, allMux) {
            struct drm_nvidia_grant_permissions_params gp = {
                .fd = kms,
                .dpyId = nvDpyIdToNvU32(dpy),
                .type = NV_DRM_PERMISSIONS_TYPE_SUB_OWNER,
            };
            if (ioctl(drm, DRM_IOCTL_NVIDIA_GRANT_PERMISSIONS, &gp) == 0)
                printf("  SUB_OWNER granted for dpy " NV_DPY_ID_PRINT_FORMAT
                       " — SWITCH_MUX is callable on this kms fd\n",
                       nvDpyIdToNvU32(dpy));
            else
                printf("  GRANT_PERMISSIONS dpy " NV_DPY_ID_PRINT_FORMAT
                       " failed errno=%d\n", nvDpyIdToNvU32(dpy), errno);
        }
        close(drm);
        break;
    }
    return 0;
}
