# Dynamic P2P Configuration for QEMU NVMe

## Problem
Currently, the NVMe device tries to find and bind to the GPU during device realization (startup), which causes:
1. Device ordering dependencies (GPU must exist before NVMe)
2. GPU reset issues if NVMe initialization fails
3. No way to defer P2P setup until VM is running

## Solution: Post-Boot P2P Configuration

---

## Approach 1: QMP Command (Recommended)

Use QEMU Monitor Protocol to bind GPU after VM is fully booted.

### Implementation

**Add QMP command in `hw/nvme/ctrl.c`:**

```c
void qmp_nvme_set_p2p_gpu(const char *nvme_id, const char *gpu_id, Error **errp)
{
    Object *obj;
    NvmeCtrl *n;
    
    /* Find NVMe device */
    obj = object_resolve_path_type(nvme_id, TYPE_NVME, NULL);
    if (!obj) {
        error_setg(errp, "NVMe device '%s' not found", nvme_id);
        return;
    }
    
    n = NVME(obj);
    
    /* Check if already configured */
    if (n->p2p.enabled) {
        error_setg(errp, "P2P already enabled for this NVMe device");
        return;
    }
    
    /* Store GPU ID and initialize P2P */
    n->p2p.gpu_id = g_strdup(gpu_id);
    
    if (!nvme_p2p_init(n, errp)) {
        g_free(n->p2p.gpu_id);
        n->p2p.gpu_id = NULL;
        return;
    }
    
    info_report("NVMe P2P: Successfully bound %s to GPU %s", nvme_id, gpu_id);
}
```

**Add to `qapi/block-core.json`:**

```json
##
# @nvme-set-p2p-gpu:
#
# Bind an NVMe device to a VFIO GPU for P2P DMA
#
# @nvme-id: the NVMe device identifier
# @gpu-id: the VFIO GPU device identifier
#
# Since: 10.1
##
{ 'command': 'nvme-set-p2p-gpu',
  'data': { 'nvme-id': 'str', 'gpu-id': 'str' } }
```

### Usage

**1. Start VM without P2P:**
```bash
qemu-system-x86_64 \
  -device vfio-pci,id=gpu0,host=10:00.0 \
  -device nvme,id=nvme0,serial=test01 \
  -qmp unix:/tmp/qmp.sock,server,nowait \
  ...
```

**2. After VM boots, configure P2P via QMP:**
```bash
echo '{ "execute": "qmp_capabilities" }' | socat - /tmp/qmp.sock
echo '{ "execute": "nvme-set-p2p-gpu", "arguments": { "nvme-id": "nvme0", "gpu-id": "gpu0" } }' | socat - /tmp/qmp.sock
```

**Advantages:**
- ✅ No device ordering issues
- ✅ Clean error handling without GPU reset
- ✅ Standard QEMU management interface
- ✅ Can enable/disable P2P dynamically

**Disadvantages:**
- ⚠️ Requires QMP infrastructure
- ⚠️ Two-step setup process

---

## Approach 2: Lazy Initialization on First Access

Defer P2P setup until the guest actually requests it.

### Implementation

**Modify `nvme_p2p_init()` signature:**

```c
/* Make this callable at any time, not just during realize */
bool nvme_p2p_init_deferred(NvmeCtrl *n, Error **errp)
{
    /* Same logic as nvme_p2p_init(), but can be called later */
    if (n->p2p.enabled) {
        return true;  /* Already initialized */
    }
    
    /* ... rest of init logic ... */
}
```

**Trigger from vendor-specific admin command:**

```c
static uint16_t nvme_admin_cmd_get_p2p_info(NvmeCtrl *n, NvmeRequest *req)
{
    NvmeP2PIovaInfo info;
    Error *local_err = NULL;
    
    /* Initialize P2P on first access if not already done */
    if (!n->p2p.enabled && n->p2p.gpu_id) {
        if (!nvme_p2p_init_deferred(n, &local_err)) {
            error_report_err(local_err);
            return NVME_INTERNAL_DEV_ERROR;
        }
    }
    
    if (!nvme_p2p_get_iova_info(n, &info)) {
        return NVME_INVALID_FIELD | NVME_DNR;
    }
    
    return nvme_c2h(n, (uint8_t *)&info, sizeof(info), req);
}
```

**VM startup:**
```bash
qemu-system-x86_64 \
  -device vfio-pci,id=gpu0,host=10:00.0 \
  -device nvme,id=nvme0,serial=test01,p2p-gpu=gpu0 \
  ...
```

- P2P property is set, but initialization is deferred
- When guest sends vendor admin command, P2P initializes then
- If it fails, guest gets error but VM stays up and GPU is safe

**Advantages:**
- ✅ Simple device configuration
- ✅ Automatic initialization when needed
- ✅ Safe error handling after boot

**Disadvantages:**
- ⚠️ Hidden complexity (non-obvious when P2P actually initializes)
- ⚠️ First command slower due to initialization

---

## Approach 3: Auto-Discovery (No GPU ID Required)

Let the NVMe device automatically discover available VFIO GPUs.

### Implementation

```c
static VFIOPCIDevice *nvme_p2p_find_gpu(Error **errp)
{
    Object *root, *obj;
    ObjectPropertyIterator iter;
    VFIOPCIDevice *first_gpu = NULL;
    
    root = object_get_root();
    object_property_iter_init(&iter, root);
    
    /* Walk QOM tree looking for VFIO PCI devices */
    while ((obj = object_property_iter_next(&iter)) != NULL) {
        if (object_dynamic_cast(obj, TYPE_VFIO_PCI_BASE)) {
            VFIOPCIDevice *vdev = VFIO_PCI_BASE(obj);
            PCIDevice *pdev = &vdev->pdev;
            
            /* Check if it's an AMD GPU (vendor 0x1002) */
            if (pci_get_word(pdev->config + PCI_VENDOR_ID) == 0x1002) {
                uint8_t class_code = pci_get_byte(pdev->config + PCI_CLASS_DEVICE);
                
                if (class_code == 0x03) {  /* VGA/Display controller */
                    first_gpu = vdev;
                    break;
                }
            }
        }
    }
    
    if (!first_gpu) {
        error_setg(errp, "No AMD GPU found in VFIO passthrough");
        return NULL;
    }
    
    return first_gpu;
}

bool nvme_p2p_init(NvmeCtrl *n, Error **errp)
{
    if (!n->p2p.enable_autodiscovery) {
        return true;
    }
    
    /* Auto-discover GPU */
    n->p2p.gpu_dev = nvme_p2p_find_gpu(errp);
    if (!n->p2p.gpu_dev) {
        return false;
    }
    
    /* ... rest of P2P initialization ... */
}
```

**VM startup:**
```bash
qemu-system-x86_64 \
  -device vfio-pci,host=10:00.0 \
  -device nvme,id=nvme0,serial=test01,p2p-auto=on \
  ...
```

**Advantages:**
- ✅ Zero configuration required
- ✅ Works with any AMD GPU passthrough

**Disadvantages:**
- ⚠️ No control over which GPU if multiple exist
- ⚠️ Still has device ordering dependency

---

## Approach 4: HMP Command (Simplest for Testing)

Use QEMU's Human Monitor Protocol for quick testing.

### Implementation

**Add HMP handler in `hw/nvme/ctrl.c`:**

```c
void hmp_nvme_set_p2p_gpu(Monitor *mon, const QDict *qdict)
{
    const char *nvme_id = qdict_get_str(qdict, "nvme-id");
    const char *gpu_id = qdict_get_str(qdict, "gpu-id");
    Error *local_err = NULL;
    
    qmp_nvme_set_p2p_gpu(nvme_id, gpu_id, &local_err);
    
    if (local_err) {
        error_report_err(local_err);
    } else {
        monitor_printf(mon, "P2P enabled: %s <-> %s\n", nvme_id, gpu_id);
    }
}
```

**Add to `hmp-commands.hx`:**

```c
{
    .name       = "nvme_set_p2p_gpu",
    .args_type  = "nvme-id:s,gpu-id:s",
    .params     = "nvme-id gpu-id",
    .help       = "bind NVMe device to VFIO GPU for P2P",
    .cmd        = hmp_nvme_set_p2p_gpu,
}
```

### Usage

**Start QEMU with monitor:**
```bash
qemu-system-x86_64 \
  -device vfio-pci,id=gpu0,host=10:00.0 \
  -device nvme,id=nvme0,serial=test01 \
  -monitor stdio \
  ...
```

**In QEMU monitor:**
```
(qemu) nvme_set_p2p_gpu nvme0 gpu0
P2P enabled: nvme0 <-> gpu0
```

**Advantages:**
- ✅ Easiest to implement for testing
- ✅ Interactive control
- ✅ Can be scripted

**Disadvantages:**
- ⚠️ Not suitable for production
- ⚠️ Requires console access

---

## Recommended Implementation Strategy

### Phase 1: Quick Testing (HMP)
1. Add simple HMP command for immediate testing
2. Validate IOVA mapping works without device ordering issues
3. Confirm GPU survives failed initialization

### Phase 2: Production (QMP + Lazy Init)
1. Implement proper QMP command
2. Add lazy initialization on first vendor command
3. Support both explicit binding and auto-discovery

### Phase 3: Enhanced (Multiple GPUs)
1. Support multiple GPU bindings
2. GPU selection by PCI address
3. Runtime P2P teardown/rebinding

---

## Next Steps

1. **Choose approach** for initial testing (recommend HMP for speed)
2. **Implement P2P unbinding** in `nvme_exit()` (already done)
3. **Test with dynamic binding** after VM boot
4. **Verify GPU survives** failed P2P initialization

This approach completely sidesteps the device ordering problem and makes GPU passthrough much safer!

